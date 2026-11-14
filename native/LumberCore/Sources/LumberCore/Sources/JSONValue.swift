// An order-preserving JSON value with JavaScript-compatible parsing and
// serialisation. The TypeScript originals walk JSON objects in key order
// (YouTube search results) and build request bodies with `JSON.stringify`;
// Foundation's JSONSerialization neither keeps key order nor formats numbers
// and escapes the way JS does, so the ports use this instead.

import Foundation

public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// A JSON object that remembers key insertion order (like a JS object with
/// string keys). Equality ignores order.
public struct JSONObject: Sendable, Equatable {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var pairs: [(String, JSONValue)] { keys.map { ($0, storage[$0]!) } }
    public var count: Int { keys.count }

    public static func == (a: JSONObject, b: JSONObject) -> Bool { a.storage == b.storage }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Accessors (optional chaining like `json?.a?.[0]`)

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// JavaScript truthiness.
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return !(n == 0 || n.isNaN)
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }
}

extension Optional where Wrapped == JSONValue {
    /// JavaScript truthiness; `undefined` (nil) is falsy.
    public var truthy: Bool { self?.truthy ?? false }
}

/// `Number(x)` for a JSON value (`undefined` → NaN).
func jsNumber(_ v: JSONValue?) -> Double {
    guard let v else { return .nan }
    switch v {
    case .null: return 0
    case .bool(let b): return b ? 1 : 0
    case .number(let n): return n
    case .string(let s): return jsNumber(s)
    case .array(let a):
        if a.isEmpty { return 0 }
        if a.count == 1 { return jsNumber(a[0]) }
        return .nan
    case .object: return .nan
    }
}

/// `Number(string)`: whitespace-trimmed decimal / hex literal; empty → 0; otherwise NaN.
func jsNumber(_ s: String) -> Double {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return 0 }
    if t == "Infinity" || t == "+Infinity" { return .infinity }
    if t == "-Infinity" { return -.infinity }
    let u = Array(t.utf8)
    if u.count > 2, u[0] == 0x30, u[1] == 0x78 || u[1] == 0x58 {
        var v = 0.0
        for c in u[2...] {
            guard let d = hexDigit(c) else { return .nan }
            v = v * 16 + Double(d)
        }
        return v
    }
    // Decimal literal only: [+-]? (digits [. digits?] | . digits) ([eE][+-]?digits)?
    var i = 0
    if i < u.count, u[i] == 0x2B || u[i] == 0x2D { i += 1 }
    var mant = 0
    while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1; mant += 1 }
    if i < u.count, u[i] == 0x2E {
        i += 1
        while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1; mant += 1 }
    }
    if mant == 0 { return .nan }
    if i < u.count, u[i] == 0x65 || u[i] == 0x45 {
        i += 1
        if i < u.count, u[i] == 0x2B || u[i] == 0x2D { i += 1 }
        var e = 0
        while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1; e += 1 }
        if e == 0 { return .nan }
    }
    if i != u.count { return .nan }
    return Double(t) ?? .nan
}

private func hexDigit(_ c: UInt8) -> Int? {
    switch c {
    case 0x30...0x39: return Int(c - 0x30)
    case 0x61...0x66: return Int(c - 0x61 + 10)
    case 0x41...0x46: return Int(c - 0x41 + 10)
    default: return nil
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible, Sendable {
    public let offset: Int
    public let reason: String
    public var description: String { "Invalid JSON at \(offset): \(reason)" }
}

extension JSONValue {
    /// `JSON.parse`. Duplicate keys: the last value wins at the first key's position.
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var p = JSONParser(bytes: [UInt8](data))
        p.skipWS()
        let v = try p.value(depth: 0)
        p.skipWS()
        if p.i != p.bytes.count { throw p.error("unexpected trailing data") }
        return v
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // Skip a UTF-8 BOM.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
    }

    func error(_ r: String) -> JSONParseError { JSONParseError(offset: i, reason: r) }

    mutating func skipWS() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
    }

    mutating func value(depth: Int) throws -> JSONValue {
        guard depth < 512 else { throw error("nesting too deep") }
        guard i < bytes.count else { throw error("unexpected end") }
        switch bytes[i] {
        case 0x7B: // {
            i += 1
            var obj = JSONObject()
            skipWS()
            if i < bytes.count, bytes[i] == 0x7D { i += 1; return .object(obj) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == 0x22 else { throw error("expected key") }
                let k = try string()
                skipWS()
                guard i < bytes.count, bytes[i] == 0x3A else { throw error("expected ':'") }
                i += 1
                skipWS()
                obj[k] = try value(depth: depth + 1)
                skipWS()
                guard i < bytes.count else { throw error("unexpected end") }
                if bytes[i] == 0x2C { i += 1; continue }
                if bytes[i] == 0x7D { i += 1; return .object(obj) }
                throw error("expected ',' or '}'")
            }
        case 0x5B: // [
            i += 1
            var arr: [JSONValue] = []
            skipWS()
            if i < bytes.count, bytes[i] == 0x5D { i += 1; return .array(arr) }
            while true {
                skipWS()
                arr.append(try value(depth: depth + 1))
                skipWS()
                guard i < bytes.count else { throw error("unexpected end") }
                if bytes[i] == 0x2C { i += 1; continue }
                if bytes[i] == 0x5D { i += 1; return .array(arr) }
                throw error("expected ',' or ']'")
            }
        case 0x22:
            return .string(try string())
        case 0x74:
            try literal("true"); return .bool(true)
        case 0x66:
            try literal("false"); return .bool(false)
        case 0x6E:
            try literal("null"); return .null
        default:
            return .number(try number())
        }
    }

    mutating func literal(_ s: String) throws {
        let u = Array(s.utf8)
        guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { throw error("bad literal") }
        i += u.count
    }

    mutating func number() throws -> Double {
        let start = i
        if i < bytes.count, bytes[i] == 0x2D { i += 1 }
        guard i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 else { throw error("bad number") }
        if bytes[i] == 0x30 { i += 1 } else { while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 } }
        if i < bytes.count, bytes[i] == 0x2E {
            i += 1
            guard i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 else { throw error("bad fraction") }
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
        }
        if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
            i += 1
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            guard i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 else { throw error("bad exponent") }
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
        }
        let s = String(decoding: bytes[start..<i], as: UTF8.self)
        guard let d = Double(s) else { throw error("bad number") }
        return d
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw error("bad \\u escape") }
        var v: UInt32 = 0
        for k in 0..<4 {
            guard let d = hexDigit(bytes[i + k]) else { throw error("bad \\u escape") }
            v = v * 16 + UInt32(d)
        }
        i += 4
        return v
    }

    mutating func string() throws -> String {
        i += 1 // opening quote
        var out = [UInt8]()
        while true {
            guard i < bytes.count else { throw error("unterminated string") }
            let c = bytes[i]
            if c == 0x22 { i += 1; break }
            if c < 0x20 { throw error("control character in string") }
            if c != 0x5C { out.append(c); i += 1; continue }
            i += 1
            guard i < bytes.count else { throw error("bad escape") }
            let e = bytes[i]
            i += 1
            switch e {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                var code = try hex4()
                if code >= 0xD800, code < 0xDC00, i + 6 <= bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75 {
                    let save = i
                    i += 2
                    let lo = try hex4()
                    if lo >= 0xDC00, lo < 0xE000 {
                        code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
                    } else {
                        i = save
                    }
                }
                // Lone surrogates can't live in a Swift String: U+FFFD.
                let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                throw error("bad escape")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Serialisation (JSON.stringify)

extension JSONValue {
    /// Compact `JSON.stringify` output (same escaping and number formatting).
    public func jsonString() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    public func jsonData() -> Data { Data(jsonString().utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n.isFinite ? jsNumberString(n) : "null"
        case .string(let s): out += jsonQuote(s)
        case .array(let a):
            out += "["
            for (k, v) in a.enumerated() {
                if k > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (k, (key, v)) in o.pairs.enumerated() {
                if k > 0 { out += "," }
                out += jsonQuote(key)
                out += ":"
                v.write(into: &out)
            }
            out += "}"
        }
    }
}

/// `JSON.stringify(string)`.
func jsonQuote(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 {
                let h = String(u.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - h.count) + h
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    return out + "\""
}

/// ECMAScript `Number.prototype.toString()` for finite numbers.
func jsNumberString(_ x: Double) -> String {
    if x == 0 { return "0" }
    if x < 0 { return "-" + jsNumberString(-x) }
    // Swift's description is the shortest round-trip representation; take its
    // digits and decimal exponent, then lay them out the way JS does.
    let desc = "\(x)"
    var mantissa = Substring(desc)
    var exp = 0
    if let e = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = desc[..<e]
        exp = Int(desc[desc.index(after: e)...]) ?? 0
    }
    let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    let intPart = parts[0]
    let fracPart = parts.count > 1 ? parts[1] : ""
    var digits = Array(intPart + fracPart)
    var point = intPart.count + exp // position of the decimal point within `digits`
    while let f = digits.first, f == "0" { digits.removeFirst(); point -= 1 }
    while let l = digits.last, l == "0" { digits.removeLast() }
    if digits.isEmpty { return "0" }
    let k = digits.count
    let n = point
    let ds = String(digits)
    if k <= n && n <= 21 { return ds + String(repeating: "0", count: n - k) }
    if 0 < n && n <= 21 { return String(digits[0..<n]) + "." + String(digits[n...]) }
    if -6 < n && n <= 0 { return "0." + String(repeating: "0", count: -n) + ds }
    let e = n - 1
    let es = e < 0 ? "-\(-e)" : "+\(e)"
    if k == 1 { return ds + "e" + es }
    return String(digits[0]) + "." + String(digits[1...]) + "e" + es
}

/// JavaScript `Math.round` (halves round toward +∞).
func jsRound(_ x: Double) -> Double {
    if !x.isFinite { return x }
    let r = x.rounded(.down)
    return x - r >= 0.5 ? r + 1 : r
}
