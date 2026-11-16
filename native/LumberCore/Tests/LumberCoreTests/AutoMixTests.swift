// Auto mix on synthetic kits: a "record" drummer (the reference) and the
// user's take of the same part, played a little differently (human timing
// jitter, dropped / extra hats, a darker phone-mic sound, quieter), placed
// at a known wrong offset.

import Foundation
import XCTest
@testable import LumberCore

final class AutoMixTests: XCTestCase {
    let sr = 48_000.0

    enum Hit { case kick, snare, hat }

    struct Rng {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(s >> 11) / Double(1 << 53)
        }
        mutating func noise() -> Float { Float(next() * 2 - 1) }
    }

    /// 120 bpm groove: kick on 1 and 3 (+ some 8th-note pickups), snare on 2
    /// and 4, hats on 8ths. Times in song seconds.
    func pattern(seconds: Double, seed: UInt64 = 7) -> [(Double, Hit)] {
        var rng = Rng(s: seed)
        var hits: [(Double, Hit)] = []
        var t = 0.0
        var beat = 0
        while t < seconds {
            if beat % 2 == 0 { hits.append((t, .kick)) } else { hits.append((t, .snare)) }
            if rng.next() < 0.3 { hits.append((t + 0.25, .kick)) }
            hits.append((t, .hat))
            hits.append((t + 0.25, .hat))
            t += 0.5
            beat += 1
        }
        return hits.filter { $0.0 < seconds }
    }

    /// Renders hits to mono. `dark` = phone-mic-ish: duller, boomier, softer attack.
    func render(_ hits: [(Double, Hit)], seconds: Double, dark: Bool = false, gain: Float = 1, seed: UInt64 = 1) -> [Float] {
        var rng = Rng(s: seed)
        var x = [Float](repeating: 0, count: Int(seconds * sr))
        for (t, kind) in hits {
            let s0 = Int(t * sr)
            let len: Int, amp: Float
            switch kind {
            case .kick: len = Int(0.25 * sr); amp = 0.8
            case .snare: len = Int(0.18 * sr); amp = 0.6
            case .hat: len = Int(0.05 * sr); amp = 0.25
            }
            for k in 0..<len where s0 + k >= 0 && s0 + k < x.count {
                let tt = Double(k) / sr
                var v: Float
                switch kind {
                case .kick:
                    let f = 50 + 90 * exp(-tt * 30)
                    v = Float(sin(2 * .pi * f * tt) * exp(-tt * (dark ? 9 : 14)))
                case .snare:
                    v = Float(exp(-tt * (dark ? 18 : 25))) * (0.7 * rng.noise() + Float(0.5 * sin(2 * .pi * 190 * tt)))
                case .hat:
                    v = Float(exp(-tt * 80)) * rng.noise()
                }
                x[s0 + k] += v * amp
            }
        }
        if dark {
            // One-pole low-pass at ~2.5 kHz, plus a mic noise floor.
            let a = Float(exp(-2 * Double.pi * 2500 / sr))
            var y: Float = 0
            for i in x.indices {
                y = (1 - a) * x[i] + a * y
                x[i] = y + 0.001 * rng.noise()
            }
        }
        return x.map { $0 * gain }
    }

    /// The user's take of `hits` from `takeStart` for `seconds`: ±6 ms human
    /// jitter, 15 % of hats dropped, a few extra ones.
    func humanTake(_ hits: [(Double, Hit)], takeStart: Double, seconds: Double, dark: Bool, gain: Float) -> [Float] {
        var rng = Rng(s: 99)
        var played: [(Double, Hit)] = []
        for (t, k) in hits where t >= takeStart && t < takeStart + seconds {
            if k == .hat && rng.next() < 0.15 { continue }
            let jitter = (rng.next() * 2 - 1) * 0.006
            played.append((t - takeStart + jitter, k))
            if k == .hat && rng.next() < 0.08 { played.append((t - takeStart + 0.125, .hat)) }
        }
        return render(played, seconds: seconds, dark: dark, gain: gain, seed: 5)
    }

    func band(_ seconds: Double) -> [Float] {
        // Bass notes changing every beat + a sustained pad: the non-drum song.
        (0..<Int(seconds * sr)).map { i in
            let t = Double(i) / sr
            let notes = [55.0, 55, 73.4, 65.4]
            let f = notes[Int(t / 0.5) % notes.count]
            let bass = 0.35 * sin(2 * .pi * f * t)
            let pad = 0.08 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.2 * t) + sin(2 * .pi * 329.6 * t))
            return Float(bass + pad)
        }
    }

    // MARK: Align

    func testAlignFindsTheOffsetAgainstTheOriginalDrums() {
        let hits = pattern(seconds: 20)
        let reference = render(hits, seconds: 20)
        let take = humanTake(hits, takeStart: 4, seconds: 12, dark: true, gain: 0.5)
        for error in [0.037, -0.052, 0.0, 0.110, -0.180] {
            // The app thinks the take starts at 4 − error; the right answer is +error.
            guard let r = AutoMix.align(take: [take], reference: [reference], referenceKind: .originalDrums,
                                        sampleRate: sr, drumOffsetSec: 4 - error) else {
                return XCTFail("no result for \(error)")
            }
            XCTAssertEqual(r.deltaSec, error, accuracy: 0.004, "error \(error)")
            XCTAssertTrue(r.isReliable, "confidence \(r.confidence) for \(error)")
        }
    }

    func testAlignAgainstTheFullSongWithoutStems() {
        let hits = pattern(seconds: 20)
        let drums = render(hits, seconds: 20)
        let bed = band(20)
        let song = zip(drums, bed).map { $0 + $1 }
        let take = humanTake(hits, takeStart: 4, seconds: 12, dark: true, gain: 0.5)
        guard let r = AutoMix.align(take: [take], reference: [song], referenceKind: .song,
                                    sampleRate: sr, drumOffsetSec: 4 - 0.045) else { return XCTFail("no result") }
        XCTAssertEqual(r.deltaSec, 0.045, accuracy: 0.006)
        XCTAssertTrue(r.isReliable, "confidence \(r.confidence)")
    }

    func testAlignIsUnsureOnUnrelatedAudio() {
        let take = humanTake(pattern(seconds: 20), takeStart: 4, seconds: 12, dark: true, gain: 0.5)
        var rng = Rng(s: 3)
        let pad = (0..<Int(20 * sr)).map { i in Float(0.2 * sin(2 * .pi * 220 * Double(i) / sr)) + 0.001 * rng.noise() }
        let r = AutoMix.align(take: [take], reference: [pad], referenceKind: .song, sampleRate: sr, drumOffsetSec: 4)
        XCTAssertFalse(r?.isReliable ?? false, "a sine pad has no hits to match: \(String(describing: r))")
    }

    // MARK: Level

    func testLevelMatchesTheOriginalDrumsLoudness() throws {
        let hits = pattern(seconds: 20)
        let original = render(hits, seconds: 20)
        let take = humanTake(hits, takeStart: 4, seconds: 12, dark: false, gain: 0.7)
        let r = try XCTUnwrap(AutoMix.matchLevel(drums: [take], song: [band(20)], originalDrums: [original],
                                                 sampleRate: sr, drumOffsetSec: 4, songGain: 0.8))
        // In the mix: take at drumGain vs the original at songGain.
        let takeDb = r.takeLufs + 20 * log10(r.drumGain)
        let refDb = r.targetLufs + 20 * log10(r.songGain)
        XCTAssertEqual(takeDb, refDb, accuracy: 0.2)
        XCTAssertEqual(r.songGain, 0.8, accuracy: 0.001, "no need to touch the song")
    }

    func testLevelTurnsTheSongDownWhenTheTakeIsTooQuiet() throws {
        let hits = pattern(seconds: 20)
        let original = render(hits, seconds: 20)
        let take = humanTake(hits, takeStart: 4, seconds: 12, dark: false, gain: 0.1)
        let r = try XCTUnwrap(AutoMix.matchLevel(drums: [take], song: [band(20)], originalDrums: [original],
                                                 sampleRate: sr, drumOffsetSec: 4, songGain: 0.8))
        XCTAssertEqual(r.drumGain, AutoMix.maxGain, accuracy: 0.001)
        XCTAssertLessThan(r.songGain, 0.8)
        XCTAssertEqual(r.takeLufs + 20 * log10(r.drumGain), r.targetLufs + 20 * log10(r.songGain), accuracy: 0.3)
    }

    func testLevelWithoutStemsSitsUnderTheSong() throws {
        let hits = pattern(seconds: 20)
        let song = zip(render(hits, seconds: 20), band(20)).map { $0 + $1 }
        let take = humanTake(hits, takeStart: 4, seconds: 12, dark: false, gain: 0.5)
        let r = try XCTUnwrap(AutoMix.matchLevel(drums: [take], song: [song], originalDrums: nil,
                                                 sampleRate: sr, drumOffsetSec: 4, songGain: 0.8))
        let songDb = AutoMix.loudness([song], sampleRate: sr, start: Int(4 * sr), length: Int(12 * sr)) + 20 * log10(r.songGain)
        XCTAssertEqual(r.takeLufs + 20 * log10(r.drumGain), songDb - AutoMix.drumsUnderSongDb, accuracy: 0.3)
    }

    // MARK: Tone

    func testToneMatchBringsADarkTakeCloserToTheOriginal() {
        let hits = pattern(seconds: 20)
        let original = render(hits, seconds: 20)
        let take = humanTake(hits, takeStart: 4, seconds: 12, dark: true, gain: 0.5)
        let r = AutoMix.matchTone(take: [take], target: [original], sampleRate: sr, values: BlanketTerm.zeroValues())
        print("tone mismatch \(r.mismatchBeforeDb) → \(r.mismatchAfterDb) dB, knobs \(r.values.filter { $0.value != 0 })")
        XCTAssertLessThan(r.mismatchAfterDb, r.mismatchBeforeDb * 0.75)
        XCTAssertTrue(r.values.values.allSatisfy { (-1...1).contains($0) })
        let lifted = (r.values[.brightness] ?? 0) + (r.values[.air] ?? 0) + (r.values[.attack] ?? 0)
        XCTAssertGreaterThan(lifted, 0, "a dark take should get brighter")
        for term in BlanketTerm.allCases where !AutoMix.toneKnobs.contains(term) {
            XCTAssertEqual(r.values[term] ?? 0, 0, "\(term) isn't a tone knob")
        }
    }

    // MARK: Master

    func testMasterHitsTheLoudnessTargetUnderTheCeiling() {
        let hits = pattern(seconds: 12)
        for gain: Float in [0.08, 0.4, 1.6] {
            let mix = zip(render(hits, seconds: 12), band(12)).map { ($0 + $1) * gain }
            var channels = [mix, mix]
            AutoMix.master(&channels, sampleRate: sr)
            let lufs = AutoMix.loudness(channels, sampleRate: sr)
            let peak = channels.flatMap { $0 }.map { abs(Double($0)) }.max() ?? 0
            print("master: input ×\(gain) → \(lufs) LUFS, peak \(20 * log10(peak)) dBFS")
            XCTAssertEqual(lufs, -14, accuracy: 1.5, "gain \(gain)")
            XCTAssertLessThanOrEqual(peak, pow(10, -1.0 / 20) + 1e-6)
        }
    }

    func testMixTakeUsesMasterWhenAsked() {
        let hits = pattern(seconds: 8)
        let song = [band(8)]
        let drums = [render(hits, seconds: 6)]
        let quiet = song.map { $0.map { $0 * 0.1 } }
        let out = DSP.mixTake(DSP.MixOptions(song: quiet, drums: drums.map { $0.map { $0 * 0.1 } }, sampleRate: sr,
                                             drumOffsetSec: 1, master: AutoMix.MasterOptions()))
        XCTAssertEqual(AutoMix.loudness(out, sampleRate: sr), -14, accuracy: 1.5)
        let plain = DSP.mixTake(DSP.MixOptions(song: quiet, drums: drums.map { $0.map { $0 * 0.1 } }, sampleRate: sr,
                                               drumOffsetSec: 1))
        XCTAssertLessThan(AutoMix.loudness(plain, sampleRate: sr), -20, "without master the mix stays quiet")
    }

    // MARK: All steps

    func testRunAlignsThenMatchesToneThenLevel() {
        let hits = pattern(seconds: 20)
        let original = render(hits, seconds: 20)
        let take = humanTake(hits, takeStart: 4, seconds: 12, dark: true, gain: 0.3)
        let input = AutoMix.Input(take: [take], song: [band(20)], originalDrums: [original], sampleRate: sr,
                                  drumOffsetSec: 4 - 0.06, values: BlanketTerm.zeroValues(), songGain: 0.8, drumGain: 1)
        let out = AutoMix.run(input, steps: Set(AutoMix.Step.allCases))
        print(out.notes.joined(separator: "\n"))
        XCTAssertEqual(out.appliedDeltaSec, 0.06, accuracy: 0.005)
        XCTAssertNotNil(out.tone)
        XCTAssertLessThan(out.tone?.mismatchAfterDb ?? 99, out.tone?.mismatchBeforeDb ?? 0)
        let l = try? XCTUnwrap(out.level)
        XCTAssertEqual((l?.takeLufs ?? 0) + 20 * log10(out.drumGain), (l?.targetLufs ?? 0) + 20 * log10(out.songGain), accuracy: 0.3)
        XCTAssertEqual(out.notes.count, 3)
    }

    func testRunWithoutStemsSkipsToneAndSaysWhy() {
        let hits = pattern(seconds: 20)
        let song = zip(render(hits, seconds: 20), band(20)).map { $0 + $1 }
        let take = humanTake(hits, takeStart: 4, seconds: 12, dark: true, gain: 0.3)
        let input = AutoMix.Input(take: [take], song: [song], originalDrums: nil, sampleRate: sr,
                                  drumOffsetSec: 4, values: BlanketTerm.zeroValues(), songGain: 0.8, drumGain: 1)
        let out = AutoMix.run(input, steps: [.tone, .level])
        XCTAssertNil(out.tone)
        XCTAssertNil(out.align)
        XCTAssertNotNil(out.level)
        XCTAssertTrue(out.notes.contains { $0.contains("Remove original drums") })
    }
}
