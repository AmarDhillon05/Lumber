// Port of src/dsp/wav.ts: WAV encode/decode for de-interleaved PCM.
//
// encode: 16- or 24-bit integer PCM, or 32-bit IEEE float (with an 18-byte fmt
//         and a fact chunk, per spec). Odd data sizes get a pad byte.
// decode: 8/16/24/32-bit integer PCM, 32/64-bit float, incl. WAVE_FORMAT_EXTENSIBLE;
//         unknown chunks are skipped; a streaming data size is clamped to the file.

import Foundation

public enum WAV {
    /// 16 / 24 = integer PCM, 32 = IEEE float32.
    public enum BitDepth: Int, Sendable, CaseIterable {
        case int16 = 16, int24 = 24, float32 = 32
    }

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case notRIFF
        case missingFmt
        case missingData
        case unsupported(format: Int, bitDepth: Int)
        public var description: String {
            switch self {
            case .notRIFF: return "decodeWav: not a RIFF/WAVE file"
            case .missingFmt: return "decodeWav: missing fmt chunk"
            case .missingData: return "decodeWav: missing data chunk"
            case .unsupported(let f, let b): return "decodeWav: unsupported format \(f) / \(b)-bit"
            }
        }
    }

    public enum EncodeError: Error, Equatable { case noChannels }

    static let formatPCM = 1
    static let formatFloat = 3
    static let formatExtensible = 0xFFFE

    // MARK: Encode

    public static func encode(_ channels: [[Float]], sampleRate: Int, bitDepth: BitDepth = .int16) throws -> [UInt8] {
        let numChannels = channels.count
        guard numChannels > 0 else { throw EncodeError.noChannels }
        let length = channels[0].count
        let isFloat = bitDepth == .float32
        let bytesPerSample = bitDepth.rawValue / 8
        let blockAlign = numChannels * bytesPerSample
        let dataSize = length * blockAlign
        let fmtSize = isFloat ? 18 : 16
        let factSize = isFloat ? 12 : 0
        let headerSize = 12 + (8 + fmtSize) + factSize + 8
        let padded = dataSize + (dataSize & 1)

        var out = [UInt8](repeating: 0, count: headerSize + padded)
        func str(_ o: Int, _ s: String) { for (i, b) in s.utf8.enumerated() { out[o + i] = b } }
        func u16(_ o: Int, _ v: Int) { out[o] = UInt8(v & 0xFF); out[o + 1] = UInt8((v >> 8) & 0xFF) }
        func u32(_ o: Int, _ v: Int) {
            let u = UInt32(truncatingIfNeeded: v)
            for k in 0..<4 { out[o + k] = UInt8((u >> (8 * UInt32(k))) & 0xFF) }
        }

        str(0, "RIFF")
        u32(4, headerSize - 8 + padded)
        str(8, "WAVE")
        var o = 12
        str(o, "fmt ")
        u32(o + 4, fmtSize)
        u16(o + 8, isFloat ? formatFloat : formatPCM)
        u16(o + 10, numChannels)
        u32(o + 12, sampleRate)
        u32(o + 16, sampleRate * blockAlign)
        u16(o + 20, blockAlign)
        u16(o + 22, bitDepth.rawValue)
        if isFloat { u16(o + 24, 0) } // cbSize
        o += 8 + fmtSize
        if isFloat {
            str(o, "fact")
            u32(o + 4, 4)
            u32(o + 8, length)
            o += 12
        }
        str(o, "data")
        u32(o + 4, dataSize)
        o += 8

        out.withUnsafeMutableBufferPointer { out in
            for i in 0..<length {
                for c in 0..<numChannels {
                    let s = channels[c][i]
                    switch bitDepth {
                    case .float32:
                        let bits = (s.isFinite ? s : 0).bitPattern
                        for k in 0..<4 { out[o + k] = UInt8((bits >> (8 * UInt32(k))) & 0xFF) }
                    case .int16:
                        let v = UInt16(bitPattern: Int16(quantize(s, 32768)))
                        out[o] = UInt8(v & 0xFF); out[o + 1] = UInt8(v >> 8)
                    case .int24:
                        let v = quantize(s, 8388608)
                        out[o] = UInt8(v & 0xFF)
                        out[o + 1] = UInt8((v >> 8) & 0xFF)
                        out[o + 2] = UInt8((v >> 16) & 0xFF)
                    }
                    o += bytesPerSample
                }
            }
        }
        return out
    }

    public static func encode(_ buffer: PCMBuffer, bitDepth: BitDepth = .int16) throws -> [UInt8] {
        try encode(buffer.channels, sampleRate: Int(buffer.sampleRate.rounded()), bitDepth: bitDepth)
    }

    /// Round to the nearest 1/scale step (JS Math.round) and clamp to the signed range.
    static func quantize(_ s: Float, _ scale: Int) -> Int {
        guard s.isFinite else { return 0 }
        let v = Int((Double(s) * Double(scale) + 0.5).rounded(.down))
        return v > scale - 1 ? scale - 1 : (v < -scale ? -scale : v)
    }

    // MARK: Decode

    public static func decode(_ bytes: [UInt8]) throws -> PCMBuffer {
        try bytes.withUnsafeBufferPointer { try decode(UnsafeRawBufferPointer($0)) }
    }

    public static func decode(_ data: Data) throws -> PCMBuffer {
        try data.withUnsafeBytes { try decode($0) }
    }

    public static func decode(_ b: UnsafeRawBufferPointer) throws -> PCMBuffer {
        let count = b.count
        func u8(_ o: Int) -> UInt8 { b[o] }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        func tag(_ o: Int) -> String { String(decoding: [b[o], b[o + 1], b[o + 2], b[o + 3]], as: UTF8.self) }

        guard count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw DecodeError.notRIFF }

        var format = 0, numChannels = 0, sampleRate = 0, bitDepth = 0
        var dataOffset = -1, dataSize = 0
        var o = 12
        while o + 8 <= count {
            let id = tag(o)
            let size = u32(o + 4)
            let body = o + 8
            if id == "fmt " {
                // (A truncated fmt chunk is a malformed file; guard instead of trapping.)
                guard body + 16 <= count else { throw DecodeError.missingFmt }
                format = u16(body)
                numChannels = u16(body + 2)
                sampleRate = u32(body + 4)
                bitDepth = u16(body + 14)
                if format == formatExtensible && size >= 40 && body + 26 <= count {
                    format = u16(body + 24) // first 2 bytes of the SubFormat GUID
                }
            } else if id == "data" {
                dataOffset = body
                dataSize = min(size, count - body)
                break
            }
            o = body + size + (size & 1)
        }

        guard numChannels > 0, sampleRate > 0, bitDepth > 0 else { throw DecodeError.missingFmt }
        guard dataOffset >= 0 else { throw DecodeError.missingData }

        let bps = bitDepth / 8
        guard bps > 0 else { throw DecodeError.unsupported(format: format, bitDepth: bitDepth) }
        let frames = dataSize / (bps * numChannels)

        let read: (Int) -> Float
        switch (format, bitDepth) {
        case (formatFloat, 32):
            read = { p in Float(bitPattern: UInt32(truncatingIfNeeded: u32(p))) }
        case (formatFloat, 64):
            read = { p in
                var bits: UInt64 = 0
                for k in 0..<8 { bits |= UInt64(b[p + k]) << (8 * UInt64(k)) }
                return Float(Double(bitPattern: bits))
            }
        case (formatPCM, 8):
            read = { p in Float((Double(u8(p)) - 128) / 128) }
        case (formatPCM, 16):
            read = { p in Float(Double(Int16(truncatingIfNeeded: u16(p))) / 32768) }
        case (formatPCM, 24):
            read = { p in
                let v = Int(b[p]) | Int(b[p + 1]) << 8 | Int(Int8(bitPattern: b[p + 2])) << 16
                return Float(Double(v) / 8388608)
            }
        case (formatPCM, 32):
            read = { p in Float(Double(Int32(truncatingIfNeeded: u32(p))) / 2147483648) }
        default:
            throw DecodeError.unsupported(format: format, bitDepth: bitDepth)
        }

        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: numChannels)
        var p = dataOffset
        for i in 0..<frames {
            for c in 0..<numChannels {
                channels[c][i] = read(p)
                p += bps
            }
        }
        return PCMBuffer(channels: channels, sampleRate: Double(sampleRate))
    }
}
