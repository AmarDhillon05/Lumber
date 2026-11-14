// Port of tests/offsets.test.ts (offsets + window peaks), plus the offsets,
// peaks and click parts of Fixtures/timing/timing.json.

import Foundation
import XCTest
@testable import LumberCore

final class TimingOffsetsTests: XCTestCase {
    typealias S = DSPTestSupport

    // MARK: Ported behaviour tests

    func testRecorderStartIsMedian() {
        let buf = 256.0 / 48000
        var samples: [Timing.ClockSample] = []
        for i in 0..<101 {
            let t = 10.2 + Double(i) * 0.02
            let jitter = Double((i * 37) % 11) / 10 - 0.5
            samples.append(.init(ctxTime: t, recSec: t - 10 + jitter * buf))
        }
        samples.append(.init(ctxTime: 10.05, recSec: 0))
        let est = Timing.estimateRecorderStartCtx(samples)!
        XCTAssertLessThan(abs(est - 10), buf / 2)
        XCTAssertNil(Timing.estimateRecorderStartCtx([.init(ctxTime: 1, recSec: 0)]))
    }

    func testDrumOffsetLandsOnTheBeat() {
        let latency = 0.12
        let offset = Timing.computeDrumOffset(.init(songStartSec: 30, songCtxStart: 12, recStartCtx: 10, latencySec: latency))
        let fileTime = 13.5 + latency - 10
        XCTAssertEqual(offset + fileTime, 31.5, accuracy: 1e-9)
        XCTAssertEqual(Timing.songToDrumTime(31.5, drumOffsetSec: offset), fileTime, accuracy: 1e-9)
    }

    func testCountInSchedule() {
        let s = Timing.scheduleCountIn(now: 5, leadSec: 0.25, bpm: 120, countInBeats: 4)
        XCTAssertEqual(s.clickTimes, [5.25, 5.75, 6.25, 6.75])
        XCTAssertEqual(s.songCtxStart, 7.25, accuracy: 1e-9)
        let none = Timing.scheduleCountIn(now: 5, leadSec: 0.25, bpm: 120, countInBeats: 0)
        XCTAssertTrue(none.clickTimes.isEmpty)
        XCTAssertEqual(none.songCtxStart, 5.25, accuracy: 1e-9)
        XCTAssertEqual(Timing.scheduleCountIn(now: 0, leadSec: 0, bpm: 1e6, countInBeats: 1).beatSec, 60.0 / 300, accuracy: 1e-9)
    }

    func testTransportPosition() {
        XCTAssertEqual(Timing.transportPosition(now: 4, songCtxStart: 5, songStartSec: 30), 30, accuracy: 1e-9)
        XCTAssertEqual(Timing.transportPosition(now: 6.5, songCtxStart: 5, songStartSec: 30), 31.5, accuracy: 1e-9)
        let loop = Timing.LoopRegion(start: 30, end: 34)
        XCTAssertEqual(Timing.transportPosition(now: 10, songCtxStart: 5, songStartSec: 30, loop: loop), 31, accuracy: 1e-9)
        XCTAssertEqual(Timing.transportPosition(now: 8, songCtxStart: 5, songStartSec: 30, loop: loop), 33, accuracy: 1e-9)
    }

    func testDrumStartForPreview() {
        let a = Timing.drumStartFor(songSec: 30, drumOffsetSec: 28)
        XCTAssertEqual(a.delaySec, 0); XCTAssertEqual(a.offsetSec, 2)
        let b = Timing.drumStartFor(songSec: 30, drumOffsetSec: 31)
        XCTAssertEqual(b.delaySec, 1); XCTAssertEqual(b.offsetSec, 0)
    }

    func testWindowPeaksHonourOffset() {
        var sig = [Float](repeating: 0, count: 100)
        sig[50] = 1
        XCTAssertEqual(Timing.windowPeaks(sig, sampleRate: 100, startSec: 0, endSec: 4, columns: 4, offsetSec: 2), [0, 0, 1, 0])
    }

    // MARK: Golden fixtures

    func testOffsetsMatchFixture() throws {
        let f = S.dict(try S.fixture("timing/timing.json")["offsets"])

        let rs = S.dict(f["recStart"])
        let samples = S.list(rs["samples"]).map { Timing.ClockSample(ctxTime: S.num($0["ctxTime"]), recSec: S.num($0["recSec"])) }
        XCTAssertEqual(Timing.estimateRecorderStartCtx(samples)!, S.num(rs["out"]), accuracy: 1e-12)

        for m in S.list(f["medians"]) { S.near(Timing.median(S.nums(m["in"])), S.num(m["out"])) }

        for d in S.list(f["drumOffsets"]) {
            let i = S.dict(d["in"])
            let got = Timing.computeDrumOffset(.init(songStartSec: S.num(i["songStartSec"]), songCtxStart: S.num(i["songCtxStart"]),
                                                     recStartCtx: S.num(i["recStartCtx"]), latencySec: S.num(i["latencySec"])))
            S.near(got, S.num(d["out"]))
        }

        for s in S.list(f["schedules"]) {
            let got = Timing.scheduleCountIn(now: S.num(s["now"]), leadSec: S.num(s["lead"]), bpm: S.num(s["bpm"]),
                                             countInBeats: Int(S.num(s["beats"])))
            let want = S.dict(s["out"])
            S.near(got.clickTimes, S.nums(want["clickTimes"]))
            S.near(got.songCtxStart, S.num(want["songCtxStart"]))
            S.near(got.beatSec, S.num(want["beatSec"]))
        }

        for t in S.list(f["transport"]) {
            let loop = (t["loop"] as? [String: Any]).map { Timing.LoopRegion(start: S.num($0["start"]), end: S.num($0["end"])) }
            let got = Timing.transportPosition(now: S.num(t["now"]), songCtxStart: S.num(t["songCtxStart"]),
                                               songStartSec: S.num(t["songStartSec"]), loop: loop)
            XCTAssertEqual(got, S.num(t["out"]), accuracy: 1e-12)
        }

        for d in S.list(f["drumStart"]) {
            let got = Timing.drumStartFor(songSec: S.num(d["songSec"]), drumOffsetSec: S.num(d["drumOffsetSec"]))
            let want = S.dict(d["out"])
            S.near(got.delaySec, S.num(want["delaySec"]))
            S.near(got.offsetSec, S.num(want["offsetSec"]))
        }
    }

    func testPeaksMatchFixture() throws {
        let f = S.dict(try S.fixture("timing/timing.json")["peaks"])
        let sig = S.f32(f["signal"])
        for c in S.list(f["cases"]) {
            let got = Timing.windowPeaks(sig, sampleRate: S.num(c["sampleRate"]), startSec: S.num(c["startSec"]),
                                         endSec: S.num(c["endSec"]), columns: Int(S.num(c["columns"])),
                                         offsetSec: S.num(c["offsetSec"]))
            S.near(got.map(Double.init), S.nums(c["out"]))
        }
        let tm = S.dict(f["toMono"])
        XCTAssertEqual(Timing.toMono(S.chans(tm["in"])), S.f32(tm["out"]))
    }

    func testClicksMatchFixture() throws {
        for c in S.list(try S.fixture("timing/timing.json")["clicks"]) {
            let o = S.dict(c["opts"])
            let opts = Timing.ClickOptions(freq: o["freq"].map { S.num($0) } ?? 1000,
                                           durationMs: o["durationMs"].map { S.num($0) } ?? 30,
                                           gain: o["gain"].map { S.num($0) } ?? 0.8)
            let got = Timing.makeClick(sampleRate: S.num(c["sampleRate"]), opts)
            let want = S.f32(c["out"])
            XCTAssertEqual(got.count, want.count)
            XCTAssertLessThanOrEqual(S.maxErr(got, want), 1e-7)
        }
        XCTAssertEqual(Timing.ClickOptions.beat, .init(freq: 1000, durationMs: 30, gain: 0.7))
        XCTAssertEqual(Timing.ClickOptions.accent, .init(freq: 1600, durationMs: 35, gain: 0.9))
    }
}
