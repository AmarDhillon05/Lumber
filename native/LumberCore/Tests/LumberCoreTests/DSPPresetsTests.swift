// Port of tests/presets.test.ts, plus Fixtures/dsp/blanket.json: every term's
// metadata, the render order, every preset's exact values, and the specs each
// knob setting expands into must equal the TypeScript.

import Foundation
import XCTest
@testable import LumberCore

final class DSPPresetsTests: XCTestCase {
    typealias S = DSPTestSupport

    // MARK: Ported behaviour tests

    func testRenderOrder() {
        XCTAssertTrue(BlanketChain.renderOrderIsComplete)
        XCTAssertEqual(BlanketChain.renderOrder.last, .naturalness)
    }

    func testPresetsBasics() {
        XCTAssertEqual(DrumPreset.all.count, 6)
        XCTAssertEqual(Set(DrumPreset.all.map(\.id)).count, 6)
        for p in DrumPreset.all {
            for (term, v) in p.values {
                XCTAssertLessThanOrEqual(v, 1)
                XCTAssertGreaterThanOrEqual(v, term.info.bipolar ? -1 : 0, "\(p.id).\(term)")
            }
        }
        XCTAssertEqual(DrumPreset.preset(id: "warm")?.label, "Warm")
        XCTAssertNil(DrumPreset.preset(id: "nope"))

        let full = DrumPreset.all[0].fullValues
        XCTAssertEqual(full.count, BlanketTerm.allCases.count)
        XCTAssertEqual(full[.warmth], 0.5)
        XCTAssertEqual(full[.air], 0)
        XCTAssertEqual(DrumPreset.fill([.air: 0.2])[.punch], 0)
    }

    func testChainBuilding() {
        XCTAssertTrue(BlanketChain.build(BlanketTerm.zeroValues()).isEmpty)
        XCTAssertTrue(BlanketChain.build([:]).isEmpty)

        let kinds = BlanketChain.build([.naturalness: 1, .volume: 0.5, .highPassRumble: 0.5]).map(\.kind)
        XCTAssertEqual(kinds.first, "highpass")
        XCTAssertEqual(kinds[kinds.count - 2], "gain")
        XCTAssertEqual(kinds.last, "compressor")

        guard case .biquad(let kick) = BlanketChain.build([.kickPresence: 0.5])[0] else { return XCTFail() }
        XCTAssertEqual(kick.kind, .peaking)
        XCTAssertEqual(kick.gainDb!, 0.5 * BlanketChain.intensity * 3, accuracy: 1e-9)

        guard case .biquad(let bright) = BlanketChain.build([.brightness: -0.4])[0] else { return XCTFail() }
        XCTAssertEqual(bright.kind, .highshelf)
        XCTAssertLessThan(bright.gainDb!, 0)

        guard case .compressor(let comp) = BlanketChain.build([.dynamicRange: -0.5])[0] else { return XCTFail() }
        XCTAssertGreaterThan(comp.ratio, 1)

        XCTAssertTrue(DrumPreset.all.allSatisfy { !BlanketChain.build($0.values).isEmpty })
        XCTAssertTrue(BlanketChain.build([.punch: .nan, .air: .infinity]).isEmpty)
    }

    func testEffectSpecCodableRoundTrip() throws {
        let specs = BlanketChain.build(Dictionary(uniqueKeysWithValues: BlanketTerm.allCases.map { ($0, 0.7) }))
        let data = try JSONEncoder().encode(specs)
        XCTAssertEqual(try JSONDecoder().decode([EffectSpec].self, from: data), specs)
    }

    // MARK: Golden fixture

    private func values(_ v: Any?) -> BlanketValues {
        var out = BlanketValues()
        for (k, x) in S.dict(v) { out[BlanketTerm(rawValue: k)!] = S.num(x) }
        return out
    }

    private func specs(_ v: Any?) throws -> [EffectSpec] {
        try JSONDecoder().decode([EffectSpec].self, from: JSONSerialization.data(withJSONObject: v!))
    }

    private func assertSpecsEqual(_ got: [EffectSpec], _ want: [EffectSpec], _ msg: String) throws {
        // Exact, field by field: JSON numbers round-trip doubles exactly.
        XCTAssertEqual(got, want, msg)
        // ...and the encoded JSON shape decodes back to the same thing.
        XCTAssertEqual(try JSONDecoder().decode([EffectSpec].self, from: JSONEncoder().encode(got)), want, msg)
    }

    func testTermsMatchFixture() throws {
        let f = try S.fixture("dsp/blanket.json")
        XCTAssertEqual(S.num(f["intensity"]), BlanketChain.intensity)
        XCTAssertEqual(f["keys"] as! [String], BlanketTerm.allCases.map(\.rawValue))
        XCTAssertEqual(f["renderOrder"] as! [String], BlanketChain.renderOrder.map(\.rawValue))
        XCTAssertEqual(f["categoryOrder"] as! [String], BlanketCategory.order.map(\.rawValue))
        for t in S.list(f["terms"]) {
            let info = BlanketTerm(rawValue: t["key"] as! String)!.info
            XCTAssertEqual(info.label, t["label"] as? String)
            XCTAssertEqual(info.category.rawValue, t["category"] as? String)
            XCTAssertEqual(info.bipolar, t["bipolar"] as? Bool)
            XCTAssertEqual(info.description, t["description"] as? String)
        }
    }

    func testPresetsMatchFixture() throws {
        let f = try S.fixture("dsp/blanket.json")
        let want = S.list(f["presets"])
        XCTAssertEqual(want.map { $0["id"] as! String }, DrumPreset.all.map(\.id))
        for (p, w) in zip(DrumPreset.all, want) {
            XCTAssertEqual(p.label, w["label"] as? String)
            XCTAssertEqual(p.description, w["description"] as? String)
            XCTAssertEqual(p.values, values(w["values"]), p.id)
        }
    }

    func testChainBuildsMatchFixture() throws {
        let f = try S.fixture("dsp/blanket.json")
        for b in S.list(f["builds"]) {
            let v = values(b["values"])
            let intensity = b["intensity"].map { S.num($0) } ?? BlanketChain.intensity
            try assertSpecsEqual(BlanketChain.build(v, intensity: intensity), specs(b["chain"]), "\(v)")
        }
    }

    func testPrimitiveBuildersMatchFixture() throws {
        let f = try S.fixture("dsp/blanket.json")
        var c = EffectChain()
        c.highPass(55, order: 2); c.highPass(60, order: 6); c.lowPass(9000, order: 8); c.lowPass(5000, order: 3)
        c.bandPass(300, 3000); c.notch(1234); c.notch(500, q: 4)
        c.peakEQ(1000, gainDb: -3, q: 2); c.lowShelf(120, gainDb: 4); c.highShelf(9000, gainDb: -2); c.gain(-6)
        try assertSpecsEqual(c.specs, specs(f["primitives"]), "primitives")
    }
}
