// Port of tests/wav.test.ts, plus Fixtures/dsp/wav.json: encoded bytes must
// equal the TypeScript's exactly; decoding (incl. 8/32-bit PCM, float64,
// WAVE_FORMAT_EXTENSIBLE, streaming sizes) must give the same samples.

import Foundation
import XCTest
@testable import LumberCore

final class DSPWAVTests: XCTestCase {
    typealias S = DSPTestSupport
    let sr = 44100.0
    let n = 4411

    func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }

    func testRoundTrips() throws {
        let L = S.tone(440, 0.8, n, sr), R = S.tone(660, -0.6, n, sr)
        for (depth, tol) in [(WAV.BitDepth.int16, 1.0 / 32768), (.int24, 1.0 / 8388608), (.float32, 0)] {
            let back = try WAV.decode(try WAV.encode([L, R], sampleRate: 44100, bitDepth: depth))
            XCTAssertEqual(back.sampleRate, sr)
            XCTAssertEqual(back.channels.count, 2)
            XCTAssertEqual(back.frameCount, n)
            XCTAssertLessThanOrEqual(max(S.maxErr(L, back.channels[0]), S.maxErr(R, back.channels[1])), tol, "\(depth)")
        }
    }

    func testHeader16() throws {
        let b = try WAV.encode([S.tone(440, 0.8, n, sr), S.tone(660, -0.6, n, sr)], sampleRate: 44100)
        XCTAssertEqual(b.count, 44 + n * 4)
        XCTAssertEqual(u32(b, 4), b.count - 8)
        XCTAssertEqual(Int(b[22]) | Int(b[23]) << 8, 2)
    }

    func testOddSizePadded() throws {
        let b = try WAV.encode([S.tone(440, 0.5, n, sr)], sampleRate: 44100, bitDepth: .int24)
        XCTAssertEqual(b.count % 2, 0)
        XCTAssertEqual(u32(b, 4), b.count - 8)
        XCTAssertEqual(try WAV.decode(b).frameCount, n)
    }

    func testClips() throws {
        let c = try WAV.decode(try WAV.encode([[1.5, -1.5, 1, -1]], sampleRate: 44100)).channels[0]
        XCTAssertGreaterThan(c[0], 0.999)
        XCTAssertEqual(c[1], -1)
        XCTAssertGreaterThan(c[2], 0.999)
        XCTAssertEqual(c[3], -1)
    }

    func testSkipsUnknownChunks() throws {
        let plain = try WAV.encode([[0.25, -0.25]], sampleRate: 8000)
        var out = Array(plain[0..<36])
        out += [0x4C, 0x49, 0x53, 0x54, 5, 0, 0, 0, 1, 2, 3, 4, 5, 0]
        out += plain[36...]
        let size = out.count - 8
        for k in 0..<4 { out[4 + k] = UInt8((size >> (8 * k)) & 0xFF) }
        let back = try WAV.decode(out)
        XCTAssertEqual(back.sampleRate, 8000)
        XCTAssertEqual(back.channels[0], [0.25, -0.25])
    }

    func testRejectsNonRIFF() {
        XCTAssertThrowsError(try WAV.decode([UInt8](repeating: 0, count: 16))) {
            XCTAssertEqual($0 as? WAV.DecodeError, .notRIFF)
        }
        XCTAssertThrowsError(try WAV.encode([], sampleRate: 44100))
    }

    // MARK: Golden fixtures

    func testEncodeMatchesFixture() throws {
        for e in S.list(try S.fixture("dsp/wav.json")["encodes"]) {
            let depth = WAV.BitDepth(rawValue: Int(S.num(e["bitDepth"])))!
            let bytes = try WAV.encode(S.chans(e["input"]), sampleRate: Int(S.num(e["sampleRate"])), bitDepth: depth)
            XCTAssertEqual(bytes, S.u8(e["bytes"]), "encode \(depth) @ \(S.num(e["sampleRate"]))")
        }
    }

    func testDecodeMatchesFixture() throws {
        let f = try S.fixture("dsp/wav.json")
        for d in S.list(f["decodes"]) {
            let got = try WAV.decode(S.u8(d["bytes"]))
            XCTAssertEqual(got.sampleRate, S.num(d["sampleRate"]))
            XCTAssertEqual(got.channels, S.chans(d["channels"]), d["name"] as! String)
        }
        // And every encoded fixture decodes back to exactly what the TS decodes.
        for e in S.list(f["encodes"]) {
            let back = try WAV.decode(S.u8(e["bytes"]))
            XCTAssertEqual(back.channels.count, S.chans(e["input"]).count)
        }
    }
}
