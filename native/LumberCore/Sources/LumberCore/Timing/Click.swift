// Port of src/audio/click.ts (metronome click) and src/audio/peaks.ts
// (waveform peaks for the editor lanes).

import Foundation

extension Timing {
    public struct ClickOptions: Sendable, Equatable {
        public var freq: Double // Hz
        public var durationMs: Double
        public var gain: Double
        public init(freq: Double = 1000, durationMs: Double = 30, gain: Double = 0.8) {
            self.freq = freq; self.durationMs = durationMs; self.gain = gain
        }
        public static let accent = ClickOptions(freq: 1600, durationMs: 35, gain: 0.9)
        public static let beat = ClickOptions(freq: 1000, durationMs: 30, gain: 0.7)
    }

    /// Short sine burst with a fast exponential decay and a 0.5 ms attack ramp.
    public static func makeClick(sampleRate: Double, _ opts: ClickOptions = ClickOptions()) -> [Float] {
        let n = max(1, DSP.jsRound((sampleRate * opts.durationMs) / 1000))
        var out = [Float](repeating: 0, count: n)
        let tau = Double(n) / 6
        let attack = Double(max(1, DSP.jsRound(sampleRate * 0.0005)))
        for i in 0..<n {
            let di = Double(i)
            let env = exp(-di / tau) * min(1, di / attack)
            out[i] = Float(opts.gain * env * sin((2 * Double.pi * opts.freq * di) / sampleRate))
        }
        return out
    }

    /// Mono mixdown (average). Returns the channel itself when mono.
    public static func toMono(_ channels: [[Float]]) -> [Float] {
        if channels.count == 1 { return channels[0] }
        guard let n = channels.first?.count else { return [] }
        var out = [Float](repeating: 0, count: n)
        for ch in channels { for i in 0..<n { out[i] = Float(Double(out[i]) + Double(ch[i])) } }
        let d = Double(channels.count)
        for i in 0..<n { out[i] = Float(Double(out[i]) / d) }
        return out
    }

    /// Peak |amplitude| per column for [startSec, endSec) of a signal placed at
    /// `offsetSec` on the timeline. Columns outside the signal are 0. The scan
    /// per column is capped (strided) at 2048 samples.
    public static func windowPeaks(_ signal: [Float], sampleRate: Double, startSec: Double, endSec: Double,
                                   columns: Int, offsetSec: Double = 0) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, columns))
        if columns <= 0 || endSec <= startSec { return out }
        let colSec = (endSec - startSec) / Double(columns)
        let maxScan = 2048
        for c in 0..<columns {
            let a = max(0, Int(((startSec + Double(c) * colSec - offsetSec) * sampleRate).rounded(.down)))
            let b = min(signal.count, Int(((startSec + Double(c + 1) * colSec - offsetSec) * sampleRate).rounded(.down)))
            if b <= a { continue }
            let step = max(1, (b - a) / maxScan)
            var p: Float = 0
            var i = a
            while i < b {
                let v = abs(signal[i])
                if v > p { p = v }
                i += step
            }
            out[c] = p
        }
        return out
    }
}
