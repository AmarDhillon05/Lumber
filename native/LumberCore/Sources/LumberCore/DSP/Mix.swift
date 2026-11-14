// Port of src/dsp/mix.ts (mixer, limiter, normalize). The resampler is in
// Resample.swift.

import Foundation

extension DSP {
    /// Separated stems of the song, for "remove original drums".
    public struct OriginalDrums: Sendable, Equatable {
        /// Separated drum stem of the song.
        public var drums: [[Float]]
        /// Song with drums removed (bass + other + vocals).
        public var noDrums: [[Float]]
        /// How much of the original drums to keep, 0..1 (linear).
        public var amount: Double
        public init(drums: [[Float]], noDrums: [[Float]], amount: Double) {
            self.drums = drums; self.noDrums = noDrums; self.amount = amount
        }
    }

    public struct MixOptions: Sendable, Equatable {
        /// Backing track (ignored when `originalDrums` is set).
        public var song: [[Float]]
        /// Processed drum take. Mono drums go to every output channel.
        public var drums: [[Float]]
        /// All inputs must already be at this rate (see `resample`).
        public var sampleRate: Double
        /// Song time (s) at which drum sample 0 lands; negative trims the drum start.
        public var drumOffsetSec: Double
        /// Linear gain on the backing (song, or noDrums + amount·drums).
        public var songGain: Double
        /// Linear gain on the drum take.
        public var drumGain: Double
        public var originalDrums: OriginalDrums?
        /// Brick-wall limit the sum (default true).
        public var limit: Bool
        /// Limiter / normalize ceiling, dBFS (default −1).
        public var ceilingDb: Double
        /// After limiting, scale so the peak sits exactly at the ceiling (default false).
        public var normalize: Bool

        public init(song: [[Float]], drums: [[Float]], sampleRate: Double, drumOffsetSec: Double,
                    songGain: Double = 1, drumGain: Double = 1, originalDrums: OriginalDrums? = nil,
                    limit: Bool = true, ceilingDb: Double = -1, normalize: Bool = false) {
            self.song = song; self.drums = drums; self.sampleRate = sampleRate
            self.drumOffsetSec = drumOffsetSec; self.songGain = songGain; self.drumGain = drumGain
            self.originalDrums = originalDrums; self.limit = limit; self.ceilingDb = ceilingDb
            self.normalize = normalize
        }
    }

    public struct LimiterOptions: Sendable, Equatable {
        public var ceilingDb: Double
        public var lookaheadMs: Double
        public var releaseMs: Double
        public init(ceilingDb: Double = -1, lookaheadMs: Double = 5, releaseMs: Double = 80) {
            self.ceilingDb = ceilingDb; self.lookaheadMs = lookaheadMs; self.releaseMs = releaseMs
        }
    }

    /// JS Math.round: nearest, ties toward +∞.
    @inline(__always) static func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

    private static func len(_ ch: [[Float]]) -> Int { ch.first?.count ?? 0 }

    /// Mix a drum take over the backing. Output channel count is the max of
    /// the inputs (mono spread to all); length covers the backing and the placed drums.
    public static func mixTake(_ o: MixOptions) -> [[Float]] {
        let parts: [(ch: [[Float]], gain: Double)]
        if let od = o.originalDrums {
            parts = [(od.noDrums, o.songGain), (od.drums, o.songGain * od.amount)]
        } else {
            parts = [(o.song, o.songGain)]
        }
        let drums = o.drums
        let offset = jsRound(o.drumOffsetSec * o.sampleRate)
        let drumLen = len(drums)
        let drumStart = max(0, -offset)
        let drumEnd = max(0, drumLen + offset)
        let backingLen = max(0, parts.map { len($0.ch) }.max() ?? 0)
        let n = max(backingLen, drumLen > drumStart ? drumEnd : 0)
        let nch = max(1, drums.count, parts.map { $0.ch.count }.max() ?? 0)

        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: nch)

        for (ch, gain) in parts where !ch.isEmpty && gain != 0 {
            for c in 0..<nch {
                let src = ch[min(c, ch.count - 1)]
                let m = min(src.count, n)
                out[c].withUnsafeMutableBufferPointer { dst in
                    for i in 0..<m { dst[i] = Float(Double(dst[i]) + Double(src[i]) * gain) }
                }
            }
        }

        if !drums.isEmpty && o.drumGain != 0 {
            for c in 0..<nch {
                let src = drums[min(c, drums.count - 1)]
                if drumStart < src.count {
                    out[c].withUnsafeMutableBufferPointer { dst in
                        for j in drumStart..<src.count {
                            dst[j + offset] = Float(Double(dst[j + offset]) + Double(src[j]) * o.drumGain)
                        }
                    }
                }
            }
        }

        if o.limit { limitPeaks(&out, sampleRate: o.sampleRate, LimiterOptions(ceilingDb: o.ceilingDb)) }
        if o.normalize { normalizePeak(&out, ceilingDb: o.ceilingDb) }
        return out
    }

    /// Stereo-linked lookahead brick-wall limiter, in place. Offline and
    /// non-causal: gain ramps down `lookaheadMs` before a peak and is
    /// guaranteed ≤ ceiling/|peak| at it; recovery is exponential (`releaseMs`).
    public static func limitPeaks(_ channels: inout [[Float]], sampleRate: Double,
                                  _ opts: LimiterOptions = LimiterOptions()) {
        let n = len(channels)
        if n == 0 { return }
        let ceiling = dbToLin(opts.ceilingDb)
        let L = max(1, jsRound((opts.lookaheadMs / 1000) * sampleRate))
        let relCoeff = exp(-1 / ((opts.releaseMs / 1000) * sampleRate))

        var g = [Float](repeating: 0, count: n)
        var needed = false
        for i in 0..<n {
            var p = 0.0
            for c in 0..<channels.count {
                let a = abs(Double(channels[c][i]))
                if a > p { p = a }
            }
            g[i] = p > ceiling ? Float(ceiling / p) : 1
            if g[i] < 1 { needed = true }
        }
        if !needed { return }

        // m[i] = min(g[i ... i+L]) via a monotonic deque.
        var m = [Float](repeating: 0, count: n)
        var dq = [Int](repeating: 0, count: n)
        var head = 0, tail = 0, next = 0
        for i in 0..<n {
            let hi = min(n - 1, i + L)
            while next <= hi {
                while tail > head && g[dq[tail - 1]] >= g[next] { tail -= 1 }
                dq[tail] = next; tail += 1
                next += 1
            }
            while dq[head] < i { head += 1 }
            m[i] = g[dq[head]]
        }

        // s[i] = mean(m[i-L ... i]) (padded with m[0] before L), then release.
        var acc = 0.0
        var env = 1.0
        let lp1 = Double(L + 1)
        for i in 0..<n {
            acc += Double(m[i])
            if i > L { acc -= Double(m[i - L - 1]) }
            let s = i >= L ? acc / lp1 : (acc + Double(L - i) * Double(m[0])) / lp1
            env = min(s, 1 - (1 - env) * relCoeff)
            for c in 0..<channels.count {
                var y = Double(channels[c][i]) * env
                if y > ceiling { y = ceiling } else if y < -ceiling { y = -ceiling }
                channels[c][i] = Float(y)
            }
        }
    }

    /// Scale in place so the absolute peak equals `ceilingDb` dBFS (silence untouched).
    public static func normalizePeak(_ channels: inout [[Float]], ceilingDb: Double = -1) {
        var p = 0.0
        for ch in channels { for v in ch { p = max(p, abs(Double(v))) } }
        if p < 1e-9 { return }
        let g = dbToLin(ceilingDb) / p
        for c in 0..<channels.count {
            channels[c].withUnsafeMutableBufferPointer { x in
                for i in 0..<x.count { x[i] = Float(Double(x[i]) * g) }
            }
        }
    }
}
