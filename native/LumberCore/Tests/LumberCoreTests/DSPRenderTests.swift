// Offline chain rendering vs Fixtures/dsp/render.json. Those references come
// from the real src/dsp/render.ts running on scripts/native/webAudioRef.ts (a
// Web Audio spec implementation standing in for react-native-audio-api), with
// Math.random swapped for the same seeded LCG as DSP.makeImpulseResponse.
// Plus analytic sanity checks of the Web Audio biquad formulas.

import Foundation
import XCTest
@testable import LumberCore

final class DSPRenderTests: XCTestCase {
    typealias S = DSPTestSupport

    func testBiquadsMatchFixture() throws {
        let f = try S.fixture("dsp/render.json")
        let sr = S.num(f["sampleRate"])
        let mono = [S.chans(f["input"])[0]]
        for b in S.list(f["biquads"]) {
            let spec = try JSONDecoder().decode(EffectSpec.self, from: JSONSerialization.data(withJSONObject: b["spec"]!))
            guard case .biquad(let bs) = spec else { return XCTFail() }
            let c = BiquadCoefficients.webAudio(kind: bs.kind, frequency: bs.frequency, q: bs.q ?? 1,
                                                gainDb: bs.gainDb ?? 0, sampleRate: sr)
            let w = S.dict(b["coeffs"])
            for (got, key) in [(c.b0, "b0"), (c.b1, "b1"), (c.b2, "b2"), (c.a1, "a1"), (c.a2, "a2")] {
                XCTAssertEqual(got, S.num(w[key]), accuracy: 1e-12, "\(bs.kind) \(bs.frequency) \(key)")
            }
            let out = DSP.renderChain(mono, sampleRate: sr, chain: [spec])
            S.assertClose(out, [S.f32(b["out"])], tol: 1e-6, "\(bs.kind) \(bs.frequency)")
        }
    }

    func testImpulseResponseMatchesFixture() throws {
        let f = try S.fixture("dsp/render.json")
        let sr = S.num(f["sampleRate"])
        let imp = S.dict(f["impulse"])
        let ir = DSP.makeImpulseResponse(sampleRate: sr, roomSize: S.num(imp["roomSize"]), damping: S.num(imp["damping"]),
                                         seed: UInt32(S.num(f["reverbSeed"])))
        XCTAssertEqual(ir.count, 2)
        XCTAssertEqual(ir[0].count, Int(S.num(imp["length"])))
        let head = S.chans(imp["head"])
        S.assertClose([Array(ir[0].prefix(512)), Array(ir[1].prefix(512))], head, tol: 1e-7, "IR head")
        XCTAssertEqual(DSP.convolverNormalizationScale(ir, sampleRate: sr), S.num(imp["normalizationScale"]),
                       accuracy: 1e-9 * S.num(imp["normalizationScale"]))
    }

    func testRendersMatchFixture() throws {
        let f = try S.fixture("dsp/render.json")
        let sr = S.num(f["sampleRate"])
        let seed = UInt32(S.num(f["reverbSeed"]))
        let input = S.chans(f["input"])
        for r in S.list(f["renders"]) {
            let name = r["name"] as! String
            let chain = try JSONDecoder().decode([EffectSpec].self, from: JSONSerialization.data(withJSONObject: r["chain"]!))
            let src = (r["stereo"] as! Bool) ? input : [input[0]]
            let out = DSP.renderChain(src, sampleRate: sr, chain: chain, reverbSeed: seed)
            S.assertClose(out, S.chans(r["out"]), tol: 1e-5, name)
        }
    }

    func testRenderBlanketPassThroughAndPreset() throws {
        let f = try S.fixture("dsp/render.json")
        let sr = S.num(f["sampleRate"])
        let input = S.chans(f["input"])
        XCTAssertEqual(DSP.renderBlanket(input, sampleRate: sr, values: [:]), input)
        let warm = DrumPreset.preset(id: "warm")!
        let want = S.list(f["renders"]).first { ($0["name"] as! String) == "preset warm" }!
        S.assertClose(DSP.renderBlanket(input, sampleRate: sr, values: warm.values), S.chans(want["out"]),
                      tol: 1e-5, "renderBlanket warm")
        let buf = DSP.renderChain(PCMBuffer(channels: input, sampleRate: sr), chain: BlanketChain.build(warm.values))
        XCTAssertEqual(buf.sampleRate, sr)
        XCTAssertEqual(buf.frameCount, input[0].count)
    }

    // MARK: Analytic checks of the Web Audio formulas

    func testBiquadResponses() {
        let sr = 48000.0
        func mag(_ k: BiquadKind, _ f0: Double, q: Double = 1, g: Double = 0, at f: Double) -> Double {
            20 * log10(BiquadCoefficients.webAudio(kind: k, frequency: f0, q: q, gainDb: g, sampleRate: sr)
                .magnitude(at: f, sampleRate: sr))
        }
        // Peaking hits its gain at the centre; shelves reach full gain far into the shelf.
        XCTAssertEqual(mag(.peaking, 1000, q: 1.2, g: 6, at: 1000), 6, accuracy: 0.01)
        XCTAssertEqual(mag(.lowshelf, 200, g: -9, at: 10), -9, accuracy: 0.05)
        XCTAssertEqual(mag(.highshelf, 2000, g: 4, at: 20000), 4, accuracy: 0.1)
        XCTAssertEqual(mag(.highshelf, 2000, g: 4, at: 2000), 2, accuracy: 0.01) // half gain at f0
        // Lowpass Q is in dB: at the cutoff the response equals Q dB.
        XCTAssertEqual(mag(.lowpass, 1000, q: 3, at: 1000), 3, accuracy: 0.05)
        XCTAssertEqual(mag(.lowpass, 1000, q: 0, at: 10), 0, accuracy: 0.01)
        XCTAssertEqual(mag(.highpass, 1000, q: 0, at: 1000), 0, accuracy: 0.05)
        // Notch kills its centre, bandpass passes it at unity.
        XCTAssertLessThan(mag(.notch, 3000, q: 30, at: 3000), -100)
        XCTAssertEqual(mag(.bandpass, 3000, q: 2, at: 3000), 0, accuracy: 0.01)
        // Above Nyquist: lowpass passes, highpass silences.
        XCTAssertEqual(BiquadCoefficients.webAudio(kind: .lowpass, frequency: 30000, sampleRate: sr), .identity)
        XCTAssertEqual(BiquadCoefficients.webAudio(kind: .highpass, frequency: 30000, sampleRate: sr).b0, 0)
    }

    func testReverbChannelHandling() {
        let sr = 8000.0
        let x = S.tone(300, 0.5, 2000, sr)
        let spec = ReverbSpec(roomSize: 0.1, damping: 0.5, wetLevel: 0.5, dryLevel: 1)
        let mono = DSP.reverb([x], sampleRate: sr, spec)
        XCTAssertEqual(mono.count, 1)
        XCTAssertEqual(mono[0].count, x.count)
        let stereo = DSP.reverb([x, x], sampleRate: sr, spec)
        // Mono = ½(L+R) of the stereo render (destination down-mix).
        let avg = zip(stereo[0], stereo[1]).map { Float(0.5 * (Double($0) + Double($1))) }
        XCTAssertLessThan(S.maxErr(mono[0], avg), 1e-6)
        XCTAssertNotEqual(stereo[0], stereo[1])
        // Dry only when wet = 0.
        let dry = DSP.reverb([x], sampleRate: sr, ReverbSpec(roomSize: 0.1, damping: 0.5, wetLevel: 0, dryLevel: 1))
        XCTAssertEqual(dry[0], x)
    }

    func testFFTConvolutionMatchesDirect() {
        var rng = S.TestRNG(4)
        let x = (0..<3000).map { _ in Float(rng.next() * 2 - 1) }
        let h = (0..<700).map { _ in rng.next() - 0.5 }
        let fast = DSP.convolveTruncated(x, h)
        var maxe = 0.0
        for i in stride(from: 0, to: x.count, by: 7) {
            var acc = 0.0
            for k in 0...min(i, h.count - 1) { acc += Double(x[i - k]) * h[k] }
            maxe = max(maxe, abs(acc - fast[i]))
        }
        XCTAssertLessThan(maxe, 1e-10)
    }
}
