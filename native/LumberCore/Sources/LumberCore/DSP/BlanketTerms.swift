// Port of src/dsp/blanketTerms.ts: the Blanket knobs, their UI categories,
// labels and descriptions. Raw values are the TS keys (snake_case), so knob
// maps round-trip through JSON (presets, the Claude prompt mix) unchanged.

/// One Blanket knob. Declaration order = the TS `BLANKET_TERM_KEYS` order.
public enum BlanketTerm: String, Sendable, Codable, CaseIterable, Hashable {
    case volume
    case highPassRumble = "high_pass_rumble"
    case denoise
    case kickPresence = "kick_presence"
    case snareBody = "snare_body"
    case boxiness
    case attack
    case harshness
    case air
    case brightness
    case resonance
    case dynamicRange = "dynamic_range"
    case detail
    case punch
    case sustain
    case consistency
    case pumping
    case roominess
    case width
    case depth
    case warmth
    case presence
    case fullness
    case clipping
    case naturalness
}

public enum BlanketCategory: String, Sendable, Codable, CaseIterable {
    case level = "Level"
    case frequency = "Frequency"
    case dynamics = "Dynamics"
    case roomSpatial = "Room / Spatial"
    case harmonic = "Harmonic"
    case artifacts = "Artifacts"
    case perceptual = "Perceptual"

    /// Render order for the grouped slider list (TS `CATEGORY_ORDER`).
    public static let order: [BlanketCategory] = [
        .level, .frequency, .dynamics, .roomSpatial, .harmonic, .artifacts, .perceptual,
    ]
}

public struct BlanketTermInfo: Sendable, Equatable {
    public let label: String
    public let category: BlanketCategory
    /// Bipolar terms keep their sign (boost/cut); the rest use |value|.
    public let bipolar: Bool
    /// One-line plain-English explanation (knob tooltip).
    public let description: String
}

/// A knob state: term → slider value (−1..1, 0 = neutral). Missing = 0.
public typealias BlanketValues = [BlanketTerm: Double]

extension BlanketTerm {
    /// TS `BLANKET_TERM_KEYS`.
    public static var keys: [BlanketTerm] { allCases }

    public var info: BlanketTermInfo {
        switch self {
        case .volume: return .init(label: "Volume", category: .level, bipolar: true,
            description: "Plain level fader for this track — louder or quieter in the mix (about ±12 dB).")
        case .highPassRumble: return .init(label: "Rumble (high-pass)", category: .frequency, bipolar: false,
            description: "Rolls off sub-bass rumble, handling thumps and stage vibration below the music.")
        case .denoise: return .init(label: "Denoise", category: .frequency, bipolar: false,
            description: "Reduces steady background noise — hiss, hum and HVAC drone.")
        case .kickPresence: return .init(label: "Kick presence", category: .frequency, bipolar: true,
            description: "Boosts the low-end weight and body of the kick drum (cut when negative).")
        case .snareBody: return .init(label: "Snare body", category: .frequency, bipolar: true,
            description: "Adds fullness and body to a thin snare (thins it out when negative).")
        case .boxiness: return .init(label: "Boxiness", category: .frequency, bipolar: true,
            description: "Tames hollow, boxy low-mid resonance (adds it back when negative).")
        case .attack: return .init(label: "Attack", category: .frequency, bipolar: true,
            description: "Sharpens stick attack and transient definition (softens when negative).")
        case .harshness: return .init(label: "Harshness", category: .frequency, bipolar: true,
            description: "Smooths harsh, brittle cymbals and bright mids (adds bite when negative).")
        case .air: return .init(label: "Air", category: .frequency, bipolar: true,
            description: "Adds open high-end air and sparkle (darkens when negative).")
        case .brightness: return .init(label: "Brightness", category: .frequency, bipolar: true,
            description: "Lifts overall brightness on a dull, muffled recording (darkens when negative).")
        case .resonance: return .init(label: "Resonance", category: .frequency, bipolar: false,
            description: "Notches out ringing resonant frequency peaks.")
        case .dynamicRange: return .init(label: "Dynamic range", category: .dynamics, bipolar: false,
            description: "Controls the spread between the loudest and quietest hits.")
        case .detail: return .init(label: "Detail", category: .dynamics, bipolar: false,
            description: "Brings out fine low-level detail and articulation.")
        case .punch: return .init(label: "Punch", category: .dynamics, bipolar: false,
            description: "Enhances transient impact so hits feel punchier.")
        case .sustain: return .init(label: "Sustain", category: .dynamics, bipolar: false,
            description: "Shapes the ring-out and tails between hits.")
        case .consistency: return .init(label: "Consistency", category: .dynamics, bipolar: false,
            description: "Evens out hits that jump inconsistently in and out.")
        case .pumping: return .init(label: "Pumping", category: .dynamics, bipolar: false,
            description: "Reduces unnatural pumping and breathing from compression.")
        case .roominess: return .init(label: "Roominess", category: .roomSpatial, bipolar: false,
            description: "Controls room reflections and reverberant wash.")
        case .width: return .init(label: "Width", category: .roomSpatial, bipolar: false,
            description: "Widens a narrow, mono-sounding stereo image.")
        case .depth: return .init(label: "Depth", category: .roomSpatial, bipolar: false,
            description: "Adds a front-to-back sense of distance and space.")
        case .warmth: return .init(label: "Warmth", category: .harmonic, bipolar: false,
            description: "Adds analog warmth to a cold, sterile recording.")
        case .presence: return .init(label: "Presence", category: .harmonic, bipolar: false,
            description: "Helps the drums cut through and sit forward in the mix.")
        case .fullness: return .init(label: "Fullness", category: .harmonic, bipolar: false,
            description: "Fills out a thin, hollow-sounding recording.")
        case .clipping: return .init(label: "Clipping", category: .artifacts, bipolar: false,
            description: "Tames harsh digital clipping and distorted peaks.")
        case .naturalness: return .init(label: "Naturalness", category: .perceptual, bipolar: false,
            description: "Keeps the result natural and un-over-processed — a gentle brick-wall guard.")
        }
    }

    /// Every term at 0 (TS `zeroValues`).
    public static func zeroValues() -> BlanketValues {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, 0.0) })
    }
}
