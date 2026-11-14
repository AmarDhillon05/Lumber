// Decode any audio file AVFoundation can read (MP3/M4A/AAC/WAV/AIFF/CAF…)
// into float channels at a target sample rate, and write float channels to
// WAV. Songs are decoded at 48 kHz for editing/export and at 44.1 kHz for
// drum separation (Demucs).
//
// LumberCore also has a pure WAV encoder (DSP/WAV); this file uses
// AVAudioFile so it streams to disk without building the whole file in memory.

import AVFoundation

/// Deinterleaved float audio. `channels[c][i]` is sample i of channel c.
public struct DecodedAudio: Sendable, Equatable {
    public var channels: [[Float]]
    public var sampleRate: Double

    public init(channels: [[Float]], sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
    }

    public var frameCount: Int { channels.first?.count ?? 0 }
    public var durationSec: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}

/// Sample format of a written WAV.
public enum WAVSampleFormat: String, Sendable, Codable, CaseIterable {
    case int16, int24, float32

    var bitDepth: Int {
        switch self {
        case .int16: 16
        case .int24: 24
        case .float32: 32
        }
    }

    var isFloat: Bool { self == .float32 }
}

public enum AudioFileIO {
    /// Engine / editing / export rate.
    public static let editingSampleRate = 48_000.0
    /// Rate the separation model expects.
    public static let separationSampleRate = 44_100.0

    /// Decodes `url` to float channels at `sampleRate`.
    ///
    /// - Parameter channelCount: 1 = mono (channels averaged), 2 = stereo (mono
    ///   duplicated), nil = keep the file's layout (files with more than two
    ///   channels are downmixed to stereo).
    /// Synchronous and CPU-heavy: call from a background task (see `decodeDetached`).
    public static func decode(_ url: URL, sampleRate: Double, channelCount: Int? = nil) throws -> DecodedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw PlatformError.decodeFailed(error.localizedDescription)
        }
        let src = file.processingFormat // float32, deinterleaved, file rate
        let srcChannels = Int(src.channelCount)
        guard srcChannels > 0, src.sampleRate > 0, sampleRate > 0 else {
            throw PlatformError.decodeFailed("Unsupported audio format")
        }
        let workChannels = min(srcChannels, 2)
        let estimate = Int(Double(file.length) * sampleRate / src.sampleRate) + 8192
        var out = [[Float]](repeating: [], count: workChannels)
        for c in 0..<workChannels { out[c].reserveCapacity(estimate) }

        if src.sampleRate == sampleRate && srcChannels == workChannels {
            try readDirect(file, format: src, into: &out)
        } else {
            try readConverted(file, from: src, sampleRate: sampleRate, channels: workChannels, into: &out)
        }
        return DecodedAudio(channels: remix(out, to: channelCount), sampleRate: sampleRate)
    }

    /// `decode` on a background task.
    public static func decodeDetached(_ url: URL, sampleRate: Double, channelCount: Int? = nil) async throws -> DecodedAudio {
        try await Task.detached(priority: .userInitiated) {
            try AudioFileIO.decode(url, sampleRate: sampleRate, channelCount: channelCount)
        }.value
    }

    /// Duration of an audio file in seconds (without decoding it).
    public static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let rate = file.fileFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    /// Writes deinterleaved float channels to a WAV file (replacing `url`).
    /// Channels shorter than the longest are padded with silence. Float input
    /// is clipped by the file converter for integer formats.
    public static func writeWAV(
        _ channels: [[Float]],
        sampleRate: Double,
        to url: URL,
        format: WAVSampleFormat = .int24
    ) throws {
        guard !channels.isEmpty, sampleRate > 0 else { throw PlatformError.writeFailed("No audio to write") }
        try? FileManager.default.removeItem(at: url)
        let frames = channels.map(\.count).max() ?? 0
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: wavSettings(sampleRate: sampleRate, channels: channels.count, format: format),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let chunk = 32_768
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)),
                  let dst = buffer.floatChannelData
            else { throw PlatformError.writeFailed("Could not allocate an audio buffer") }
            var start = 0
            while start < frames {
                let n = min(chunk, frames - start)
                for (c, channel) in channels.enumerated() {
                    let d = dst[c]
                    let have = max(0, min(n, channel.count - start))
                    channel.withUnsafeBufferPointer { p in
                        if have > 0, let base = p.baseAddress { d.update(from: base + start, count: have) }
                    }
                    if have < n { (d + have).update(repeating: 0, count: n - have) }
                }
                buffer.frameLength = AVAudioFrameCount(n)
                try file.write(from: buffer)
                start += n
            }
            // `file` is closed (header finalized) when it goes out of scope here.
        } catch let e as PlatformError {
            throw e
        } catch {
            throw PlatformError.writeFailed(error.localizedDescription)
        }
    }

    /// AVAudioFile settings for a little-endian interleaved PCM WAV.
    static func wavSettings(sampleRate: Double, channels: Int, format: WAVSampleFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: format.bitDepth,
            AVLinearPCMIsFloatKey: format.isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    // MARK: Internals

    private static func readDirect(_ file: AVAudioFile, format: AVAudioFormat, into out: inout [[Float]]) throws {
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw PlatformError.decodeFailed("Could not allocate an audio buffer")
        }
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                throw PlatformError.decodeFailed(error.localizedDescription)
            }
            if buffer.frameLength == 0 { break }
            append(buffer, to: &out)
        }
    }

    private static func readConverted(
        _ file: AVAudioFile,
        from src: AVAudioFormat,
        sampleRate: Double,
        channels: Int,
        into out: inout [[Float]]
    ) throws {
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: false
        ),
            let converter = AVAudioConverter(from: src, to: dstFormat)
        else { throw PlatformError.decodeFailed("No converter for this format") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        if Int(src.channelCount) > channels { converter.downmix = true }

        let chunk: AVAudioFrameCount = 32_768
        guard let output = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: chunk) else {
            throw PlatformError.decodeFailed("Could not allocate an audio buffer")
        }
        let feeder = FileFeeder(file: file, format: src, chunk: chunk)
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                feeder.next(inputStatus)
            }
            if status == .error {
                throw PlatformError.decodeFailed(error?.localizedDescription ?? "Conversion failed")
            }
            if let readError = feeder.error {
                throw PlatformError.decodeFailed(readError.localizedDescription)
            }
            if output.frameLength > 0 { append(output, to: &out) }
            if status == .endOfStream { break }
            if status == .inputRanDry && output.frameLength == 0 { break }
        }
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to out: inout [[Float]]) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        for c in 0..<min(out.count, Int(buffer.format.channelCount)) {
            out[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: n))
        }
    }

    private static func remix(_ channels: [[Float]], to count: Int?) -> [[Float]] {
        guard let count, count != channels.count, !channels.isEmpty else { return channels }
        if count == 1 {
            let n = channels.map(\.count).min() ?? 0
            let scale = 1 / Float(channels.count)
            var mono = [Float](repeating: 0, count: n)
            for ch in channels {
                for i in 0..<n { mono[i] += ch[i] * scale }
            }
            return [mono]
        }
        // Up to `count` channels: repeat the last one (mono → stereo duplicates).
        return (0..<count).map { channels[min($0, channels.count - 1)] }
    }
}

/// Feeds an AVAudioConverter from a file in chunks. The input block may be
/// imported as @Sendable, so its state lives in a reference type rather than
/// captured `var`s. Only ever used synchronously from `convert`.
private final class FileFeeder: @unchecked Sendable {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let chunk: AVAudioFrameCount
    private var done = false
    private(set) var error: Error?

    init(file: AVAudioFile, format: AVAudioFormat, chunk: AVAudioFrameCount) {
        self.file = file
        self.format = format
        self.chunk = chunk
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if done || file.framePosition >= file.length {
            done = true
            status.pointee = .endOfStream
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            done = true
            status.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: buffer, frameCount: chunk)
        } catch {
            self.error = error
            done = true
            status.pointee = .endOfStream
            return nil
        }
        if buffer.frameLength == 0 {
            done = true
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return buffer
    }
}
