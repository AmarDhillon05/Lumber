// Streaming 32-bit float WAV writer: header first with placeholder sizes,
// interleaved blocks appended as they arrive, sizes patched on finish.
// Float keeps headroom — a no-drums stem can exceed ±1 before the final mix.
// Port of src/separation/wavStream.ts.

import Foundation

public func floatWavHeader(sampleRate: Int, channels: Int, dataBytes: Int) -> Data {
    var d = Data()
    func ascii(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
    func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    ascii("RIFF"); u32(36 + dataBytes); ascii("WAVE")
    ascii("fmt "); u32(16); u16(3) // IEEE float
    u16(channels); u32(sampleRate); u32(sampleRate * channels * 4); u16(channels * 4); u16(32)
    ascii("data"); u32(dataBytes)
    return d
}

/// Writes to a file handle; `finish()` patches the header sizes.
public final class FloatWavWriter {
    private let handle: FileHandle
    private let sampleRate: Int
    private let channels: Int
    public private(set) var dataBytes = 0

    public init(url: URL, sampleRate: Int, channels: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.sampleRate = sampleRate
        self.channels = channels
        try handle.write(contentsOf: floatWavHeader(sampleRate: sampleRate, channels: channels, dataBytes: 0))
    }

    public func write(_ block: [[Float]]) throws {
        let frames = block.first?.count ?? 0
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            for c in 0..<channels { interleaved[i * channels + c] = block[c][i] } // targets are little-endian
        }
        let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.write(contentsOf: data)
        dataBytes += data.count
    }

    public func finish() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: floatWavHeader(sampleRate: sampleRate, channels: channels, dataBytes: dataBytes))
        try handle.close()
    }
}
