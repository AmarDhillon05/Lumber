// Port of src/dsp/chain.ts (primitive builders) and src/dsp/Blanket.ts (the
// perceptual knobs, each mapping an amount onto primitives with the exact TS
// ranges). In TS `chain.blanket.punch(x)`; here `chain.blanket(.punch, x)`.

import Foundation

/// An ordered list of effect specs, built by value. Pure: no audio engine.
public struct EffectChain: Sendable, Equatable {
    public var specs: [EffectSpec] = []

    public init(_ specs: [EffectSpec] = []) { self.specs = specs }

    /// Butterworth section Q values per even order (cascaded biquads).
    static let butterQ: [Int: [Double]] = [
        2: [0.7071],
        4: [0.5412, 1.3066],
        6: [0.5176, 0.7071, 1.9319],
        8: [0.5098, 0.6013, 0.9000, 2.5629],
    ]

    public mutating func add(_ spec: EffectSpec) { specs.append(spec) }

    // MARK: Filters

    private mutating func butterworth(_ kind: BiquadKind, _ frequency: Double, _ order: Int) {
        for q in Self.butterQ[order] ?? Self.butterQ[4]! {
            add(.biquad(BiquadSpec(kind: kind, frequency: frequency, q: q)))
        }
    }

    public mutating func highPass(_ cutoffHz: Double, order: Int = 4) { butterworth(.highpass, cutoffHz, order) }
    public mutating func lowPass(_ cutoffHz: Double, order: Int = 4) { butterworth(.lowpass, cutoffHz, order) }

    public mutating func bandPass(_ lowHz: Double, _ highHz: Double) {
        let frequency = (lowHz * highHz).squareRoot()
        add(.biquad(BiquadSpec(kind: .bandpass, frequency: frequency, q: frequency / (highHz - lowHz))))
    }

    public mutating func notch(_ centerHz: Double, q: Double = 30) {
        add(.biquad(BiquadSpec(kind: .notch, frequency: centerHz, q: q)))
    }

    // MARK: Parametric / shelving EQ

    public mutating func peakEQ(_ centerHz: Double, gainDb: Double, q: Double) {
        add(.biquad(BiquadSpec(kind: .peaking, frequency: centerHz, q: q, gainDb: gainDb)))
    }

    public mutating func lowShelf(_ cutoffHz: Double, gainDb: Double) {
        add(.biquad(BiquadSpec(kind: .lowshelf, frequency: cutoffHz, gainDb: gainDb)))
    }

    public mutating func highShelf(_ cutoffHz: Double, gainDb: Double) {
        add(.biquad(BiquadSpec(kind: .highshelf, frequency: cutoffHz, gainDb: gainDb)))
    }

    // MARK: Gain

    public mutating func gain(_ db: Double) { add(.gain(db: db)) }

    // MARK: Blanket

    private static func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }

    /// Append one Blanket knob at `amount` (0..1 nominal; the editor feeds
    /// slider × INTENSITY). Same mapping as Blanket.ts.
    public mutating func blanket(_ term: BlanketTerm, _ amount: Double = 1) {
        switch term {
        case .volume:
            // Bipolar fader, ≈ ±12 dB at the editor's swing; the very bottom is silence.
            let db = amount * 4.0
            gain(db <= -11.5 ? -120 : db)
        case .highPassRumble:
            highPass(40 + amount * 40) // 40 → 80 Hz
        case .denoise:
            add(.spectralGate(SpectralGateParams(propDecrease: Self.clamp01(amount), stationary: true)))
        case .kickPresence: peakEQ(90, gainDb: amount * 3.0, q: 1.2)
        case .snareBody: peakEQ(200, gainDb: amount * 2.5, q: 1.5)
        case .boxiness: peakEQ(350, gainDb: -amount * 3.0, q: 0.8)
        case .attack: peakEQ(4000, gainDb: amount * 3.0, q: 1.0)
        case .harshness: peakEQ(6000, gainDb: -amount * 2.5, q: 1.0)
        case .air: highShelf(10000, gainDb: amount * 3.0)
        case .brightness: highShelf(8000, gainDb: amount * 2.0)
        case .resonance: add(.resonance(amount: amount))
        case .dynamicRange:
            add(.compressor(DynamicsParams(thresholdDb: -18, ratio: 1.0 + amount * 3.0, attackMs: 10, releaseMs: 100)))
        case .punch:
            add(.compressor(DynamicsParams(thresholdDb: -20, ratio: 1.0 + amount * 2.0, attackMs: amount * 30.0, releaseMs: 80)))
        case .sustain:
            add(.gate(DynamicsParams(thresholdDb: -40, ratio: 1.0 + amount * 2.0, attackMs: 1.0, releaseMs: 100)))
        case .detail:
            add(.upwardCompressor(UpwardCompressorParams(
                thresholdDb: -30, ratio: 1.0 + amount, maxGainDb: amount * 4.0, attackMs: 5, releaseMs: 150)))
        case .consistency:
            add(.compressor(DynamicsParams(thresholdDb: -12, ratio: 1.0 + amount * 1.0, attackMs: 5, releaseMs: 50)))
        case .pumping:
            add(.compressor(DynamicsParams(thresholdDb: -18, ratio: 1.0 + amount * 1.0, attackMs: 10,
                                           releaseMs: 100 + amount * 400)))
        case .roominess:
            add(.spectralGate(SpectralGateParams(propDecrease: Self.clamp01(amount), stationary: false)))
        case .width: add(.width(amount: amount))
        case .depth:
            add(.reverb(ReverbSpec(roomSize: Self.clamp01(amount * 0.3), damping: 0.7,
                                   wetLevel: Self.clamp01(amount * 0.15), dryLevel: 1.0)))
        case .clipping: add(.saturation(drive: 1.0 + amount))
        case .warmth: add(.saturation(drive: 1.0 + amount * 2.0))
        case .presence:
            add(.presence(PresenceParams(lowHz: 2000, highHz: 8000, drive: 1.0 + amount, blend: amount * 0.3)))
        case .fullness:
            peakEQ(200, gainDb: amount * 1.5, q: 1.5)
            add(.saturation(drive: 1.0 + amount * 0.5))
        case .naturalness:
            add(.compressor(DynamicsParams(thresholdDb: -3, ratio: 1.0 + amount * 19.0, attackMs: 0.1, releaseMs: 50)))
        }
    }
}
