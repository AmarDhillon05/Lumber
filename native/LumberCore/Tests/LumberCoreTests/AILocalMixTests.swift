import Foundation
import XCTest
@testable import LumberCore

final class AILocalMixTests: XCTestCase {
    func testInterpreterMatchesTS() throws {
        let fx = try Fixture.load("ai/localmix.json")
        var analyses: [String: MixAnalysis?] = [:]
        for (k, v) in fx["analyses"]!.object!.pairs { analyses[k] = v.isNull ? nil : try fromJSON(MixAnalysis.self, v) }
        var starts: [String: KnobValues] = [:]
        for (k, v) in fx["starts"]!.object!.pairs { starts[k] = MixKnobs.fillValues(knobValues(v)) }
        var failures = 0
        let cases = fx["cases"]!.array!
        XCTAssertGreaterThan(cases.count, 400)
        for c in cases {
            let prompt = c["prompt"]!.string!
            let r = LocalMix.interpret(
                LocalMixInput(
                    prompt: prompt, values: starts[c["start"]!.string!]!, songGain: c["songGain"]!.number!, drumGain: c["drumGain"]!.number!,
                    analysis: analyses[c["analysis"]!.string!]!))
            let want = c["expected"]!
            let ctx = "\(prompt) [\(c["start"]!.string!), \(c["analysis"]!.string!)]"
            let ok = r.values == knobValues(want["values"]) && r.matched == want["matched"]!.array!.map { $0.string! }
                && r.explanation == want["explanation"]?.string && r.songGain == want["songGain"]?.number && r.drumGain == want["drumGain"]?.number
            if !ok {
                failures += 1
                if failures <= 10 {
                    XCTFail("\(ctx)\n got: \(MixKnobs.json(r.values).jsonString()) \(r.matched) \(r.explanation) \(String(describing: r.songGain)) \(String(describing: r.drumGain))\n want: \(want.jsonString())")
                }
            }
        }
        XCTAssertEqual(failures, 0)
    }

    // MARK: ports of tests/ai.test.ts (offline interpreter)

    func lm(_ p: String, _ values: KnobValues = MixKnobs.zeroValues(), _ a: MixAnalysis? = nil, song: Double = 0.8, drums: Double = 1) -> LocalMixResult {
        LocalMix.interpret(LocalMixInput(prompt: p, values: values, songGain: song, drumGain: drums, analysis: a))
    }

    func testVocabularyAndBasics() {
        for w in ["warm", "dark", "bright", "harsh", "punchy", "tight", "dry", "roomy", "big", "boomy", "muddy", "boxy", "thin", "crisp", "compressed", "natural", "vintage", "lofi", "modern"] {
            XCTAssert(LocalMix.vocabulary.contains(w), w)
        }
        let warm = lm("warmer")
        XCTAssert(warm.values["warmth"]! > 0 && warm.values["brightness"]! < 0 && warm.matched.contains("warm"))
        XCTAssert(lm("less bright").values["brightness"]! < 0)
        XCTAssertEqual(lm("less boomy").values, lm("it sounds boomy").values)
        XCTAssert(lm("not bright enough").values["brightness"]! > 0)
        let rock = lm("punchy and dry like a 90s rock record")
        XCTAssert(rock.values["punch"]! > 0.3 && rock.values["depth"] == 0 && rock.values["roominess"]! > 0)
        XCTAssertEqual(lm("less boomy, more room").matched, ["-boomy", "roomy"])
        XCTAssertEqual(lm("clean up the mud").matched, ["-muddy"])
        XCTAssert(lm("80's").matched.contains("80s"))
        XCTAssert(lm("a bit warmer").values["warmth"]! < lm("warmer").values["warmth"]! && lm("warmer").values["warmth"]! < lm("way warmer").values["warmth"]!)
        XCTAssert(MixKnobs.keys.allSatisfy { lm("reset", MixKnobs.fillValues(["warmth": 0.8, "punch": 0.8])).values[$0] == 0 })
        XCTAssert(lm("drums louder").drumGain! > 1)
        XCTAssertNil(lm("drums louder").songGain)
        XCTAssertEqual(lm("extremely louder drums", drums: 1.45).drumGain, 1.5)
        XCTAssertNil(lm("lower the boom").drumGain)
        XCTAssertEqual(MixKnobs.changedTerms(MixKnobs.zeroValues(), lm("the song is too loud").values), [])
        let none = lm("asdf qwerty")
        XCTAssert(none.matched.isEmpty && none.values == MixKnobs.zeroValues() && none.explanation.contains("didn"))
        XCTAssert(warm.explanation.hasPrefix("Offline interpreter:"))
        XCTAssert(lm("extremely noisy, so much hiss").values["denoise"]! <= 0.35)
    }
}
