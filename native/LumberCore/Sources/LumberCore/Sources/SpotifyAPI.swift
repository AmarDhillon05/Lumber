// The few Spotify Web API calls Lumber uses. Port of src/sources/spotifyApi.ts.
// Field names follow the February 2026 API: playlist contents come from
// /playlists/{id}/items and each entry's track is under `item`.

import Foundation

public struct SpotifyPlaylist: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var trackCount: Int?
    public var artworkUrl: String?
}

public struct SpotifyPage<T: Sendable & Equatable>: Sendable, Equatable {
    public var items: [T]
    public var next: Int? // offset of the next page
}

public struct SpotifyAPI: Sendable {
    public static let base = "https://api.spotify.com/v1"

    private let http: HTTPClient
    private let token: @Sendable (_ forceRefresh: Bool) async throws -> String

    public init(http: HTTPClient, token: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.http = http
        self.token = token
    }

    public init(http: HTTPClient, session: SpotifySession) {
        self.init(http: http) { force in try await session.accessToken(forceRefresh: force) }
    }

    /// A track object → SpotifyTrack; nil for episodes, local files and missing ids.
    public static func toTrack(_ t: JSONValue?) -> SpotifyTrack? {
        guard let t, t.truthy, t["type"]?.string != "episode", t["id"].truthy, !t["is_local"].truthy else { return nil }
        let ms = t["duration_ms"]
        return SpotifyTrack(
            trackId: t["id"]?.string ?? jsonText(t["id"]),
            title: t["name"]?.string ?? "",
            artists: (t["artists"]?.array ?? []).compactMap { $0["name"]?.string }.filter { !$0.isEmpty },
            durationSec: ms.truthy ? jsRound(jsNumber(ms) / 1000) : nil,
            artworkUrl: t["album"]?["images"]?[0]?["url"]?.string)
    }

    private func get(_ path: String) async throws -> JSONValue? {
        for attempt in 0..<2 {
            let tok = try await token(attempt > 0)
            let res = try await http.send(HTTPRequest(url: "\(Self.base)\(path)", headers: ["authorization": "Bearer \(tok)"]))
            if res.status == 401 && attempt == 0 { continue } // token went stale: refresh once
            if res.status == 204 { return nil }
            if res.status == 403 { throw SourceError("Spotify refused this request (only your own playlists can be opened)") }
            if res.status == 429 { throw SourceError("Spotify rate limit hit, try again in a minute") }
            if !res.ok { throw SourceError("Spotify API \(res.status) for \(path.components(separatedBy: "?")[0])") }
            return res.body.isEmpty ? nil : try res.json()
        }
        throw SourceError("Spotify session expired, connect again")
    }

    /// nil when nothing is playing (or a podcast is).
    public func currentlyPlaying() async throws -> SpotifyTrack? {
        guard let json = try await get("/me/player/currently-playing"), json.truthy else { return nil }
        return Self.toTrack(json["item"])
    }

    public func likedTracks(offset: Int = 0) async throws -> SpotifyPage<SpotifyTrack> {
        let json = try await get("/me/tracks?limit=50&offset=\(offset)")
        return Self.page(json, offset) { Self.toTrack($0["track"]) }
    }

    public func playlists(offset: Int = 0) async throws -> SpotifyPage<SpotifyPlaylist> {
        let json = try await get("/me/playlists?limit=50&offset=\(offset)")
        return Self.page(json, offset) { p in
            guard p["id"].truthy else { return nil }
            let total = p["items"]?["total"] ?? p["tracks"]?["total"]
            return SpotifyPlaylist(
                id: p["id"]?.string ?? jsonText(p["id"]),
                name: p["name"]?.string ?? "",
                trackCount: total?.number.map { Int($0) },
                artworkUrl: p["images"]?[0]?["url"]?.string)
        }
    }

    public func playlistTracks(_ playlistId: String, offset: Int = 0) async throws -> SpotifyPage<SpotifyTrack> {
        let json = try await get("/playlists/\(encodeURIComponent(playlistId))/items?limit=50&offset=\(offset)")
        return Self.page(json, offset) { i in
            let item = i["item"]
            return Self.toTrack(item == nil || item == .null ? i["track"] : item)
        }
    }

    static func page<T>(_ json: JSONValue?, _ offset: Int, _ map: (JSONValue) -> T?) -> SpotifyPage<T> {
        let raw = json?["items"]?.array ?? []
        return SpotifyPage(items: raw.compactMap(map), next: json?["next"].truthy == true ? offset + raw.count : nil)
    }
}

private func jsonText(_ v: JSONValue?) -> String {
    guard let v else { return "" }
    if case .number(let n) = v { return jsNumberString(n) }
    return v.jsonString()
}
