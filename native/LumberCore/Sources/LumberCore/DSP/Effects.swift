// Port of src/dsp/effects.ts: the custom (non-Web-Audio-node) effects. Each
// mutates `channels` in place, like the TS (which mutates its Float32Arrays).
// Arithmetic is Double, storage Float, mirroring JS numbers over Float32Array.

import Foundation

extension DSP {
    private static func peakAt(_ channels: [[Float]], _ i: Int) -> Double {
        var peak = 0.0
        for c in 0..<channels.count {
            let a = abs(Double(channels[c][i]))
            if a > peak { peak = a }
        }
        return peak
    }

    private static func applyGain(_ channels: inout [[Float]], _ i: Int, _ g: Double) {
        for c in 0..<channels.count { channels[c][i] = Float(Double(channels[c][i]) * g) }
    }

    // MARK: Dynamics

    /// Feedforward compressor (replaces pedalboard.Compressor). Stereo-linked
    /// peak detector; gain reduction tracked in dB with attack/release.
    public static func compress(_ channels: inout [[Float]], sampleRate sr: Double, _ p: DynamicsParams) {
        guard let n = channels.first?.count else { return }
        let attCoeff = exp(-1 / (sr * (p.attackMs / 1000) + eps))
        let relCoeff = exp(-1 / (sr * (p.releaseMs / 1000) + eps))
        let slope = 1 - 1 / p.ratio
        var gr = 0.0
        for i in 0..<n {
            let levelDb = 20 * log10(peakAt(channels, i) + eps)
            let over = levelDb - p.thresholdDb
            let target = over > 0 ? over * slope : 0
            let coeff = target > gr ? attCoeff : relCoeff
            gr = target + (gr - target) * coeff
            applyGain(&channels, i, dbToLin(-gr))
        }
    }

    /// Upward compressor (Blanket.detail): boosts signal below the threshold,
    /// with the makeup gain capped at `maxGainDb`.
    public static func upwardCompress(_ channels: inout [[Float]], sampleRate sr: Double, _ p: UpwardCompressorParams) {
        guard let n = channels.first?.count else { return }
        let attCoeff = exp(-1 / (sr * (p.attackMs / 1000) + eps))
        let relCoeff = exp(-1 / (sr * (p.releaseMs / 1000) + eps))
        let slope = 1 - 1 / p.ratio
        var env = 0.0
        var gain = 0.0
        for i in 0..<n {
            let peak = peakAt(channels, i)
            // Peak follower: instant attack, slow release.
            env = peak > env ? peak : peak + (env - peak) * relCoeff
            let levelDb = 20 * log10(env + eps)
            let under = p.thresholdDb - levelDb
            var target = under > 0 ? under * slope : 0
            if target > p.maxGainDb { target = p.maxGainDb }
            let coeff = target > gain ? attCoeff : relCoeff
            gain = target + (gain - target) * coeff
            applyGain(&channels, i, dbToLin(gain))
        }
    }

    /// Noise gate / downward expander (replaces pedalboard.NoiseGate).
    public static func gate(_ channels: inout [[Float]], sampleRate sr: Double, _ p: DynamicsParams) {
        guard let n = channels.first?.count else { return }
        let attCoeff = exp(-1 / (sr * (p.attackMs / 1000) + eps))
        let relCoeff = exp(-1 / (sr * (p.releaseMs / 1000) + eps))
        var att = 0.0
        for i in 0..<n {
            let levelDb = 20 * log10(peakAt(channels, i) + eps)
            let under = p.thresholdDb - levelDb
            let target = under > 0 ? under * (p.ratio - 1) : 0
            let coeff = target < att ? attCoeff : relCoeff
            att = target + (att - target) * coeff
            applyGain(&channels, i, dbToLin(-att))
        }
    }

    // MARK: Harmonic

    /// y = tanh(x·drive) / drive
    public static func saturate(_ channels: inout [[Float]], drive: Double) {
        for c in 0..<channels.count {
            channels[c].withUnsafeMutableBufferPointer { x in
                for i in 0..<x.count { x[i] = Float(tanh(Double(x[i]) * drive) / drive) }
            }
        }
    }

    /// Harmonic excitation on a band, blended back (Blanket.presence).
    public static func presence(_ channels: inout [[Float]], sampleRate sr: Double, _ p: PresenceParams) {
        let coeffs = BiquadCoefficients.bandpass(lowHz: p.lowHz, highHz: p.highHz, sampleRate: sr)
        for ch in 0..<channels.count {
            let band = filtfilt(channels[ch], coeffs)
            channels[ch].withUnsafeMutableBufferPointer { data in
                for i in 0..<data.count {
                    let b = Double(band[i])
                    let harmonic = tanh(b * p.drive) / p.drive - b
                    data[i] = Float(Double(data[i]) + harmonic * p.blend)
                }
            }
        }
    }

    // MARK: Spatial

    /// Mid-side widening (Blanket.width); no-op on mono.
    public static func width(_ channels: inout [[Float]], amount: Double) {
        guard channels.count >= 2 else { return }
        let n = channels[0].count
        for i in 0..<n {
            let l = Double(channels[0][i]), r = Double(channels[1][i])
            let m = (l + r) / 2
            let s = ((l - r) / 2) * (1 + amount)
            channels[0][i] = Float(m + s)
            channels[1][i] = Float(m - s)
        }
    }

    // MARK: Resonance detection

    /// Up to 5 ringing peaks (Hz) in 80–8000 Hz; the renderer notches them out.
    public static func detectResonances(_ channels: [[Float]], sampleRate sr: Double) -> [Double] {
        guard let n = channels.first?.count else { return [] }
        let N = nextPow2(n)
        var re = [Float](repeating: 0, count: N)
        var im = [Float](repeating: 0, count: N)
        let nch = Double(channels.count)
        for i in 0..<n {
            var s = 0.0
            for c in 0..<channels.count { s += Double(channels[c][i]) }
            re[i] = Float(s / nch)
        }
        fft(&re, &im)

        let half = N / 2
        var mag = [Float](repeating: 0, count: half)
        for i in 0..<half { mag[i] = Float(hypot(Double(re[i]), Double(im[i]))) }

        // moving-average smoothing (savgol stand-in)
        let w = 25
        var sm = [Float](repeating: 0, count: half)
        for i in 0..<half {
            var acc = 0.0
            var cnt = 0
            for j in max(0, i - w)...min(half - 1, i + w) {
                acc += Double(mag[j])
                cnt += 1
            }
            sm[i] = Float(acc / Double(cnt))
        }

        let sorted = sm.sorted()
        let height = sorted[Int((Double(sorted.count) * 0.95).rounded(.down))]
        let binHz = sr / Double(N)
        let minDist = 50

        var peaks: [Double] = []
        var lastIdx = -minDist
        var i = 1
        while i < half - 1 && peaks.count < 5 {
            if sm[i] > height && sm[i] > sm[i - 1] && sm[i] >= sm[i + 1] && i - lastIdx >= minDist {
                let freq = Double(i) * binHz
                if freq > 80 && freq < 8000 {
                    peaks.append(freq)
                    lastIdx = i
                }
            }
            i += 1
        }
        return peaks
    }

    // MARK: Spectral gate

    /// Spectral gating (Blanket.denoise / roominess): v1 approximation of
    /// `noisereduce`. STFT, per-bin floor, attenuate bins near it by propDecrease.
    public static func spectralGate(_ channels: inout [[Float]], _ p: SpectralGateParams) {
        if p.propDecrease <= 0 { return }
        let frame = 2048
        let hop = frame / 4
        var win = [Float](repeating: 0, count: frame)
        for i in 0..<frame { win[i] = Float(0.5 - 0.5 * cos((2 * Double.pi * Double(i)) / Double(frame))) }
        for c in 0..<channels.count {
            channels[c] = gateChannel(channels[c], win, frame, hop, p)
        }
    }

    private static func gateChannel(_ x: [Float], _ win: [Float], _ FRAME: Int, _ HOP: Int,
                                    _ p: SpectralGateParams) -> [Float] {
        let n = x.count
        // Math.ceil((n - FRAME) / HOP) + 1, at least 1
        let frames = max(1, Int((Double(n - FRAME) / Double(HOP)).rounded(.up)) + 1)
        let half = FRAME / 2

        var specRe = [[Float]](), specIm = [[Float]](), mags = [[Float]]()
        specRe.reserveCapacity(frames); specIm.reserveCapacity(frames); mags.reserveCapacity(frames)
        for f in 0..<frames {
            var re = [Float](repeating: 0, count: FRAME)
            var im = [Float](repeating: 0, count: FRAME)
            let start = f * HOP
            for i in 0..<FRAME {
                let idx = start + i
                let v = idx < n ? Double(x[idx]) : 0
                re[i] = Float(v * Double(win[i]))
            }
            fft(&re, &im)
            var mag = [Float](repeating: 0, count: half)
            for i in 0..<half { mag[i] = Float(hypot(Double(re[i]), Double(im[i]))) }
            specRe.append(re); specIm.append(im); mags.append(mag)
        }

        var floor = [Float](repeating: 0, count: half)
        if p.stationary {
            var col = [Float](repeating: 0, count: frames)
            let qi = Int((Double(frames) * 0.2).rounded(.down))
            for b in 0..<half {
                for f in 0..<frames { col[f] = mags[f][b] }
                col.sort()
                floor[b] = col[qi] // 20th percentile ≈ noise level
            }
        }

        let keep = 1 - p.propDecrease
        let SMOOTH = 30
        for f in 0..<frames {
            for b in 0..<half {
                var fl = Double(floor[b])
                if !p.stationary {
                    var acc = 0.0
                    var cnt = 0
                    for j in max(0, f - SMOOTH)...min(frames - 1, f + SMOOTH) {
                        acc += Double(mags[j][b])
                        cnt += 1
                    }
                    fl = acc / Double(cnt)
                }
                let gainMask = Double(mags[f][b]) > fl * 1.5 ? 1 : keep
                specRe[f][b] = Float(Double(specRe[f][b]) * gainMask)
                specIm[f][b] = Float(Double(specIm[f][b]) * gainMask)
                if b > 0 && b < half {
                    specRe[f][FRAME - b] = Float(Double(specRe[f][FRAME - b]) * gainMask)
                    specIm[f][FRAME - b] = Float(Double(specIm[f][FRAME - b]) * gainMask)
                }
            }
        }

        var out = [Float](repeating: 0, count: n)
        var norm = [Float](repeating: 0, count: n)
        for f in 0..<frames {
            fft(&specRe[f], &specIm[f], inverse: true)
            let start = f * HOP
            for i in 0..<FRAME {
                let idx = start + i
                if idx < n {
                    let w = Double(win[i])
                    out[idx] = Float(Double(out[idx]) + Double(specRe[f][i]) * w)
                    norm[idx] = Float(Double(norm[idx]) + w * w)
                }
            }
        }
        for i in 0..<n {
            out[i] = Double(norm[i]) > eps ? Float(Double(out[i]) / Double(norm[i])) : x[i]
        }
        return out
    }
}
