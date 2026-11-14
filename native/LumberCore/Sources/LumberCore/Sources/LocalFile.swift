// Pure helpers for Files import. Port of src/sources/localFileCore.ts.

import Foundation

public enum LocalFile {
    public static let audioExtensions = ["mp3", "m4a", "wav", "aac", "aiff", "aif"]

    /// MIME types the RN document picker used; the native picker uses UTTypes
    /// (public.mp3, com.apple.m4a-audio, com.microsoft.waveform-audio,
    /// public.aac-audio, public.aiff-audio, public.audio).
    public static let audioMimeTypes = [
        "audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/wav", "audio/x-wav", "audio/aac", "audio/aiff",
        "audio/x-aiff", "audio/*",
    ]

    private static let ext = JSRegex(#"\.([A-Za-z0-9]+)$"#)
    private static let extStrip = JSRegex(#"\.[A-Za-z0-9]+$"#)

    public static func extensionOf(_ name: String) -> String? {
        ext.exec(name.jsTrimmed)?.groups[1]?.lowercased()
    }

    public static func isSupportedAudioName(_ name: String) -> Bool {
        guard let e = extensionOf(name) else { return false }
        return audioExtensions.contains(e)
    }

    /// "01 - Back In Black.m4a" → "01 - Back In Black"
    public static func titleFromFileName(_ name: String) -> String {
        let base = extStrip.replaceAll(name, "").replacingOccurrences(of: "_", with: " ").jsTrimmed
        return base.isEmpty ? "Untitled" : base
    }

    /// Stable on-disk name `file-<hash16>.<ext>`: the same file imported twice
    /// maps to the same path and Song.id (`file:<hash16>`).
    public static func storedFileName(hashHex: String, originalName: String) -> String {
        "file-\(hashHex.prefix(16)).\(extensionOf(originalName) ?? "audio")"
    }

    public static func songId(hashHex: String) -> String { "file:\(hashHex.prefix(16))" }

    /// Lower-case hex SHA-256 of a file, streamed in 1 MB blocks.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var s = SHA256Hasher()
        while true {
            let block = h.readData(ofLength: 1 << 20)
            if block.isEmpty { break }
            s.update(block)
        }
        return s.finalize().map { b in (b < 16 ? "0" : "") + String(b, radix: 16) }.joined()
    }
}
