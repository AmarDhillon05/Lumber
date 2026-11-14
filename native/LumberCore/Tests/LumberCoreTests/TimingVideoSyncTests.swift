// Port of tests/videoSync.test.ts, plus Fixtures/timing/videoSync.json.

import Foundation
import XCTest
@testable import LumberCore

final class TimingVideoSyncTests: XCTestCase {
    typealias S = DSPTestSupport

    // MARK: Ported behaviour tests

    func testWallToCtxMapping() {
        let q = 256.0 / 48000
        var pairs = (0..<200).map { i -> Timing.WallCtxPair in
            let wall = 200_000 + Double(i) * 25.3
            return .init(wallMs: wall, ctxSec: ((wall / 1000 - 100) / q).rounded(.down) * q)
        }
        pairs.append(.init(wallMs: 1, ctxSec: 0))
        let off = Timing.wallToCtxOffset(pairs)!
        XCTAssertLessThan(abs(off + 100), q)
        XCTAssertNil(Timing.wallToCtxOffset([]))
    }

    func testStartEstimateFromProgress() {
        var samples: [Timing.ProgressSample] = []
        for i in 1...100 {
            let delay = Double((i * 7) % 20) + 1
            let wall = 10_000 + Double(i) * 100 + delay
            let real = (wall - delay - 10_000) / 1000
            samples.append(.init(wallMs: wall, durationSec: (real * 30).rounded(.down) / 30))
        }
        samples.append(.init(wallMs: 10_050, durationSec: 0))
        let est = Timing.estimateVideoStartWall(samples)!
        XCTAssertTrue(est >= 10_000 && est - 10_000 < 25, "\(est)")
        XCTAssertNil(Timing.estimateVideoStartWall([]))
        XCTAssertEqual(Timing.quantile([3, 1, 2], 0.5), 2, accuracy: 1e-6)
        XCTAssertEqual(Timing.quantile([0, 10], 0.25), 2.5, accuracy: 1e-6)
    }

    func testOffsetOnSongTimeline() {
        XCTAssertEqual(Timing.outputLatencySec(roundTripMs: 108), 0.1, accuracy: 1e-6)
        XCTAssertEqual(Timing.outputLatencySec(roundTripMs: 2), 0)
        let off = Timing.computeVideoOffset(.init(songStartSec: 30, songCtxStart: 12, videoStartCtx: 11.4, outputLatencySec: 0.1))
        XCTAssertEqual(off + 1.7, 31, accuracy: 1e-6)
    }

    func testFullTiming() {
        let pairs = (0..<50).map { i -> Timing.WallCtxPair in
            let wall = 110_000 + Double(i) * 25
            return .init(wallMs: wall, ctxSec: wall / 1000 - 100)
        }
        let progress = (0..<30).map { Timing.ProgressSample(wallMs: 111_400 + Double($0 + 1) * 100, durationSec: Double($0 + 1) * 0.1) }
        func run(_ p: [Timing.WallCtxPair], _ pr: [Timing.ProgressSample], call: Double = 111_000) -> Timing.VideoTiming? {
            Timing.videoTiming(.init(pairs: p, progress: pr, recordCallWallMs: call, songStartSec: 30, songCtxStart: 12, latencyMs: 108))
        }
        let t = run(pairs, progress)!
        XCTAssertEqual(t.source, .progress)
        XCTAssertEqual(t.offsetSec, 30 + (11.4 - 12) - 0.1, accuracy: 1e-6)
        XCTAssertEqual(t.durationSec, 3, accuracy: 1e-6)
        let noProg = run(pairs, [])!
        XCTAssertEqual(noProg.source, .call)
        XCTAssertEqual(noProg.offsetSec, 30 + (11.0 - 12) - 0.1, accuracy: 1e-6)
        XCTAssertEqual(run(pairs, [.init(wallMs: 110_100, durationSec: 1)])!.source, .call)
        XCTAssertNil(run([], progress, call: 0))
        XCTAssertEqual(Timing.finalVideoOffsetSec(10, nudgeMs: 250), 10.25, accuracy: 1e-6)
        XCTAssertEqual(Timing.finalVideoOffsetSec(10, nudgeMs: nil), 10, accuracy: 1e-6)
    }

    func testExportPlan() {
        let p = Timing.planVideoExport(videoOffsetSec: 28.5, videoDurationSec: 40, mixDurationSec: 200)!
        XCTAssertEqual(p.audioStartSec, 28.5, accuracy: 1e-6)
        XCTAssertEqual(p.videoStartSec, 0, accuracy: 1e-6)
        XCTAssertEqual(p.durationSec, 40, accuracy: 1e-6)
        let early = Timing.planVideoExport(videoOffsetSec: -0.4, videoDurationSec: 10, mixDurationSec: 200)!
        XCTAssertEqual(early.audioStartSec, 0, accuracy: 1e-6)
        XCTAssertEqual(early.videoStartSec, 0.4, accuracy: 1e-6)
        XCTAssertEqual(early.durationSec, 9.6, accuracy: 1e-6)
        let late = Timing.planVideoExport(videoOffsetSec: 195, videoDurationSec: 10, mixDurationSec: 200)!
        XCTAssertEqual(late.durationSec, 5, accuracy: 1e-6)
        XCTAssertNil(Timing.planVideoExport(videoOffsetSec: 300, videoDurationSec: 10, mixDurationSec: 200))
        XCTAssertEqual(Timing.sampleRange(p, sampleRate: 48000, totalSamples: 200 * 48000), 1_368_000..<(1_368_000 + 40 * 48000))
        let r = Timing.sampleRange(late, sampleRate: 48000, totalSamples: 200 * 48000)
        XCTAssertEqual(r.upperBound, 200 * 48000)
        XCTAssertEqual(r.lowerBound, 195 * 48000)
    }

    func testPreviewStart() {
        let a = Timing.videoStartFor(songSec: 30, videoOffsetSec: 28, videoDurationSec: 10)!
        XCTAssertEqual(a.delaySec, 0); XCTAssertEqual(a.videoSec, 2)
        let b = Timing.videoStartFor(songSec: 27, videoOffsetSec: 28, videoDurationSec: 10)!
        XCTAssertEqual(b.delaySec, 1); XCTAssertEqual(b.videoSec, 0)
        XCTAssertNil(Timing.videoStartFor(songSec: 40, videoOffsetSec: 28, videoDurationSec: 10))
    }

    // MARK: Golden fixture

    func pairs(_ v: Any?) -> [Timing.WallCtxPair] { S.list(v).map { .init(wallMs: S.num($0["wallMs"]), ctxSec: S.num($0["ctxSec"])) } }
    func progress(_ v: Any?) -> [Timing.ProgressSample] {
        S.list(v).map { .init(wallMs: S.num($0["wallMs"]), durationSec: S.num($0["durationSec"])) }
    }

    func testMatchesFixture() throws {
        let f = try S.fixture("timing/videoSync.json")

        let w = S.dict(f["wallToCtx"])
        S.near(Timing.wallToCtxOffset(pairs(w["pairs"]))!, S.num(w["out"]))

        for q in S.list(f["quantiles"]) {
            S.near(Timing.quantile(S.nums(q["values"]), S.num(q["q"])), S.num(q["out"]))
        }

        let sw = S.dict(f["startWall"])
        S.near(Timing.estimateVideoStartWall(progress(sw["progress"]))!, S.num(sw["out"]))
        S.near(Timing.estimateVideoStartWall(progress(sw["progress"]), q: 0.25)!, S.num(sw["out25"]))

        for o in S.list(f["outputLatency"]) {
            S.near(Timing.outputLatencySec(roundTripMs: S.num(o["ms"])), S.num(o["out"]))
        }

        for t in S.list(f["timings"]) {
            let i = S.dict(t["in"])
            let got = Timing.videoTiming(.init(pairs: pairs(i["pairs"]), progress: progress(i["progress"]),
                                               recordCallWallMs: S.num(i["recordCallWallMs"]), songStartSec: S.num(i["songStartSec"]),
                                               songCtxStart: S.num(i["songCtxStart"]), latencyMs: S.num(i["latencyMs"])))
            guard let want = t["out"] as? [String: Any] else { XCTAssertNil(got); continue }
            S.near(got?.offsetSec, S.num(want["offsetSec"]))
            XCTAssertEqual(got?.source.rawValue, want["source"] as? String)
            S.near(got?.durationSec, S.num(want["durationSec"]))
        }

        for p in S.list(f["plans"]) {
            let mix = S.num(p["mixDurationSec"])
            let got = Timing.planVideoExport(videoOffsetSec: S.num(p["videoOffsetSec"]), videoDurationSec: S.num(p["videoDurationSec"]),
                                             mixDurationSec: mix)
            guard let want = p["out"] as? [String: Any] else { XCTAssertNil(got); continue }
            S.near(got?.audioStartSec, S.num(want["audioStartSec"]))
            S.near(got?.videoStartSec, S.num(want["videoStartSec"]))
            S.near(got?.durationSec, S.num(want["durationSec"]))
            let range = S.nums(p["range"]).map { Int($0) }
            let r = Timing.sampleRange(got!, sampleRate: 44100, totalSamples: Int((mix * 44100).rounded()))
            XCTAssertEqual([r.lowerBound, r.upperBound], range)
        }

        for s in S.list(f["startFor"]) {
            let got = Timing.videoStartFor(songSec: S.num(s["songSec"]), videoOffsetSec: S.num(s["videoOffsetSec"]),
                                           videoDurationSec: S.num(s["videoDurationSec"]))
            guard let want = s["out"] as? [String: Any] else { XCTAssertNil(got); continue }
            S.near(got?.delaySec, S.num(want["delaySec"]))
            S.near(got?.videoSec, S.num(want["videoSec"]))
        }
    }
}
