// Port of src/dsp/presets.ts: named starting points for the Blanket knobs,
// sparse maps in slider units (−1..1, later × BlanketChain.intensity).
//
// Tuning notes (from the TS): denoise/roominess clamp their spectral-gate
// amount at 1 (reached at slider ≈ .34), so presets sit just under it;
// high_pass_rumble 1.0 would be a 160 Hz cut, so Phone-mic rescue uses .5 (100 Hz).

public struct DrumPreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let description: String
    public let values: BlanketValues

    /// The full knob state the editor loads (0 for missing terms).
    public var fullValues: BlanketValues { DrumPreset.fill(values) }

    /// Expand a sparse map to every term, 0 for missing (TS `fillValues`).
    public static func fill(_ sparse: BlanketValues) -> BlanketValues {
        Dictionary(uniqueKeysWithValues: BlanketTerm.allCases.map { ($0, sparse[$0] ?? 0) })
    }

    public static func preset(id: String) -> DrumPreset? { all.first { $0.id == id } }

    public static let all: [DrumPreset] = [
        DrumPreset(id: "warm", label: "Warm",
                   description: "Rounded, saturated kit with softened cymbals and a touch of room.",
                   values: [.warmth: 0.5, .fullness: 0.4, .brightness: -0.4, .harshness: 0.5,
                            .dynamicRange: 0.3, .depth: 0.2]),
        DrumPreset(id: "bright", label: "Bright / Harsh",
                   description: "Crisp stick attack and open top end that cuts through a dense mix.",
                   values: [.attack: 0.8, .presence: 0.6, .air: 0.6, .brightness: 0.5, .punch: 0.4]),
        DrumPreset(id: "loud", label: "Loud",
                   description: "Heavily compressed, punchy and up-front, with a big kick.",
                   values: [.punch: 0.8, .dynamicRange: 0.8, .kickPresence: 0.6, .warmth: 0.3, .naturalness: 1]),
        DrumPreset(id: "tight", label: "Tight / Dry",
                   description: "Short tails, less room and mud, controlled low end.",
                   values: [.sustain: 0.6, .roominess: 0.3, .boxiness: 0.5, .punch: 0.5, .highPassRumble: 0.5]),
        DrumPreset(id: "roomy", label: "Roomy / Vintage",
                   description: "Darker, warmer kit set back in a small room, ghost notes lifted.",
                   values: [.depth: 0.6, .warmth: 0.6, .brightness: -0.3, .detail: 0.5]),
        DrumPreset(id: "phone", label: "Phone-mic rescue",
                   description: "Cleans up a phone recording: rumble, hiss, boxiness and ringing.",
                   values: [.highPassRumble: 0.5, .denoise: 0.3, .boxiness: 0.6, .resonance: 0.5, .naturalness: 1]),
    ]
}
