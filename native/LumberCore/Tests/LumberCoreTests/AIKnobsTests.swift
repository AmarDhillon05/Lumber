import Foundation
import XCTest
@testable import LumberCore

func knobValues(_ v: JSONValue?) -> KnobValues {
    var out: KnobValues = [:]
    for (k, x) in v?.object?.pairs ?? [] { out[k] = x.number }
    return out
}

final class AIKnobsTests: XCTestCase {
    func testKnobsMatchTS() throws {
        let fx = try Fixture.load("ai/knobs.json")
        XCTAssertEqual(MixKnobs.keys, fx["keys"]!.array!.map { $0.string! })
        for r in fx["ranges"]!.array! {
            XCTAssertEqual(MixKnobs.range(r["key"]!.string!), KnobRange(min: r["min"]!.number!, max: r["max"]!.number!))
        }
        for c in fx["clamp"]!.array! {
            XCTAssertEqual(MixKnobs.clampKnob(c["key"]!.string!, c["input"]!.number!), c["expected"]!.number!, c.jsonString())
        }
        for c in fx["effective"]!.array! {
            XCTAssertEqual(MixKnobs.effectiveValue(c["key"]!.string!, c["input"]!.number!), c["expected"]!.number!)
        }
        for c in fx["gain"]!.array! { XCTAssertEqual(MixKnobs.clampGain(c["input"]!.number!), c["expected"]!.number!) }
        let base = knobValues(fx["base"])
        for c in fx["sanitize"]!.array! {
            let r = MixKnobs.sanitizeValues(c["input"], base: base)
            XCTAssertEqual(r.values, knobValues(c["values"]), c["input"]!.jsonString())
            XCTAssertEqual(r.dropped, c["dropped"]!.array!.map { $0.string! }, c["input"]!.jsonString())
        }
        let ch = fx["changed"]!
        XCTAssertEqual(MixKnobs.changedTerms(knobValues(ch["a"]), knobValues(ch["b"])), ch["expected"]!.array!.map { $0.string! })
    }

    func testPortedKnobChecks() {
        XCTAssertEqual(MixKnobs.range("brightness"), KnobRange(min: -1, max: 1))
        XCTAssertEqual(MixKnobs.range("punch"), KnobRange(min: 0, max: 1))
        XCTAssertEqual(MixKnobs.range("denoise").max, 0.35)
        XCTAssertEqual(MixKnobs.range("roominess").max, 0.35)
        XCTAssertEqual(MixKnobs.clampKnob("punch", 3), 1)
        XCTAssertEqual(MixKnobs.clampKnob("punch", -0.5), 0)
        XCTAssertEqual(MixKnobs.clampKnob("air", -4), -1)
        XCTAssert(MixKnobs.keys.allSatisfy { (MixKnobs.range($0).min < 0) == MixKnobs.info[$0]!.bipolar })
        XCTAssertEqual(MixKnobs.intensity, 3)
        XCTAssertEqual(MixKnobs.presets.map(\.id), ["warm", "bright", "loud", "tight", "roomy", "phone"])
    }
}
