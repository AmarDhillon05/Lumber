// Prompt → knob values with Claude (Anthropic Messages API), called directly
// from the phone with the user's own API key over plain HTTP. Port of
// src/ai/claude.ts: the same system prompt, user payload, JSON schema
// (structured outputs via output_config.format) and validation.
//
// Differences from the TS version, which went through @anthropic-ai/sdk:
// - Raw HTTP: `x-api-key`, `anthropic-version: 2026-10-21`, and the
//   server-side-fallback beta in the `anthropic-beta` header (the SDK moved
//   `betas` out of the body the same way).
// - Errors are classified from the HTTP status / transport error instead of
//   SDK error classes; one retry on 408/409/429/5xx/transport errors (the
//   SDK's maxRetries: 1), honouring `x-should-retry` and `retry-after(-ms)`.

import Foundation

public enum ClaudeModel: String, Sendable, CaseIterable, Codable {
    case opus = "claude-opus-5-5"
    case haiku = "claude-haiku-5-5"

    public var label: String {
        switch self {
        case .opus: return "Opus 5.5 (best)"
        case .haiku: return "Haiku 5.5 (faster, cheaper)"
        }
    }

    public static let `default` = ClaudeModel.opus

    /// Server-side refusal fallback ("default" routing) — Opus, not Haiku.
    var supportsFallbacks: Bool { self != .haiku }
}

public struct ClaudeMixInput: Sendable {
    public var prompt: String
    public var values: KnobValues
    public var songGain: Double
    public var drumGain: Double
    public var originalDrums: Double?
    public var hasStems: Bool
    public var analysis: MixAnalysis?

    public init(
        prompt: String, values: KnobValues, songGain: Double, drumGain: Double, originalDrums: Double? = nil, hasStems: Bool = false,
        analysis: MixAnalysis? = nil
    ) {
        self.prompt = prompt
        self.values = values
        self.songGain = songGain
        self.drumGain = drumGain
        self.originalDrums = originalDrums
        self.hasStems = hasStems
        self.analysis = analysis
    }
}

public enum ClaudeErrorKind: String, Sendable {
    case noKey = "no_key"
    case badKey = "bad_key"
    case billing
    case network
    case rateLimit = "rate_limit"
    case overloaded
    case refusal
    case badResponse = "bad_response"
    case other

    /// Failures where the offline interpreter is a sensible stand-in.
    public var isTransient: Bool { self == .network || self == .rateLimit || self == .overloaded }
}

public struct ClaudeMixError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let kind: ClaudeErrorKind
    public let message: String
    public init(_ kind: ClaudeErrorKind, _ message: String) {
        self.kind = kind
        self.message = message
    }
    public var description: String { message }
    public var errorDescription: String? { message }
}

public enum ClaudeMix {
    public static let endpoint = "https://api.anthropic.com/v1/messages"
    public static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let maxExplanation = 400

    // What each knob's slider value means at render (from src/dsp/README.md).
    static let calibration: [String: String] = [
        "volume": "track level, about ±12 dB at ±1",
        "high_pass_rumble":
            "high-pass cutoff ≈ 40 Hz + value·\(jsNumberString(MixKnobs.intensity))·40 Hz (0.5 ≈ 100 Hz; 1.0 = 160 Hz removes the kick fundamental)",
        "denoise": "spectral noise reduction; saturates at ≈0.34, so 0.35 is the max",
        "kick_presence": "peak EQ at 90 Hz",
        "snare_body": "peak EQ at 200 Hz",
        "boxiness": "positive = dip at 350 Hz (less box/mud); negative adds it back",
        "attack": "peak EQ at 4 kHz",
        "harshness": "positive = dip at 6 kHz (smoother); negative adds bite",
        "air": "high shelf at 10 kHz",
        "brightness": "high shelf at 8 kHz (negative darkens)",
        "resonance": "notches up to 5 detected ringing peaks",
        "dynamic_range": "downward compression (4:1 at thr −18 dB per unit)",
        "detail": "upward compression, lifts low-level detail and ghost notes",
        "punch": "slow-attack compression that accentuates transients",
        "sustain": "noise gate: higher = shorter tails, less bleed",
        "consistency": "fast 2:1 compression that evens out hits",
        "pumping": "long-release compression that smooths pumping",
        "roominess": "reduces room reflections; saturates at ≈0.34, so 0.35 is the max",
        "width": "stereo side boost (no effect on a mono take)",
        "depth": "small-room reverb send (pushes the kit back)",
        "warmth": "tanh saturation",
        "presence": "harmonic excitation on 2–8 kHz",
        "fullness": "+200 Hz and gentle saturation",
        "clipping": "softens already-clipped peaks",
        "naturalness": "brick-wall limiter guard at −3 dBFS, placed last",
    ]

    // MARK: request

    public static func knobCatalog() -> JSONValue {
        .array(MixKnobs.keys.map { name in
            let info = MixKnobs.info[name]!
            let r = MixKnobs.range(name)
            var o = JSONObject()
            o["name"] = .string(name)
            o["label"] = .string(info.label)
            o["category"] = .string(info.category)
            o["bipolar"] = .bool(info.bipolar)
            o["range"] = [.number(r.min), .number(r.max)]
            o["description"] = .string(info.description)
            if let dsp = calibration[name] { o["dsp"] = .string(dsp) }
            return .object(o)
        })
    }

    static func presetsJSON() -> JSONValue {
        .array(MixKnobs.presets.map { p in
            [
                "id": .string(p.id), "label": .string(p.label), "description": .string(p.description),
                "values": .object(JSONObject(p.values.map { ($0.0, .number($0.1)) })),
            ]
        })
    }

    /// Stable system prompt (cache-friendly: no per-request content).
    public static func buildSystemPrompt() -> String {
        let g = MixKnobs.gainRange
        let lines = [
            "You are the mix assistant in Lumber, an iPhone app where a drummer records drums over a song.",
            "The user describes the drum sound they want. You set the drum processing knobs (\"Blanket\" DSP) and, if useful, the song/drum faders.",
            "",
            "How to work:",
            "- Start from the current knob values and change what the request calls for; keep unrelated knobs as they are unless the request implies a fresh start.",
            "- Use the analysis descriptors to judge where the audio already is. Examples: if the drum take is already bright (high centroid, strong presence/air bands), \"brighter\" needs only a small move; long decayMs means the take already rings or has room; low crestDb means it is already compressed; a mono take (stereoWidth null) makes width pointless.",
            "- Compare the drums with the song (or its drumless stem) when the request mentions fitting, blending or cutting through.",
            "- Knob values are slider units. At render each is multiplied by INTENSITY = \(jsNumberString(MixKnobs.intensity)), so 0.3 is already a clear move and 1.0 is heavy. Typical useful values are 0.1–0.6; the presets below are good calibration.",
            "- Bipolar knobs range −1..1 (negative is the opposite move). One-directional knobs range 0..1. Do not exceed the listed range.",
            "- songGain and drumGain are linear faders \(jsNumberString(g.min))–\(jsNumberString(g.max)) (1 = unity). Return null to leave a fader alone; only change them when the request is about level or balance.",
            "- explanation: one or two short sentences for the user, plain English, naming the main moves and why (mention the analysis when it changed your decision). No knob dumps.",
            "- Return the complete set of knob values, every knob, in the JSON format requested.",
            "",
            "Knob catalog (JSON):",
            knobCatalog().jsonString(),
            "",
            "Presets (sparse knob maps; unlisted knobs are 0):",
            presetsJSON().jsonString(),
        ]
        return lines.joined(separator: "\n")
    }

    public static func buildUserMessage(_ input: ClaudeMixInput) -> String {
        var current = JSONObject()
        current["values"] = MixKnobs.json(input.values)
        current["songGain"] = .number(input.songGain)
        current["drumGain"] = .number(input.drumGain)
        if input.hasStems { current["originalDrumsBlend"] = .number(input.originalDrums ?? 0) }
        var analysis: JSONValue = .null
        if let a = input.analysis {
            analysis = [
                "drums": a.drums.rounded().json,
                "song": a.song.map { $0.rounded().json } ?? .null,
                "songSource": .string(
                    a.song == nil
                        ? "unavailable"
                        : a.songIsDrumless ? "drumless stem (original drums removed)" : "full song incl. its original drums"),
                "notes":
                    "Levels in dBFS; bands = share of spectral energy per band in dB (sub 20–60, low 60–250, lowMid 250–800, mid 0.8–2.5k, presence 2.5–6k, air 6–20k Hz); decayMs = median time for a hit to fall 20 dB; stereoWidth = side/(mid+side) energy or null for mono.",
            ]
        }
        let payload: JSONValue = ["request": .string(input.prompt.jsTrimmed), "current": .object(current), "analysis": analysis]
        return payload.jsonString()
    }

    public static func outputSchema() -> JSONValue {
        let g = MixKnobs.gainRange
        var props = JSONObject()
        for k in MixKnobs.keys {
            let r = MixKnobs.range(k)
            props[k] = ["type": "number", "description": .string("\(MixKnobs.info[k]!.label), \(jsNumberString(r.min))..\(jsNumberString(r.max))")]
        }
        let nullableNumber: JSONValue = [["type": "number"], ["type": "null"]]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["values", "songGain", "drumGain", "explanation"],
            "properties": [
                "values": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": .array(MixKnobs.keys.map { .string($0) }),
                    "properties": .object(props),
                ],
                "songGain": ["anyOf": nullableNumber, "description": .string("song fader \(jsNumberString(g.min))..\(jsNumberString(g.max)), or null to keep")],
                "drumGain": ["anyOf": nullableNumber, "description": .string("drum fader \(jsNumberString(g.min))..\(jsNumberString(g.max)), or null to keep")],
                "explanation": ["type": "string", "description": "one or two sentences for the user"],
            ],
        ]
    }

    /// The Messages API request body. Thinking stays adaptive (the default on
    /// these models); effort is set explicitly because the default differs by model.
    public static func buildRequestBody(_ input: ClaudeMixInput, model: ClaudeModel = .default) -> JSONValue {
        var o = JSONObject()
        o["model"] = .string(model.rawValue)
        o["max_tokens"] = 16000
        o["output_config"] = ["effort": "medium", "format": ["type": "json_schema", "schema": outputSchema()]]
        o["cache_control"] = ["type": "ephemeral"]
        o["system"] = .string(buildSystemPrompt())
        o["messages"] = [["role": "user", "content": .string(buildUserMessage(input))]]
        if model.supportsFallbacks { o["fallbacks"] = "default" }
        return .object(o)
    }

    public static func betas(for model: ClaudeModel) -> [String] { model.supportsFallbacks ? [fallbackBeta] : [] }

    public static func buildHTTPRequest(_ input: ClaudeMixInput, apiKey: String, model: ClaudeModel = .default, timeout: Double = 60) -> HTTPRequest {
        var headers = [
            "content-type": "application/json",
            "accept": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": apiVersion,
        ]
        let b = betas(for: model)
        if !b.isEmpty { headers["anthropic-beta"] = b.joined(separator: ",") }
        return HTTPRequest(url: endpoint, method: "POST", headers: headers, body: buildRequestBody(input, model: model).jsonData(), timeout: timeout)
    }

    // MARK: response

    /// Validate Claude's JSON on top of the current mix. Throws ClaudeMixError(.badResponse).
    public static func parseSuggestion(_ text: String, current: (values: KnobValues, songGain: Double, drumGain: Double)) throws -> MixSuggestion {
        guard let raw = try? JSONValue.parse(text) else { throw ClaudeMixError(.badResponse, "Claude’s reply wasn’t valid JSON.") }
        guard raw.truthy, raw.object != nil || raw.array != nil else { throw ClaudeMixError(.badResponse, "Claude’s reply had no knob values.") }
        guard let v = raw["values"], v.object != nil || v.array != nil else {
            throw ClaudeMixError(.badResponse, "Claude’s reply had no knob values.")
        }
        let values = MixKnobs.sanitizeValues(v, base: current.values).values
        func gain(_ g: JSONValue?, _ cur: Double) -> Double? {
            guard let n = g?.number, n.isFinite, abs(MixKnobs.clampGain(n) - cur) > 1e-3 else { return nil }
            return MixKnobs.clampGain(n)
        }
        var explanation = raw["explanation"]?.string?.jsTrimmed ?? ""
        if explanation.jsLength > maxExplanation {
            explanation = explanation.jsSlice(0, maxExplanation - 1).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…"
        }
        return MixSuggestion(
            values: values, songGain: gain(raw["songGain"], current.songGain), drumGain: gain(raw["drumGain"], current.drumGain),
            explanation: explanation.isEmpty ? "Updated the knobs." : explanation)
    }

    /// Map an HTTP error response to a user-facing error.
    public static func classify(status: Int, body: Data) -> ClaudeMixError {
        switch status {
        case 401: return ClaudeMixError(.badKey, "The API key was rejected. Check it in AI settings.")
        case 403: return ClaudeMixError(.badKey, "This API key isn’t allowed to use that model.")
        case 429: return ClaudeMixError(.rateLimit, "Rate limited by the Anthropic API — try again in a minute.")
        case 402: return ClaudeMixError(.billing, "The Anthropic account is out of credit.")
        case 500...: return ClaudeMixError(.overloaded, "The Anthropic API is busy right now.")
        default:
            let json = try? JSONValue.parse(body)
            let detail = json?["error"]?["message"]?.string ?? String(decoding: body.prefix(200), as: UTF8.self)
            return ClaudeMixError(.other, "Anthropic API error \(status): \(detail)".jsTrimmed)
        }
    }

    /// Map a thrown error (transport, cancellation, …) to a user-facing error.
    public static func classify(_ e: Error) -> ClaudeMixError {
        if let e = e as? ClaudeMixError { return e }
        if let t = e as? HTTPTransportError {
            return t == .timedOut ? ClaudeMixError(.network, "Claude timed out.") : ClaudeMixError(.network, "No connection to the Anthropic API.")
        }
        if e is CancellationError { return ClaudeMixError(.other, "Request was cancelled.") }
        return ClaudeMixError(.other, errorMessage(e))
    }

    static func shouldRetry(_ res: HTTPResponse) -> Bool {
        if let h = res.headers["x-should-retry"] { return h == "true" }
        return res.status == 408 || res.status == 409 || res.status == 429 || res.status >= 500
    }

    static func retryDelayMs(_ res: HTTPResponse?) -> Int {
        if let ms = res?.headers["retry-after-ms"].flatMap(Double.init), ms >= 0, ms < 60_000 { return Int(ms) }
        if let s = res?.headers["retry-after"].flatMap(Double.init), s >= 0, s < 60 { return Int(s * 1000) }
        return 500
    }

    /// One request to Claude (plus at most one retry); returns a validated
    /// suggestion or throws ClaudeMixError.
    public static func suggest(
        _ input: ClaudeMixInput, apiKey: String, model: ClaudeModel = .default, http: HTTPClient,
        sleep: @Sendable (Int) async -> Void = { ms in try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
    ) async throws -> MixSuggestion {
        if apiKey.isEmpty { throw ClaudeMixError(.noKey, "No API key set.") }
        let request = buildHTTPRequest(input, apiKey: apiKey, model: model)
        var response: HTTPResponse?
        for attempt in 0..<2 {
            do {
                let res = try await http.send(request)
                if res.ok {
                    response = res
                    break
                }
                if attempt == 0 && shouldRetry(res) {
                    await sleep(retryDelayMs(res))
                    continue
                }
                throw classify(status: res.status, body: res.body)
            } catch let e as ClaudeMixError {
                throw e
            } catch {
                if attempt == 0 && !(error is CancellationError) {
                    await sleep(retryDelayMs(nil))
                    continue
                }
                throw classify(error)
            }
        }
        guard let response, let message = try? response.json(), message.object != nil else {
            throw ClaudeMixError(.other, "Unexpected response from the Anthropic API.")
        }
        switch message["stop_reason"]?.string {
        case "refusal": throw ClaudeMixError(.refusal, "Claude declined this request.")
        case "max_tokens": throw ClaudeMixError(.badResponse, "Claude’s reply was cut off.")
        default: break
        }
        let text = (message["content"]?.array ?? []).filter { $0["type"]?.string == "text" }.map { $0["text"]?.string ?? "" }.joined()
        return try parseSuggestion(text, current: (input.values, input.songGain, input.drumGain))
    }
}

// MARK: - API key helpers (src/ai/keyStore.ts)

public enum AnthropicKey {
    private static let shape = JSRegex("^sk-ant-[A-Za-z0-9_-]{20,}$")

    /// Light sanity check before saving (Anthropic keys start with "sk-ant-").
    public static func looksValid(_ k: String) -> Bool { shape.test(k.jsTrimmed) }

    /// "sk-ant-…abcd" for display.
    public static func mask(_ k: String) -> String {
        k.jsLength > 12 ? "\(k.jsSlice(0, 7))…\(k.jsSlice(k.jsLength - 4))" : "••••"
    }
}
