// The Blanket knob terms and drum presets the Edit screen shows, ported from
// src/dsp/blanketTerms.ts and src/dsp/presets.ts (same keys, labels, order
// and values). Keys are the JSON keys of `MixSettings.values`.
//
// LumberCore/DSP owns the DSP behind these terms. When it exposes its own term
// table and presets, point `terms` / `presets` at it; the keys must not change.

import Foundation

enum KnobCategory: String, CaseIterable, Sendable {
    case level = "Level"
    case frequency = "Frequency"
    case dynamics = "Dynamics"
    case room = "Room / Spatial"
    case harmonic = "Harmonic"
    case artifacts = "Artifacts"
    case perceptual = "Perceptual"
}

struct KnobTermInfo: Hashable, Sendable, Identifiable {
    var key: String
    var label: String
    var category: KnobCategory
    /// EQ-style terms where negative is a sensible opposite; the rest use |value|.
    var bipolar: Bool
    var description: String

    var id: String { key }
}

struct MixPreset: Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var description: String
    var values: [String: Double] // sparse, slider units -1...1
}

enum KnobCatalog {
    static let terms: [KnobTermInfo] = [
        .init(key: "volume", label: "Volume", category: .level, bipolar: true,
              description: "Plain level fader for this track — louder or quieter in the mix (about ±12 dB)."),

        .init(key: "high_pass_rumble", label: "Rumble (high-pass)", category: .frequency, bipolar: false,
              description: "Rolls off sub-bass rumble, handling thumps and stage vibration below the music."),
        .init(key: "denoise", label: "Denoise", category: .frequency, bipolar: false,
              description: "Reduces steady background noise — hiss, hum and HVAC drone."),
        .init(key: "kick_presence", label: "Kick presence", category: .frequency, bipolar: true,
              description: "Boosts the low-end weight and body of the kick drum (cut when negative)."),
        .init(key: "snare_body", label: "Snare body", category: .frequency, bipolar: true,
              description: "Adds fullness and body to a thin snare (thins it out when negative)."),
        .init(key: "boxiness", label: "Boxiness", category: .frequency, bipolar: true,
              description: "Tames hollow, boxy low-mid resonance (adds it back when negative)."),
        .init(key: "attack", label: "Attack", category: .frequency, bipolar: true,
              description: "Sharpens stick attack and transient definition (softens when negative)."),
        .init(key: "harshness", label: "Harshness", category: .frequency, bipolar: true,
              description: "Smooths harsh, brittle cymbals and bright mids (adds bite when negative)."),
        .init(key: "air", label: "Air", category: .frequency, bipolar: true,
              description: "Adds open high-end air and sparkle (darkens when negative)."),
        .init(key: "brightness", label: "Brightness", category: .frequency, bipolar: true,
              description: "Lifts overall brightness on a dull, muffled recording (darkens when negative)."),
        .init(key: "resonance", label: "Resonance", category: .frequency, bipolar: false,
              description: "Notches out ringing resonant frequency peaks."),

        .init(key: "dynamic_range", label: "Dynamic range", category: .dynamics, bipolar: false,
              description: "Controls the spread between the loudest and quietest hits."),
        .init(key: "detail", label: "Detail", category: .dynamics, bipolar: false,
              description: "Brings out fine low-level detail and articulation."),
        .init(key: "punch", label: "Punch", category: .dynamics, bipolar: false,
              description: "Enhances transient impact so hits feel punchier."),
        .init(key: "sustain", label: "Sustain", category: .dynamics, bipolar: false,
              description: "Shapes the ring-out and tails between hits."),
        .init(key: "consistency", label: "Consistency", category: .dynamics, bipolar: false,
              description: "Evens out hits that jump inconsistently in and out."),
        .init(key: "pumping", label: "Pumping", category: .dynamics, bipolar: false,
              description: "Reduces unnatural pumping and breathing from compression."),

        .init(key: "roominess", label: "Roominess", category: .room, bipolar: false,
              description: "Controls room reflections and reverberant wash."),
        .init(key: "width", label: "Width", category: .room, bipolar: false,
              description: "Widens a narrow, mono-sounding stereo image."),
        .init(key: "depth", label: "Depth", category: .room, bipolar: false,
              description: "Adds a front-to-back sense of distance and space."),

        .init(key: "warmth", label: "Warmth", category: .harmonic, bipolar: false,
              description: "Adds analog warmth to a cold, sterile recording."),
        .init(key: "presence", label: "Presence", category: .harmonic, bipolar: false,
              description: "Helps the drums cut through and sit forward in the mix."),
        .init(key: "fullness", label: "Fullness", category: .harmonic, bipolar: false,
              description: "Fills out a thin, hollow-sounding recording."),

        .init(key: "clipping", label: "Clipping", category: .artifacts, bipolar: false,
              description: "Tames harsh digital clipping and distorted peaks."),

        .init(key: "naturalness", label: "Naturalness", category: .perceptual, bipolar: false,
              description: "Keeps the result natural and un-over-processed — a gentle brick-wall guard."),
    ]

    static let keys: [String] = terms.map(\.key)

    static func terms(in category: KnobCategory) -> [KnobTermInfo] {
        terms.filter { $0.category == category }
    }

    static func info(_ key: String) -> KnobTermInfo? {
        terms.first { $0.key == key }
    }

    /// Every term present (0 when missing); unknown keys are kept as-is so a
    /// newer DSP's terms survive a round trip through an older build.
    static func filledValues(_ sparse: [String: Double]) -> [String: Double] {
        var out = sparse
        for key in keys where out[key] == nil {
            out[key] = 0
        }
        return out
    }

    static let presets: [MixPreset] = [
        .init(id: "warm", label: "Warm",
              description: "Rounded, saturated kit with softened cymbals and a touch of room.",
              values: ["warmth": 0.5, "fullness": 0.4, "brightness": -0.4, "harshness": 0.5, "dynamic_range": 0.3, "depth": 0.2]),
        .init(id: "bright", label: "Bright / Harsh",
              description: "Crisp stick attack and open top end that cuts through a dense mix.",
              values: ["attack": 0.8, "presence": 0.6, "air": 0.6, "brightness": 0.5, "punch": 0.4]),
        .init(id: "loud", label: "Loud",
              description: "Heavily compressed, punchy and up-front, with a big kick.",
              values: ["punch": 0.8, "dynamic_range": 0.8, "kick_presence": 0.6, "warmth": 0.3, "naturalness": 1]),
        .init(id: "tight", label: "Tight / Dry",
              description: "Short tails, less room and mud, controlled low end.",
              values: ["sustain": 0.6, "roominess": 0.3, "boxiness": 0.5, "punch": 0.5, "high_pass_rumble": 0.5]),
        .init(id: "roomy", label: "Roomy / Vintage",
              description: "Darker, warmer kit set back in a small room, ghost notes lifted.",
              values: ["depth": 0.6, "warmth": 0.6, "brightness": -0.3, "detail": 0.5]),
        .init(id: "phone", label: "Phone-mic rescue",
              description: "Cleans up a phone recording: rumble, hiss, boxiness and ringing.",
              values: ["high_pass_rumble": 0.5, "denoise": 0.3, "boxiness": 0.6, "resonance": 0.5, "naturalness": 1]),
    ]

    static func preset(_ id: String?) -> MixPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    /// A preset's full knob state.
    static func values(for preset: MixPreset) -> [String: Double] {
        var out: [String: Double] = [:]
        for key in keys { out[key] = preset.values[key] ?? 0 }
        return out
    }

    static func zeroValues() -> [String: Double] { filledValues([:]) }
}
