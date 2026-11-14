import Foundation
import XCTest
@testable import LumberCore

final class AIClaudeTests: XCTestCase {
    var fx: JSONValue!

    override func setUpWithError() throws { fx = try Fixture.load("ai/claude.json") }

    func input(_ j: JSONValue) throws -> ClaudeMixInput {
        let a = j["analysis"]
        return ClaudeMixInput(
            prompt: j["prompt"]!.string!, values: knobValues(j["values"]), songGain: j["songGain"]!.number!, drumGain: j["drumGain"]!.number!,
            originalDrums: j["originalDrums"]?.number, hasStems: j["hasStems"]?.bool ?? false,
            analysis: a == nil || a!.isNull ? nil : try fromJSON(MixAnalysis.self, a!))
    }

    var sample: ClaudeMixInput { get throws { try input(fx["inputs"]!["full"]!) } }

    // MARK: golden fixtures

    func testSystemPromptCatalogAndSchemaMatchTS() {
        XCTAssertEqual(ClaudeMix.knobCatalog().jsonString(), fx["knobCatalog"]?.string)
        XCTAssertEqual(ClaudeMix.outputSchema().jsonString(), fx["outputSchema"]?.string)
        XCTAssertEqual(ClaudeMix.buildSystemPrompt(), fx["systemPrompt"]?.string)
    }

    func testUserMessagesMatchTS() throws {
        for (name, j) in fx["inputs"]!.object!.pairs {
            XCTAssertEqual(ClaudeMix.buildUserMessage(try input(j)), fx["userMessages"]![name]?.string, name)
        }
    }

    func testRequestBodiesMatchTS() throws {
        for (name, j) in fx["inputs"]!.object!.pairs {
            for model in ClaudeModel.allCases {
                let key = "\(name)/\(model == .opus ? "opus" : "haiku")"
                let want = fx["requests"]![key]!
                XCTAssertEqual(ClaudeMix.buildRequestBody(try input(j), model: model).jsonString(), want["body"]?.string, key)
                XCTAssertEqual(ClaudeMix.betas(for: model), want["betas"]!.array!.map { $0.string! }, key)
            }
        }
    }

    func testParseSuggestionMatchesTS() throws {
        let cur = fx["current"]!
        let current = (values: knobValues(cur["values"]), songGain: cur["songGain"]!.number!, drumGain: cur["drumGain"]!.number!)
        for c in fx["replies"]!.array! {
            let text = c["text"]!.string!
            if let want = c["expected"] {
                let s = try ClaudeMix.parseSuggestion(text, current: current)
                XCTAssertEqual(s.values, knobValues(want["values"]), text)
                XCTAssertEqual(s.songGain, want["songGain"]?.number, text)
                XCTAssertEqual(s.drumGain, want["drumGain"]?.number, text)
                XCTAssertEqual(s.explanation, want["explanation"]?.string, text)
            } else {
                XCTAssertThrowsError(try ClaudeMix.parseSuggestion(text, current: current)) { e in
                    XCTAssertEqual((e as? ClaudeMixError)?.kind.rawValue, c["errorKind"]?.string)
                    XCTAssertEqual(errorMessage(e), c["error"]?.string)
                }
            }
        }
    }

    // MARK: ports of tests/claude.test.ts

    func testRequestShape() throws {
        let body = ClaudeMix.buildRequestBody(try sample)
        XCTAssertEqual(body["model"]?.string, "claude-opus-5-5")
        XCTAssertEqual(body["output_config"]?["format"]?["type"]?.string, "json_schema")
        XCTAssertEqual(body["output_config"]?["effort"]?.string, "medium")
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["thinking"])
        XCTAssertEqual(body["fallbacks"]?.string, "default")
        let haiku = ClaudeMix.buildRequestBody(try sample, model: .haiku)
        XCTAssertNil(haiku["fallbacks"])
        XCTAssertFalse(ClaudeMix.outputSchema().jsonString().contains("\"minimum\""))
        XCTAssertEqual(ClaudeMix.buildSystemPrompt(), ClaudeMix.buildSystemPrompt())
        let user = try JSONValue.parse(ClaudeMix.buildUserMessage(try sample))
        XCTAssertEqual(user["request"]?.string, "punchy and dry like a 90s rock record")
        XCTAssertEqual(user["analysis"]?["drums"]?["rmsDb"]?.number, -21.5)
    }

    static func message(_ text: String, stop: String = "end_turn") -> HTTPResponse {
        let m: JSONValue = [
            "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
            "content": [["type": "thinking", "thinking": "", "signature": "sig"], ["type": "text", "text": .string(text)]],
            "stop_reason": .string(stop), "usage": ["input_tokens": 10, "output_tokens": 10],
        ]
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: m.jsonData())
    }

    static func reply(_ values: KnobValues, explanation: String, songGain: Double? = nil) -> String {
        let j: JSONValue = [
            "values": MixKnobs.json(MixKnobs.fillValues(values)), "songGain": songGain.map { .number($0) } ?? .null, "drumGain": .null,
            "explanation": .string(explanation),
        ]
        return j.jsonString()
    }

    func testRoundTrip() async throws {
        let http = FakeHTTP { _, _ in Self.message(Self.reply(["punch": 0.7, "sustain": 0.4], explanation: "Punchier and drier.")) }
        let s = try await ClaudeMix.suggest(try sample, apiKey: "sk-ant-test", http: http)
        XCTAssertEqual(s.values["punch"], 0.7)
        XCTAssertEqual(s.values["sustain"], 0.4)
        XCTAssertEqual(s.explanation, "Punchier and drier.")
        let req = http.requests[0]
        XCTAssertEqual(req.url, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.headers["x-api-key"], "sk-ant-test")
        XCTAssertEqual(req.headers["anthropic-version"], "2026-10-21")
        XCTAssertEqual(req.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertEqual(req.timeout, 60)
        let body = try JSONValue.parse(req.body!)
        XCTAssert(body["messages"]![0]!["content"]!.string!.contains("90s rock"))
        let haiku = FakeHTTP { _, _ in Self.message(Self.reply([:], explanation: "x")) }
        _ = try await ClaudeMix.suggest(try sample, apiKey: "k", model: .haiku, http: haiku)
        XCTAssertNil(haiku.requests[0].headers["anthropic-beta"])
    }

    func kind(_ http: FakeHTTP, key: String = "k") async throws -> ClaudeMixError? {
        do {
            _ = try await ClaudeMix.suggest(try sample, apiKey: key, http: http, sleep: { _ in })
            return nil
        } catch let e as ClaudeMixError {
            return e
        }
    }

    func testErrorKinds() async throws {
        let refusal = try await kind(FakeHTTP { _, _ in Self.message("{}", stop: "refusal") })
        XCTAssertEqual(refusal?.kind, .refusal)
        let cut = try await kind(FakeHTTP { _, _ in Self.message("{\"values\":{", stop: "max_tokens") })
        XCTAssertEqual(cut?.kind, .badResponse)
        func status(_ s: Int, _ type: String) -> FakeHTTP {
            FakeHTTP(status: s, json: ["type": "error", "error": ["type": .string(type), "message": "nope"]], headers: ["x-should-retry": "false"])
        }
        let e401 = try await kind(status(401, "authentication_error"))
        XCTAssertEqual(e401?.kind, .badKey)
        let e403 = try await kind(status(403, "permission_error"))
        XCTAssertEqual(e403?.kind, .badKey)
        let e429 = try await kind(status(429, "rate_limit_error"))
        XCTAssertEqual(e429?.kind, .rateLimit)
        XCTAssertTrue(e429!.kind.isTransient)
        let e529 = try await kind(status(529, "overloaded_error"))
        XCTAssertEqual(e529?.kind, .overloaded)
        XCTAssertTrue(e529!.kind.isTransient)
        let e402 = try await kind(status(402, "billing_error"))
        XCTAssertEqual(e402?.kind, .billing)
        XCTAssertFalse(e402!.kind.isTransient)
        let e400 = try await kind(status(400, "invalid_request_error"))
        XCTAssertEqual(e400, ClaudeMixError(.other, "Anthropic API error 400: nope"))
        let net = try await kind(FakeHTTP { _, _ in throw HTTPTransportError.failed("Network request failed") })
        XCTAssertEqual(net, ClaudeMixError(.network, "No connection to the Anthropic API."))
        let timeout = try await kind(FakeHTTP { _, _ in throw HTTPTransportError.timedOut })
        XCTAssertEqual(timeout, ClaudeMixError(.network, "Claude timed out."))
        let noKeyHTTP = FakeHTTP { _, _ in Self.message("{}") }
        let noKey = try await kind(noKeyHTTP, key: "")
        XCTAssertEqual(noKey?.kind, .noKey)
        XCTAssertTrue(noKeyHTTP.requests.isEmpty)
        XCTAssertEqual(ClaudeMix.classify(ClaudeMixError(.refusal, "x")).kind, .refusal)
    }

    func testRetriesOnceOnRetryableStatus() async throws {
        let http = FakeHTTP { _, n in
            n == 0 ? HTTPResponse(status: 529, headers: ["retry-after-ms": "5"], text: "{}") : Self.message(Self.reply(["air": 0.2], explanation: "Airier."))
        }
        let s = try await ClaudeMix.suggest(try sample, apiKey: "k", http: http, sleep: { ms in XCTAssertEqual(ms, 5) })
        XCTAssertEqual(s.values["air"], 0.2)
        XCTAssertEqual(http.requests.count, 2)
        let twice = FakeHTTP { _, _ in HTTPResponse(status: 503, text: "{}") }
        let e = try await kind(twice)
        XCTAssertEqual(e?.kind, .overloaded)
        XCTAssertEqual(twice.requests.count, 2)
        let noRetry = FakeHTTP { _, _ in HTTPResponse(status: 401, text: "{}") }
        _ = try await kind(noRetry)
        XCTAssertEqual(noRetry.requests.count, 1)
    }

    func testRunPromptMix() async throws {
        let input = try sample
        let r = await PromptMix.run(input, apiKey: nil, http: FakeHTTP { _, _ in XCTFail("no request expected"); return HTTPResponse(status: 500) })
        XCTAssertEqual(r.source, .offline)
        XCTAssert(r.notice!.contains("No Anthropic API key"))
        XCTAssert(r.suggestion.explanation.hasPrefix("Offline interpreter"))
        XCTAssert(r.suggestion.values["punch"]! > 0)
        let c = await PromptMix.run(input, apiKey: "k", http: FakeHTTP { _, _ in Self.message(Self.reply(["air": 0.2], explanation: "Airier.", songGain: 0.7)) })
        XCTAssertEqual(c.source, .claude)
        XCTAssertEqual(c.suggestion.values["air"], 0.2)
        XCTAssertEqual(c.suggestion.songGain, 0.7)
        XCTAssertNil(c.notice)
        let bad = await PromptMix.run(input, apiKey: "k", http: FakeHTTP(status: 401, json: ["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]]))
        XCTAssertEqual(bad.source, .offline)
        XCTAssert(bad.notice!.contains("rejected"))
        let down = await PromptMix.run(input, apiKey: "k", http: FakeHTTP { _, _ in throw HTTPTransportError.failed("offline") })
        XCTAssertEqual(down.source, .offline)
        XCTAssertEqual(down.notice, "No connection to the Anthropic API. Used the offline interpreter instead.")
    }

    func testAnalyzeProject() {
        let sr = 48000.0
        let take: [[Float]] = [(0..<(48000 * 4)).map { $0 % 12000 < 400 ? 0.5 : 0 }]
        let bed: [[Float]] = [(0..<(48000 * 20)).map { Float(0.1 * sin(Double($0) / 10)) }]
        let full = PromptMix.analyzeProject(MixProjectAudio(sampleRate: sr, drums: take, song: bed), drumOffsetSec: 2)
        XCTAssertEqual(full.song?.durationSec, 5)
        XCTAssertFalse(full.songIsDrumless)
        let stems = PromptMix.analyzeProject(MixProjectAudio(sampleRate: sr, drums: take, song: nil, stems: (drums: bed, noDrums: bed)), drumOffsetSec: 30)
        XCTAssertTrue(stems.songIsDrumless)
        XCTAssertGreaterThan(stems.song?.rmsDb ?? -200, -40)
    }

    func testKeyHelpers() {
        XCTAssertTrue(AnthropicKey.looksValid("  sk-ant-api03-abcdefghijklmnopqrstuvwxyz "))
        XCTAssertFalse(AnthropicKey.looksValid("sk-ant-short"))
        XCTAssertEqual(AnthropicKey.mask("sk-ant-api03-abcdefWXYZ"), "sk-ant-…WXYZ")
        XCTAssertEqual(AnthropicKey.mask("short"), "••••")
        XCTAssertEqual(ClaudeModel.default.rawValue, "claude-opus-5-5")
        XCTAssertEqual(ClaudeModel.haiku.rawValue, "claude-haiku-5-5")
    }
}
