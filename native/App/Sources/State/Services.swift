// The seams between the UI and everything that touches hardware, the network
// or heavy DSP. Screens only see these protocols (through `Services`);
// App/Sources/Platform implements them with AVAudioEngine, AVCaptureSession,
// AVAssetExportSession, Photos, ONNX Runtime and ASWebAuthenticationSession,
// on top of LumberCore. Until a real implementation lands, MockServices.swift
// stands in so every screen renders and the flows can be clicked through.
//
// Conventions:
// - Every protocol is @MainActor: the UI calls straight in, and an
//   implementation hops to its own queue/actor for heavy or real-time work.
//   Audio render/tap callbacks must not be MainActor-isolated — put them in
//   `nonisolated` helpers so Swift 6 doesn't insert main-thread checks.
// - URLs are absolute file URLs. Files an implementation creates may live
//   anywhere (e.g. tmp); the app moves them into Documents/lumber/... itself,
//   except where a parameter names the destination directory.
// - Progress callbacks take 0...1 and are MainActor closures: call them from
//   the main actor (e.g. `await MainActor.run { progress(p) }`).
// - Errors: throw anything with a readable `localizedDescription`; the UI
//   shows it as is. `ServiceError.notImplemented` marks missing features.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

typealias ProgressHandler = @MainActor @Sendable (Double) -> Void

enum ServiceError: LocalizedError, Sendable {
    case notImplemented(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let feature): "\(feature) isn't available in this build yet."
        case .failed(let message): message
        }
    }
}

// MARK: - Song sources (Files, YouTube, pasted links)

/// A search hit from YouTube, a pasted link or Spotify (src/sources/types.ts).
struct SearchResult: Hashable, Sendable, Identifiable {
    var externalId: String // YouTube video id, Spotify track id, ...
    var title: String
    var artist: String?
    var durationSec: Double?
    var artworkUrl: String?
    var source: SongSourceKind

    var id: String { "\(source.rawValue):\(externalId)" }
}

/// A pasted YouTube/Spotify link, resolved ("Spotify playlist · 42 songs").
struct PastedLink: Sendable {
    var label: String
    var results: [SearchResult]
}

/// A playable song file in app storage, ready to add to the library.
struct ImportedSong: Sendable {
    var id: String // stable: "<source>:<externalId>" (file: content hash or uuid)
    var title: String
    var artist: String?
    var durationSec: Double?
    var artworkUrl: String?
    var source: SongSourceKind
    var fileURL: URL
}

@MainActor
protocol SongSourceService: AnyObject, Sendable {
    /// Copies a file picked in the Files app (security-scoped access is
    /// already started by the caller) into `directory`.
    func importFile(at url: URL, into directory: URL) async throws -> ImportedSong
    func searchYouTube(_ query: String) async throws -> [SearchResult]
    /// nil when `text` isn't a YouTube/Spotify link (the UI then searches).
    func resolvePastedLink(_ text: String) async throws -> PastedLink?
    /// Downloads a result's audio (Spotify results are matched to YouTube)
    /// into `directory`.
    func fetch(_ result: SearchResult, into directory: URL, progress: @escaping ProgressHandler) async throws -> ImportedSong
}

// MARK: - Spotify

struct SpotifyPlaylist: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var trackCount: Int?
    var artworkUrl: String?
}

struct SpotifyPage<Item: Sendable>: Sendable {
    var items: [Item]
    var nextOffset: Int? // nil when there are no more
}

/// Spotify login (PKCE via ASWebAuthenticationSession, redirect
/// lumbernative://spotify-callback, tokens in the Keychain) and library reads.
@MainActor
protocol SpotifyService: AnyObject, Sendable {
    func isConnected() async -> Bool
    func connect() async throws
    func disconnect() async
    func nowPlaying() async throws -> SearchResult?
    func likedTracks(offset: Int) async throws -> SpotifyPage<SearchResult>
    func playlists(offset: Int) async throws -> SpotifyPage<SpotifyPlaylist>
    func playlistTracks(playlistId: String, offset: Int) async throws -> SpotifyPage<SearchResult>
}

// MARK: - Recording (transport, mic, latency)

struct AudioRouteInfo: Hashable, Sendable {
    var key: String // stable per output route, keys Settings.latencyByRoute
    var name: String // "AirPods Pro", "Headphones", "Speaker"
    var isHeadphones: Bool
    var isBluetooth: Bool

    static let unknown = AudioRouteInfo(key: "unknown", name: "Unknown output", isHeadphones: false, isBluetooth: false)
}

struct LoopRegion: Hashable, Sendable {
    var start: Double
    var end: Double
}

struct CountIn: Hashable, Sendable {
    var bpm: Double
    var beats: Int
}

struct TransportRequest: Sendable {
    var songId: String
    var songURL: URL
    var startSec: Double // song position to start from (loop.start when looping)
    var loop: LoopRegion? // records one pass when set
    var countIn: CountIn?
    var record: Bool // false = play only
    var latencyMs: Double // round-trip latency to compensate
}

/// When the transport actually started, for lining up the camera clip.
struct TransportTiming: Sendable {
    var songStartSec: Double
    /// Host time (seconds, CACurrentMediaTime clock) at which song time
    /// `songStartSec` was rendered by the engine (after any count-in).
    var songStartHostTime: Double
    /// How long rendered audio takes to reach the player's ears (reported
    /// output latency + the calibrated residual). The drummer plays to what
    /// they hear, so camera frames line up with the song this much later
    /// than the render clock says.
    var outputLatencySec: Double = 0
}

/// The mic recording from `stop()` after a recording start.
struct RecordedTake: Sendable {
    var drumsURL: URL // WAV; the app moves it into lumber/takes
    var songStartSec: Double
    var drumOffsetSec: Double // song time where sample 0 belongs (latency-compensated)
    var latencyMs: Double
    var sampleRate: Double
    var durationSec: Double
}

struct CalibrationResult: Sendable {
    var routeKey: String
    var latencyMs: Double
    var confidence: Double
    var spreadMs: Double
    var isReliable: Bool
}

@MainActor
protocol AudioEngineService: AnyObject, Sendable {
    /// Session + engine setup (mic permission is requested here).
    func prepare() async throws
    /// Decodes the song for playback; returns its duration in seconds.
    func loadSong(at url: URL) async throws -> Double
    func currentRoute() -> AudioRouteInfo
    /// Emits whenever the output route changes (headphones in/out, AirPods).
    func routeChanges() -> AsyncStream<AudioRouteInfo>
    var isRunning: Bool { get }
    /// Starts playback (and recording). `onAutoStop` fires when the transport
    /// ends by itself (song or loop pass finished); the UI then calls `stop()`.
    func start(_ request: TransportRequest, onAutoStop: @escaping @MainActor @Sendable () -> Void) async throws
    /// Current song position in seconds, nil when not running.
    func position() -> Double?
    /// Seconds of count-in left (0 once the song is playing).
    func countInRemaining() -> Double
    func transportTiming() -> TransportTiming?
    /// Stops; returns the take when it was recording.
    func stop() async throws -> RecordedTake?
    /// Plays clicks and listens for them on the current route.
    func calibrate() async throws -> CalibrationResult
}

// MARK: - Camera

struct CameraClip: Sendable {
    var url: URL // .mov without audio; the app moves it into lumber/videos
    var startHostTime: Double? // CACurrentMediaTime clock, when frame 0 was captured
    var durationSec: Double
    var facing: CameraFacing
}

@MainActor
protocol CameraService: AnyObject, Sendable {
    var isAvailable: Bool { get }
    var facing: CameraFacing { get set }
    func requestAccess() async -> Bool
    func startPreview() async throws
    func stopPreview()
    /// Starts filming (muted). Called just before the audio transport starts.
    func startRecording() throws
    /// nil when nothing was filmed.
    func stopRecording() async -> CameraClip?
    #if canImport(UIKit)
    /// The live preview; called once per CameraPanel appearance.
    func makePreviewView() -> UIView
    #endif
}

// MARK: - Edit: preview playback + waveforms

/// The audio files behind a project.
struct ProjectAudioRequest: Sendable {
    var songURL: URL
    var stems: (drums: URL, noDrums: URL)? // when "Remove original drums" ran
    var takeURL: URL // the mic recording

    /// The backing track: the drumless stem when there is one.
    var bedURL: URL { stems?.noDrums ?? songURL }
}

struct LoadedProjectAudio: Sendable {
    var songDurationSec: Double
    var drumsDurationSec: Double
    var sampleRate: Double
    var hasStems: Bool
}

enum WaveLane: Sendable {
    case song, drums
}

struct MixLevels: Hashable, Sendable {
    var songGain: Double
    var drumGain: Double
    var originalDrums: Double
}

@MainActor
protocol MixPreviewService: AnyObject, Sendable {
    func load(_ request: ProjectAudioRequest) async throws -> LoadedProjectAudio
    /// Peak envelope (0...1, `columns` values) of a lane between song times
    /// `start` and `end`. The drum lane is shifted by `drumOffsetSec`.
    func peaks(_ lane: WaveLane, start: Double, end: Double, columns: Int, drumOffsetSec: Double) -> [Float]
    func setLevels(_ levels: MixLevels)
    func setDrumOffset(_ seconds: Double)
    /// Re-renders the take through the Blanket chain with these knob values
    /// and swaps it into the preview (called debounced while knobs move).
    func renderDrums(knobValues: [String: Double]) async throws
    var isPlaying: Bool { get }
    var duration: Double { get }
    func play(from seconds: Double)
    func stop()
    func seek(to seconds: Double)
    func position() -> Double
    func unload()
}

// MARK: - Drum removal

struct SeparationOutput: Sendable {
    var drumsURL: URL
    var noDrumsURL: URL
    var sampleRate: Double
}

@MainActor
protocol SeparationService: AnyObject, Sendable {
    /// "full", "light", ... shown next to the progress.
    var modeLabel: String { get }
    /// Stems already on disk for this song (e.g. after the db was reset).
    func cachedResult(forSong songURL: URL) -> SeparationOutput?
    /// A message when the previous run crashed the app (the next run steps down).
    func checkForCrash() -> String?
    /// Writes the stems into `directory`.
    func separateDrums(songURL: URL, into directory: URL, progress: @escaping ProgressHandler) async throws -> SeparationOutput
}

// MARK: - "Describe the sound"

enum PromptMixSource: String, Sendable {
    case claude, offline
}

struct PromptMixRequest: Sendable {
    var prompt: String
    var mix: MixSettings
    var audio: ProjectAudioRequest
    var drumOffsetSec: Double
}

struct PromptMixResult: Sendable {
    var values: [String: Double] // full knob state to apply
    var songGain: Double?
    var drumGain: Double?
    var explanation: String
    var source: PromptMixSource
    var notice: String?
}

@MainActor
protocol PromptMixService: AnyObject, Sendable {
    /// "Claude · Sonnet" / "Offline".
    var modeLabel: String { get }
    func interpret(_ request: PromptMixRequest) async throws -> PromptMixResult
}

// MARK: - Export

enum ExportFormat: String, Sendable, CaseIterable {
    case wav, m4a, video

    var recordingKind: RecordingKind {
        switch self {
        case .wav: .mixWav
        case .m4a: .mixM4a
        case .video: .video
        }
    }
}

struct ExportVideoInput: Sendable {
    var url: URL // the take's camera clip
    var offsetSec: Double // song time where video time 0 belongs (incl. videoNudgeMs)
}

struct ExportRequest: Sendable {
    var format: ExportFormat
    var title: String
    var audio: ProjectAudioRequest
    var mix: MixSettings
    var drumOffsetSec: Double // take.drumOffsetSec + mix.nudgeMs / 1000
    var video: ExportVideoInput? // required for .video
}

struct ExportedFile: Sendable {
    var url: URL // anywhere; the app moves it into lumber/recordings
    var durationSec: Double
    var thumbnailURL: URL? // JPEG, videos only
}

@MainActor
protocol ExportService: AnyObject, Sendable {
    func export(_ request: ExportRequest, progress: @escaping ProgressHandler) async throws -> ExportedFile
}

// MARK: - Photos

enum PhotosSaveOutcome: Sendable, Equatable {
    case saved, denied, unavailable
}

@MainActor
protocol PhotoLibraryService: AnyObject, Sendable {
    func saveVideo(at url: URL) async throws -> PhotosSaveOutcome
}

// MARK: - Container

/// Everything the screens use, injected through the environment.
@MainActor
final class Services {
    let sources: any SongSourceService
    let spotify: any SpotifyService
    let audio: any AudioEngineService
    let camera: any CameraService
    let preview: any MixPreviewService
    let separation: any SeparationService
    let promptMix: any PromptMixService
    let export: any ExportService
    let photos: any PhotoLibraryService

    init(
        sources: any SongSourceService,
        spotify: any SpotifyService,
        audio: any AudioEngineService,
        camera: any CameraService,
        preview: any MixPreviewService,
        separation: any SeparationService,
        promptMix: any PromptMixService,
        export: any ExportService,
        photos: any PhotoLibraryService
    ) {
        self.sources = sources
        self.spotify = spotify
        self.audio = audio
        self.camera = camera
        self.preview = preview
        self.separation = separation
        self.promptMix = promptMix
        self.export = export
        self.photos = photos
    }
}
