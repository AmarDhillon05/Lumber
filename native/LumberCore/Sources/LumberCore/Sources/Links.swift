// Pasted links → playable search results. Port of src/sources/links.ts.
// YouTube links resolve to that video; Spotify track links are read from the
// public track page (title, artists, duration) and matched to the best
// YouTube upload.

import Foundation

public enum SongSourceKind: String, Sendable, Codable {
    case file, youtube, spotify
}

public struct SearchResult: Sendable, Equatable, Codable {
    public var externalId: String // e.g. YouTube video id
    public var title: String
    public var artist: String? // channel name for YouTube
    public var durationSec: Double?
    public var artworkUrl: String?
    public var source: SongSourceKind

    public init(externalId: String, title: String, artist: String? = nil, durationSec: Double? = nil, artworkUrl: String? = nil, source: SongSourceKind) {
        self.externalId = externalId
        self.title = title
        self.artist = artist
        self.durationSec = durationSec
        self.artworkUrl = artworkUrl
        self.source = source
    }

    public init(hit h: VideoHit) {
        self.init(externalId: h.videoId, title: h.title, artist: h.channel, durationSec: h.durationSec, artworkUrl: h.thumbnailUrl, source: .youtube)
    }
}

/// A song the app can play and record over (always a local file).
public struct Song: Sendable, Equatable, Codable {
    public var id: String // `${source}:${externalId}`
    public var title: String
    public var artist: String?
    public var durationSec: Double?
    public var artworkUrl: String?
    public var source: SongSourceKind
    public var uri: String

    public init(id: String, title: String, artist: String? = nil, durationSec: Double? = nil, artworkUrl: String? = nil, source: SongSourceKind, uri: String) {
        self.id = id
        self.title = title
        self.artist = artist
        self.durationSec = durationSec
        self.artworkUrl = artworkUrl
        self.source = source
        self.uri = uri
    }
}

public enum ParsedLink: Sendable, Equatable {
    case youtube(videoId: String)
    case spotify(trackId: String)
    case spotifyShort(url: String)
}

public struct SpotifyTrack: Sendable, Equatable, Codable {
    public var trackId: String
    public var title: String
    public var artists: [String]
    public var durationSec: Double?
    public var artworkUrl: String?

    public init(trackId: String, title: String, artists: [String], durationSec: Double? = nil, artworkUrl: String? = nil) {
        self.trackId = trackId
        self.title = title
        self.artists = artists
        self.durationSec = durationSec
        self.artworkUrl = artworkUrl
    }
}

public struct LinkResults: Sendable, Equatable {
    public var label: String // e.g. "Spotify: AC/DC – Back In Black"
    public var results: [SearchResult]
}

private let ytId = JSRegex("^[A-Za-z0-9_-]{11}$")
private let spotifyUri = JSRegex("^spotify:track:([A-Za-z0-9]{22})$")
private let linkShape = JSRegex(#"^(?:https?://)?([^/?#\s]+)([^\s]*)$"#, ignoreCase: true)
private let hostPrefix = JSRegex(#"^(www|m|music)\."#)
private let ytSegment = JSRegex("^/(?:shorts|embed|live|v)/([A-Za-z0-9_-]{11})")
private let spotifyTrackPath = JSRegex("/track/([A-Za-z0-9]{22})")
private let pathEnd = JSRegex("[?#]")
private let entity = JSRegex("&(#x[0-9a-f]+|#[0-9]+|[a-z]+);", ignoreCase: true)
private let shortLinkTarget = JSRegex("open\\.spotify\\.com/(?:intl-[a-z-]+/)?track/([A-Za-z0-9]{22})", ignoreCase: true)

private let entities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]

let spotifyPageHeaders = [
    "user-agent":
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
    "accept-language": "en",
]

public enum Links {
    /// nil when the text isn't a supported link (treat it as a search).
    public static func parseLink(_ text: String) -> ParsedLink? {
        let s = text.jsTrimmed
        if let m = spotifyUri.exec(s), let id = m.groups[1] { return .spotify(trackId: id) }
        guard let m = linkShape.exec(s), let rawHost = m.groups[1] else { return nil }
        let host = hostPrefix.replaceAll(rawHost.lowercased(), "")
        let rest = m.groups[2] ?? ""
        let path = pathEnd.split(rest)[0]
        let query: String
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...]).components(separatedBy: "#")[0]
        } else {
            query = ""
        }
        func param(_ k: String) -> String? {
            for kv in query.components(separatedBy: "&") {
                let parts = kv.components(separatedBy: "=")
                if parts[0] == k { return parts.count > 1 ? parts[1] : nil }
            }
            return nil
        }

        if host == "youtube.com" || host == "youtube-nocookie.com" {
            if let v = param("v"), ytId.test(v) { return .youtube(videoId: v) }
            if let seg = ytSegment.exec(path), let id = seg.groups[1] { return .youtube(videoId: id) }
            return nil
        }
        if host == "youtu.be" {
            let id = path.jsSlice(1, 12)
            return ytId.test(id) ? .youtube(videoId: id) : nil
        }
        if host == "open.spotify.com" || host == "play.spotify.com" {
            // Also covers localized paths like /intl-de/track/<id>.
            if let t = spotifyTrackPath.exec(path), let id = t.groups[1] { return .spotify(trackId: id) }
            return nil
        }
        if host == "spotify.link" || host == "spotify.app.link" {
            return .spotifyShort(url: "https://\(host)\(rest)")
        }
        return nil
    }

    // MARK: Spotify track page

    public static func decodeEntities(_ s: String) -> String {
        entity.replaceAll(s) { m in
            let all = m.text
            let e = m.groups[1] ?? ""
            if e.hasPrefix("#") {
                let isHex = e.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = isHex ? String(e.dropFirst(2)) : String(e.dropFirst())
                guard let code = UInt32(digits, radix: isHex ? 16 : 10) else { return all }
                // JS yields a lone surrogate here, which becomes U+FFFD once encoded.
                if (0xD800...0xDFFF).contains(code) { return "\u{FFFD}" }
                guard let scalar = Unicode.Scalar(code) else { return all }
                return String(Character(scalar))
            }
            return entities[e.lowercased()] ?? all
        }
    }

    static func meta(_ html: String, _ key: String) -> String? {
        let re = JSRegex("<meta\\s+(?:property|name)=\"\(key)\"\\s+content=\"([^\"]*)\"", ignoreCase: true)
        guard let m = re.exec(html), let v = m.groups[1] else { return nil }
        return decodeEntities(v)
    }

    public static func parseSpotifyTrackPage(trackId: String, html: String) throws -> SpotifyTrack {
        guard let title = meta(html, "og:title"), !title.isEmpty else {
            throw SourceError("Could not read the Spotify track (page format changed?)")
        }
        // "AC/DC" or "Artist A, Artist B"; og:description ("A · Album · Song · 1980") as fallback.
        let musicians = meta(html, "music:musician_description") ?? meta(html, "og:description")?.components(separatedBy: " · ")[0]
        let artists = (musicians ?? "").components(separatedBy: ",").map { $0.jsTrimmed }.filter { !$0.isEmpty }
        let duration = meta(html, "music:duration").map(jsNumber) ?? .nan
        return SpotifyTrack(
            trackId: trackId,
            title: title,
            artists: artists,
            durationSec: duration.isFinite && duration > 0 ? duration : nil,
            artworkUrl: meta(html, "og:image"))
    }

    public static func fetchSpotifyTrack(trackId: String, http: HTTPClient) async throws -> SpotifyTrack {
        let res = try await http.send(HTTPRequest(url: "https://open.spotify.com/track/\(trackId)", headers: spotifyPageHeaders))
        if !res.ok { throw SourceError("Spotify page HTTP \(res.status)") }
        return try parseSpotifyTrackPage(trackId: trackId, html: res.text)
    }

    /// spotify.link short links redirect (via an HTML page) to open.spotify.com.
    public static func expandSpotifyShortLink(_ url: String, http: HTTPClient) async throws -> String {
        let res = try await http.send(HTTPRequest(url: url, headers: spotifyPageHeaders))
        guard let m = shortLinkTarget.exec(res.text), let id = m.groups[1] else {
            throw SourceError("That Spotify link is not a track")
        }
        return id
    }

    // MARK: Matching a Spotify track to a YouTube upload

    private static let combining = JSRegex("[\u{0300}-\u{036f}]")
    private static let nonAlnum = JSRegex("[^a-z0-9]+")

    static func normalize(_ s: String) -> String {
        let d = s.lowercased().decomposedStringWithCompatibilityMapping
        return nonAlnum.replaceAll(combining.replaceAll(d, ""), " ").jsTrimmed
    }

    /// Variants almost never wanted for drumming along, unless the Spotify title says so.
    static let unwanted = [
        "live", "cover", "drumcover", "karaoke", "instrumental", "remix", "slowed", "sped up", "nightcore", "8d", "reverb",
        "lyrics", "reaction", "tutorial", "lesson", "alternate", "acoustic", "demo", "extended", "version",
    ]
    private static let unwantedRes = unwanted.map { JSRegex("\\b\($0)\\b") }
    private static let officialAudio = JSRegex(#"official (audio|video|music video)|\baudio\b"#)

    public static func scoreMatch(_ track: SpotifyTrack, _ hit: VideoHit) -> Double {
        let title = normalize(hit.title)
        let channel = normalize(hit.channel ?? "")
        let wanted = normalize(track.title)
        let artist = normalize(track.artists.first ?? "")
        var score = 0.0

        // Duration is the strongest signal that it's the studio recording.
        if let td = track.durationSec, td != 0, let hd = hit.durationSec, hd != 0, !td.isNaN, !hd.isNaN {
            let diff = abs(td - hd)
            score += diff <= 2 ? 40 : diff <= 5 ? 30 : diff <= 15 ? 10 : diff <= 40 ? -10 : -40
        }
        let words = wanted.components(separatedBy: " ").filter { !$0.isEmpty }
        let present = words.filter { title.contains($0) }.count
        score += words.isEmpty ? 0 : (25 * Double(present)) / Double(words.count)
        if !artist.isEmpty && (title.contains(artist) || channel.contains(artist)) { score += 15 }

        // Auto-generated "Artist - Topic" channels carry the album audio.
        if channel.hasSuffix(" topic") { score += 20 }
        if officialAudio.test(title) { score += 8 }
        // The artist's own channel, e.g. "TheKillersMusic", "acdcVEVO".
        let compact = { (x: String) in x.replacingOccurrences(of: " ", with: "") }
        var ca = compact(artist)
        if ca.hasPrefix("the") { ca.removeFirst(3) }
        if !artist.isEmpty && compact(channel).contains(ca) { score += 12 }
        if channel.hasSuffix("vevo") { score += 4 }

        for re in unwantedRes where re.test(title) && !re.test(wanted) { score -= 25 }
        return score
    }

    public static func rankMatches(_ track: SpotifyTrack, _ hits: [VideoHit]) -> [VideoHit] {
        hits.enumerated()
            .map { (i: $0.offset, h: $0.element, s: scoreMatch(track, $0.element) - Double($0.offset) * 0.5) }
            .sorted { $0.s != $1.s ? $0.s > $1.s : $0.i < $1.i }
            .map(\.h)
    }

    // MARK: Entry points

    static func youtubeVideo(_ videoId: String, http: HTTPClient) async throws -> SearchResult {
        // oEmbed gives title/channel/thumbnail without the player API.
        let url = "https://www.youtube.com/oembed?format=json&url=\(encodeURIComponent("https://www.youtube.com/watch?v=\(videoId)"))"
        let res = try await http.send(HTTPRequest(url: url))
        let info = res.ok ? try res.json() : .object(JSONObject())
        return SearchResult(
            externalId: videoId,
            title: info["title"]?.string ?? videoId,
            artist: info["author_name"]?.string,
            artworkUrl: info["thumbnail_url"]?.string,
            source: .youtube)
    }

    /// nil when the text isn't a supported link (treat it as a search).
    public static func resolveLink(_ text: String, http: HTTPClient, maxResults: Int = 5) async throws -> LinkResults? {
        guard let link = parseLink(text) else { return nil }
        let trackId: String
        switch link {
        case .youtube(let id):
            return LinkResults(label: "YouTube link", results: [try await youtubeVideo(id, http: http)])
        case .spotify(let id):
            trackId = id
        case .spotifyShort(let url):
            trackId = try await expandSpotifyShortLink(url, http: http)
        }
        let track = try await fetchSpotifyTrack(trackId: trackId, http: http)
        return try await findSpotifyTrackOnYouTube(track, http: http, maxResults: maxResults)
    }

    /// A Spotify track (link, "now playing" or library) → best YouTube uploads, best first.
    public static func findSpotifyTrackOnYouTube(_ track: SpotifyTrack, http: HTTPClient, maxResults: Int = 5) async throws -> LinkResults {
        let query = track.artists.first.flatMap { $0.isEmpty ? nil : "\($0) - \(track.title)" } ?? track.title
        let hits = try await YouTube.searchVideos(query, http: http)
        let ranked = rankMatches(track, hits).prefix(maxResults)
        let names = track.artists.joined(separator: ", ")
        return LinkResults(label: "Spotify: \(names.isEmpty ? "Unknown" : names) – \(track.title)", results: ranked.map(SearchResult.init(hit:)))
    }
}
