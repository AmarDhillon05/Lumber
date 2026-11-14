// HTDemucs (4-stem) separation around an ONNX graph that excludes the STFT.
// Port of src/separation/demucs.ts (which matches PyTorch demucs at ~95 dB):
// the STFT/iSTFT exactly as demucs computes them, overlap-add chunking as in
// demucs.apply.apply_model (overlap 0.25, shifts 0), and the input
// normalization from demucs.api. Only drums and no-drums (bass + other +
// vocals) are kept; the iSTFT is linear, so the three non-drum spectrograms are
// summed before inverting, and both real outputs share one complex inverse FFT.

import Foundation

public enum Demucs {
    public static let sampleRate = 44100
    public static let nfft = 4096
    public static let hop = 1024
    /// int(44100 * 39/5), the model's training segment.
    public static let segment = 343_980
    public static let frames = (segment + hop - 1) / hop // 336
    public static let bins = nfft / 2 // 2048 (demucs drops the Nyquist bin)
    public static let sources = ["drums", "bass", "other", "vocals"]
    public static let overlap = 0.25
    public static let stride = Int((1 - overlap) * Double(segment))

    static let pad = (hop / 2) * 3 // demucs re-pads by 1536 so frames line up with the hop
    static let norm = 1 / Double(nfft).squareRoot() // torch.stft(normalized=True)
}

/// Model outputs for one segment.
public struct DemucsOutputs: Sendable {
    /// (4 sources, 4 cac, bins, frames)
    public var spec: [Float]
    /// (4 sources, 2 channels, segment)
    public var wave: [Float]
    public init(spec: [Float], wave: [Float]) {
        self.spec = spec
        self.wave = wave
    }
}

/// One inference over a segment. `mix` is (2, segment), `mag` is (4, bins, frames).
public protocol DemucsRunner: Sendable {
    func run(mix: [Float], mag: [Float]) async throws -> DemucsOutputs
}

/// Receives finished audio in order, block after block, so a whole song never
/// has to be held as stems in memory.
public protocol StemSink {
    mutating func write(drums: [[Float]], noDrums: [[Float]]) async throws
}

/// Hann window, FFT and the overlap-add envelope torch.istft divides by.
struct DemucsTables: Sendable {
    let fft = FFT(Demucs.nfft)
    let hann: [Double]
    let olaEnvelope: [Double]

    init() {
        let n = Demucs.nfft
        hann = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
        // Sum of squared windows over every frame, including the zero frames
        // demucs pads on each side.
        let totalFrames = Demucs.frames + 4
        var env = [Double](repeating: 0, count: Demucs.segment)
        for s in 0..<Demucs.segment {
            let p = s + n / 2 + Demucs.pad
            var e = 0.0
            for j in 0..<totalFrames {
                let q = p - j * Demucs.hop
                if q >= 0 && q < n { e += hann[q] * hann[q] }
            }
            env[s] = e
        }
        olaEnvelope = env
    }

    static let shared = DemucsTables()
}

/// Scratch buffers for one segment, allocated once per song and reused.
public final class DemucsWorkspace {
    var mix = [Float](repeating: 0, count: 2 * Demucs.segment)
    var mag = [Float](repeating: 0, count: 4 * Demucs.bins * Demucs.frames)
    var re = [Double](repeating: 0, count: Demucs.nfft)
    var im = [Double](repeating: 0, count: Demucs.nfft)
    var accA = [Double](repeating: 0, count: Demucs.segment)
    var accB = [Double](repeating: 0, count: Demucs.segment)
    var restRe = [Float](repeating: 0, count: Demucs.bins * Demucs.frames)
    var restIm = [Float](repeating: 0, count: Demucs.bins * Demucs.frames)
    var drums = [[Float]](repeating: [Float](repeating: 0, count: Demucs.segment), count: 2)
    var noDrums = [[Float]](repeating: [Float](repeating: 0, count: Demucs.segment), count: 2)
    public init() {}
}

@inline(__always)
func reflectIndex(_ i: Int, _ length: Int) -> Int {
    if i < 0 { return -i }
    if i >= length { return 2 * (length - 1) - i }
    return i
}

extension Demucs {
    /// demucs HTDemucs._spec + _magnitude for a stereo segment of exactly
    /// `segment` samples → (4, bins, frames) with channels [L.re, L.im, R.re, R.im].
    public static func spectrogram(left: [Float], right: [Float], workspace ws: DemucsWorkspace = DemucsWorkspace()) -> [Float] {
        precondition(left.count == segment && right.count == segment)
        let t = DemucsTables.shared
        let plane = bins * frames
        for frame in 0..<frames {
            let start = frame * hop - pad
            for q in 0..<nfft {
                let i = reflectIndex(start + q, segment)
                ws.re[q] = Double(left[i]) * t.hann[q]
                ws.im[q] = Double(right[i]) * t.hann[q]
            }
            t.fft.transform(&ws.re, &ws.im)
            // Unpack the two real transforms from the one complex transform.
            for k in 0..<bins {
                let m = (nfft - k) % nfft
                let o = k * frames + frame
                ws.mag[o] = Float(0.5 * (ws.re[k] + ws.re[m]) * norm)
                ws.mag[plane + o] = Float(0.5 * (ws.im[k] - ws.im[m]) * norm)
                ws.mag[2 * plane + o] = Float(0.5 * (ws.im[k] + ws.im[m]) * norm)
                ws.mag[3 * plane + o] = Float(0.5 * (ws.re[m] - ws.re[k]) * norm)
            }
        }
        return ws.mag
    }

    /// demucs HTDemucs._ispec for two real signals at once; results are added
    /// into outA/outB. `spec` planes are read at the given offsets.
    static func inverseSpectrogramPair(
        spec: UnsafeBufferPointer<Float>, aRe: Int, aIm: Int,
        bRe: UnsafeBufferPointer<Float>, bIm: UnsafeBufferPointer<Float>,
        outA: inout [Float], outB: inout [Float], ws: DemucsWorkspace
    ) {
        let t = DemucsTables.shared
        for s in 0..<segment {
            ws.accA[s] = 0
            ws.accB[s] = 0
        }
        let scale = 1 / (norm * Double(nfft)) // undo 1/n of the inverse FFT, then ×sqrt(n)
        for frame in 0..<frames {
            // Y = A + iB as a full Hermitian-pair spectrum; C2R ignores imag at DC.
            ws.re[0] = Double(spec[aRe + frame])
            ws.im[0] = Double(bRe[frame])
            for k in 1..<bins {
                let o = k * frames + frame
                let ar = Double(spec[aRe + o]), ai = Double(spec[aIm + o])
                let br = Double(bRe[o]), bi = Double(bIm[o])
                ws.re[k] = ar - bi
                ws.im[k] = ai + br
                ws.re[nfft - k] = ar + bi
                ws.im[nfft - k] = br - ai
            }
            ws.re[bins] = 0 // Nyquist bin was dropped → zero
            ws.im[bins] = 0
            t.fft.transform(&ws.re, &ws.im, inverse: true)
            let start = frame * hop - pad
            let q0 = max(0, -start)
            let q1 = min(nfft, segment - start)
            if q0 < q1 {
                for q in q0..<q1 {
                    let w = t.hann[q] * scale
                    ws.accA[start + q] += ws.re[q] * w
                    ws.accB[start + q] += ws.im[q] * w
                }
            }
        }
        for s in 0..<segment {
            outA[s] += Float(ws.accA[s] / t.olaEnvelope[s])
            outB[s] += Float(ws.accB[s] / t.olaEnvelope[s])
        }
    }

    /// One model call on a normalized segment-long stereo chunk → drums and
    /// no-drums (normalized domain), each [left, right]. Results live in the
    /// workspace and are overwritten by the next call.
    public static func separateSegment(
        left: [Float], right: [Float], runner: some DemucsRunner, workspace ws: DemucsWorkspace = DemucsWorkspace()
    ) async throws -> (drums: [[Float]], noDrums: [[Float]]) {
        for i in 0..<segment {
            ws.mix[i] = left[i]
            ws.mix[segment + i] = right[i]
        }
        let mag = spectrogram(left: left, right: right, workspace: ws)
        let out = try await runner.run(mix: ws.mix, mag: mag)
        let plane = bins * frames
        precondition(out.spec.count == 16 * plane && out.wave.count == 8 * segment, "unexpected model output size")

        out.spec.withUnsafeBufferPointer { spec in
            for ch in 0..<2 {
                for x in 0..<segment {
                    ws.drums[ch][x] = 0
                    ws.noDrums[ch][x] = 0
                }
                for x in 0..<plane {
                    ws.restRe[x] = 0
                    ws.restIm[x] = 0
                }
                for s in 1..<sources.count {
                    let r = (s * 4 + 2 * ch) * plane
                    let i = (s * 4 + 2 * ch + 1) * plane
                    for x in 0..<plane {
                        ws.restRe[x] += spec[r + x]
                        ws.restIm[x] += spec[i + x]
                    }
                }
                ws.restRe.withUnsafeBufferPointer { restRe in
                    ws.restIm.withUnsafeBufferPointer { restIm in
                        inverseSpectrogramPair(
                            spec: spec, aRe: (2 * ch) * plane, aIm: (2 * ch + 1) * plane,
                            bRe: restRe, bIm: restIm,
                            outA: &ws.drums[ch], outB: &ws.noDrums[ch], ws: ws
                        )
                    }
                }
                // Time branch.
                let w0 = ch * segment
                for x in 0..<segment { ws.drums[ch][x] += out.wave[w0 + x] }
                for s in 1..<sources.count {
                    let ws0 = (s * 2 + ch) * segment
                    for x in 0..<segment { ws.noDrums[ch][x] += out.wave[ws0 + x] }
                }
            }
        }
        return (ws.drums, ws.noDrums)
    }

    /// Full-song separation: demucs.api normalization + apply_model chunking.
    /// `input` is 1 or 2 channels at `sampleRate`. Output is streamed to `sink`
    /// in order; total samples written equals the input length.
    public static func separate<Sink: StemSink>(
        input: [[Float]],
        runner: some DemucsRunner,
        sink: inout Sink,
        onProgress: ((Double) -> Void)? = nil,
        afterChunk: ((Int, Int) async throws -> Void)? = nil
    ) async throws {
        guard let left = input.first else { return }
        let right = input.count > 1 ? input[1] : left
        let length = left.count
        guard length > 0 else { return }

        // Normalize by the mono mix's mean / (unbiased) std, as demucs.api does.
        var sum = 0.0
        for i in 0..<length { sum += 0.5 * Double(left[i] + right[i]) }
        let mean = sum / Double(length)
        var sq = 0.0
        for i in 0..<length {
            let d = 0.5 * Double(left[i] + right[i]) - mean
            sq += d * d
        }
        var std = (sq / Double(max(1, length - 1))).squareRoot()
        if std == 0 || !std.isFinite { std = 1 }

        // Triangular cross-fade weight, peak 1 in the middle of the segment.
        let halfSeg = segment / 2
        var weight = [Float](repeating: 0, count: segment)
        for i in 0..<segment {
            weight[i] = Float(i < halfSeg ? i + 1 : segment - i) / Float(halfSeg)
        }

        var acc = [[Float]](repeating: [Float](repeating: 0, count: segment), count: 4) // dL dR nL nR
        var accW = [Float](repeating: 0, count: segment)
        let ws = DemucsWorkspace()
        let offsets = Array(Swift.stride(from: 0, to: length, by: stride))

        var chunkL = [Float](repeating: 0, count: segment)
        var chunkR = [Float](repeating: 0, count: segment)
        let fMean = Float(mean), fStd = Float(std)
        for (c, offset) in offsets.enumerated() {
            let chunkLen = min(segment, length - offset)
            // TensorChunk.padded: centre the chunk, real audio as context, zeros past the ends.
            let lead = (segment - chunkLen) / 2
            let start = offset - lead
            for i in 0..<segment {
                let j = start + i
                if j >= 0 && j < length {
                    chunkL[i] = (left[j] - fMean) / fStd
                    chunkR[i] = (right[j] - fMean) / fStd
                } else {
                    chunkL[i] = 0
                    chunkR[i] = 0
                }
            }
            let (drums, noDrums) = try await separateSegment(left: chunkL, right: chunkR, runner: runner, workspace: ws)
            let outs = [drums[0], drums[1], noDrums[0], noDrums[1]]
            for i in 0..<chunkLen {
                let w = weight[i]
                for k in 0..<4 { acc[k][i] += w * outs[k][lead + i] }
                accW[i] += w
            }

            let isLast = c == offsets.count - 1
            let emit = isLast ? chunkLen : stride
            var block = [[Float]](repeating: [Float](repeating: 0, count: emit), count: 4)
            for i in 0..<emit {
                for k in 0..<4 {
                    let v = acc[k][i] / accW[i]
                    // drums: v*std + mean; no-drums is three stems summed → 3*mean.
                    block[k][i] = v * fStd + (k < 2 ? fMean : 3 * fMean)
                }
            }
            try await sink.write(drums: [block[0], block[1]], noDrums: [block[2], block[3]])

            if !isLast {
                for k in 0..<4 {
                    acc[k].replaceSubrange(0..<(segment - stride), with: acc[k][stride..<segment])
                    for i in (segment - stride)..<segment { acc[k][i] = 0 }
                }
                accW.replaceSubrange(0..<(segment - stride), with: accW[stride..<segment])
                for i in (segment - stride)..<segment { accW[i] = 0 }
            }
            onProgress?(Double(c + 1) / Double(offsets.count))
            try await afterChunk?(c + 1, offsets.count)
        }
    }
}
