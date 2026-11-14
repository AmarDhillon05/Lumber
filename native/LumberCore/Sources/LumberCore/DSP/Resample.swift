// Port of the windowed-sinc resampler in src/dsp/mix.ts: Kaiser-windowed sinc,
// polyphase. Exact phases for rational ratios with ≤ 2048 phases, otherwise a
// 1024-phase table with linear interpolation.

import Foundation

extension DSP {
    private static let zeroCrossings = 32.0 // per side, at the filter cutoff
    private static let rolloff = 0.95 // cutoff as a fraction of the lower Nyquist
    private static let kaiserBeta = 9.0 // ≈ 90 dB stopband
    private static let maxExactPhases = 2048
    private static let interpPhases = 1024

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let q = (x * x) / 4
        for k in 1..<50 {
            let dk = Double(k)
            term *= q / (dk * dk)
            sum += term
            if term < 1e-12 * sum { break }
        }
        return sum
    }

    public enum ResampleError: Error, Equatable { case nonPositiveRate }

    /// Band-limited resample. Output length is round(inLength · toRate / fromRate).
    /// Same-rate input is returned as a copy.
    public static func resample(_ channels: [[Float]], from fromRate: Double, to toRate: Double) throws -> [[Float]] {
        if fromRate == toRate { return channels }
        guard fromRate > 0 && toRate > 0 else { throw ResampleError.nonPositiveRate }

        let fr = jsRound(fromRate)
        let tr = jsRound(toRate)
        let div = gcd(fr, tr)
        let up = tr / div
        let down = fr / div
        let ratio = toRate / fromRate

        let fc = min(1, ratio) * rolloff
        let half = Int((zeroCrossings / fc).rounded(.up))
        let taps = 2 * half

        let exact = up <= maxExactPhases
        let phases = exact ? up : interpPhases
        let rows = exact ? phases : phases + 1
        var table = [Float](repeating: 0, count: rows * taps)
        let i0b = besselI0(kaiserBeta)
        let dhalf = Double(half)
        for p in 0..<rows {
            let frac = Double(p) / Double(phases)
            var sum = 0.0
            for k in 0..<taps {
                let t = Double(k - half + 1) - frac
                let x = fc * t
                let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                let r = t / dhalf
                let w = abs(r) >= 1 ? 0 : besselI0(kaiserBeta * (1 - r * r).squareRoot()) / i0b
                let v = fc * sinc * w
                table[p * taps + k] = Float(v)
                sum += v // the TS sums the unrounded value
            }
            for k in 0..<taps { table[p * taps + k] = Float(Double(table[p * taps + k]) / sum) }
        }

        return table.withUnsafeBufferPointer { table in
            channels.map { x -> [Float] in
                let inLen = x.count
                let outLen = jsRound(Double(inLen) * toRate / fromRate)
                var y = [Float](repeating: 0, count: outLen)
                x.withUnsafeBufferPointer { x in
                    for n in 0..<outLen {
                        var base: Int
                        var row0: Int
                        var row1 = -1
                        var mix = 0.0
                        if exact {
                            let num = n * down
                            base = num / up // floor (num ≥ 0)
                            row0 = (num - base * up) * taps
                        } else {
                            let pos = Double(n) / ratio
                            base = Int(pos.rounded(.down))
                            let fp = (pos - Double(base)) * Double(phases)
                            let p = Int(fp.rounded(.down))
                            mix = fp - Double(p)
                            row0 = p * taps
                            row1 = (p + 1) * taps
                        }
                        let start = base - half + 1
                        var acc = 0.0
                        let k0 = max(0, -start)
                        let k1 = min(taps, inLen - start)
                        if k0 < k1 {
                            if row1 < 0 {
                                for k in k0..<k1 { acc += Double(x[start + k]) * Double(table[row0 + k]) }
                            } else {
                                for k in k0..<k1 {
                                    let t0 = Double(table[row0 + k])
                                    let w = t0 + (Double(table[row1 + k]) - t0) * mix
                                    acc += Double(x[start + k]) * w
                                }
                            }
                        }
                        y[n] = Float(acc)
                    }
                }
                return y
            }
        }
    }
}
