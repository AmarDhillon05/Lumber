// Compact audio descriptors for "Describe the sound". Port of src/ai/analyze.ts.
// Bounded cost: at most `maxSec` of audio for level/envelope, and the
// spectrum is an average of a few dozen 4096-point FFT windows.
//
// Samples are Float (like the TS Float32Array); arithmetic is Double and the
// FFT stores intermediate values as Float, exactly as the TS code does.

import Foundation

public enum Band: String, CaseIterable, Sendable, Codable {
    case sub, low, lowMid, mid, presence, air

    public var edges: (lo: Double, hi: Double) {
        switch self {
        case .sub: return (20, 60)
        case .low: return (60, 250)
        case .lowMid: return (250, 800)
        case .mid: return (800, 2500)
        case .presence: return (2500, 6000)
        case .air: return (6000, 20000)
        }
    }
}

public struct BandLevels: Sendable, Equatable, Codable {
    public var sub, low, lowMid, mid, presence, air: Double

    public init(sub: Double, low: Double, lowMid: Double, mid: Double, presence: Double, air: Double) {
        self.sub = sub
        self.low = low
        self.lowMid = lowMid
        self.mid = mid
        self.presence = presence
        self.air = air
    }

    public subscript(b: Band) -> Double {
        get {
            switch b {
            case .sub: return sub
            case .low: return low
            case .lowMid: return lowMid
            case .mid: return mid
            case .presence: return presence
            case .air: return air
            }
        }
        set {
            switch b {
            case .sub: sub = newValue
            case .low: low = newValue
            case .lowMid: lowMid = newValue
            case .mid: mid = newValue
            case .presence: presence = newValue
            case .air: air = newValue
            }
        }
    }
}

public struct AudioDescriptors: Sendable, Equatable, Codable {
    public var durationSec: Double // analysed span
    public var channels: Int
    public var rmsDb: Double // dBFS, whole analysed span
    public var peakDb: Double // dBFS sample peak
    public var crestDb: Double // peak − RMS
    public var loudnessLufs: Double // integrated, K-weighted, gated (BS.1770-style)
    public var dynamicRangeDb: Double // 95th − 10th percentile frame level
    public var noiseFloorDb: Double // 10th percentile frame level
    public var bands: BandLevels // share of spectral energy per band, dB
    public var centroidHz: Double
    public var onsetsPerSec: Double
    public var decayMs: Double // median time for a hit to fall 20 dB
    public var stereoWidth: Double? // side / (mid + side) energy; nil for mono

    public init(
        durationSec: Double, channels: Int, rmsDb: Double, peakDb: Double, crestDb: Double, loudnessLufs: Double,
        dynamicRangeDb: Double, noiseFloorDb: Double, bands: BandLevels, centroidHz: Double, onsetsPerSec: Double,
        decayMs: Double, stereoWidth: Double?
    ) {
        self.durationSec = durationSec
        self.channels = channels
        self.rmsDb = rmsDb
        self.peakDb = peakDb
        self.crestDb = crestDb
        self.loudnessLufs = loudnessLufs
        self.dynamicRangeDb = dynamicRangeDb
        self.noiseFloorDb = noiseFloorDb
        self.bands = bands
        self.centroidHz = centroidHz
        self.onsetsPerSec = onsetsPerSec
        self.decayMs = decayMs
        self.stereoWidth = stereoWidth
    }

    /// JSON in the TS key order (for the Claude request).
    public var json: JSONValue {
        var b = JSONObject()
        for band in Band.allCases { b[band.rawValue] = .number(bands[band]) }
        return [
            "durationSec": .number(durationSec),
            "channels": .number(Double(channels)),
            "rmsDb": .number(rmsDb),
            "peakDb": .number(peakDb),
            "crestDb": .number(crestDb),
            "loudnessLufs": .number(loudnessLufs),
            "dynamicRangeDb": .number(dynamicRangeDb),
            "noiseFloorDb": .number(noiseFloorDb),
            "bands": .object(b),
            "centroidHz": .number(centroidHz),
            "onsetsPerSec": .number(onsetsPerSec),
            "decayMs": .number(decayMs),
            "stereoWidth": stereoWidth.map { .number($0) } ?? .null,
        ]
    }

    /// Rounded copy for prompts / UI.
    public func rounded() -> AudioDescriptors {
        func r(_ x: Double, _ p: Double = 1) -> Double {
            let m = pow(10, p)
            return jsRound(x * m) / m
        }
        var bands = self.bands
        for b in Band.allCases { bands[b] = r(bands[b]) }
        return AudioDescriptors(
            durationSec: r(durationSec), channels: channels, rmsDb: r(rmsDb), peakDb: r(peakDb), crestDb: r(crestDb),
            loudnessLufs: r(loudnessLufs), dynamicRangeDb: r(dynamicRangeDb), noiseFloorDb: r(noiseFloorDb), bands: bands,
            centroidHz: jsRound(centroidHz), onsetsPerSec: r(onsetsPerSec, 2), decayMs: jsRound(decayMs),
            stereoWidth: stereoWidth.map { r($0, 3) })
    }
}

public struct AnalyzeOptions: Sendable {
    public var startSec: Double
    public var maxSec: Double
    public var fftWindows: Int
    public init(startSec: Double = 0, maxSec: Double = 30, fftWindows: Int = 32) {
        self.startSec = startSec
        self.maxSec = maxSec
        self.fftWindows = fftWindows
    }
}

public struct MixAnalysis: Sendable, Equatable, Codable {
    public var drums: AudioDescriptors
    public var song: AudioDescriptors?
    public var songIsDrumless: Bool // song descriptors come from the no-drums stem
    public init(drums: AudioDescriptors, song: AudioDescriptors?, songIsDrumless: Bool) {
        self.drums = drums
        self.song = song
        self.songIsDrumless = songIsDrumless
    }
}

public enum AudioAnalysis {
    static let hop = 512
    static let fftN = 4096
    static let silentDb = -120.0

    static func toDb(_ p: Double) -> Double { p > 1e-12 ? 10 * log10(p) : silentDb }
    static func ampDb(_ a: Double) -> Double { a > 1e-6 ? 20 * log10(a) : silentDb }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        if sorted.isEmpty { return silentDb }
        let i = Swift.min(sorted.count - 1, Swift.max(0, Int(jsRound(p * Double(sorted.count - 1)))))
        return sorted[i]
    }

    static func median(_ xs: [Double]) -> Double {
        if xs.isEmpty { return 0 }
        let s = xs.sorted()
        let m = s.count >> 1
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    struct Biquad { var b0, b1, b2, a1, a2: Double }

    static func highShelf(_ fs: Double, _ f0: Double, _ gainDb: Double, _ q: Double) -> Biquad {
        let A = pow(10, gainDb / 40)
        let w = (2 * Double.pi * f0) / fs
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let s = 2 * A.squareRoot() * alpha
        let a0 = A + 1 - (A - 1) * c + s
        return Biquad(
            b0: (A * (A + 1 + (A - 1) * c + s)) / a0,
            b1: (-2 * A * (A - 1 + (A + 1) * c)) / a0,
            b2: (A * (A + 1 + (A - 1) * c - s)) / a0,
            a1: (2 * (A - 1 - (A + 1) * c)) / a0,
            a2: (A + 1 - (A - 1) * c - s) / a0)
    }

    static func highPass(_ fs: Double, _ f0: Double, _ q: Double) -> Biquad {
        let w = (2 * Double.pi * f0) / fs
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: (-2 * c) / a0, a2: (1 - alpha) / a0)
    }

    /// Sum of K-weighted squares per `step` samples.
    static func kWeightedSteps(_ ch: [Float], _ start: Int, _ len: Int, _ fs: Double, _ step: Int) -> [Double] {
        let f1 = highShelf(fs, 1681.974450955533, 3.999843853973347, 0.7071752369554196)
        let f2 = highPass(fs, 38.13547087602444, 0.5003270373238773)
        var out = [Double](repeating: 0, count: (len + step - 1) / step)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0, z1 = 0.0, z2 = 0.0, u1 = 0.0, u2 = 0.0
        ch.withUnsafeBufferPointer { c in
            for i in 0..<len {
                let x = Double(c[start + i])
                let y = f1.b0 * x + f1.b1 * x1 + f1.b2 * x2 - f1.a1 * y1 - f1.a2 * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                let z = f2.b0 * y + f2.b1 * u1 + f2.b2 * u2 - f2.a1 * z1 - f2.a2 * z2
                u2 = u1; u1 = y; z2 = z1; z1 = z
                out[i / step] += z * z
            }
        }
        return out
    }

    /// BS.1770-style integrated loudness: 400 ms blocks, 75 % overlap, −70 / −10 gates.
    static func integratedLufs(_ chs: [[Float]], _ start: Int, _ len: Int, _ fs: Double) -> Double {
        let step = Swift.max(1, Int(jsRound(fs * 0.1)))
        let steps = chs.map { kWeightedSteps($0, start, len, fs, step) }
        let nSteps = steps[0].count
        var blocks: [Double] = []
        var b = 0
        while b + 4 <= nSteps {
            var sum = 0.0
            for s in steps { sum += s[b] + s[b + 1] + s[b + 2] + s[b + 3] }
            blocks.append(-0.691 + toDb(sum / Double(4 * step)))
            b += 1
        }
        if blocks.isEmpty {
            var sum = 0.0
            for s in steps { for i in 0..<nSteps { sum += s[i] } }
            return -0.691 + toDb(sum / Double(Swift.max(1, len)))
        }
        func meanLufs(_ xs: [Double]) -> Double {
            -0.691 + toDb(xs.reduce(0) { $0 + pow(10, ($1 + 0.691) / 10) } / Double(xs.count))
        }
        let abs = blocks.filter { $0 > -70 }
        if abs.isEmpty { return silentDb }
        let rel = abs.filter { $0 > meanLufs(abs) - 10 }
        return meanLufs(rel.isEmpty ? abs : rel)
    }

    /// Descriptors for a mono or stereo buffer (extra channels are ignored).
    /// Silent input yields −120 dB levels and zeros.
    public static func analyze(_ channels: [[Float]], sampleRate: Double, options: AnalyzeOptions = AnalyzeOptions()) -> AudioDescriptors {
        let chs = Array(channels.prefix(2))
        let total = chs.first?.count ?? 0
        let start = Swift.min(total, Swift.max(0, Int((options.startSec * sampleRate).rounded(.down))))
        let len = Swift.min(total - start, Int((options.maxSec * sampleRate).rounded(.down)))
        let stereo = chs.count == 2
        let nCh = Swift.max(1, chs.count)

        // --- one pass: peak, energy, frame envelope, mid/side energy
        var peak = 0.0, sumSq = 0.0, midE = 0.0, sideE = 0.0
        let nFrames = Swift.max(0, len / hop)
        var frameDb = [Double](repeating: 0, count: nFrames)
        for f in 0..<nFrames {
            var fe = 0.0
            let base = start + f * hop
            for i in 0..<hop {
                var m = 0.0
                for c in 0..<nCh {
                    let v = Double(chs[c][base + i])
                    let a = v < 0 ? -v : v
                    if a > peak { peak = a }
                    m += v
                    sumSq += v * v
                }
                m /= Double(nCh)
                fe += m * m
                if stereo {
                    let l = Double(chs[0][base + i]), r = Double(chs[1][base + i])
                    let mid = (l + r) / 2, side = (l - r) / 2
                    midE += mid * mid
                    sideE += side * side
                }
            }
            frameDb[f] = toDb(fe / Double(hop))
        }
        let used = nFrames * hop
        let rmsDb = toDb(sumSq / Double(Swift.max(1, used * nCh)))
        let peakDb = ampDb(peak)

        let sortedFrames = frameDb.sorted()
        let noiseFloorDb = percentile(sortedFrames, 0.1)
        let loudFrame = percentile(sortedFrames, 0.95)
        let dynamicRangeDb = Swift.max(0, loudFrame - noiseFloorDb)

        // --- onsets + decay on the frame envelope
        let hopSec = Double(hop) / sampleRate
        let minGap = Swift.max(1, Int(jsRound(0.05 / hopSec))) // 50 ms refractory
        let floorGate = Swift.max(noiseFloorDb + 10, loudFrame - 40)
        var onsets: [Int] = []
        if nFrames > 3 {
            for f in 3..<nFrames {
                let prevMin = Swift.min(frameDb[f - 1], frameDb[f - 2], frameDb[f - 3])
                let rise = frameDb[f] - prevMin
                if rise >= 8 && frameDb[f] >= floorGate && (onsets.isEmpty || f - onsets[onsets.count - 1] >= minGap) {
                    onsets.append(f)
                }
            }
        }
        var decays: [Double] = []
        for (k, o) in onsets.enumerated() {
            let end = k + 1 < onsets.count ? onsets[k + 1] : nFrames
            var pk = o
            for f in o..<Swift.min(end, o + 5) where frameDb[f] > frameDb[pk] { pk = f }
            let target = frameDb[pk] - 20
            var f = pk
            while f < end && frameDb[f] > target { f += 1 }
            decays.append(Double(f - pk) * hopSec * 1000)
        }
        let durationSec = Double(len) / sampleRate

        // --- averaged power spectrum over a few windows
        let nWin = len >= fftN ? Swift.max(1, Swift.min(options.fftWindows, len / fftN)) : 0
        let nBins = fftN / 2
        var power = [Double](repeating: 0, count: nBins)
        var hann = [Float](repeating: 0, count: fftN)
        for i in 0..<fftN { hann[i] = Float(0.5 - 0.5 * cos((2 * Double.pi * Double(i)) / Double(fftN - 1))) }
        var re = [Float](repeating: 0, count: fftN)
        var im = [Float](repeating: 0, count: fftN)
        for w in 0..<nWin {
            let off = start + (nWin == 1 ? 0 : Int((Double((len - fftN) * w) / Double(nWin - 1)).rounded(.down)))
            for i in 0..<fftN {
                var m = 0.0
                for c in 0..<nCh { m += Double(chs[c][off + i]) }
                re[i] = Float((m / Double(nCh)) * Double(hann[i]))
                im[i] = 0
            }
            fft32(&re, &im)
            for k in 0..<nBins {
                let r = Double(re[k]), i = Double(im[k])
                power[k] += r * r + i * i
            }
        }
        let binHz = sampleRate / Double(fftN)
        var bandE = BandLevels(sub: 0, low: 0, lowMid: 0, mid: 0, presence: 0, air: 0)
        var totalE = 0.0, centroidNum = 0.0
        for k in 1..<nBins {
            let hz = Double(k) * binHz
            if hz < 20 || hz > 20000 { continue }
            let p = power[k]
            totalE += p
            centroidNum += p * hz
            for b in Band.allCases {
                let (lo, hi) = b.edges
                if hz >= lo && hz < hi {
                    bandE[b] += p
                    break
                }
            }
        }
        var bands = bandE
        for b in Band.allCases { bands[b] = totalE > 0 ? toDb(bandE[b] / totalE) : silentDb }

        return AudioDescriptors(
            durationSec: durationSec,
            channels: chs.count,
            rmsDb: rmsDb,
            peakDb: peakDb,
            crestDb: rmsDb <= silentDb ? 0 : peakDb - rmsDb,
            loudnessLufs: len > 0 ? integratedLufs(chs, start, len, sampleRate) : silentDb,
            dynamicRangeDb: dynamicRangeDb,
            noiseFloorDb: noiseFloorDb,
            bands: bands,
            centroidHz: totalE > 0 ? centroidNum / totalE : 0,
            onsetsPerSec: durationSec > 0 ? Double(onsets.count) / durationSec : 0,
            decayMs: median(decays),
            stereoWidth: stereo ? (midE + sideE > 0 ? sideE / (midE + sideE) : 0) : nil)
    }

    /// Radix-2 FFT in place, Float storage / Double arithmetic (src/dsp/fft.ts).
    /// Private copy so the AI module doesn't depend on the DSP port; unify after merge.
    static func fft32(_ re: inout [Float], _ im: inout [Float]) {
        let n = re.count
        if n <= 1 { return }
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var len = 2
        while len <= n {
            let ang = (-2 * Double.pi) / Double(len)
            let wRe = cos(ang), wIm = sin(ang)
            let half = len / 2
            var i = 0
            while i < n {
                var curRe = 1.0, curIm = 0.0
                for k in 0..<half {
                    let a = i + k, b = a + half
                    let bRe = Double(re[b]), bIm = Double(im[b])
                    let tRe = bRe * curRe - bIm * curIm
                    let tIm = bRe * curIm + bIm * curRe
                    let aRe = Double(re[a]), aIm = Double(im[a])
                    re[b] = Float(aRe - tRe)
                    im[b] = Float(aIm - tIm)
                    re[a] = Float(aRe + tRe)
                    im[a] = Float(aIm + tIm)
                    let nextRe = curRe * wRe - curIm * wIm
                    curIm = curRe * wIm + curIm * wRe
                    curRe = nextRe
                }
                i += len
            }
            len <<= 1
        }
    }
}
