// Media the simulator tests build at runtime, so nothing binary is committed:
// a quiet song, a drum take with one click, and a video that is black except
// for one white frame. Plus readers that find the click / the flash again in
// an exported file.

import AVFoundation
import CoreVideo
import XCTest
@testable import LumberNative

enum MediaFixtures {
    static func dir(_ name: String = UUID().uuidString) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fixtures-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Stereo 110 Hz sine at −26 dBFS (so a click stands out), 44.1 kHz int16.
    static func song(seconds: Double, in dir: URL, name: String = "song.wav", amplitude: Float = 0.05) throws -> URL {
        let rate = 44_100.0
        let n = Int(seconds * rate)
        var ch = [Float](repeating: 0, count: n)
        for i in 0..<n { ch[i] = amplitude * sin(2 * .pi * 110 * Float(i) / Float(rate)) }
        let url = dir.appendingPathComponent(name)
        try AudioFileIO.writeWAV([ch, ch], sampleRate: rate, to: url, format: .int16)
        return url
    }

    /// Something drum-like for separation: bass + decaying noise bursts on the beat.
    static func groove(seconds: Double, in dir: URL) throws -> URL {
        let rate = 44_100.0
        let n = Int(seconds * rate)
        var l = [Float](repeating: 0, count: n), r = l
        var seed: UInt32 = 12345
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        for i in 0..<n {
            let t = Double(i) / rate
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let hit = Float(exp(-beat * 40)) * noise() * 0.5
            let kick = Float(exp(-beat * 25) * sin(2 * .pi * 60 * beat)) * 0.6
            let bass = 0.15 * sin(2 * .pi * 55 * Float(t))
            l[i] = hit + kick + bass
            r[i] = hit * 0.8 + kick + bass
        }
        let url = dir.appendingPathComponent("groove.wav")
        try AudioFileIO.writeWAV([l, r], sampleRate: rate, to: url, format: .int16)
        return url
    }

    /// Mono 48 kHz take: silence with one sharp click at `clickAt` seconds.
    static func take(seconds: Double, clickAt: Double, in dir: URL) throws -> URL {
        let rate = 48_000.0
        var ch = [Float](repeating: 0, count: Int(seconds * rate))
        let start = Int(clickAt * rate)
        for k in 0..<240 where start + k < ch.count { ch[start + k] = 0.9 * Float(exp(-Double(k) / 20)) }
        let url = dir.appendingPathComponent("take.wav")
        try AudioFileIO.writeWAV([ch], sampleRate: rate, to: url, format: .float32)
        return url
    }

    /// H.264 .mov, 30 fps, black except frame `flashFrame` (white).
    static func flashVideo(seconds: Double, flashFrame: Int, in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("clip.mov")
        try? FileManager.default.removeItem(at: url)
        let w = 360, h = 640, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ServiceError.failed("startWriting") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw ServiceError.failed("no pixel buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw ServiceError.failed("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, i == flashFrame ? 255 : 0, CVPixelBufferGetBytesPerRow(pb) * h)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)) else {
                throw writer.error ?? ServiceError.failed("append frame \(i)")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ServiceError.failed("finishWriting") }
        return url
    }

    /// Time (s) of the loudest sample in a decoded file.
    static func peakTime(_ channels: [[Float]], sampleRate: Double) -> Double {
        var best: Float = -1, at = 0
        for ch in channels {
            for (i, v) in ch.enumerated() where abs(v) > best {
                best = abs(v)
                at = i
            }
        }
        return Double(at) / sampleRate
    }

    /// Time (s) of the loudest audio sample in a movie's audio track.
    static func audioPeakTime(inMovie url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ServiceError.failed("no audio track")
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        reader.startReading()
        var best: Float = -1, bestTime = 0.0
        while let sb = out.copyNextSampleBuffer() {
            guard let fmt = CMSampleBufferGetFormatDescription(sb),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            let channels = Int(asbd.mChannelsPerFrame)
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
            guard let ptr, channels > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            ptr.withMemoryRebound(to: Float.self, capacity: count) { f in
                for i in 0..<count where abs(f[i]) > best {
                    best = abs(f[i])
                    bestTime = start + Double(i / channels) / asbd.mSampleRate
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? ServiceError.failed("audio read failed") }
        return bestTime
    }

    /// Presentation time (s) of the brightest frame in a movie.
    static func flashTime(inMovie url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ServiceError.failed("no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(out)
        reader.startReading()
        var best = -1.0, bestTime = 0.0
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let bytes = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
            var sum = 0.0, n = 0.0
            if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
                var i = 0
                while i < bytes {
                    sum += Double(base[i])
                    n += 1
                    i += 64
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            let mean = n > 0 ? sum / n : 0
            if mean > best {
                best = mean
                bestTime = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            }
        }
        if reader.status == .failed { throw reader.error ?? ServiceError.failed("video read failed") }
        return bestTime
    }

    static func trackCount(_ url: URL, _ type: AVMediaType) async throws -> Int {
        try await AVURLAsset(url: url).loadTracks(withMediaType: type).count
    }

    static func rms(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }
}
