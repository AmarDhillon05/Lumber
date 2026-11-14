// Song sources, Spotify and "Describe the sound", adapting LumberCore's
// YouTube / Links / Spotify / PromptMix ports to the app's service protocols.
// LumberCore has its own SearchResult/SpotifyPlaylist types; inside this
// module the unqualified names are the app's, and the core ones are spelled
// `LumberCore.X`.

import AuthenticationServices
import Foundation
import LumberCore
import Security
import UIKit

private let http = URLSessionHTTPClient()

// MARK: - Song sources

@MainActor
final class LiveSongSources: SongSourceService {
    func importFile(at url: URL, into directory: URL) async throws -> ImportedSong {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard LocalFile.isSupportedAudioName(name) else {
            throw ServiceError.failed("That file type isn't supported. Use MP3, M4A, WAV, AAC or AIFF.")
        }
        let hash = try await Task.detached { try LocalFile.sha256Hex(fileAt: url) }.value
        let dest = directory.appendingPathComponent(LocalFile.storedFileName(hashHex: hash, originalName: name))
        let fm = FileManager.default
        if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: url, to: dest) }
        return ImportedSong(
            id: LocalFile.songId(hashHex: hash), title: LocalFile.titleFromFileName(name), artist: nil,
            durationSec: try? AudioFileIO.duration(of: dest), artworkUrl: nil, source: .file, fileURL: dest
        )
    }

    func searchYouTube(_ query: String) async throws -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return try await YouTube.searchVideos(q, http: http).map { Self.result(LumberCore.SearchResult(hit: $0)) }
    }

    func resolvePastedLink(_ text: String) async throws -> PastedLink? {
        guard let r = try await Links.resolveLink(text, http: http) else { return nil }
        return PastedLink(label: r.label, results: r.results.map(Self.result))
    }

    func fetch(_ result: SearchResult, into directory: URL, progress: @escaping ProgressHandler) async throws -> ImportedSong {
        // Spotify audio is DRM'd: download the best YouTube match instead.
        var target = result
        if result.source == .spotify {
            let track = SpotifyTrack(
                trackId: result.externalId, title: result.title,
                artists: result.artist.map { [$0] } ?? [], durationSec: result.durationSec, artworkUrl: result.artworkUrl
            )
            let matches = try await Links.findSpotifyTrackOnYouTube(track, http: http)
            guard let best = matches.results.first else { throw ServiceError.failed("Couldn't find \"\(result.title)\" on YouTube.") }
            target = Self.result(best)
        }

        let videoId = target.externalId
        let audio = try await YouTube.resolveAudio(videoId: videoId, http: http)
        let dest = directory.appendingPathComponent("youtube-\(videoId).m4a")
        let fm = FileManager.default
        let complete = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) == audio.contentLength
        if !complete {
            let part = fm.temporaryDirectory.appendingPathComponent("youtube-\(videoId).m4a.part")
            try? fm.removeItem(at: part)
            fm.createFile(atPath: part.path, contents: nil)
            let sink = FileAppender(try FileHandle(forWritingTo: part))
            do {
                _ = try await YouTube.downloadAudio(
                    audio, io: HTTPChunkIO(http: http) { try await sink.append($0) },
                    options: DownloadOptions(onProgress: { p in Task { @MainActor in progress(p) } })
                )
                await sink.close()
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: part, to: dest)
            } catch {
                await sink.close()
                try? fm.removeItem(at: part)
                throw error
            }
        }
        progress(1)
        return ImportedSong(
            id: "youtube:\(videoId)",
            title: result.source == .spotify ? result.title : (target.title.isEmpty ? (audio.title ?? videoId) : target.title),
            artist: result.source == .spotify ? result.artist : (target.artist ?? audio.channel),
            durationSec: audio.durationSec ?? target.durationSec,
            artworkUrl: result.artworkUrl ?? target.artworkUrl ?? audio.thumbnailUrl,
            source: .youtube,
            fileURL: dest
        )
    }

    static func result(_ r: LumberCore.SearchResult) -> SearchResult {
        SearchResult(
            externalId: r.externalId, title: r.title, artist: r.artist, durationSec: r.durationSec,
            artworkUrl: r.artworkUrl, source: SongSourceKind(rawValue: r.source.rawValue) ?? .youtube
        )
    }
}

/// Serializes appends to one file from the download's async callbacks.
private actor FileAppender {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func append(_ data: Data) throws { try handle.write(contentsOf: data) }
    func close() { try? handle.close() }
}

// MARK: - Spotify

/// Spotify tokens in the iOS keychain (same JSON as the React Native app).
struct KeychainTokenStore: SpotifyTokenStore {
    static let service = "com.amardhillon.lumber.native.spotify"

    func load() async throws -> SpotifyTokens? {
        guard let data = Keychain.read(service: Self.service, account: "tokens") else { return nil }
        return try JSONDecoder().decode(SpotifyTokens.self, from: data)
    }

    func save(_ tokens: SpotifyTokens) async throws {
        try Keychain.write(try JSONEncoder().encode(tokens), service: Self.service, account: "tokens")
    }

    func clear() async throws { Keychain.delete(service: Self.service, account: "tokens") }
}

enum Keychain {
    static func read(service: String, account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func write(_ data: Data, service: String, account: String) throws {
        delete(service: service, account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw ServiceError.failed("Couldn't save to the keychain (\(status)).") }
    }

    static func delete(service: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

@MainActor
final class LiveSpotify: NSObject, SpotifyService, ASWebAuthenticationPresentationContextProviding {
    private let config = SpotifyConfig.lumberNative
    private let store = KeychainTokenStore()
    private lazy var session = SpotifySession(http: http, config: config, store: store)
    private lazy var api = SpotifyAPI(http: http, session: session)
    private var authSession: ASWebAuthenticationSession?

    func isConnected() async -> Bool { (try? await session.connected()) ?? false }

    func connect() async throws {
        let verifier = SpotifyAuth.randomVerifier()
        let state = SpotifyAuth.randomVerifier(bytes: 48)
        let authorize = SpotifyAuth.buildAuthorizeUrl(config, challenge: SpotifyAuth.challenge(for: verifier), state: state)
        guard let url = URL(string: authorize) else { throw ServiceError.failed("Bad Spotify login URL") }
        let scheme = URL(string: config.redirectUri)?.scheme ?? "lumbernative"
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) } else {
                    cont.resume(throwing: error ?? ServiceError.failed("Spotify login was cancelled"))
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            authSession = s
            if !s.start() { cont.resume(throwing: ServiceError.failed("Couldn't open Spotify login")) }
        }
        authSession = nil
        let code = try SpotifyAuth.parseCallback(callback.absoluteString, expectedState: state)
        let tokens = try await SpotifyAuth.exchangeCode(http, config, code: code, verifier: verifier)
        try await store.save(tokens)
    }

    func disconnect() async { try? await store.clear() }

    func nowPlaying() async throws -> SearchResult? {
        try await api.currentlyPlaying().map(Self.result)
    }

    func likedTracks(offset: Int) async throws -> SpotifyPage<SearchResult> {
        let p = try await api.likedTracks(offset: offset)
        return SpotifyPage(items: p.items.map(Self.result), nextOffset: p.next)
    }

    func playlists(offset: Int) async throws -> SpotifyPage<SpotifyPlaylist> {
        let p = try await api.playlists(offset: offset)
        return SpotifyPage(
            items: p.items.map { SpotifyPlaylist(id: $0.id, name: $0.name, trackCount: $0.trackCount, artworkUrl: $0.artworkUrl) },
            nextOffset: p.next
        )
    }

    func playlistTracks(playlistId: String, offset: Int) async throws -> SpotifyPage<SearchResult> {
        let p = try await api.playlistTracks(playlistId, offset: offset)
        return SpotifyPage(items: p.items.map(Self.result), nextOffset: p.next)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    private static func result(_ t: SpotifyTrack) -> SearchResult {
        SearchResult(
            externalId: t.trackId, title: t.title, artist: t.artists.joined(separator: ", "),
            durationSec: t.durationSec, artworkUrl: t.artworkUrl, source: .spotify
        )
    }
}

// MARK: - Describe the sound

@MainActor
final class LivePromptMix: PromptMixService {
    static let keyService = "com.amardhillon.lumber.native.anthropic"

    var modeLabel: String {
        Keychain.read(service: Self.keyService, account: "apiKey") == nil ? "Offline interpreter" : "Claude"
    }

    func interpret(_ request: PromptMixRequest) async throws -> PromptMixResult {
        let audio = try await ProjectAudio.load(request.audio)
        let mix = request.mix
        let offset = request.drumOffsetSec
        let analysis = await Task.detached(priority: .userInitiated) {
            PromptMix.analyzeProject(
                MixProjectAudio(
                    sampleRate: audio.sampleRate, drums: audio.take,
                    song: audio.originalDrums == nil ? audio.bed : nil,
                    stems: audio.originalDrums.map { (drums: $0, noDrums: audio.bed) }
                ),
                drumOffsetSec: offset
            )
        }.value
        let key = Keychain.read(service: Self.keyService, account: "apiKey").flatMap { String(data: $0, encoding: .utf8) }
        let outcome = await PromptMix.run(
            ClaudeMixInput(
                prompt: request.prompt, values: mix.values, songGain: mix.songGain, drumGain: mix.drumGain,
                originalDrums: audio.originalDrums == nil ? nil : mix.originalDrums,
                hasStems: audio.originalDrums != nil, analysis: analysis
            ),
            apiKey: key, http: http
        )
        let s = outcome.suggestion
        return PromptMixResult(
            values: s.values, songGain: s.songGain, drumGain: s.drumGain, explanation: s.explanation,
            source: outcome.source == .claude ? .claude : .offline, notice: outcome.notice
        )
    }

    static func setAPIKey(_ key: String?) throws {
        if let key, !key.isEmpty {
            try Keychain.write(Data(key.utf8), service: keyService, account: "apiKey")
        } else {
            Keychain.delete(service: keyService, account: "apiKey")
        }
    }
}
