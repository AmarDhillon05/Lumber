import Foundation
import XCTest
@testable import LumberCore

/// Rebuilds the fixture script's synthetic signals bit-for-bit (Float storage, Double math).
enum Signals {
    static let sr = 48000.0

    static func build(_ s: JSONValue) -> [Float] {
        let n = { (k: String) in Int(s[k]!.number!) }
        let d = { (k: String) in s[k]!.number! }
        switch s["type"]!.string! {
        case "tone":
            return (0..<n("n")).map { i in Float(d("amp") * sin((2 * Double.pi * d("freq") * Double(i)) / sr)) }
        case "noise":
            return noise(n("n"), seed: UInt32(n("seed")))
        case "diff":
            let x = build(s["of"]!)
            var y = [Float](repeating: 0, count: x.count)
            if x.count > 1 { for i in 1..<x.count { y[i] = Float(0.5 * (Double(x[i]) - Double(x[i - 1]))) } }
            return y
        case "lowpass":
            let x = build(s["of"]!), a = d("a")
            var p = 0.0
            return x.map { v in
                p = a * p + (1 - a) * Double(v)
                return Float(p)
            }
        case "neg":
            return build(s["of"]!).map { -$0 }
        case "hits":
            let count = Int((d("sec") * sr).rounded(.down))
            let nz = noise(count, seed: 7)
            let period = Int((d("every") * sr).rounded(.down))
            let amp = d("amp"), tau = d("tau")
            return (0..<count).map { i in
                let t = Double(i % period) / sr
                return Float(amp * Double(nz[i]) * exp(-t / tau))
            }
        case "zeros":
            return [Float](repeating: 0, count: n("n"))
        case "concat":
            return s["parts"]!.array!.flatMap(build)
        case "pulses":
            let period = n("period"), width = n("width"), amp = Float(d("amp"))
            return (0..<n("n")).map { $0 % period < width ? amp : 0 }
        case "slowSine":
            return (0..<n("n")).map { i in Float(d("amp") * sin(Double(i) / d("div"))) }
        default:
            fatalError("unknown signal")
        }
    }

    static func noise(_ n: Int, seed: UInt32) -> [Float] {
        var st = seed
        return (0..<n).map { _ in
            st = st &* 1_664_525 &+ 1_013_904_223
            return Float(Double(st) / 2_147_483_648 - 1)
        }
    }

    static func tone(_ freq: Double, _ amp: Double, _ n: Int) -> [Float] {
        (0..<n).map { i in Float(amp * sin((2 * Double.pi * freq * Double(i)) / sr)) }
    }
}

func assertDescriptorsClose(_ a: AudioDescriptors, _ b: AudioDescriptors, tol: Double = 1e-6, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
    let pairs: [(String, Double, Double)] = [
        ("durationSec", a.durationSec, b.durationSec), ("rmsDb", a.rmsDb, b.rmsDb), ("peakDb", a.peakDb, b.peakDb),
        ("crestDb", a.crestDb, b.crestDb), ("loudnessLufs", a.loudnessLufs, b.loudnessLufs), ("dynamicRangeDb", a.dynamicRangeDb, b.dynamicRangeDb),
        ("noiseFloorDb", a.noiseFloorDb, b.noiseFloorDb), ("centroidHz", a.centroidHz, b.centroidHz), ("onsetsPerSec", a.onsetsPerSec, b.onsetsPerSec),
        ("decayMs", a.decayMs, b.decayMs),
    ] + Band.allCases.map { ("bands.\($0.rawValue)", a.bands[$0], b.bands[$0]) }
    for (k, x, y) in pairs { XCTAssertClose(x, y, tol, "\(name).\(k)", file: file, line: line) }
    XCTAssertEqual(a.channels, b.channels, name, file: file, line: line)
    XCTAssertClose(a.stereoWidth, b.stereoWidth, tol, "\(name).stereoWidth", file: file, line: line)
}

final class AIAnalyzeTests: XCTestCase {
    func testDescriptorsMatchTS() throws {
        let fx = try Fixture.load("ai/analyze.json")
        for c in try XCTUnwrap(fx["cases"]?.array) {
            let name = c["name"]!.string!
            let chs = c["channels"]!.array!.map(Signals.build)
            for (ch, first) in zip(chs, c["firstSamples"]!.array!) {
                XCTAssertEqual(Array(ch.prefix(4)), first.array!.map { Float($0.number!) }, "\(name) signal")
            }
            var opts = AnalyzeOptions()
            if let o = c["opts"], !o.isNull {
                if let v = o["startSec"]?.number { opts.startSec = v }
                if let v = o["maxSec"]?.number { opts.maxSec = v }
                if let v = o["fftWindows"]?.number { opts.fftWindows = Int(v) }
            }
            let d = AudioAnalysis.analyze(chs, sampleRate: Signals.sr, options: opts)
            let want = try fromJSON(AudioDescriptors.self, c["descriptors"]!)
            assertDescriptorsClose(d, want, name)
            XCTAssertJSONEqual(d.rounded().json, c["rounded"], name)
        }
    }

    // MARK: ports of tests/ai.test.ts (analysis)

    func testSine() {
        let d = AudioAnalysis.analyze([Signals.tone(1000, 0.5, 48000 * 4)], sampleRate: 48000)
        XCTAssertEqual(d.rmsDb, -9.03, accuracy: 0.2)
        XCTAssertEqual(d.peakDb, -6.02, accuracy: 0.1)
        XCTAssertEqual(d.crestDb, 3.01, accuracy: 0.2)
        XCTAssertEqual(d.loudnessLufs, -9.03, accuracy: 0.5)
        XCTAssert(d.bands.mid > -1 && d.bands.air < -30)
        XCTAssertEqual(d.centroidHz, 1000, accuracy: 60)
        XCTAssertNil(d.stereoWidth)
        XCTAssertLessThan(d.onsetsPerSec, 0.5)
    }

    func testStereoWidthAndSilence() {
        let l = Signals.noise(96000, seed: 3), r = Signals.noise(96000, seed: 9)
        XCTAssertEqual(AudioAnalysis.analyze([l, l], sampleRate: 48000).stereoWidth, 0)
        XCTAssertEqual(AudioAnalysis.analyze([l, l.map { -$0 }], sampleRate: 48000).stereoWidth ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(AudioAnalysis.analyze([l, r], sampleRate: 48000).stereoWidth ?? 0, 0.5, accuracy: 0.05)
        let silent = AudioAnalysis.analyze([[Float](repeating: 0, count: 48000)], sampleRate: 48000)
        XCTAssert([silent.rmsDb, silent.peakDb, silent.crestDb, silent.loudnessLufs, silent.centroidHz, silent.decayMs].allSatisfy(\.isFinite))
        XCTAssertEqual(silent.onsetsPerSec, 0)
        XCTAssertLessThanOrEqual(silent.rmsDb, -100)
        XCTAssertEqual(AudioAnalysis.analyze([[]], sampleRate: 48000).durationSec, 0)
        XCTAssertEqual(AudioAnalysis.analyze([], sampleRate: 48000).durationSec, 0)
    }

    func testRoundedStaysSmall() {
        let kit = AudioAnalysis.analyze([Signals.build(["type": "hits", "sec": 8, "every": 0.25, "tau": 0.03, "amp": 0.8])], sampleRate: 48000)
        XCTAssertEqual(kit.onsetsPerSec, 4, accuracy: 0.5)
        XCTAssertEqual(kit.decayMs, 69, accuracy: 25)
        XCTAssertLessThan(kit.rounded().json.jsonString().count, 400)
    }
}
