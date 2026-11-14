// Biquads.
//
// 1. `BiquadCoefficients.bandpass` + `DSP.filtfilt`: port of src/dsp/biquad.ts
//    (Audio EQ Cookbook band-pass, zero-phase forward-backward Direct Form I),
//    used inside the presence effect.
// 2. `BiquadCoefficients.webAudio`: the Web Audio API BiquadFilterNode
//    coefficient formulas (https://webaudio.github.io/web-audio-api/#filters-characteristics),
//    which is what the TS chain's EQ ran on (react-native-audio-api's
//    OfflineAudioContext). Note the spec's quirks, kept here on purpose:
//    lowpass/highpass read Q in **dB** (α = sin ω0 / (2·10^(Q/20))), shelves
//    ignore Q (fixed slope S = 1), and A = 10^(G/40). AudioParam values are
//    single precision, so frequency/Q/gain are rounded to Float first.

import Foundation

/// Normalized biquad coefficients (a0 = 1).
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// Cookbook constant-0-dB-peak band-pass between `lowHz` and `highHz` (biquad.ts `bandpass`).
    public static func bandpass(lowHz: Double, highHz: Double, sampleRate fs: Double) -> BiquadCoefficients {
        let f0 = (lowHz * highHz).squareRoot()
        let q = f0 / (highHz - lowHz)
        let w0 = (2 * Double.pi * f0) / fs
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return BiquadCoefficients(b0: alpha / a0, b1: 0, b2: -alpha / a0,
                                  a1: (-2 * cos(w0)) / a0, a2: (1 - alpha) / a0)
    }

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    private static func normalized(_ b0: Double, _ b1: Double, _ b2: Double,
                                   _ a0: Double, _ a1: Double, _ a2: Double) -> BiquadCoefficients {
        let s = 1 / a0
        return BiquadCoefficients(b0: b0 * s, b1: b1 * s, b2: b2 * s, a1: a1 * s, a2: a2 * s)
    }

    /// Web Audio BiquadFilterNode coefficients.
    /// - Parameters:
    ///   - frequency: Hz, clamped to [0, Nyquist].
    ///   - q: the node's Q (default 1). dB for lowpass/highpass, linear for band/notch/peaking, unused for shelves.
    ///   - gainDb: peaking/shelf gain (default 0).
    public static func webAudio(kind: BiquadKind, frequency: Double, q: Double = 1,
                                gainDb: Double = 0, sampleRate: Double) -> BiquadCoefficients {
        // AudioParams are float32.
        let f = Double(Float(frequency))
        let qv = Double(Float(q))
        let g = Double(Float(gainDb))
        let nyquist = sampleRate / 2
        let f0 = min(max(f, 0), nyquist)
        let normFreq = f0 / nyquist // 0..1, as the spec's edge cases are phrased
        let w0 = Double.pi * normFreq // = 2π f0 / Fs
        let cosw = cos(w0)
        let sinw = sin(w0)
        let A = pow(10, g / 40)

        switch kind {
        case .lowpass, .highpass:
            // Edge cases (as in Chromium's Biquad.cpp): at Nyquist the lowpass
            // passes everything / the highpass nothing; at 0 the reverse.
            if normFreq >= 1 { return kind == .lowpass ? identity : BiquadCoefficients(b0: 0, b1: 0, b2: 0, a1: 0, a2: 0) }
            if normFreq <= 0 { return kind == .lowpass ? BiquadCoefficients(b0: 0, b1: 0, b2: 0, a1: 0, a2: 0) : identity }
            let alpha = sinw / (2 * pow(10, qv / 20))
            if kind == .lowpass {
                let b1 = 1 - cosw
                return normalized(b1 / 2, b1, b1 / 2, 1 + alpha, -2 * cosw, 1 - alpha)
            } else {
                let b1 = -(1 + cosw)
                return normalized((1 + cosw) / 2, b1, (1 + cosw) / 2, 1 + alpha, -2 * cosw, 1 - alpha)
            }
        case .bandpass:
            if normFreq <= 0 || normFreq >= 1 { return BiquadCoefficients(b0: 0, b1: 0, b2: 0, a1: 0, a2: 0) }
            if qv <= 0 { return identity }
            let alpha = sinw / (2 * qv)
            return normalized(alpha, 0, -alpha, 1 + alpha, -2 * cosw, 1 - alpha)
        case .notch:
            if normFreq <= 0 || normFreq >= 1 { return identity }
            if qv <= 0 { return BiquadCoefficients(b0: 0, b1: 0, b2: 0, a1: 0, a2: 0) }
            let alpha = sinw / (2 * qv)
            return normalized(1, -2 * cosw, 1, 1 + alpha, -2 * cosw, 1 - alpha)
        case .peaking:
            if normFreq <= 0 || normFreq >= 1 { return identity }
            if qv <= 0 { return BiquadCoefficients(b0: A * A, b1: 0, b2: 0, a1: 0, a2: 0) }
            let alpha = sinw / (2 * qv)
            return normalized(1 + alpha * A, -2 * cosw, 1 - alpha * A, 1 + alpha / A, -2 * cosw, 1 - alpha / A)
        case .lowshelf, .highshelf:
            let isLow = kind == .lowshelf
            if normFreq >= 1 { return isLow ? BiquadCoefficients(b0: A * A, b1: 0, b2: 0, a1: 0, a2: 0) : identity }
            if normFreq <= 0 { return isLow ? identity : BiquadCoefficients(b0: A * A, b1: 0, b2: 0, a1: 0, a2: 0) }
            let alphaS = sinw / 2 * 2.0.squareRoot() // S = 1
            let k = 2 * alphaS * A.squareRoot()
            if isLow {
                return normalized(A * ((A + 1) - (A - 1) * cosw + k),
                                  2 * A * ((A - 1) - (A + 1) * cosw),
                                  A * ((A + 1) - (A - 1) * cosw - k),
                                  (A + 1) + (A - 1) * cosw + k,
                                  -2 * ((A - 1) + (A + 1) * cosw),
                                  (A + 1) + (A - 1) * cosw - k)
            } else {
                return normalized(A * ((A + 1) + (A - 1) * cosw + k),
                                  -2 * A * ((A - 1) + (A + 1) * cosw),
                                  A * ((A + 1) + (A - 1) * cosw - k),
                                  (A + 1) - (A - 1) * cosw + k,
                                  2 * ((A - 1) - (A + 1) * cosw),
                                  (A + 1) - (A - 1) * cosw - k)
            }
        }
    }

    /// Complex response magnitude at `frequency` Hz (for tests / UI curves).
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
    }
}

extension DSP {
    /// Single-pass Direct Form I (Double state, Float output).
    public static func biquad(_ x: [Float], _ c: BiquadCoefficients) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        x.withUnsafeBufferPointer { x in
            y.withUnsafeMutableBufferPointer { y in
                for i in 0..<x.count {
                    let xn = Double(x[i])
                    let yn = c.b0 * xn + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
                    x2 = x1; x1 = xn
                    y2 = y1; y1 = yn
                    y[i] = Float(yn)
                }
            }
        }
        return y
    }

    /// Zero-phase: filter forward, then backward (≈ scipy sosfiltfilt, order 2).
    /// Note the backward pass re-reads the Float-rounded forward output, as the TS does.
    public static func filtfilt(_ x: [Float], _ c: BiquadCoefficients) -> [Float] {
        let fwd = biquad(x, c)
        let back = biquad(Array(fwd.reversed()), c)
        return Array(back.reversed())
    }
}
