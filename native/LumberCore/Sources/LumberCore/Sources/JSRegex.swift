// Small helpers that reproduce the JavaScript string/regex operations the
// TypeScript originals rely on. Positions are UTF-16 offsets, as in JS.
// NSRegularExpression (ICU) matches JS for the ASCII patterns used here; one
// known difference: ICU's `\b` / `\w` treat non-ASCII letters as word
// characters, JS doesn't.

import Foundation

final class JSRegex: @unchecked Sendable {
    // NSRegularExpression is immutable and documented as thread-safe.
    let re: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false) {
        do {
            re = try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("bad regex \(pattern): \(error)")
        }
    }

    struct Match {
        let range: NSRange
        let groups: [String?] // groups[0] = whole match
        var index: Int { range.location }
        var end: Int { range.location + range.length }
        var text: String { groups[0] ?? "" }
    }

    private func make(_ m: NSTextCheckingResult, _ ns: NSString) -> Match {
        var g: [String?] = []
        for k in 0..<m.numberOfRanges {
            let r = m.range(at: k)
            g.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        return Match(range: m.range, groups: g)
    }

    /// `re.exec(s)` (first match).
    func exec(_ s: String) -> Match? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return make(m, ns)
    }

    /// `re.test(s)`.
    func test(_ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Every match, as a global regex would find them.
    func all(_ s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { make($0, ns) }
    }

    /// `s.search(re)`: index of the first match or −1.
    func search(_ s: String) -> Int { exec(s)?.index ?? -1 }

    /// `s.replace(/re/g, template)` with `$1`-style references.
    func replaceAll(_ s: String, _ template: String) -> String {
        re.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    /// `s.replace(/re/g, fn)`.
    func replaceAll(_ s: String, _ fn: (Match) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += fn(make(m, ns))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// `s.split(re)` (no capture groups in the patterns that use it).
    func split(_ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }
}

extension String {
    /// UTF-16 length (JS `.length`).
    var jsLength: Int { (self as NSString).length }

    /// `s.slice(from)` / `s.slice(from, to)` with UTF-16 offsets (non-negative).
    func jsSlice(_ from: Int, _ to: Int? = nil) -> String {
        let ns = self as NSString
        let a = Swift.min(Swift.max(0, from), ns.length)
        let b = Swift.min(Swift.max(a, to ?? ns.length), ns.length)
        return ns.substring(with: NSRange(location: a, length: b - a))
    }

    /// JS `trim()`.
    var jsTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private let uriUnreserved: Set<UInt8> = Set(
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8))

/// JavaScript `encodeURIComponent`.
public func encodeURIComponent(_ s: String) -> String {
    var out = ""
    for b in s.utf8 {
        if uriUnreserved.contains(b) {
            out.unicodeScalars.append(Unicode.Scalar(b))
        } else {
            let h = String(b, radix: 16, uppercase: true)
            out += "%" + (h.count == 1 ? "0" + h : h)
        }
    }
    return out
}

struct URIError: Error, CustomStringConvertible {
    var description: String { "URI malformed" }
}

/// JavaScript `decodeURIComponent` (throws on malformed escapes).
func decodeURIComponent(_ s: String) throws -> String {
    guard s.contains("%") else { return s }
    guard let d = s.removingPercentEncoding else { throw URIError() }
    return d
}
