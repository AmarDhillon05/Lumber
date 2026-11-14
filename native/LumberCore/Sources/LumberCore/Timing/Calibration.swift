// Port of src/audio/calibration.ts (the pure part): find the round-trip latency
// of a click train inside a mic recording.
//
// 1. Matched filter: cross-correlate the recording with the click (FFT).
// 2. Coarse: sum the filter energy (1 ms bins) at every click position per lag.
// 3. Fine: the same sum at full rate within ±2 ms of the coarse peak.
// The device run (play clicks + record) lives in the app.

import Foundation

extension Timing {
    public struct LatencyEstimate: Sendable, Equatable {
        public var latencyMs: Double
        /// Peak-to-median ratio of the coarse correlation (~1 = no clicks; real clicks ≫ 8).
        public var confidence: Double
        /// Spread (ms) of per-click lags around the estimate.
        public var spreadMs: Double
        public init(latencyMs: Double, confidence: Double, spreadMs: Double) {
            self.latencyMs = latencyMs; self.confidence = confidence; self.spreadMs = spreadMs
        }
        /// confidence ≥ 8 and spread ≤ 2 ms.
        public var isReliable: Bool { confidence >= 8 && spreadMs <= 2 }
    }

    public static let calibrationClicks = 8
    public static let calibrationIntervalSec = 0.5

    /// Delay of a click train in `recorded` (mono).
    /// - Parameters:
    ///   - clickFileTimes: where each click would sit with zero latency (s from the first sample).
    ///   - maxLagSec: search window (default 0.6 s, covers Bluetooth).
    ///   - template: the click waveform (default `makeClick(sampleRate, .beat)`).
    public static func estimateLatency(_ recorded: [Float], sampleRate: Double, clickFileTimes: [Double],
                                       maxLagSec: Double = 0.6, template: [Float]? = nil) -> LatencyEstimate {
        let tpl = template ?? makeClick(sampleRate: sampleRate, .beat)
        let m = matchedFilter(recorded, tpl)
        var m2 = [Float](repeating: 0, count: m.count)
        for i in 0..<m.count { m2[i] = Float(Double(m[i]) * Double(m[i])) }

        let bin = max(1, DSP.jsRound(sampleRate / 1000))
        let nb = m2.count / bin
        var binE = [Double](repeating: 0, count: nb)
        for b in 0..<nb {
            var e = 0.0
            for k in 0..<bin { e += Double(m2[b * bin + k]) }
            binE[b] = e
        }
        let maxLag = DSP.jsRound((maxLagSec * sampleRate) / Double(bin))
        let clickBins = clickFileTimes.map { Int(floor(($0 * sampleRate) / Double(bin))) }
        var scores = [Double](repeating: 0, count: maxLag + 1)
        for lag in 0...maxLag {
            var s = 0.0
            for c in clickBins {
                let b = c + lag
                if b >= 0 && b < nb { s += binE[b] }
            }
            scores[lag] = s
        }
        var best = 0
        if maxLag >= 1 { for lag in 1...maxLag where scores[lag] > scores[best] { best = lag } }
        let med = median(scores)
        let confidence = scores[best] / (med + 1e-12)

        let starts = clickFileTimes.map { DSP.jsRound($0 * sampleRate) }
        let center = Double(best * bin)
        let fineLag = argmaxLag(m2, starts, center - Double(2 * bin), center + Double(3 * bin))

        let perClick = starts.map { argmaxLag(m2, [$0], Double(fineLag - 5 * bin), Double(fineLag + 5 * bin)) }
        var sq = 0.0
        for l in perClick { sq += Double((l - fineLag) * (l - fineLag)) }
        let spread = (sq / Double(max(1, perClick.count))).squareRoot()

        return LatencyEstimate(latencyMs: (Double(fineLag) / sampleRate) * 1000,
                               confidence: confidence,
                               spreadMs: (spread / sampleRate) * 1000)
    }

    /// out[n] = Σ_k x[n+k]·t[k] via FFT; same length as x.
    public static func matchedFilter(_ x: [Float], _ t: [Float]) -> [Float] {
        let n = DSP.nextPow2(x.count + t.count)
        var xr = [Float](repeating: 0, count: n), xi = [Float](repeating: 0, count: n)
        var tr = [Float](repeating: 0, count: n), ti = [Float](repeating: 0, count: n)
        for i in 0..<x.count { xr[i] = x[i] }
        for i in 0..<t.count { tr[i] = t[i] }
        DSP.fft(&xr, &xi)
        DSP.fft(&tr, &ti)
        for i in 0..<n { // X · conj(T)
            let a = Double(xr[i]), b = Double(xi[i]), c = Double(tr[i]), d = Double(ti[i])
            xr[i] = Float(a * c + b * d)
            xi[i] = Float(b * c - a * d)
        }
        DSP.fft(&xr, &xi, inverse: true)
        return Array(xr[0..<x.count])
    }

    /// Lag in [lo, hi] maximizing Σ m2[start + lag].
    private static func argmaxLag(_ m2: [Float], _ starts: [Int], _ loIn: Double, _ hiIn: Double) -> Int {
        let lo = max(0, DSP.jsRound(loIn))
        let hi = max(lo, DSP.jsRound(hiIn))
        var bestLag = lo
        var bestScore = -Double.infinity
        for lag in lo...hi {
            var score = 0.0
            for s in starts {
                let o = s + lag
                if o >= 0 && o < m2.count { score += Double(m2[o]) }
            }
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        return bestLag
    }
}
