// Text formatting shared by the screens: playhead times (src/theme.ts fmtTime)
// and the Recordings helpers from src/recordings/core.ts.

import Foundation

/// "1:05.3" (minutes:seconds with one decimal), "--:--" when not finite.
func fmtTime(_ sec: Double) -> String {
    guard sec.isFinite else { return "--:--" }
    let s = max(0, sec)
    let m = Int(s / 60)
    let r = s - Double(m) * 60
    let rounded = (r * 10).rounded() / 10
    // Guard "0:60.0" from rounding at the boundary.
    if rounded >= 60 { return "\(m + 1):00.0" }
    return "\(m):\(rounded < 10 ? "0" : "")\(String(format: "%.1f", rounded))"
}

enum RecordingFormat {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// "Nov 12, 2026 · 14:05" in local time.
    static func date(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        let month = months[max(0, min(11, (c.month ?? 1) - 1))]
        return "\(month) \(c.day ?? 1), \(c.year ?? 1970) · \(pad(c.hour ?? 0)):\(pad(c.minute ?? 0))"
    }

    /// "Song — Nov 12, 2026 · 14:05", with " (raw take)" for raw takes.
    static func defaultTitle(songTitle: String?, at ms: Double, kind: RecordingKind) -> String {
        let trimmed = songTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = trimmed.isEmpty ? "Lumber" : trimmed
        let raw = kind.isRawTake ? " (raw take)" : ""
        return "\(base)\(raw) — \(date(ms))"
    }

    /// Filesystem-safe, unique file name: `<title>_<id>.<ext>`.
    static func fileName(title: String, id: String, ext: String) -> String {
        let allowed = title.unicodeScalars.filter { s in
            s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "_" || s == "-" || s == " ")
        }
        let cleaned = String(String.UnicodeScalarView(allowed))
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " })
            .joined(separator: "_")
        let safe = cleaned.isEmpty ? "lumber" : String(cleaned.prefix(60))
        var e = ext.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        return "\(safe)_\(id).\(e.isEmpty ? "bin" : e)"
    }

    /// Lowercased extension of a path or URL string, "" when none.
    static func ext(_ path: String) -> String {
        let clean = path.split(separator: "?").first.map(String.init) ?? path
        let last = clean.split(separator: "/").last.map(String.init) ?? clean
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return "" }
        return String(last[last.index(after: dot)...]).lowercased()
    }

    /// Newest first; ties broken by id so the order is stable.
    static func sorted(_ list: [Recording]) -> [Recording] {
        list.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id
        }
    }

    static func totalSize(_ list: [Recording]) -> Double {
        list.reduce(0) { $0 + ($1.size.isFinite && $1.size > 0 ? $1.size : 0) }
    }

    static func bytes(_ n: Double) -> String {
        guard n.isFinite, n > 0 else { return "0 KB" }
        let mb = 1024.0 * 1024.0
        if n < mb { return "\(max(1, Int((n / 1024).rounded()))) KB" }
        if n < mb * 1024 { return String(format: "%.1f MB", n / mb) }
        return String(format: "%.2f GB", n / (mb * 1024))
    }

    /// "1:05" / "12:00" / "1:02:03".
    static func duration(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "--:--" }
        let s = Int(sec.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        return h > 0 ? "\(h):\(pad(m)):\(pad(r))" : "\(m):\(pad(r))"
    }
}

/// Base-36 time + random suffix, like the RN app's newId().
func newId() -> String {
    let time = String(Int(nowMs()), radix: 36)
    let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    let suffix = String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    return time + suffix
}
