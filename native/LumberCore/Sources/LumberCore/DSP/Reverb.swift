// Port of src/dsp/reverbIR.ts plus the Web Audio ConvolverNode it fed.
//
// The IR is exponentially-decaying noise, low-passed by `damping`
// (approximating pedalboard.Reverb's Freeverb room). The TS drew the noise from
// Math.random(), so no two renders matched; here it comes from a seeded
// 32-bit LCG (s = s·1664525 + 1013904223, u = s / 2^32) so renders are
// reproducible. The statistics are the same; individual samples are not.
//
// Convolution follows the ConvolverNode with `normalize = true` (the default):
// the IR is scaled by the spec's RMS-based normalization
// (GainCalibration 0.00125 × 44100 / sampleRate / rms), and the output is
// truncated to the input length (an OfflineAudioContext renders exactly
// `length` frames, so the tail past the end is lost — same as the TS).

import Foundation

/// Deterministic 32-bit LCG giving uniform doubles in [0, 1).
public struct LCGRandom: Sendable {
    public var state: UInt32
    public init(seed: UInt32) { state = seed }
    public mutating func next() -> Double {
        state = state &* 1664525 &+ 1013904223
        return Double(state) / 4294967296.0
    }
}

extension DSP {
    /// Default seed for the reverb IR noise.
    public static let defaultReverbSeed: UInt32 = 0x5EED_0001

    /// Stereo impulse response for `depth`'s reverb (reverbIR.ts `makeImpulseResponse`).
    public static func makeImpulseResponse(sampleRate sr: Double, roomSize: Double, damping: Double,
                                           seed: UInt32 = defaultReverbSeed) -> [[Float]] {
        var rng = LCGRandom(seed: seed)
        let decay = 0.1 + roomSize * 3.0 // seconds
        let len = max(1, Int((sr * decay).rounded(.down)))
        let lpCoeff = 1 - min(0.999, damping)
        var ir = [[Float]](repeating: [Float](repeating: 0, count: len), count: 2)
        let dlen = Double(len)
        for c in 0..<2 {
            var lp = 0.0
            for i in 0..<len {
                let di = Double(i)
                let env = pow(1 - di / dlen, 2) * exp(-3 * (di / sr) / decay)
                let noise = rng.next() * 2 - 1
                lp += lpCoeff * (noise - lp)
                ir[c][i] = Float(lp * env)
            }
        }
        return ir
    }

    /// Web Audio ConvolverNode normalization scale for `ir` (spec `calculateNormalizationScale`).
    public static func convolverNormalizationScale(_ ir: [[Float]], sampleRate: Double) -> Double {
        let gainCalibration = 0.00125
        let gainCalibrationSampleRate = 44100.0
        let minPower = 0.000125
        let length = ir.first?.count ?? 0
        guard length > 0 else { return 1 }
        var power = 0.0
        for ch in ir {
            var p = 0.0
            for v in ch { p += Double(v) * Double(v) }
            power += p
        }
        power = (power / Double(ir.count * length)).squareRoot()
        if !power.isFinite || power < minPower { power = minPower }
        var scale = 1 / power
        scale *= gainCalibration
        if sampleRate > 0 { scale *= gainCalibrationSampleRate / sampleRate }
        if ir.count == 4 { scale *= 0.5 }
        return scale
    }

    /// Linear convolution of `x` with `h`, truncated to `x.count` (FFT
    /// overlap-add, all Double). Returns Double samples.
    public static func convolveTruncated(_ x: [Float], _ h: [Double]) -> [Double] {
        let n = x.count, m = h.count
        var out = [Double](repeating: 0, count: n)
        if n == 0 || m == 0 { return out }
        if m <= 64 || n <= 64 {
            for i in 0..<n {
                var acc = 0.0
                for k in 0...min(i, m - 1) { acc += Double(x[i - k]) * h[k] }
                out[i] = acc
            }
            return out
        }
        let N = nextPow2(2 * m)
        let L = N - m + 1
        var hRe = [Double](repeating: 0, count: N)
        var hIm = [Double](repeating: 0, count: N)
        for k in 0..<m { hRe[k] = h[k] }
        fftDouble(&hRe, &hIm)
        var start = 0
        var re = [Double](repeating: 0, count: N)
        var im = [Double](repeating: 0, count: N)
        while start < n {
            let segLen = min(L, n - start)
            for i in 0..<N { re[i] = i < segLen ? Double(x[start + i]) : 0; im[i] = 0 }
            fftDouble(&re, &im)
            for i in 0..<N {
                let r = re[i] * hRe[i] - im[i] * hIm[i]
                let j = re[i] * hIm[i] + im[i] * hRe[i]
                re[i] = r; im[i] = j
            }
            fftDouble(&re, &im, inverse: true)
            let end = min(n, start + N)
            for i in start..<end { out[i] += re[i - start] }
            start += L
        }
        return out
    }

    /// Reverb as the TS graph built it: source → [ConvolverNode → wet gain] + [dry gain] → sum.
    /// Mono input: the stereo convolver output is summed back to mono by the
    /// destination's speaker down-mix (½(L+R)). Stereo: L uses IR channel 0, R channel 1.
    /// Channels beyond the first two get the dry path only.
    public static func reverb(_ channels: [[Float]], sampleRate sr: Double, _ spec: ReverbSpec,
                              seed: UInt32 = defaultReverbSeed) -> [[Float]] {
        guard !channels.isEmpty else { return channels }
        let ir = makeImpulseResponse(sampleRate: sr, roomSize: spec.roomSize, damping: spec.damping, seed: seed)
        let scale = convolverNormalizationScale(ir, sampleRate: sr)
        let wet = Double(Float(spec.wetLevel))
        let dry = Double(Float(spec.dryLevel))
        let h0 = ir[0].map { Double($0) * scale }
        let h1 = ir[1].map { Double($0) * scale }
        var out = channels
        if channels.count == 1 {
            let hm = zip(h0, h1).map { 0.5 * ($0 + $1) }
            let y = convolveTruncated(channels[0], hm)
            for i in 0..<y.count { out[0][i] = Float(dry * Double(channels[0][i]) + wet * y[i]) }
        } else {
            for (c, h) in [(0, h0), (1, h1)] {
                let y = convolveTruncated(channels[c], h)
                for i in 0..<y.count { out[c][i] = Float(dry * Double(channels[c][i]) + wet * y[i]) }
            }
            for c in 2..<channels.count {
                for i in 0..<channels[c].count { out[c][i] = Float(dry * Double(channels[c][i])) }
            }
        }
        return out
    }
}
