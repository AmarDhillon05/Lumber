// Flows that combine services with state: importing and downloading songs,
// drum removal, finishing a take, exports and the Recordings library.

import Foundation

extension AppModel {
    // MARK: Songs

    /// A file picked in the Files app.
    func importSong(from url: URL) async throws {
        #if canImport(Darwin)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif
        let song = try await services.sources.importFile(at: url, into: files.dir(.songs))
        addSong(song)
    }

    /// Downloads a search result into the library (progress in `jobs`).
    func addSearchResult(_ result: SearchResult) async {
        let jobId = AppModel.downloadJobId(result)
        if let job = jobs[jobId], job.isRunning { return }
        setJob(jobId, Job(label: "Downloading", progress: 0))
        do {
            let song = try await services.sources.fetch(result, into: files.dir(.songs)) { [weak self] p in
                self?.setJob(jobId, Job(label: "Downloading", progress: p))
            }
            addSong(song)
            setJob(jobId, nil)
        } catch {
            setJob(jobId, Job(label: "Failed", progress: 0, error: error.localizedDescription))
        }
    }

    func isInLibrary(_ result: SearchResult) -> Bool {
        songs.contains { $0.id == result.id }
    }

    /// Picks up stems separated earlier (e.g. after db.json was reset).
    func adoptCachedStems() {
        for song in songs where song.stems == nil {
            if let cached = services.separation.cachedResult(forSong: url(song.uri)) {
                setStems(song.id, cached)
            }
        }
    }

    /// "Remove original drums" (progress and errors in `jobs`).
    func removeOriginalDrums(_ songId: String) async {
        guard let song = song(songId) else { return }
        let jobId = AppModel.separationJobId(songId)
        if let job = jobs[jobId], job.isRunning { return }
        let label = "Removing drums (\(services.separation.modeLabel))"
        setJob(jobId, Job(label: label, progress: 0))
        do {
            let output = try await services.separation.separateDrums(
                songURL: url(song.uri), into: files.dir(.stems)
            ) { [weak self] p in
                self?.setJob(jobId, Job(label: label, progress: p))
            }
            setStems(songId, output)
            setJob(jobId, nil)
        } catch {
            setJob(jobId, Job(label: "Failed", progress: 0, error: error.localizedDescription))
        }
    }

    // MARK: Recording

    /// The latency to compensate on `route`: calibrated, else an estimate.
    func latency(for route: AudioRouteInfo) -> (baseMs: Double, calibrated: Bool, totalMs: Double) {
        let calibrated = settings.latencyByRoute[route.key]
        let base = calibrated ?? (route.isBluetooth ? 200 : 15)
        return (base, calibrated != nil, base + settings.latencyNudgeMs)
    }

    /// Stores a finished take (and its camera clip) and opens it in Edit.
    func finishTake(songId: String, recorded: RecordedTake, clip: CameraClip?, timing: TransportTiming?) throws {
        let id = newId()
        let drums = try files.place(recorded.drumsURL, in: .takes, name: "take-\(id).wav")
        var video: TakeVideo?
        if let clip {
            if let timing, let start = clip.startHostTime {
                let ext = clip.url.pathExtension.isEmpty ? "mov" : clip.url.pathExtension
                let moved = try files.place(clip.url, in: .videos, name: "take-\(id).\(ext)")
                let offset = timing.videoOffset(videoStartHostTime: start)
                video = TakeVideo(uri: files.reference(for: moved), offsetSec: offset,
                                  durationSec: clip.durationSec, facing: clip.facing, syncSource: .call)
            } else {
                try? FileManager.default.removeItem(at: clip.url)
            }
        }
        let take = Take(
            id: id,
            songId: songId,
            drumsUri: files.reference(for: drums),
            songStartSec: recorded.songStartSec,
            drumOffsetSec: recorded.drumOffsetSec,
            latencyMs: recorded.latencyMs,
            sampleRate: recorded.sampleRate,
            createdAt: nowMs(),
            video: video
        )
        let project = addTake(take)
        path = [.edit(projectId: project.id)]
    }

    func recordCalibration(_ result: CalibrationResult) {
        updateSettings { $0.latencyByRoute[result.routeKey] = (result.latencyMs * 10).rounded() / 10 }
    }

    // MARK: Edit / export

    func audioRequest(for project: Project) -> ProjectAudioRequest? {
        guard let song = song(project.songId), let take = take(project.takeId) else { return nil }
        let stems = song.stems.map { (drums: url($0.drumsUri), noDrums: url($0.noDrumsUri)) }
        return ProjectAudioRequest(songURL: url(song.uri), stems: stems, takeURL: url(take.drumsUri))
    }

    /// Song time where the drum file's first sample plays.
    func drumOffsetSec(_ project: Project) -> Double {
        (take(project.takeId)?.drumOffsetSec ?? 0) + project.mix.nudgeMs / 1000
    }

    func exportMix(_ format: ExportFormat, projectId: String, progress: @escaping ProgressHandler) async throws -> Recording {
        guard let project = project(projectId), let audio = audioRequest(for: project),
              let take = take(project.takeId) else {
            throw ServiceError.failed("This take is missing.")
        }
        var video: ExportVideoInput?
        if format == .video {
            guard let v = take.video else { throw ServiceError.failed("This take has no video.") }
            video = ExportVideoInput(url: url(v.uri), offsetSec: v.offsetSec + (project.mix.videoNudgeMs ?? 0) / 1000)
        }
        let request = ExportRequest(format: format, title: project.name, audio: audio, mix: project.mix,
                                    drumOffsetSec: drumOffsetSec(project), video: video)
        let exported = try await services.export.export(request, progress: progress)
        return try saveRecordingFile(
            exported.url, kind: format.recordingKind, project: project,
            durationSec: exported.durationSec, thumbnail: exported.thumbnailURL, copy: false
        )
    }

    /// Copies the take as recorded (drums WAV, plus the camera clip if filmed).
    func saveRawTake(projectId: String, drumsDurationSec: Double) throws -> [Recording] {
        guard let project = project(projectId), let take = take(project.takeId) else {
            throw ServiceError.failed("This take is missing.")
        }
        var out = [try saveRecordingFile(url(take.drumsUri), kind: .takeWav, project: project,
                                         durationSec: drumsDurationSec, thumbnail: nil, copy: true)]
        if let v = take.video {
            out.append(try saveRecordingFile(url(v.uri), kind: .takeVideo, project: project,
                                             durationSec: v.durationSec, thumbnail: nil, copy: true))
        }
        return out
    }

    /// Moves (or copies) a file into lumber/recordings and lists it.
    private func saveRecordingFile(
        _ source: URL, kind: RecordingKind, project: Project, durationSec: Double, thumbnail: URL?, copy: Bool
    ) throws -> Recording {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ServiceError.failed("The exported file is missing.")
        }
        let id = newId()
        let createdAt = nowMs()
        let title = RecordingFormat.defaultTitle(songTitle: song(project.songId)?.title, at: createdAt, kind: kind)
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        let fileName = RecordingFormat.fileName(title: title, id: id, ext: ext)
        let dest = try files.place(source, in: .recordings, name: fileName, copy: copy)
        var thumbName: String?
        if let thumbnail {
            let name = RecordingFormat.fileName(title: title, id: id + "-thumb", ext: "jpg")
            if (try? files.place(thumbnail, in: .recordings, name: name)) != nil { thumbName = name }
        }
        let rec = Recording(
            id: id, kind: kind, fileName: fileName, uri: files.reference(for: dest), title: title,
            projectId: project.id, songId: project.songId, createdAt: createdAt,
            durationSec: durationSec, size: files.fileSize(dest), thumbnail: thumbName
        )
        addRecording(rec)
        return rec
    }
}
