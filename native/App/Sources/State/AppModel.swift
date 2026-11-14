// App state: library, takes, projects, recordings, settings (persisted to
// Documents/lumber/db.json, debounced) plus navigation and long-running job
// progress (not persisted). The port of src/state/store.ts.

import Foundation
import Observation

enum Route: Hashable, Sendable {
    case record(songId: String)
    case edit(projectId: String)
    case recordings(openId: String?)
}

/// Progress of a long-running per-song job (download, separation).
struct Job: Hashable, Sendable {
    var label: String
    var progress: Double // 0...1
    var error: String?

    var isRunning: Bool { error == nil }
}

@MainActor
@Observable
final class AppModel {
    // Persisted
    private(set) var songs: [LibrarySong] = []
    private(set) var takes: [Take] = []
    private(set) var projects: [Project] = []
    private(set) var recordings: [Recording] = []
    private(set) var settings: Settings = .defaults

    // Session only
    private(set) var loaded = false
    var path: [Route] = []
    private(set) var jobs: [String: Job] = [:]

    let services: Services
    let files: DocumentStore
    private let store: DbStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(services: Services, files: DocumentStore = DocumentStore()) {
        self.services = services
        self.files = files
        self.store = DbStore(files: files)
    }

    // MARK: Load / save

    func load() async {
        guard !loaded else { return }
        let store = self.store
        let db = await Task.detached(priority: .userInitiated) { store.load() }.value
        songs = db.songs
        takes = db.takes
        projects = db.projects
        recordings = db.recordings
        settings = db.settings
        loaded = true
    }

    var snapshot: Db {
        Db(version: Db.currentVersion, songs: songs, takes: takes, projects: projects,
           recordings: recordings, settings: settings)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes db.json right away (also used when the app goes to the background).
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard loaded else { return }
        do {
            try store.save(snapshot)
        } catch {
            print("Lumber: saving db.json failed: \(error)")
        }
    }

    // MARK: Lookup

    func song(_ id: String) -> LibrarySong? { songs.first { $0.id == id } }
    func project(_ id: String) -> Project? { projects.first { $0.id == id } }
    func take(_ id: String) -> Take? { takes.first { $0.id == id } }
    func projects(forSong id: String) -> [Project] { projects.filter { $0.songId == id } }
    func recording(_ id: String) -> Recording? { recordings.first { $0.id == id } }

    func url(_ stored: String) -> URL { files.url(for: stored) }

    // MARK: Songs

    func addSong(_ imported: ImportedSong) {
        guard !songs.contains(where: { $0.id == imported.id }) else { return }
        let song = LibrarySong(
            id: imported.id,
            title: imported.title,
            artist: imported.artist,
            durationSec: imported.durationSec,
            artworkUrl: imported.artworkUrl,
            source: imported.source,
            uri: files.reference(for: imported.fileURL),
            addedAt: nowMs(),
            stems: nil
        )
        songs.insert(song, at: 0)
        scheduleSave()
    }

    func removeSong(_ id: String) {
        let song = self.song(id)
        for take in takes where take.songId == id {
            files.remove(take.drumsUri)
            files.remove(take.video?.uri)
        }
        files.remove(song?.uri)
        files.remove(song?.stems?.drumsUri)
        files.remove(song?.stems?.noDrumsUri)
        songs.removeAll { $0.id == id }
        takes.removeAll { $0.songId == id }
        projects.removeAll { $0.songId == id }
        scheduleSave()
    }

    func updateSong(_ id: String, _ change: (inout LibrarySong) -> Void) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        change(&songs[i])
        scheduleSave()
    }

    func setStems(_ songId: String, _ output: SeparationOutput) {
        let stems = SeparationResult(
            drumsUri: files.reference(for: output.drumsURL),
            noDrumsUri: files.reference(for: output.noDrumsURL),
            sampleRate: output.sampleRate
        )
        updateSong(songId) { $0.stems = stems }
    }

    // MARK: Takes / projects

    /// Adds the take and a project for it ("<song> — take N").
    @discardableResult
    func addTake(_ take: Take) -> Project {
        let n = projects(forSong: take.songId).count + 1
        let now = nowMs()
        let project = Project(
            id: newId(),
            songId: take.songId,
            takeId: take.id,
            name: "\(song(take.songId)?.title ?? "Take") — take \(n)",
            mix: .defaults(),
            createdAt: now,
            updatedAt: now
        )
        takes.append(take)
        projects.insert(project, at: 0)
        scheduleSave()
        return project
    }

    func removeProject(_ id: String) {
        guard let p = project(id) else { return }
        let stillUsed = projects.contains { $0.id != id && $0.takeId == p.takeId }
        if !stillUsed, let take = self.take(p.takeId) {
            files.remove(take.drumsUri)
            files.remove(take.video?.uri)
            takes.removeAll { $0.id == take.id }
        }
        projects.removeAll { $0.id == id }
        scheduleSave()
    }

    func updateMix(_ projectId: String, _ change: (inout MixSettings) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        change(&projects[i].mix)
        projects[i].updatedAt = nowMs()
        scheduleSave()
    }

    func renameProject(_ projectId: String, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[i].name = t
        scheduleSave()
    }

    // MARK: Recordings
    // Recordings outlive their song/project: deleting a song or take leaves
    // anything already saved here alone.

    func addRecording(_ rec: Recording) {
        recordings.removeAll { $0.id == rec.id }
        recordings.insert(rec, at: 0)
        scheduleSave()
    }

    func renameRecording(_ id: String, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].title = t
        scheduleSave()
    }

    func removeRecording(_ id: String) {
        guard let rec = recording(id) else { return }
        try? FileManager.default.removeItem(at: recordingURL(rec))
        if let thumb = rec.thumbnail {
            try? FileManager.default.removeItem(at: files.recordingURL(fileName: thumb))
        }
        recordings.removeAll { $0.id == id }
        scheduleSave()
    }

    func recordingURL(_ rec: Recording) -> URL { files.recordingURL(fileName: rec.fileName) }

    func thumbnailURL(_ rec: Recording) -> URL? {
        rec.thumbnail.map { files.recordingURL(fileName: $0) }
    }

    func recordingExists(_ rec: Recording) -> Bool {
        FileManager.default.fileExists(atPath: recordingURL(rec).path)
    }

    // MARK: Settings

    func updateSettings(_ change: (inout Settings) -> Void) {
        change(&settings)
        scheduleSave()
    }

    // MARK: Jobs

    func setJob(_ id: String, _ job: Job?) {
        jobs[id] = job
    }

    static func separationJobId(_ songId: String) -> String { "sep:\(songId)" }
    static func downloadJobId(_ result: SearchResult) -> String { "dl:\(result.id)" }
}
