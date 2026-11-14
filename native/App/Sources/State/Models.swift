// Persisted data: the same shapes (and JSON field names) as the RN app's
// src/state/types.ts, so a db.json reads the same in both apps.
//
// Differences from the RN app:
// - File references (`uri`, `drumsUri`, stems, video) are stored relative to
//   the app's Documents directory ("lumber/songs/x.m4a"): the container path
//   changes between installs. `DocumentStore.url(for:)` still resolves old
//   absolute file:// URIs.
// - Decoding is lenient (see `init(from:)` below): missing fields get the same
//   defaults as src/state/migrate.ts and unusable list entries are dropped, so
//   old or partially written files keep loading.

import Foundation

// MARK: - Songs

enum SongSourceKind: String, Codable, Sendable, CaseIterable {
    case file, youtube, spotify

    var label: String {
        switch self {
        case .file: "File"
        case .youtube: "YouTube"
        case .spotify: "Spotify"
        }
    }
}

/// Output of "Remove original drums" (Documents-relative WAV paths).
struct SeparationResult: Codable, Hashable, Sendable {
    var drumsUri: String // the song's original drums
    var noDrumsUri: String // bass + other + vocals
    var sampleRate: Double
}

struct LibrarySong: Codable, Hashable, Sendable, Identifiable {
    var id: String // `${source}:${externalId}`
    var title: String
    var artist: String?
    var durationSec: Double?
    var artworkUrl: String?
    var source: SongSourceKind
    var uri: String // Documents-relative audio file
    var addedAt: Double // ms since 1970 (JS Date.now())
    var stems: SeparationResult?
}

// MARK: - Takes

enum CameraFacing: String, Codable, Sendable, CaseIterable {
    case front, back
}

enum VideoSyncSource: String, Codable, Sendable {
    case progress, call
}

struct TakeVideo: Codable, Hashable, Sendable {
    var uri: String // Documents-relative .mov (no audio track)
    var offsetSec: Double // song time where video time 0 belongs
    var durationSec: Double
    var facing: CameraFacing
    var syncSource: VideoSyncSource
}

struct Take: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var songId: String
    var drumsUri: String // Documents-relative WAV of the mic recording
    var songStartSec: Double // song position playback started from
    var drumOffsetSec: Double // song time where drum-file sample 0 belongs (latency-compensated)
    var latencyMs: Double // round-trip latency that was compensated
    var sampleRate: Double
    var createdAt: Double // ms
    var video: TakeVideo?
}

// MARK: - Projects

struct MixSettings: Codable, Hashable, Sendable {
    var nudgeMs: Double // manual alignment on top of take.drumOffsetSec
    var songGain: Double // 0...1.5
    var drumGain: Double // 0...1.5
    var originalDrums: Double // 0...1, only used when the song has stems
    var values: [String: Double] // Blanket knob term -> -1...1
    var presetId: String?
    var videoNudgeMs: Double?

    static func defaults() -> MixSettings {
        MixSettings(
            nudgeMs: 0,
            songGain: 0.8,
            drumGain: 1,
            originalDrums: 0,
            values: KnobCatalog.filledValues([:]),
            presetId: nil,
            videoNudgeMs: nil
        )
    }
}

struct Project: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var songId: String
    var takeId: String
    var name: String
    var mix: MixSettings
    var createdAt: Double // ms
    var updatedAt: Double // ms
}

// MARK: - Settings

struct Settings: Codable, Hashable, Sendable {
    var latencyByRoute: [String: Double] // ms, measured by calibration
    var latencyNudgeMs: Double // manual global nudge on top
    var bpm: Double
    var countIn: Bool

    static let defaults = Settings(latencyByRoute: [:], latencyNudgeMs: 0, bpm: 120, countIn: true)
}

// MARK: - Recordings

enum RecordingKind: String, Codable, Sendable, CaseIterable {
    case video
    case mixWav = "mix-wav"
    case mixM4a = "mix-m4a"
    case takeWav = "take-wav"
    case takeVideo = "take-video"

    var isVideo: Bool { self == .video || self == .takeVideo }
    var isRawTake: Bool { self == .takeWav || self == .takeVideo }

    var label: String {
        switch self {
        case .video: "Video"
        case .mixWav: "Mix · WAV"
        case .mixM4a: "Mix · M4A"
        case .takeWav: "Raw take · WAV"
        case .takeVideo: "Raw take · video"
        }
    }
}

/// Something saved on the Recordings screen. Files live in
/// Documents/lumber/recordings and are resolved by `fileName`.
struct Recording: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var kind: RecordingKind
    var fileName: String // in lumber/recordings
    var uri: String // Documents-relative path at save time (reference only)
    var title: String
    var projectId: String?
    var songId: String?
    var createdAt: Double // ms
    var durationSec: Double
    var size: Double // bytes
    var thumbnail: String? // JPEG file name in lumber/recordings (videos only)
}

// MARK: - Database

struct Db: Codable, Sendable {
    /// Bump when the shape changes and add a step to `migrated()`.
    static let currentVersion = 1

    var version: Int
    var songs: [LibrarySong]
    var takes: [Take]
    var projects: [Project]
    var recordings: [Recording]
    var settings: Settings

    static func empty() -> Db {
        Db(version: currentVersion, songs: [], takes: [], projects: [], recordings: [], settings: .defaults)
    }

    /// Brings a decoded file up to `currentVersion`. Field-level defaults are
    /// already applied by the lenient decoders; version steps go here.
    func migrated() -> Db {
        var db = self
        // if db.version < 2 { ...; db.version = 2 }
        var seen = Set<String>()
        db.recordings = db.recordings.filter { seen.insert($0.id).inserted }
        db.projects = db.projects.map { p in
            var p = p
            p.mix.values = KnobCatalog.filledValues(p.mix.values)
            return p
        }
        db.version = Db.currentVersion
        return db
    }
}

// MARK: - Lenient decoding

/// Ms since 1970, like JS `Date.now()`.
func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

/// Decodes an array, skipping elements that don't decode.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                out.append(element)
            } else if (try? container.decode(Skip.self)) == nil {
                break // can't advance; stop rather than loop forever
            }
        }
        elements = out
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it's missing or the wrong type.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func optional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    func list<T: Decodable>(_ key: Key) -> [T] {
        ((try? decodeIfPresent(LossyArray<T>.self, forKey: key)) ?? nil)?.elements ?? []
    }
}

extension LibrarySong {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        uri = try c.decode(String.self, forKey: .uri)
        title = c.value(.title, default: "Untitled")
        artist = c.optional(.artist)
        durationSec = c.optional(.durationSec)
        artworkUrl = c.optional(.artworkUrl)
        source = c.value(.source, default: .file)
        addedAt = c.value(.addedAt, default: 0)
        stems = c.optional(.stems)
    }
}

extension SeparationResult {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drumsUri = try c.decode(String.self, forKey: .drumsUri)
        noDrumsUri = try c.decode(String.self, forKey: .noDrumsUri)
        sampleRate = c.value(.sampleRate, default: 44_100)
    }
}

extension TakeVideo {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uri = try c.decode(String.self, forKey: .uri)
        offsetSec = c.value(.offsetSec, default: 0)
        durationSec = c.value(.durationSec, default: 0)
        facing = c.value(.facing, default: .front)
        syncSource = c.value(.syncSource, default: .call)
    }
}

extension Take {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        songId = try c.decode(String.self, forKey: .songId)
        drumsUri = try c.decode(String.self, forKey: .drumsUri)
        songStartSec = c.value(.songStartSec, default: 0)
        drumOffsetSec = c.value(.drumOffsetSec, default: 0)
        latencyMs = c.value(.latencyMs, default: 0)
        sampleRate = c.value(.sampleRate, default: 48_000)
        createdAt = c.value(.createdAt, default: 0)
        video = c.optional(.video)
    }
}

extension MixSettings {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MixSettings.defaults()
        nudgeMs = c.value(.nudgeMs, default: d.nudgeMs)
        songGain = c.value(.songGain, default: d.songGain)
        drumGain = c.value(.drumGain, default: d.drumGain)
        originalDrums = c.value(.originalDrums, default: d.originalDrums)
        values = KnobCatalog.filledValues(c.value(.values, default: [:]))
        presetId = c.optional(.presetId)
        videoNudgeMs = c.optional(.videoNudgeMs)
    }
}

extension Project {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        songId = try c.decode(String.self, forKey: .songId)
        takeId = try c.decode(String.self, forKey: .takeId)
        name = c.value(.name, default: "Take")
        mix = c.value(.mix, default: MixSettings.defaults())
        createdAt = c.value(.createdAt, default: 0)
        updatedAt = c.value(.updatedAt, default: createdAt)
    }
}

extension Settings {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.defaults
        latencyByRoute = c.value(.latencyByRoute, default: d.latencyByRoute)
        latencyNudgeMs = c.value(.latencyNudgeMs, default: d.latencyNudgeMs)
        bpm = c.value(.bpm, default: d.bpm)
        countIn = c.value(.countIn, default: d.countIn)
    }
}

extension Recording {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(RecordingKind.self, forKey: .kind) // unknown kinds are dropped
        uri = c.value(.uri, default: "")
        let named: String = c.value(.fileName, default: "")
        let fallback = uri.split(separator: "/").last.map { String($0).removingPercentEncoding ?? String($0) } ?? ""
        fileName = named.isEmpty ? fallback : named
        if fileName.isEmpty {
            throw DecodingError.dataCorruptedError(forKey: .fileName, in: c, debugDescription: "recording has no file")
        }
        createdAt = c.value(.createdAt, default: 0)
        let t: String = c.value(.title, default: "")
        title = t.isEmpty ? RecordingFormat.defaultTitle(songTitle: nil, at: createdAt, kind: kind) : t
        projectId = c.optional(.projectId)
        songId = c.optional(.songId)
        durationSec = max(0, c.value(.durationSec, default: 0))
        size = max(0, c.value(.size, default: 0))
        thumbnail = c.optional(.thumbnail)
    }
}

extension Db {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: 1)
        songs = c.list(.songs)
        takes = c.list(.takes)
        projects = c.list(.projects)
        recordings = c.list(.recordings)
        settings = c.value(.settings, default: .defaults)
    }
}
