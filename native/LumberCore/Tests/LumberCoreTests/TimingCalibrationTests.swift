// Port of tests/calibration.test.ts, plus Fixtures/timing/timing.json: the
// matched filter output and, for the same synthesized recordings, the exact
// estimates the TypeScript produced.

import Foundation
import XCTest
@testable import LumberCore

final class TimingCalibrationTests: XCTestCase {
    typealias S = DSPTestSupport
    static let SR = 48000.0

    struct SynthOptions {
        var delayMs: Double
        var gain: Double
        var noise: Double
        var polarity: Double = 1
        var seed: UInt32 = 1
        var lowpass = false
    }

    /// Same synthesized recording as tests/calibration.test.ts.
    static func synth(_ o: SynthOptions) -> (x: [Float], clickTimes: [Double]) {
        let clickTimes = (0..<8).map { 0.3 + Double($0) * 0.5 }
        var x = [Float](repeating: 0, count: Int((SR * 5).rounded()))
        var r = S.TestRNG(o.seed)
        for i in 0..<x.count {
            let u = max(1e-12, r.next())
            let g = (-2 * log(u)).squareRoot() * cos(2 * Double.pi * r.next())
            x[i] = Float(o.noise * g + 0.05 * sin((2 * Double.pi * 60 * Double(i)) / SR))
        }
        let click = Timing.makeClick(sampleRate: SR, .beat)
        let delay = (o.delayMs / 1000) * SR
        for t in clickTimes {
            let start = t * SR + delay
            let i0 = Int(start.rounded(.down))
            let frac = start - Double(i0)
            for k in 0..<click.count {
                let prev = k > 0 ? Double(click[k - 1]) : 0
                let v = (1 - frac) * Double(click[k]) + frac * prev
                x[i0 + k] = Float(Double(x[i0 + k]) + o.polarity * o.gain * v)
            }
            for k in 0..<click.count {
                x[i0 + k + 336] = Float(Double(x[i0 + k + 336]) + 0.3 * o.gain * Double(click[k]))
            }
        }
        if o.lowpass {
            var y = 0.0
            for i in 0..<x.count {
                y += 0.5 * (Double(x[i]) - y)
                x[i] = Float(y)
            }
        }
        return (x, clickTimes)
    }

    // MARK: Ported behaviour tests

    func testFinds137msInNoise() {
        let (x, ct) = Self.synth(.init(delayMs: 137.3, gain: 0.25, noise: 0.02))
        let e = Timing.estimateLatency(x, sampleRate: Self.SR, clickFileTimes: ct)
        XCTAssertEqual(e.latencyMs, 137.3, accuracy: 1)
        XCTAssertTrue(e.isReliable, "\(e)")
    }

    func testInvertedPolarityAndLowpass() {
        let (x, ct) = Self.synth(.init(delayMs: 42.1, gain: 0.3, noise: 0.01, polarity: -1, seed: 7, lowpass: true))
        XCTAssertEqual(Timing.estimateLatency(x, sampleRate: Self.SR, clickFileTimes: ct).latencyMs, 42.1, accuracy: 1)
    }

    func testBluetoothScaleDelay() {
        let (x, ct) = Self.synth(.init(delayMs: 230, gain: 0.08, noise: 0.03, seed: 3))
        XCTAssertEqual(Timing.estimateLatency(x, sampleRate: Self.SR, clickFileTimes: ct).latencyMs, 230, accuracy: 1.5)
    }

    func testPureNoiseUnreliable() {
        let (x, ct) = Self.synth(.init(delayMs: 100, gain: 0, noise: 0.05, seed: 11))
        XCTAssertFalse(Timing.estimateLatency(x, sampleRate: Self.SR, clickFileTimes: ct).isReliable)
    }

    // MARK: Golden fixtures

    func testMatchedFilterMatchesFixture() throws {
        let m = S.dict(try S.fixture("timing/timing.json")["matchedFilter"])
        let got = Timing.matchedFilter(S.f32(m["x"]), S.f32(m["t"]))
        XCTAssertLessThanOrEqual(S.maxErr(got, S.f32(m["out"])), 2e-6)
    }

    func testEstimatesMatchFixture() throws {
        for c in S.list(try S.fixture("timing/timing.json")["calibration"]) {
            let o = S.dict(c["synth"])
            let (x, ct) = Self.synth(.init(delayMs: S.num(o["delayMs"]), gain: S.num(o["gain"]), noise: S.num(o["noise"]),
                                           polarity: o["polarity"].map { S.num($0) } ?? 1,
                                           seed: UInt32(S.num(o["seed"])), lowpass: (o["lowpass"] as? Bool) ?? false))
            // The synthesized input itself agrees with the TS (spot check of 1000 samples).
            XCTAssertLessThanOrEqual(S.maxErr(Array(x[14000..<15000]), S.f32(c["head"])), 1e-7)
            XCTAssertEqual(ct, S.nums(c["clickTimes"]))
            let e = Timing.estimateLatency(x, sampleRate: Self.SR, clickFileTimes: ct)
            let w = S.dict(c["est"])
            XCTAssertEqual(e.latencyMs, S.num(w["latencyMs"]), accuracy: 1e-9, "latency \(o)")
            XCTAssertEqual(e.spreadMs, S.num(w["spreadMs"]), accuracy: 1e-9, "spread \(o)")
            XCTAssertEqual(e.confidence, S.num(w["confidence"]), accuracy: 1e-4 * S.num(w["confidence"]), "confidence \(o)")
        }
    }
}
