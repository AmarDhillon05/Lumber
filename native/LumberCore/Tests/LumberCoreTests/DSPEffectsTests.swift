// Port of tests/dsp.test.ts, plus golden comparisons against Fixtures/dsp/effects.json.

import Foundation
import XCTest
@testable import LumberCore

final class DSPEffectsTests: XCTestCase {
    typealias S = DSPTestSupport
    let sr = 48000.0
    func tone(_ f: Double, _ a: Double, _ n: Int = 48000) -> [Float] { S.tone(f, a, n, sr) }

    // MARK: Ported behaviour tests

    func testFFTRoundTrip() {
        let N = 1024
        var rng = S.TestRNG(9)
        let orig = (0..<N).map { Float(sin(2 * Double.pi * 5 * Double($0) / Double(N)) + 0.3 * rng.next()) }
        var re = orig
        var im = [Float](repeating: 0, count: N)
        DSP.fft(&re, &im)
        DSP.fft(&re, &im, inverse: true)
        XCTAssertLessThan(S.maxErr(re, orig), 1e-4)
        XCTAssertEqual(DSP.nextPow2(1000), 1024)
        XCTAssertEqual(DSP.nextPow2(1024), 1024)
    }

    func testCompressorReducesPeak() {
        var ch = [tone(220, 0.9)]
        let before = S.peak(ch[0])
        DSP.compress(&ch, sampleRate: sr, DynamicsParams(thresholdDb: -18, ratio: 4, attackMs: 10, releaseMs: 100))
        XCTAssertLessThan(S.peak(ch[0]), before)
    }

    func testGateAttenuatesQuietSignal() {
        var ch = [tone(220, 0.003)]
        DSP.gate(&ch, sampleRate: sr, DynamicsParams(thresholdDb: -40, ratio: 3, attackMs: 1, releaseMs: 100))
        XCTAssertLessThan(S.peak(ch[0]), 0.003)
    }

    func testSaturationBounded() {
        var ch = [tone(220, 2.0)]
        DSP.saturate(&ch, drive: 3)
        XCTAssertLessThanOrEqual(S.peak(ch[0]), 2.0)
        XCTAssertGreaterThan(S.peak(ch[0]), 0)
    }

    func testWidth() {
        var mono = [tone(220, 0.5)]
        let ref = mono[0]
        DSP.width(&mono, amount: 1)
        XCTAssertEqual(mono[0], ref, "no-op on mono")

        let L = tone(220, 0.5), R = tone(220, 0.2)
        var stereo = [L, R]
        DSP.width(&stereo, amount: 1)
        for i in 0..<1000 {
            let m = (Double(stereo[0][i]) + Double(stereo[1][i])) / 2
            XCTAssertEqual(m, (Double(L[i]) + Double(R[i])) / 2, accuracy: 1e-5)
        }
    }

    func testPresenceFinite() {
        var ch = [tone(4000, 0.4)]
        DSP.presence(&ch, sampleRate: sr, PresenceParams(lowHz: 2000, highHz: 8000, drive: 2, blend: 0.3))
        XCTAssertTrue(S.peak(ch[0]).isFinite)
        XCTAssertGreaterThan(S.peak(ch[0]), 0)
    }

    func testResonanceDetectorContract() {
        let base = tone(120, 0.05), ring = tone(2000, 0.6)
        let mix = zip(base, ring).map { $0 + $1 }
        let freqs = DSP.detectResonances([mix], sampleRate: sr)
        XCTAssertTrue((1...5).contains(freqs.count))
        XCTAssertTrue(freqs.allSatisfy { $0 > 80 && $0 < 8000 })
    }

    func testSpectralGateLengthAndFinite() {
        var ch = [tone(220, 0.5, 24000)]
        DSP.spectralGate(&ch, SpectralGateParams(propDecrease: 0.8, stationary: true))
        XCTAssertEqual(ch[0].count, 24000)
        XCTAssertTrue(S.finite(ch[0]))
    }

    func testAmplifiedBlanketRangesStayFinite() {
        var ch = [tone(220, 0.9)]
        DSP.saturate(&ch, drive: 1 + 3 * 2)
        XCTAssertTrue(S.finite(ch[0]) && S.peak(ch[0]) > 0 && S.peak(ch[0]) <= 0.9)

        ch = [tone(220, 0.9)]
        let before = S.peak(ch[0])
        DSP.compress(&ch, sampleRate: sr, DynamicsParams(thresholdDb: -3, ratio: 1 + 3 * 19, attackMs: 0.1, releaseMs: 50))
        XCTAssertTrue(S.finite(ch[0]) && S.peak(ch[0]) <= before)

        ch = [tone(220, 0.5, 24000)]
        DSP.spectralGate(&ch, SpectralGateParams(propDecrease: 1, stationary: true))
        XCTAssertTrue(S.finite(ch[0]))

        var stereo = [tone(220, 0.5), tone(220, 0.2)]
        DSP.width(&stereo, amount: 3)
        XCTAssertTrue(S.finite(stereo[0]) && S.finite(stereo[1]))

        ch = [tone(4000, 0.4)]
        DSP.presence(&ch, sampleRate: sr, PresenceParams(lowHz: 2000, highHz: 8000, drive: 4, blend: 0.9))
        XCTAssertTrue(S.finite(ch[0]) && S.peak(ch[0]) > 0)
    }

    func testUpwardCompressor() {
        var quiet = [tone(220, 0.01)]
        let qBefore = S.peak(quiet[0])
        let p = UpwardCompressorParams(thresholdDb: -30, ratio: 4, maxGainDb: 12, attackMs: 5, releaseMs: 150)
        DSP.upwardCompress(&quiet, sampleRate: sr, p)
        XCTAssertGreaterThan(S.peak(quiet[0]), qBefore)
        XCTAssertTrue(S.finite(quiet[0]))

        var loud = [tone(220, 0.9)]
        DSP.upwardCompress(&loud, sampleRate: sr, p)
        XCTAssertLessThanOrEqual(S.peak(loud[0]), 1.0)
        XCTAssertGreaterThanOrEqual(S.peak(loud[0]), 0.9 - 1e-3)
    }

    // MARK: Golden fixtures

    func testFFTMatchesFixture() throws {
        let fx = S.dict(try S.fixture("dsp/effects.json")["fft"])
        var re = S.f32(fx["re"]), im = S.f32(fx["im"])
        DSP.fft(&re, &im)
        XCTAssertLessThanOrEqual(S.maxErr(re, S.f32(fx["outRe"])), 1e-6)
        XCTAssertLessThanOrEqual(S.maxErr(im, S.f32(fx["outIm"])), 1e-6)
        DSP.fft(&re, &im, inverse: true)
        XCTAssertLessThanOrEqual(S.maxErr(re, S.f32(fx["invRe"])), 1e-7)
        XCTAssertLessThanOrEqual(S.maxErr(im, S.f32(fx["invIm"])), 1e-7)
    }

    func testNextPow2MatchesFixture() throws {
        for pair in try S.fixture("dsp/effects.json")["nextPow2"] as! [[Int]] {
            XCTAssertEqual(DSP.nextPow2(pair[0]), pair[1], "nextPow2(\(pair[0]))")
        }
    }

    func testBandpassAndFiltfiltMatchFixture() throws {
        let f = try S.fixture("dsp/effects.json")
        let bp = S.dict(f["bandpass"])
        let c = BiquadCoefficients.bandpass(lowHz: S.num(bp["lowHz"]), highHz: S.num(bp["highHz"]),
                                            sampleRate: S.num(bp["sampleRate"]))
        let want = S.dict(bp["coeffs"])
        XCTAssertEqual(c.b0, S.num(want["b0"]), accuracy: 1e-15)
        XCTAssertEqual(c.b1, S.num(want["b1"]), accuracy: 1e-15)
        XCTAssertEqual(c.b2, S.num(want["b2"]), accuracy: 1e-15)
        XCTAssertEqual(c.a1, S.num(want["a1"]), accuracy: 1e-15)
        XCTAssertEqual(c.a2, S.num(want["a2"]), accuracy: 1e-15)
        let input = S.chans(f["input"])
        XCTAssertLessThanOrEqual(S.maxErr(DSP.filtfilt(input[0], c), S.f32(bp["filtfilt"])), 1e-7)
    }

    func testEffectsMatchFixture() throws {
        let f = try S.fixture("dsp/effects.json")
        let sr = S.num(f["sampleRate"])
        let input = S.chans(f["input"])
        for c in S.list(f["cases"]) {
            let name = c["name"] as! String
            let p = S.dict(c["params"])
            var ch = (c["stereo"] as! Bool) ? input : [input[0]]
            func dyn() -> DynamicsParams {
                DynamicsParams(thresholdDb: S.num(p["thresholdDb"]), ratio: S.num(p["ratio"]),
                               attackMs: S.num(p["attackMs"]), releaseMs: S.num(p["releaseMs"]))
            }
            switch c["fn"] as! String {
            case "compress": DSP.compress(&ch, sampleRate: sr, dyn())
            case "gate": DSP.gate(&ch, sampleRate: sr, dyn())
            case "upwardCompress":
                DSP.upwardCompress(&ch, sampleRate: sr, UpwardCompressorParams(
                    thresholdDb: S.num(p["thresholdDb"]), ratio: S.num(p["ratio"]), maxGainDb: S.num(p["maxGainDb"]),
                    attackMs: S.num(p["attackMs"]), releaseMs: S.num(p["releaseMs"])))
            case "saturate": DSP.saturate(&ch, drive: S.num(p["drive"]))
            case "presence":
                DSP.presence(&ch, sampleRate: sr, PresenceParams(lowHz: S.num(p["lowHz"]), highHz: S.num(p["highHz"]),
                                                                  drive: S.num(p["drive"]), blend: S.num(p["blend"])))
            case "width": DSP.width(&ch, amount: S.num(p["amount"]))
            case "spectralGate":
                DSP.spectralGate(&ch, SpectralGateParams(propDecrease: S.num(p["propDecrease"]),
                                                         stationary: p["stationary"] as! Bool))
            default: XCTFail("unknown fn in \(name)")
            }
            S.assertClose(ch, S.chans(c["out"]), tol: 2e-6, name)
        }
    }

    func testResonancesMatchFixture() throws {
        let f = try S.fixture("dsp/effects.json")
        let sr = S.num(f["sampleRate"])
        let r = S.dict(f["resonance"])
        let got = DSP.detectResonances([S.f32(r["input"])], sampleRate: sr)
        let want = S.nums(r["freqs"])
        XCTAssertEqual(got.count, want.count)
        for (g, w) in zip(got, want) { XCTAssertEqual(g, w, accuracy: 1e-9) }
        XCTAssertFalse(want.isEmpty)
        let drums = DSP.detectResonances(S.chans(f["input"]), sampleRate: sr)
        XCTAssertEqual(drums, S.nums(r["drumFreqs"]))
    }
}
