// Stand-ins for the platform services, so the app runs end to end before the
// real implementations land: Files import really copies the file, the
// "recorder" writes a silent WAV of the right length, WAV export writes a
// silent mix, and everything else reports that it isn't in this build yet.
// Replace members of `Services.live()` (App/ServicesFactory.swift) as real
// implementations arrive.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension Services {
    static func mock() -> Services {
        Services(
            sources: MockSongSourceService(),
            spotify: MockSpotifyService(),
            audio: MockAudioEngineService(),
            camera: MockCameraService(),
            preview: MockMixPreviewService(),
            separation: MockSeparationService(),
            promptMix: MockPromptMixService(),
            autoMix: MockAutoMixService(),
            export: MockExportService(),
            photos: MockPhotoLibraryService()
        )
    }
}

// MARK: - Song sources

@MainActor
final class MockSongSourceService: SongSourceService {
    func importFile(at url: URL, into directory: URL) async throws -> ImportedSong {
        let id = newId()
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let dest = directory.appendingPathComponent("file-\(id).\(ext)")
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: url, to: dest)
        let title = url.deletingPathExtension().lastPathComponent
        return ImportedSong(id: "file:\(id)", title: title.isEmpty ? "Imported song" : title, artist: nil,
                            durationSec: nil, artworkUrl: nil, source: .file, fileURL: dest)
    }

    func searchYouTube(_ query: String) async throws -> [SearchResult] {
        throw ServiceError.notImplemented("YouTube search")
    }

    func resolvePastedLink(_ text: String) async throws -> PastedLink? {
        let t = text.lowercased()
        if t.contains("youtu") || t.contains("spotify.com") {
            throw ServiceError.notImplemented("Opening links")
        }
        return nil
    }

    func fetch(_ result: SearchResult, into directory: URL, progress: @escaping ProgressHandler) async throws -> ImportedSong {
        throw ServiceError.notImplemented("Downloading songs")
    }
}

// MARK: - Spotify

@MainActor
final class MockSpotifyService: SpotifyService {
    func isConnected() async -> Bool { false }
    func connect() async throws { throw ServiceError.notImplemented("Spotify login") }
    func disconnect() async {}
    func nowPlaying() async throws -> SearchResult? { throw ServiceError.notImplemented("Spotify") }
    func likedTracks(offset: Int) async throws -> SpotifyPage<SearchResult> { throw ServiceError.notImplemented("Spotify") }
    func playlists(offset: Int) async throws -> SpotifyPage<SpotifyPlaylist> { throw ServiceError.notImplemented("Spotify") }
    func playlistTracks(playlistId: String, offset: Int) async throws -> SpotifyPage<SearchResult> {
        throw ServiceError.notImplemented("Spotify")
    }
}

// MARK: - Audio engine

/// A wall-clock transport with no sound; recording yields a silent WAV.
@MainActor
final class MockAudioEngineService: AudioEngineService {
    private var request: TransportRequest?
    private var startedAt: Date?
    private var countInSec: Double = 0
    private var autoStop: Task<Void, Never>?
    private let songDuration: Double = 180

    var isRunning: Bool { startedAt != nil }

    func prepare() async throws {}

    func loadSong(at url: URL) async throws -> Double {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ServiceError.failed("The song file is missing.")
        }
        return songDuration
    }

    func currentRoute() -> AudioRouteInfo {
        AudioRouteInfo(key: "mock:headphones", name: "Headphones (mock)", isHeadphones: true, isBluetooth: false)
    }

    func routeChanges() -> AsyncStream<AudioRouteInfo> {
        AsyncStream { _ in }
    }

    func start(_ request: TransportRequest, onAutoStop: @escaping @MainActor @Sendable () -> Void) async throws {
        self.request = request
        countInSec = request.countIn.map { Double($0.beats) * 60 / max(1, $0.bpm) } ?? 0
        startedAt = Date()
        let end = request.loop?.end ?? songDuration
        let runFor = max(0.5, end - request.startSec + countInSec)
        autoStop?.cancel()
        autoStop = Task { @MainActor in
            try? await Task.sleep(for: .seconds(runFor))
            if !Task.isCancelled { onAutoStop() }
        }
    }

    private var elapsed: Double { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    func position() -> Double? {
        guard let request, startedAt != nil else { return nil }
        return request.startSec + max(0, elapsed - countInSec)
    }

    func countInRemaining() -> Double { max(0, countInSec - elapsed) }

    func transportTiming() -> TransportTiming? {
        guard let request, let startedAt else { return nil }
        let host = ProcessInfo.processInfo.systemUptime - Date().timeIntervalSince(startedAt) + countInSec
        return TransportTiming(songStartSec: request.startSec, songStartHostTime: host)
    }

    func stop() async throws -> RecordedTake? {
        autoStop?.cancel()
        autoStop = nil
        defer {
            request = nil
            startedAt = nil
        }
        guard let request, request.record else { return nil }
        let seconds = max(0.5, elapsed - countInSec)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(newId()).wav")
        try SilentWav.write(to: url, seconds: seconds, sampleRate: 48_000)
        return RecordedTake(
            drumsURL: url,
            songStartSec: request.startSec,
            drumOffsetSec: request.startSec - request.latencyMs / 1000,
            latencyMs: request.latencyMs,
            sampleRate: 48_000,
            durationSec: seconds
        )
    }

    func calibrate() async throws -> CalibrationResult {
        throw ServiceError.notImplemented("Latency calibration")
    }
}

// MARK: - Camera

@MainActor
final class MockCameraService: CameraService {
    var isAvailable: Bool { false }
    var facing: CameraFacing = .front
    func requestAccess() async -> Bool { false }
    func startPreview() async throws { throw ServiceError.notImplemented("Camera") }
    func stopPreview() {}
    func startRecording() throws { throw ServiceError.notImplemented("Camera") }
    func stopRecording() async -> CameraClip? { nil }
    #if canImport(UIKit)
    func makePreviewView() -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }
    #endif
}

// MARK: - Mix preview

/// Wall-clock playhead and made-up waveforms.
@MainActor
final class MockMixPreviewService: MixPreviewService {
    private var loaded: LoadedProjectAudio?
    private var playStartedAt: Date?
    private var playFrom: Double = 0
    private var seekPos: Double = 0

    func load(_ request: ProjectAudioRequest) async throws -> LoadedProjectAudio {
        let fm = FileManager.default
        guard fm.fileExists(atPath: request.takeURL.path) else {
            throw ServiceError.failed("The take's recording is missing.")
        }
        let drums = SilentWav.duration(of: request.takeURL) ?? 30
        let audio = LoadedProjectAudio(songDurationSec: 180, drumsDurationSec: drums, sampleRate: 48_000,
                                       hasStems: request.stems != nil)
        loaded = audio
        return audio
    }

    func peaks(_ lane: WaveLane, start: Double, end: Double, columns: Int, drumOffsetSec: Double) -> [Float] {
        guard columns > 0, end > start else { return [] }
        let drumsEnd = drumOffsetSec + (loaded?.drumsDurationSec ?? 0)
        return (0..<columns).map { i in
            let t = start + (end - start) * Double(i) / Double(columns)
            switch lane {
            case .song:
                return Float(0.35 + 0.25 * abs(sin(t * 1.7)) + 0.15 * abs(sin(t * 7.3)))
            case .drums:
                guard t >= drumOffsetSec, t < drumsEnd else { return 0 }
                let beat = (t * 2).truncatingRemainder(dividingBy: 1)
                return Float(beat < 0.15 ? 0.9 : 0.12)
            }
        }
    }

    func setLevels(_ levels: MixLevels) {}
    func setDrumOffset(_ seconds: Double) {}

    func renderDrums(knobValues: [String: Double]) async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    var isPlaying: Bool { playStartedAt != nil }
    var duration: Double { loaded?.songDurationSec ?? 0 }

    func play(from seconds: Double) {
        playFrom = seconds
        playStartedAt = Date()
    }

    func stop() {
        seekPos = position()
        playStartedAt = nil
    }

    func seek(to seconds: Double) {
        seekPos = seconds
        if playStartedAt != nil {
            playFrom = seconds
            playStartedAt = Date()
        }
    }

    func position() -> Double {
        guard let playStartedAt else { return seekPos }
        return min(duration, playFrom + Date().timeIntervalSince(playStartedAt))
    }

    func unload() {
        playStartedAt = nil
        loaded = nil
    }
}

// MARK: - Separation

@MainActor
final class MockSeparationService: SeparationService {
    var modeLabel: String { "mock" }
    func cachedResult(forSong songURL: URL) -> SeparationOutput? { nil }
    func checkForCrash() -> String? { nil }

    func separateDrums(songURL: URL, into directory: URL, progress: @escaping ProgressHandler) async throws -> SeparationOutput {
        for step in 1...10 {
            try await Task.sleep(for: .milliseconds(150))
            progress(Double(step) / 20)
        }
        throw ServiceError.notImplemented("Drum removal")
    }
}

// MARK: - Prompt mix

@MainActor
final class MockPromptMixService: PromptMixService {
    var modeLabel: String { "Offline" }

    func interpret(_ request: PromptMixRequest) async throws -> PromptMixResult {
        throw ServiceError.notImplemented("Describe the sound")
    }
}

// MARK: - Auto mix

@MainActor
final class MockAutoMixService: AutoMixService {
    func run(_ request: AutoMixRequest) async throws -> AutoMixResult {
        throw ServiceError.notImplemented("Auto mix")
    }
}

// MARK: - Export

@MainActor
final class MockExportService: ExportService {
    func export(_ request: ExportRequest, progress: @escaping ProgressHandler) async throws -> ExportedFile {
        guard request.format == .wav else {
            throw ServiceError.notImplemented(request.format == .m4a ? "M4A export" : "Video export")
        }
        let seconds = SilentWav.duration(of: request.audio.takeURL) ?? 10
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mix-\(newId()).wav")
        progress(0.5)
        try SilentWav.write(to: url, seconds: seconds, sampleRate: 48_000)
        progress(1)
        return ExportedFile(url: url, durationSec: seconds, thumbnailURL: nil)
    }
}

// MARK: - Photos

@MainActor
final class MockPhotoLibraryService: PhotoLibraryService {
    func saveVideo(at url: URL) async throws -> PhotosSaveOutcome { .unavailable }
}

// MARK: - Silent WAV (mock output)

enum SilentWav {
    /// 16-bit mono PCM silence, capped at 10 minutes.
    static func write(to url: URL, seconds: Double, sampleRate: Int) throws {
        let frames = Int(min(600, max(0, seconds)) * Double(sampleRate))
        let dataBytes = frames * 2
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        d.append(Data(count: dataBytes))
        try d.write(to: url, options: [.atomic])
    }

    /// Duration of a canonical 44-byte-header PCM WAV, nil when it isn't one.
    static func duration(of url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44), header.count == 44,
              header.prefix(4) == Data("RIFF".utf8) else { return nil }
        func u32(_ at: Int) -> Int {
            header[at..<(at + 4)].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        }
        let byteRate = u32(28)
        let size = u32(40)
        guard byteRate > 0 else { return nil }
        return Double(size) / Double(byteRate)
    }
}
