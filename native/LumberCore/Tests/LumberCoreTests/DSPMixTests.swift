// Port of tests/mix.test.ts, plus Fixtures/dsp/mix.json (mixTake, limiter,
// normalize and resampler outputs from the TypeScript).

import Foundation
import XCTest
@testable import LumberCore

final class DSPMixTests: XCTestCase {
    typealias S = DSPTestSupport
    let sr = 48000.0
    let ceil1 = pow(10, -1.0 / 20)
    func filled(_ n: Int, _ v: Float) -> [Float] { [Float](repeating: v, count: n) }
    func ramp(_ n: Int) -> [Float] { (0..<n).map { Float(Double($0) / Double(n)) } }
    func opts(song: [[Float]], drums: [[Float]], offset: Double, songGain: Double = 1, drumGain: Double = 1,
              limit: Bool = false, normalize: Bool = false, original: DSP.OriginalDrums? = nil) -> DSP.MixOptions {
        DSP.MixOptions(song: song, drums: drums, sampleRate: sr, drumOffsetSec: offset, songGain: songGain,
                       drumGain: drumGain, originalDrums: original, limit: limit, normalize: normalize)
    }

    func sineErr(_ x: [Float], _ freq: Double, _ rate: Double, _ amp: Double, _ from: Int, _ to: Int) -> Double {
        var e = 0.0
        for i in from..<to { e = max(e, abs(Double(x[i]) - amp * sin(2 * Double.pi * freq * Double(i) / rate))) }
        return e
    }

    func rms(_ x: [Float], _ from: Int, _ to: Int) -> Double {
        var s = 0.0
        for i in from..<to { s += Double(x[i]) * Double(x[i]) }
        return (s / Double(max(1, to - from))).squareRoot()
    }

    // MARK: Ported behaviour tests

    func testPositiveOffset() {
        let n = Int(sr)
        let drums = [ramp(n)]
        let out = DSP.mixTake(opts(song: [filled(n, 0), filled(n, 0)], drums: drums, offset: 0.5))
        let off = n / 2
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].count, n + off)
        XCTAssertEqual(out[0][off - 1], 0)
        XCTAssertEqual(out[0][off + 100], drums[0][100])
        XCTAssertEqual(out[1][off + 100], drums[0][100])
    }

    func testNegativeOffsetTrims() {
        let n = Int(sr)
        let drums = [ramp(n)]
        let out = DSP.mixTake(opts(song: [filled(n, 0)], drums: drums, offset: -0.25))
        let trim = n / 4
        XCTAssertEqual(out[0][0], drums[0][trim])
        XCTAssertEqual(out[0][10], drums[0][trim + 10])
        XCTAssertEqual(out[0].count, n)
    }

    func testDrumsFullyTrimmed() {
        let out = DSP.mixTake(opts(song: [filled(100, 0.1)], drums: [filled(50, 1)], offset: -1))
        XCTAssertEqual(out[0].count, 100)
        XCTAssertEqual(Double(out[0][0]), 0.1, accuracy: 1e-7)
    }

    func testGains() {
        let out = DSP.mixTake(opts(song: [filled(1000, 0.2), filled(1000, 0.2)], drums: [filled(1000, 0.4)],
                                   offset: 0, songGain: 0.5, drumGain: 0.25))
        XCTAssertEqual(Double(out[0][500]), 0.2, accuracy: 1e-6)
        XCTAssertEqual(Double(out[1][500]), 0.2, accuracy: 1e-6)
    }

    func testOriginalDrums() {
        let od = DSP.OriginalDrums(drums: [filled(1000, 0.3)], noDrums: [filled(1000, 0.1)], amount: 0.5)
        let out = DSP.mixTake(opts(song: [filled(1000, 9)], drums: [filled(1000, 0)], offset: 0, songGain: 0.5, original: od))
        XCTAssertEqual(Double(out[0][10]), 0.125, accuracy: 1e-6)
    }

    func testLimiterCeiling() {
        let n = Int(sr)
        let out = DSP.mixTake(opts(song: [S.tone(220, 1.5, n, sr), S.tone(330, 1.5, n, sr)],
                                   drums: [S.tone(80, 1.2, n, sr)], offset: 0.1, limit: true))
        let p = max(S.peak(out[0]), S.peak(out[1]))
        XCTAssertLessThanOrEqual(Double(p), ceil1 + 1e-6)
        XCTAssertTrue(S.finite(out[0]))
    }

    func testLimiterTransparentBelowCeiling() {
        let x = S.tone(440, 0.5, Int(sr), sr)
        var ch = [x]
        DSP.limitPeaks(&ch, sampleRate: sr)
        XCTAssertEqual(ch[0], x)
    }

    func testLimiterIsLocal() {
        let n = Int(sr)
        var x = S.tone(440, 0.5, n, sr)
        let at = n / 2
        x[at] = 2
        var ch = [x]
        DSP.limitPeaks(&ch, sampleRate: sr, DSP.LimiterOptions(lookaheadMs: 5, releaseMs: 50))
        let L = Int((0.005 * sr).rounded())
        let far = at - 2 * L
        XCTAssertLessThanOrEqual(Double(abs(ch[0][at])), ceil1 + 1e-7)
        XCTAssertEqual(ch[0][far], x[far])
        XCTAssertLessThan(abs(ch[0][at + n / 4] - x[at + n / 4]), 1e-3)
    }

    func testNormalize() {
        let n = Int(sr)
        let out = DSP.mixTake(opts(song: [S.tone(220, 0.1, n, sr)], drums: [S.tone(110, 0.05, n, sr)], offset: 0,
                                   limit: true, normalize: true))
        XCTAssertEqual(Double(S.peak(out[0])), ceil1, accuracy: 1e-6)
        var silent = [filled(10, 0)]
        DSP.normalizePeak(&silent)
        XCTAssertEqual(silent[0], filled(10, 0))
    }

    func testResample44to48() throws {
        let x = S.tone(1000, 0.5, 44100, 44100)
        let y = try DSP.resample([x], from: 44100, to: 48000)[0]
        XCTAssertEqual(y.count, 48000)
        XCTAssertLessThan(sineErr(y, 1000, 48000, 0.5, 2000, 46000), 2e-3)
    }

    func testResample48to44Stereo() throws {
        let n = Int(sr)
        let out = try DSP.resample([S.tone(15000, 0.5, n, sr), S.tone(440, 0.5, n, sr)], from: 48000, to: 44100)
        XCTAssertEqual(out[0].count, 44100)
        XCTAssertEqual(out[1].count, 44100)
        XCTAssertLessThan(sineErr(out[0], 15000, 44100, 0.5, 2000, 42000), 5e-3)
        XCTAssertLessThan(sineErr(out[1], 440, 44100, 0.5, 2000, 42000), 2e-3)
    }

    func testResampleRejectsAlias() throws {
        let y = try DSP.resample([S.tone(23000, 0.5, Int(sr), sr)], from: 48000, to: 44100)[0]
        XCTAssertLessThan(rms(y, 2000, 42000), 0.005)
    }

    func testResampleInterpolatedPhases() throws {
        let y = try DSP.resample([S.tone(1000, 0.5, Int(sr), sr)], from: 48000, to: 47993)[0]
        XCTAssertEqual(y.count, Int((sr * 47993 / 48000).rounded()))
        XCTAssertLessThan(sineErr(y, 1000, 47993, 0.5, 2000, 45000), 3e-3)
    }

    func testResampleSameRateCopies() throws {
        let x = ramp(100)
        XCTAssertEqual(try DSP.resample([x], from: 48000, to: 48000)[0], x)
        XCTAssertThrowsError(try DSP.resample([x], from: 0, to: 48000))
    }

    // MARK: Golden fixtures

    func testMixTakeMatchesFixture() throws {
        let f = try S.fixture("dsp/mix.json")
        for m in S.list(f["mixes"]) {
            let o = S.dict(m["opts"])
            var original: DSP.OriginalDrums?
            if let od = o["originalDrums"] as? [String: Any] {
                original = DSP.OriginalDrums(drums: S.chans(od["drums"]), noDrums: S.chans(od["noDrums"]), amount: S.num(od["amount"]))
            }
            let out = DSP.mixTake(DSP.MixOptions(
                song: S.chans(o["song"]), drums: S.chans(o["drums"]), sampleRate: S.num(o["sampleRate"]),
                drumOffsetSec: S.num(o["drumOffsetSec"]), songGain: S.num(o["songGain"]), drumGain: S.num(o["drumGain"]),
                originalDrums: original, limit: o["limit"] as! Bool, ceilingDb: S.num(o["ceilingDb"]),
                normalize: o["normalize"] as! Bool))
            S.assertClose(out, S.chans(m["out"]), tol: 1e-7, m["name"] as! String)
        }
    }

    func testLimiterMatchesFixture() throws {
        let f = S.dict(try S.fixture("dsp/mix.json")["limiter"])
        let input = S.chans(f["input"])
        let sr = S.num(f["sampleRate"])
        var a = input
        DSP.limitPeaks(&a, sampleRate: sr)
        S.assertClose(a, S.chans(f["defaultOut"]), tol: 1e-7, "limiter default")
        var b = input
        DSP.limitPeaks(&b, sampleRate: sr, DSP.LimiterOptions(ceilingDb: -3, lookaheadMs: 2, releaseMs: 20))
        S.assertClose(b, S.chans(f["customOut"]), tol: 1e-7, "limiter custom")
        var c = input
        DSP.normalizePeak(&c, ceilingDb: -2)
        S.assertClose(c, S.chans(f["normalizeOut"]), tol: 1e-7, "normalize")
    }

    func testResampleMatchesFixture() throws {
        let f = S.dict(try S.fixture("dsp/mix.json")["resample"])
        let input = S.chans(f["input"])
        for c in S.list(f["cases"]) {
            let from = S.num(c["from"]), to = S.num(c["to"])
            let out = try DSP.resample(input, from: from, to: to)
            S.assertClose(out, S.chans(c["out"]), tol: 1e-6, "resample \(from)→\(to)")
        }
    }
}
