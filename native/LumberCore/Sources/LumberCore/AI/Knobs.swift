// Knob metadata and validation for the AI mixer. Port of src/ai/knobs.ts.
// The metadata (BLANKET_TERMS, presets, INTENSITY) comes from the generated
// `KnobTable`; it duplicates what the DSP module ports and should be unified
// with it after merge (the AI code only reads keys, labels, categories,
// `bipolar`, descriptions and presets).

import Foundation

/// A full knob state: term key → slider value (−1..1, 0 = neutral).
public typealias KnobValues = [String: Double]

public struct MixKnobInfo: Sendable, Equatable {
    public let key: String
    public let label: String
    public let category: String
    public let bipolar: Bool
    public let description: String
}

public struct MixPreset: Sendable {
    public let id: String
    public let label: String
    public let description: String
    /// Sparse knob map in declaration order.
    public let values: [(String, Double)]
}

public struct KnobRange: Sendable, Equatable {
    public let min: Double
    public let max: Double
}

public enum MixKnobs {
    /// Render-time multiplier for slider values (src/dsp/blanketChain.ts).
    public static let intensity = KnobTable.intensity
    /// Term keys in catalog order (BLANKET_TERM_KEYS).
    public static let keys: [String] = KnobTable.terms.map(\.key)
    public static let info: [String: MixKnobInfo] = Dictionary(uniqueKeysWithValues: KnobTable.terms.map { ($0.key, $0) })
    public static let presets: [MixPreset] = KnobTable.presets
    public static let gainRange = KnobRange(min: 0, max: 1.5)

    // denoise / roominess clamp their spectral-gate amount at slider ≈ .34
    // (INTENSITY = 3); higher values sound identical, so suggestions stop there.
    static let softMax: [String: Double] = ["denoise": 0.35, "roominess": 0.35]

    public static func isKnown(_ key: String) -> Bool { info[key] != nil }

    /// Every term, 0 unless given.
    public static func fillValues(_ sparse: KnobValues = [:]) -> KnobValues {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, sparse[$0] ?? 0) })
    }

    public static func zeroValues() -> KnobValues { fillValues() }

    /// Bipolar terms use −1..1; one-directional terms 0..1 (the knob mirrors negatives).
    public static func range(_ term: String) -> KnobRange {
        KnobRange(min: info[term]?.bipolar == true ? -1 : 0, max: softMax[term] ?? 1)
    }

    /// The value a term actually renders with (one-directional terms use |v|).
    public static func effectiveValue(_ term: String, _ v: Double?) -> Double {
        let x = v.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return info[term]?.bipolar == true ? x : abs(x)
    }

    static func round3(_ x: Double) -> Double { jsRound(x * 1000) / 1000 }
    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, x)) }

    public static func clampKnob(_ term: String, _ v: Double) -> Double {
        let r = range(term)
        return round3(clamp(v, r.min, r.max))
    }

    public static func clampGain(_ g: Double) -> Double { round3(clamp(g, gainRange.min, gainRange.max)) }

    /// Validate an untrusted knob map on top of `base`: unknown keys and
    /// non-numbers are dropped (and listed), numbers are clamped, every term is present.
    public static func sanitizeValues(_ raw: JSONValue?, base: KnobValues) -> (values: KnobValues, dropped: [String]) {
        var values = base
        var dropped: [String] = []
        if let o = raw?.object {
            for (k, v) in o.pairs {
                guard isKnown(k), let n = v.number, n.isFinite else {
                    dropped.append(k)
                    continue
                }
                values[k] = clampKnob(k, n)
            }
        } else if let a = raw?.array {
            // A JS array is an object with index keys: all unknown.
            dropped = a.indices.map(String.init)
        }
        return (values, dropped)
    }

    /// Terms whose value differs between two states (by more than rounding), in catalog order.
    public static func changedTerms(_ a: KnobValues, _ b: KnobValues) -> [String] {
        keys.filter { abs((a[$0] ?? 0) - (b[$0] ?? 0)) > 1e-3 }
    }

    /// Values as a JSON object in catalog order (then any extra keys, sorted).
    public static func json(_ values: KnobValues) -> JSONValue {
        var o = JSONObject()
        for k in keys where values[k] != nil { o[k] = .number(values[k]!) }
        for k in values.keys.sorted() where o[k] == nil { o[k] = .number(values[k]!) }
        return .object(o)
    }
}
