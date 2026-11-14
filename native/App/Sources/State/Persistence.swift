// Where files live, and db.json. Everything is under Documents/lumber (visible
// in the Files app because UIFileSharingEnabled is on):
//
//   lumber/db.json        library, takes, projects, recordings, settings
//   lumber/songs/         imported / downloaded song audio
//   lumber/stems/         "Remove original drums" output
//   lumber/takes/         mic recordings (WAV)
//   lumber/videos/        camera clips (.mov)
//   lumber/recordings/    exports and raw-take copies shown on Recordings
//
// Paths in db.json are relative to Documents, because the app container path
// changes between installs (SideStore reinstalls, restores).

import Foundation

struct DocumentStore: Sendable {
    enum Folder: String, Sendable, CaseIterable {
        case songs, stems, takes, videos, recordings
    }

    let documents: URL

    init(documents: URL? = nil) {
        self.documents = documents
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    var appDir: URL { ensure(documents.appendingPathComponent("lumber", isDirectory: true)) }

    var dbURL: URL { appDir.appendingPathComponent("db.json") }

    func dir(_ folder: Folder) -> URL {
        ensure(appDir.appendingPathComponent(folder.rawValue, isDirectory: true))
    }

    /// Absolute URL for a stored reference: a Documents-relative path, or an
    /// absolute file:// URI / path written by an older install (re-rooted at
    /// this container's Documents when it points into a Documents folder).
    func url(for stored: String) -> URL {
        var path = stored
        if stored.hasPrefix("file://") {
            path = URL(string: stored)?.path ?? String(stored.dropFirst("file://".count))
        }
        guard path.hasPrefix("/") else {
            return documents.appendingPathComponent(path)
        }
        if let range = path.range(of: "/Documents/") {
            return documents.appendingPathComponent(String(path[range.upperBound...]))
        }
        return URL(fileURLWithPath: path)
    }

    /// The reference to store for a file: relative to Documents when inside it.
    func reference(for url: URL) -> String {
        let file = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = documents.standardizedFileURL.resolvingSymlinksInPath().path
        if file.hasPrefix(root + "/") {
            return String(file.dropFirst(root.count + 1))
        }
        return file
    }

    func recordingURL(fileName: String) -> URL {
        dir(.recordings).appendingPathComponent(fileName)
    }

    func exists(_ stored: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: stored).path)
    }

    /// Moves (or copies) `source` to `folder/name`, replacing what's there.
    @discardableResult
    func place(_ source: URL, in folder: Folder, name: String, copy: Bool = false) throws -> URL {
        let dest = dir(folder).appendingPathComponent(name)
        let fm = FileManager.default
        if source.standardizedFileURL == dest.standardizedFileURL { return dest }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        if copy {
            try fm.copyItem(at: source, to: dest)
        } else {
            try fm.moveItem(at: source, to: dest)
        }
        return dest
    }

    func remove(_ stored: String?) {
        guard let stored, !stored.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(for: stored))
    }

    func fileSize(_ url: URL) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.doubleValue ?? 0
    }

    private func ensure(_ dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Loads and saves db.json.
struct DbStore: Sendable {
    let files: DocumentStore

    /// The saved database, migrated; empty when there's none or it's unreadable
    /// (an unreadable file is kept as db.json.corrupt for inspection).
    func load() -> Db {
        let url = files.dbURL
        guard let data = try? Data(contentsOf: url) else { return .empty() }
        do {
            return try JSONDecoder().decode(Db.self, from: data).migrated()
        } catch {
            let backup = url.deletingLastPathComponent().appendingPathComponent("db.json.corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return .empty()
        }
    }

    /// Atomic write (temp file + rename), so a crash mid-write can't truncate.
    func save(_ db: Db) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(db)
        try data.write(to: files.dbURL, options: [.atomic])
    }
}
