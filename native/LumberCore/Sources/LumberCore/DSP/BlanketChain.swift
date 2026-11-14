// Port of src/dsp/blanketChain.ts: knob values → effect chain, in a fixed
// processing order independent of the UI grouping.

import Foundation

public enum BlanketChain {
    /// Slider values are −1..1; this widens them so the effects are clearly audible.
    public static let intensity: Double = 3

    /// Processing order: clean-up, corrective → tonal EQ, dynamics (gate first,
    /// upward compression last), harmonic colour, space, level, naturalness guard.
    public static let renderOrder: [BlanketTerm] = [
        // clean-up
        .highPassRumble, .denoise, .roominess, .resonance,
        // corrective EQ
        .boxiness, .harshness,
        // tonal EQ
        .kickPresence, .snareBody, .attack, .brightness, .air,
        // dynamics
        .sustain, .punch, .dynamicRange, .consistency, .pumping, .detail,
        // harmonic
        .fullness, .warmth, .presence, .clipping,
        // space
        .width, .depth,
        // level + guard
        .volume, .naturalness,
    ]

    /// Append the Blanket chain for `values` to `chain`. Terms at 0, missing or
    /// non-finite are skipped. Bipolar terms keep their sign; the rest use |value|.
    public static func apply(_ values: BlanketValues, to chain: inout EffectChain, intensity: Double = intensity) {
        for term in renderOrder {
            let value = values[term] ?? 0
            if value == 0 || !value.isFinite { continue }
            let signed = term.info.bipolar ? value : abs(value)
            chain.blanket(term, signed * intensity)
        }
    }

    /// Knob values → the effect specs they expand into (in render order).
    public static func build(_ values: BlanketValues, intensity: Double = intensity) -> [EffectSpec] {
        var chain = EffectChain()
        apply(values, to: &chain, intensity: intensity)
        return chain.specs
    }

    /// True if every term appears in the render order exactly once.
    public static var renderOrderIsComplete: Bool {
        Set(renderOrder).count == renderOrder.count && renderOrder.count == BlanketTerm.allCases.count
    }
}
