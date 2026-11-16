// Auto mix: the steps a mix engineer does before touching the knobs by ear.
//
//   align   Line the take up with the song by cross-correlating onset
//           envelopes (where the hits are) of the take and a reference: the
//           separated original drums when there are stems (the drummer you're
//           replacing), else the full song. Returns a correction to the offset.
//   tone    Make the take's tonal balance match the original drums: measure
//           how each EQ knob moves the take's band levels (a sensitivity
//           matrix from real renders), solve a bounded, regularised least
//           squares for knob values, then verify with one more render.
//   level   Set the drum fader so the take sits at the original drums'
//           loudness (or ~5 dB under the song without stems), using gated,
//           K-weighted loudness over the stretch of song the take covers.
//   master  Bus glue (gentle 2:1 compression), loudness normalised to a
//           target LUFS, then the −1 dBFS limiter. Export only.
//
// All offline and deterministic; everything is tested on Linux.

import Foundation

public enum AutoMix {
    // MARK: - Onsets

    /// Onset-strength envelope at ~1 kHz (one value per `hop` samples):
    /// positive jumps in log energy of a low band (< 150 Hz: kick) and a high
    /// band (> 2 kHz: snare crack, hats), each normalised, summed, then
    /// lightly smoothed so near-misses still correlate.
    public static func onsetEnvelope(_ channels: [[Float]], sampleRate sr: Double) -> (env: [Float], rate: Double) {
        let hop = max(1, Int(sr / 1000))
        let rate = sr / Double(hop)
        guard let n = channels.first?.count, n > hop * 4 else { return ([], rate) }
        let frames = n / hop
        var lowE = [Double](repeating: 0, count: frames)
        var highE = [Double](repeating: 0, count: frames)
        let aLow = exp(-2 * Double.pi * 150 / sr)
        let aHigh = exp(-2 * Double.pi * 2000 / sr)
        let nch = Double(channels.count)
        var lp1 = 0.0, lp2 = 0.0
        for i in 0..<(frames * hop) {
            var x = 0.0
            for c in channels { x += Double(c[i]) }
            x /= nch
            lp1 = (1 - aLow) * x + aLow * lp1
            lp2 = (1 - aHigh) * x + aHigh * lp2
            let hi = x - lp2
            lowE[i / hop] += lp1 * lp1
            highE[i / hop] += hi * hi
        }
        func flux(_ e: [Double]) -> [Double] {
            let l = e.map { log(1e-10 + $0) }
            var out = [Double](repeating: 0, count: l.count)
            for k in 3..<max(3, l.count) {
                let base = (l[k - 1] + l[k - 2] + l[k - 3]) / 3
                out[k] = max(0, l[k] - base)
            }
            // Normalise by the spread so neither band dominates.
            let mean = out.reduce(0, +) / Double(max(1, out.count))
            let sd = sqrt(out.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, out.count)))
            return sd > 1e-12 ? out.map { $0 / sd } : out
        }
        let a = flux(lowE), b = flux(highE)
        var env = [Double](repeating: 0, count: frames)
        for k in 0..<frames { env[k] = a[k] + b[k] }
        // Gaussian smoothing, σ ≈ 2 ms.
        let kernel = (-6...6).map { exp(-Double($0 * $0) / (2 * 4.0)) }
        var smooth = [Float](repeating: 0, count: frames)
        for k in 0..<frames {
            var s = 0.0
            for (j, w) in kernel.enumerated() {
                let idx = k + j - 6
                if idx >= 0 && idx < frames { s += env[idx] * w }
            }
            smooth[k] = Float(s)
        }
        return (smooth, rate)
    }

    // MARK: - Align

    public enum AlignReference: String, Sendable, Codable { case originalDrums, song }

    public struct AlignResult: Sendable, Equatable {
        /// Add this to the current drum offset (s). Positive = drums later.
        public var deltaSec: Double
        /// 0…1: how much the best match stands out from the next best one.
        public var confidence: Double
        public var reference: AlignReference
        /// Below this the result shouldn't be applied automatically.
        public static let minConfidence = 0.08
        public var isReliable: Bool { confidence >= Self.minConfidence }
    }

    /// Correction to `drumOffsetSec` that best lines up the hits in `take`
    /// with the hits in `reference` (song time 0 = reference sample 0),
    /// searching ±`maxShiftSec`.
    public static func align(
        take: [[Float]], reference: [[Float]], referenceKind: AlignReference,
        sampleRate: Double, drumOffsetSec: Double, maxShiftSec: Double = 0.25
    ) -> AlignResult? {
        let t = onsetEnvelope(take, sampleRate: sampleRate)
        let r = onsetEnvelope(reference, sampleRate: sampleRate)
        guard !t.env.isEmpty, !r.env.isEmpty else { return nil }
        let rate = t.rate
        let maxLag = Int(maxShiftSec * rate)
        let start = Int((drumOffsetSec * rate).rounded())
        // Zero-mean take envelope: correlation then measures alignment, not loudness.
        let tMean = t.env.reduce(0, +) / Float(t.env.count)
        let tz = t.env.map { $0 - tMean }
        var scores = [Double](repeating: -.infinity, count: 2 * maxLag + 1)
        for li in 0...(2 * maxLag) {
            let lag = li - maxLag
            // Take frame j sits at reference frame start + lag + j.
            let j0 = max(0, -(start + lag))
            let j1 = min(tz.count, r.env.count - (start + lag))
            guard j1 - j0 > Int(rate) else { continue } // need ≥ 1 s overlap
            var s = 0.0
            tz.withUnsafeBufferPointer { tp in
                r.env.withUnsafeBufferPointer { rp in
                    let off = start + lag
                    for j in j0..<j1 { s += Double(tp[j]) * Double(rp[j + off]) }
                }
            }
            // Normalise by overlap; slight preference for small corrections, so
            // a whole-beat jump has to be clearly better to win.
            let x = Double(lag) / Double(max(1, maxLag))
            scores[li] = s / Double(j1 - j0) * (1 - 0.15 * x * x)
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best].isFinite, scores[best] > 0
        else { return nil }
        // Sub-frame peak by parabola.
        var frac = 0.0
        if best > 0, best < scores.count - 1, scores[best - 1].isFinite, scores[best + 1].isFinite {
            let a = scores[best - 1], b = scores[best], c = scores[best + 1]
            let d = a - 2 * b + c
            if d < 0 { frac = max(-0.5, min(0.5, 0.5 * (a - c) / d)) }
        }
        // Confidence: best vs the best score at least 25 ms away.
        let guardBins = Int(0.025 * rate)
        var second = 0.0
        for i in scores.indices where abs(i - best) > guardBins && scores[i].isFinite { second = max(second, scores[i]) }
        let confidence = max(0, min(1, (scores[best] - second) / scores[best]))
        let lagBins = Double(best - maxLag) + frac
        return AlignResult(deltaSec: lagBins / rate, confidence: confidence, reference: referenceKind)
    }

    // MARK: - Loudness and bands

    /// Gated, K-weighted loudness (LUFS) of `channels[start..<start+len]`.
    public static func loudness(_ channels: [[Float]], sampleRate: Double, start: Int = 0, length: Int? = nil) -> Double {
        let total = channels.first?.count ?? 0
        let s = max(0, min(total, start))
        let len = max(0, min(total - s, length ?? total))
        guard len > 0 else { return AudioAnalysis.silentDb }
        return AudioAnalysis.integratedLufs(Array(channels.prefix(2)), s, len, sampleRate)
    }

    /// Average band levels (dB, power) over up to `maxWindows` 4096-point
    /// Hann windows taken from the loudest part of the signal.
    public static func bandLevels(_ channels: [[Float]], sampleRate sr: Double, maxWindows: Int = 48) -> BandLevels {
        let n = 4096
        let total = channels.first?.count ?? 0
        var power = [Double](repeating: 0, count: Band.allCases.count)
        guard total >= n else { return BandLevels(sub: -120, low: -120, lowMid: -120, mid: -120, presence: -120, air: -120) }
        // Candidate windows, hop n/2; keep the loudest (skip silence between hits).
        var candidates: [(start: Int, energy: Double)] = []
        var s = 0
        while s + n <= total {
            var e = 0.0
            for c in channels { for i in stride(from: s, to: s + n, by: 8) { e += Double(c[i] * c[i]) } }
            candidates.append((s, e))
            s += n / 2
        }
        let chosen = candidates.sorted { $0.energy > $1.energy }.prefix(maxWindows)
        let hann = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1))) }
        for w in chosen {
            for c in channels {
                var re = [Float](repeating: 0, count: n), im = re
                for i in 0..<n { re[i] = c[w.start + i] * hann[i] }
                DSP.fft(&re, &im)
                for k in 1..<(n / 2) {
                    let f = Double(k) * sr / Double(n)
                    let p = Double(re[k] * re[k] + im[k] * im[k])
                    for (bi, band) in Band.allCases.enumerated() where f >= band.edges.lo && f < band.edges.hi {
                        power[bi] += p
                    }
                }
            }
        }
        var out = BandLevels(sub: 0, low: 0, lowMid: 0, mid: 0, presence: 0, air: 0)
        for (bi, band) in Band.allCases.enumerated() { out[band] = 10 * log10(power[bi] + 1e-12) }
        return out
    }

    /// Band levels relative to their own (power) total: tonal shape, not level.
    static func shape(_ b: BandLevels) -> [Double] {
        let lin = Band.allCases.map { pow(10, b[$0] / 10) }
        let total = 10 * log10(lin.reduce(0, +) + 1e-12)
        return Band.allCases.map { b[$0] - total }
    }

    /// How much each band's mismatch counts (phone mics can't do much below 60 Hz).
    static let bandWeights: [Double] = [0.4, 1, 1, 1, 1, 0.8]

    // MARK: - Tone

    /// The EQ-like knobs tone matching may move.
    public static let toneKnobs: [BlanketTerm] = [.kickPresence, .snareBody, .boxiness, .attack, .harshness, .air, .brightness]

    public struct ToneResult: Sendable, Equatable {
        public var values: BlanketValues
        /// Weighted RMS band mismatch (dB) before and after.
        public var mismatchBeforeDb: Double
        public var mismatchAfterDb: Double
    }

    static func mismatch(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0, w = 0.0
        for i in a.indices {
            s += bandWeights[i] * (a[i] - b[i]) * (a[i] - b[i])
            w += bandWeights[i]
        }
        return sqrt(s / w)
    }

    /// Knob values (starting from `values`) that move the rendered take's
    /// tonal shape toward `target`'s. Only `toneKnobs` change.
    public static func matchTone(
        take: [[Float]], target: [[Float]], sampleRate: Double, values: BlanketValues, excerptSec: Double = 8
    ) -> ToneResult {
        let excerpt = loudestExcerpt(take, sampleRate: sampleRate, seconds: excerptSec)
        func shapeOf(_ v: BlanketValues) -> [Double] {
            shape(bandLevels(DSP.renderBlanket(excerpt, sampleRate: sampleRate, values: v), sampleRate: sampleRate))
        }
        let goal = shape(bandLevels(target, sampleRate: sampleRate))
        let base = shapeOf(values)
        let before = mismatch(base, goal)

        // Sensitivity of each band to each knob, by finite difference (step 0.5).
        let step = 0.5
        var S = [[Double]](repeating: [Double](repeating: 0, count: toneKnobs.count), count: base.count)
        for (k, term) in toneKnobs.enumerated() {
            var v = values
            let cur = v[term] ?? 0
            let dir: Double = cur + step <= 1 ? 1 : -1
            v[term] = cur + dir * step
            let moved = shapeOf(v)
            for b in base.indices { S[b][k] = (moved[b] - base[b]) / (dir * step) }
        }
        // Weighted, ridge-regularised least squares with box constraints by
        // projected gradient descent: minimise Σ w_b (S·d − e)_b² + λ|d|².
        let e = base.indices.map { goal[$0] - base[$0] }
        let lambda = 0.5
        var d = [Double](repeating: 0, count: toneKnobs.count)
        let lo = toneKnobs.map { -1 - (values[$0] ?? 0) }
        let hi = toneKnobs.map { 1 - (values[$0] ?? 0) }
        // Step size from a bound on the Hessian's largest eigenvalue.
        var L = lambda
        for b in base.indices { L += bandWeights[b] * S[b].reduce(0) { $0 + $1 * $1 } }
        let eta = 1 / max(L, 1e-6)
        for _ in 0..<400 {
            var g = d.map { lambda * $0 }
            for b in base.indices {
                var r = -e[b]
                for k in d.indices { r += S[b][k] * d[k] }
                for k in d.indices { g[k] += bandWeights[b] * r * S[b][k] }
            }
            for k in d.indices { d[k] = min(hi[k], max(lo[k], d[k] - eta * 2 * g[k])) }
        }
        // Verify on a real render; back off if the linear model overshot.
        var best = (values, before)
        for scale in [1.0, 0.6, 0.3] {
            var v = values
            for (k, term) in toneKnobs.enumerated() {
                let nv = (values[term] ?? 0) + scale * d[k]
                v[term] = (nv * 100).rounded() / 100
            }
            let m = mismatch(shapeOf(v), goal)
            if m < best.1 - 0.05 { best = (v, m) }
            if m < before * 0.7 { break }
        }
        return ToneResult(values: best.0, mismatchBeforeDb: before, mismatchAfterDb: best.1)
    }

    /// The loudest `seconds` of `channels` (energy over 0.5 s blocks).
    static func loudestExcerpt(_ channels: [[Float]], sampleRate: Double, seconds: Double) -> [[Float]] {
        let n = channels.first?.count ?? 0
        let len = Int(seconds * sampleRate)
        guard n > len else { return channels }
        let block = Int(0.5 * sampleRate)
        var energy: [Double] = []
        var i = 0
        while i + block <= n {
            var e = 0.0
            for c in channels { for j in stride(from: i, to: i + block, by: 4) { e += Double(c[j] * c[j]) } }
            energy.append(e)
            i += block
        }
        let window = max(1, len / block)
        var bestStart = 0, bestE = -1.0, run = 0.0
        for k in energy.indices {
            run += energy[k]
            if k >= window { run -= energy[k - window] }
            if k >= window - 1 && run > bestE {
                bestE = run
                bestStart = (k - window + 1) * block
            }
        }
        return channels.map { Array($0[bestStart..<min(n, bestStart + len)]) }
    }

    // MARK: - Level

    public struct LevelResult: Sendable, Equatable {
        public var songGain: Double
        public var drumGain: Double
        public var takeLufs: Double
        public var targetLufs: Double
    }

    /// Without stems: the drums sit this far under the full song.
    public static let drumsUnderSongDb = 5.0
    public static let maxGain = 1.5
    public static let minSongGain = 0.1

    /// Fader settings that put the rendered take (`drums`, at `drumOffsetSec`)
    /// at the original drums' level (stems), else `drumsUnderSongDb` under the
    /// song, both measured over the song time the take covers.
    public static func matchLevel(
        drums: [[Float]], song: [[Float]], originalDrums: [[Float]]?, sampleRate: Double,
        drumOffsetSec: Double, songGain: Double
    ) -> LevelResult? {
        let takeLen = drums.first?.count ?? 0
        let start = max(0, Int(drumOffsetSec * sampleRate))
        let skip = max(0, -Int(drumOffsetSec * sampleRate)) // take samples before song time 0
        let takeL = loudness(drums, sampleRate: sampleRate, start: skip, length: takeLen - skip)
        guard takeL > -70 else { return nil }
        let refL: Double
        if let od = originalDrums {
            refL = loudness(od, sampleRate: sampleRate, start: start, length: takeLen - skip)
        } else {
            refL = loudness(song, sampleRate: sampleRate, start: start, length: takeLen - skip) - drumsUnderSongDb
        }
        guard refL > -70 else { return nil }
        // In the mix the reference plays at songGain; the take at drumGain.
        var sg = songGain
        var dg = sg * pow(10, (refL - takeL) / 20)
        if dg > maxGain {
            sg = max(minSongGain, sg * maxGain / dg)
            dg = maxGain
        }
        let round2 = { (x: Double) in (x * 100).rounded() / 100 }
        return LevelResult(songGain: round2(sg), drumGain: round2(min(maxGain, dg)), takeLufs: takeL, targetLufs: refL)
    }

    // MARK: - Master

    public struct MasterOptions: Sendable, Equatable {
        public var targetLufs: Double
        public var ceilingDb: Double
        /// Most the loudness step may add (don't blow up a near-silent mix).
        public var maxBoostDb: Double
        public init(targetLufs: Double = -14, ceilingDb: Double = -1, maxBoostDb: Double = 24) {
            self.targetLufs = targetLufs; self.ceilingDb = ceilingDb; self.maxBoostDb = maxBoostDb
        }
    }

    /// Glue compression → loudness to target → brick-wall limit, in place.
    public static func master(_ channels: inout [[Float]], sampleRate: Double, _ o: MasterOptions = MasterOptions()) {
        let before = loudness(channels, sampleRate: sampleRate)
        guard before > -70 else {
            DSP.limitPeaks(&channels, sampleRate: sampleRate, DSP.LimiterOptions(ceilingDb: o.ceilingDb))
            return
        }
        // Gentle bus compression: only the loudest moments, 2:1, slow-ish.
        DSP.compress(&channels, sampleRate: sampleRate,
                     DynamicsParams(thresholdDb: before + 9, ratio: 2, attackMs: 25, releaseMs: 250))
        let glued = loudness(channels, sampleRate: sampleRate)
        let gainDb = min(o.maxBoostDb, o.targetLufs - glued)
        let g = Float(pow(10, gainDb / 20))
        for c in channels.indices {
            channels[c].withUnsafeMutableBufferPointer { x in for i in 0..<x.count { x[i] *= g } }
        }
        DSP.limitPeaks(&channels, sampleRate: sampleRate, DSP.LimiterOptions(ceilingDb: o.ceilingDb))
    }

    // MARK: - All together

    public enum Step: String, Sendable, Codable, CaseIterable { case align, tone, level }

    public struct Input: Sendable {
        public var take: [[Float]]
        public var song: [[Float]] // the bed (no-drums stem when there are stems)
        public var originalDrums: [[Float]]?
        public var sampleRate: Double
        public var drumOffsetSec: Double
        public var values: BlanketValues
        public var songGain: Double
        public var drumGain: Double
        public init(take: [[Float]], song: [[Float]], originalDrums: [[Float]]?, sampleRate: Double,
                    drumOffsetSec: Double, values: BlanketValues, songGain: Double, drumGain: Double) {
            self.take = take; self.song = song; self.originalDrums = originalDrums; self.sampleRate = sampleRate
            self.drumOffsetSec = drumOffsetSec; self.values = values; self.songGain = songGain; self.drumGain = drumGain
        }
    }

    public struct Output: Sendable {
        public var align: AlignResult?
        /// Applied offset change (s): `align.deltaSec` when reliable, else 0.
        public var appliedDeltaSec: Double
        public var tone: ToneResult?
        public var level: LevelResult?
        public var values: BlanketValues
        public var songGain: Double
        public var drumGain: Double
        public var notes: [String]
    }

    /// Runs the requested steps in the order that makes each one valid for the
    /// next: align (so the others measure the right stretch), tone (it changes
    /// loudness), then level on the take rendered with the new knobs.
    public static func run(_ input: Input, steps: Set<Step>) -> Output {
        var out = Output(align: nil, appliedDeltaSec: 0, tone: nil, level: nil, values: input.values,
                         songGain: input.songGain, drumGain: input.drumGain, notes: [])
        var offset = input.drumOffsetSec
        let sr = input.sampleRate

        if steps.contains(.align) {
            // With stems: the original drums. Without: the full song (bed).
            let reference = input.originalDrums ?? input.song
            let kind: AlignReference = input.originalDrums != nil ? .originalDrums : .song
            if let a = align(take: input.take, reference: reference, referenceKind: kind,
                             sampleRate: sr, drumOffsetSec: offset) {
                out.align = a
                let ms = Int((a.deltaSec * 1000).rounded())
                let against = kind == .originalDrums ? "the original drums" : "the song's beat"
                if a.isReliable {
                    out.appliedDeltaSec = a.deltaSec
                    offset += a.deltaSec
                    out.notes.append(ms == 0
                        ? "Already lined up with \(against)."
                        : "Moved the drums \(ms > 0 ? "+" : "")\(ms) ms to line up with \(against).")
                } else {
                    out.notes.append("Couldn't find a clear match with \(against) (best guess \(ms) ms) — left the alignment alone.")
                }
            } else {
                out.notes.append("Not enough overlap between the take and the song to align.")
            }
        }

        if steps.contains(.tone) {
            if let od = input.originalDrums {
                let t = matchTone(take: input.take, target: od, sampleRate: sr, values: out.values)
                out.tone = t
                out.values = t.values
                let gain = t.mismatchBeforeDb - t.mismatchAfterDb
                out.notes.append(gain > 0.2
                    ? String(format: "Matched the tone of the original drums (%.1f → %.1f dB off).", t.mismatchBeforeDb, t.mismatchAfterDb)
                    : "Tone already close to the original drums.")
            } else {
                out.notes.append("Tone match needs the original drums: run Remove original drums first.")
            }
        }

        if steps.contains(.level) {
            let rendered = DSP.renderBlanket(input.take, sampleRate: sr, values: out.values)
            if let l = matchLevel(drums: rendered, song: input.song, originalDrums: input.originalDrums,
                                  sampleRate: sr, drumOffsetSec: offset, songGain: out.songGain) {
                out.level = l
                out.songGain = l.songGain
                out.drumGain = l.drumGain
                out.notes.append(input.originalDrums != nil
                    ? "Set the drums to the original drummer's level."
                    : "Set the drums about \(Int(drumsUnderSongDb)) dB under the song.")
            } else {
                out.notes.append("The take is too quiet to set a level.")
            }
        }
        return out
    }
}
