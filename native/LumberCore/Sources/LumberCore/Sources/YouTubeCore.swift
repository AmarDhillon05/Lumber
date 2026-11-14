// YouTube (InnerTube) search + player + chunked m4a download. Port of
// src/sources/youtubeCore.ts: the clients' stream URLs come back already
// signed, so there is no player-JS deciphering. See docs/youtube.md.

import Foundation

// MARK: - Clients

public struct InnertubeClient: Sendable {
    public let key: String
    public let nameId: Int // X-Youtube-Client-Name
    public let userAgent: String
    /// context.client (minus hl/gl/visitorData), in request key order.
    public let context: JSONObject

    public var clientVersion: String { context["clientVersion"]?.string ?? "" }
}

/// Versions mirror youtubei.js 18.2 / yt-dlp 2026.08 (see youtubeCore.ts).
public enum YouTube {
    public static let clients: [String: InnertubeClient] = [
        "ANDROID_VR": InnertubeClient(
            key: "ANDROID_VR",
            nameId: 28,
            userAgent:
                "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            context: JSONObject([
                ("clientName", "ANDROID_VR"),
                ("clientVersion", "1.65.10"),
                ("deviceMake", "Oculus"),
                ("deviceModel", "Quest 3"),
                ("androidSdkVersion", 32),
                ("osName", "Android"),
                ("osVersion", "12L"),
                ("platform", "MOBILE"),
                ("clientFormFactor", "SMALL_FORM_FACTOR"),
            ])),
        "VISIONOS": InnertubeClient(
            key: "VISIONOS",
            nameId: 101,
            userAgent:
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            context: JSONObject([
                ("clientName", "VISIONOS"),
                ("clientVersion", "1.02"),
                ("deviceMake", "Apple"),
                ("deviceModel", "RealityDevice17,1"),
                ("osName", "visionOS"),
                ("osVersion", "26.5.23O471"),
                ("platform", "MOBILE"),
            ])),
        "IOS": InnertubeClient(
            key: "IOS",
            nameId: 5,
            userAgent: "com.google.ios.youtube/20.11.6 (iPhone10,4; U; CPU iOS 16_7_7 like Mac OS X)",
            context: JSONObject([
                ("clientName", "IOS"),
                ("clientVersion", "20.11.6"),
                ("deviceMake", "Apple"),
                ("deviceModel", "iPhone10,4"),
                ("osName", "iOS"),
                ("osVersion", "16.7.7.20H330"),
                ("platform", "MOBILE"),
            ])),
    ]

    public static let defaultClientOrder = ["VISIONOS", "ANDROID_VR", "IOS"]

    static let webNameId = 1
    static let webVersion = "2.20260623.01.00"
    static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    static let base = "https://www.youtube.com"

    // googlevideo throttles long single requests; ~10 MB ranges come back at full speed.
    public static let chunkBytes = 10 * 1024 * 1024
}

// MARK: - Session (visitor data)

extension YouTube {
    /// A visitor id ties requests together; without one the player endpoint
    /// answers LOGIN_REQUIRED.
    public static func getVisitorData(_ http: HTTPClient) async throws -> String {
        let res = try await http.send(HTTPRequest(url: "\(base)/sw.js_data", headers: ["user-agent": webUserAgent]))
        if !res.ok { throw SourceError("YouTube: sw.js_data HTTP \(res.status)") }
        return try parseVisitorData(res.text)
    }

    public static func parseVisitorData(_ swJsData: String) throws -> String {
        var s = swJsData
        if s.hasPrefix(")]}'") { s.removeFirst(4) }
        let json = try JSONValue.parse(s)
        guard let v = json[0]?[2]?[0]?[0]?[13]?.string, !v.isEmpty else {
            throw SourceError("YouTube: no visitorData in sw.js_data")
        }
        return v
    }
}

// MARK: - Search

public struct VideoHit: Sendable, Equatable, Codable {
    public var videoId: String
    public var title: String
    public var channel: String?
    public var durationSec: Double?
    public var thumbnailUrl: String?

    public init(videoId: String, title: String, channel: String? = nil, durationSec: Double? = nil, thumbnailUrl: String? = nil) {
        self.videoId = videoId
        self.title = title
        self.channel = channel
        self.durationSec = durationSec
        self.thumbnailUrl = thumbnailUrl
    }
}

extension YouTube {
    public static func buildSearchRequest(query: String, visitorData: String) -> HTTPRequest {
        let body: JSONValue = [
            "context": ["client": ["clientName": "WEB", "clientVersion": .string(webVersion), "hl": "en", "gl": "US", "visitorData": .string(visitorData)]],
            "query": .string(query),
            "params": "EgIQAQ==", // filter: type = video
        ]
        return HTTPRequest(
            url: "\(base)/youtubei/v1/search?prettyPrint=false",
            method: "POST",
            headers: [
                "content-type": "application/json",
                "user-agent": webUserAgent,
                "x-youtube-client-name": String(webNameId),
                "x-youtube-client-version": webVersion,
                "x-goog-visitor-id": visitorData,
            ],
            body: body.jsonData())
    }

    /// Walks the search response and collects every `videoRenderer`, in
    /// document order. Live streams (no lengthText) are skipped.
    public static func parseSearchResponse(_ json: JSONValue) -> [VideoHit] {
        var hits: [VideoHit] = []
        var seen = Set<String>()
        func walk(_ node: JSONValue) {
            switch node {
            case .array(let a):
                for n in a { walk(n) }
            case .object(let o):
                if let vr = o["videoRenderer"], vr.truthy, let id = vr["videoId"]?.string, !seen.contains(id) {
                    seen.insert(id)
                    let lengthText = vr["lengthText"]?["simpleText"]?.string ?? textOf(vr["lengthText"])
                    if let lengthText, !lengthText.isEmpty {
                        hits.append(
                            VideoHit(
                                videoId: id,
                                title: textOf(vr["title"]) ?? id,
                                channel: textOf(vr["ownerText"]) ?? textOf(vr["longBylineText"]),
                                durationSec: parseClock(lengthText),
                                thumbnailUrl: bestThumbnail(vr["thumbnail"]?["thumbnails"])))
                    }
                }
                for (k, v) in o.pairs where k != "videoRenderer" { walk(v) }
            default:
                return
            }
        }
        walk(json)
        return hits
    }

    public static func searchVideos(_ query: String, http: HTTPClient, visitorData: String? = nil) async throws -> [VideoHit] {
        let vd: String
        if let visitorData { vd = visitorData } else { vd = try await getVisitorData(http) }
        let res = try await http.send(buildSearchRequest(query: query, visitorData: vd))
        if !res.ok { throw SourceError("YouTube search HTTP \(res.status)") }
        return parseSearchResponse(try res.json())
    }
}

// MARK: - Player + format selection

public struct AdaptiveFormat: Sendable, Equatable {
    public var itag: Int
    public var url: String?
    public var signatureCipher: String?
    public var mimeType: String?
    public var bitrate: Double?
    public var averageBitrate: Double?
    public var contentLength: JSONValue?
    public var approxDurationMs: String?
    public var audioQuality: String?
    public var xtags: String?
    public var isDrc: Bool
    /// nil when the format has no audioTrack; otherwise its audioIsDefault (nil if absent).
    public var audioTrack: AudioTrack?

    public struct AudioTrack: Sendable, Equatable {
        public var audioIsDefault: Bool?
        public var displayName: String?
    }

    public init(
        itag: Int, url: String? = nil, signatureCipher: String? = nil, mimeType: String? = nil, bitrate: Double? = nil,
        averageBitrate: Double? = nil, contentLength: JSONValue? = nil, xtags: String? = nil, isDrc: Bool = false,
        audioTrack: AudioTrack? = nil
    ) {
        self.itag = itag
        self.url = url
        self.signatureCipher = signatureCipher
        self.mimeType = mimeType
        self.bitrate = bitrate
        self.averageBitrate = averageBitrate
        self.contentLength = contentLength
        self.xtags = xtags
        self.isDrc = isDrc
        self.audioTrack = audioTrack
    }

    public init(json f: JSONValue) {
        itag = Int(jsNumber(f["itag"]).isFinite ? jsNumber(f["itag"]) : 0)
        url = f["url"]?.string
        signatureCipher = f["signatureCipher"]?.string
        mimeType = f["mimeType"]?.string
        bitrate = f["bitrate"]?.number
        averageBitrate = f["averageBitrate"]?.number
        contentLength = f["contentLength"].flatMap { $0.isNull ? nil : $0 }
        approxDurationMs = f["approxDurationMs"]?.string
        audioQuality = f["audioQuality"]?.string
        xtags = f["xtags"]?.string
        isDrc = f["isDrc"].truthy
        if let t = f["audioTrack"], t.truthy {
            audioTrack = AudioTrack(audioIsDefault: t["audioIsDefault"]?.bool, displayName: t["displayName"]?.string)
        }
    }
}

public struct ResolvedAudio: Sendable, Equatable, Codable {
    public var videoId: String
    public var client: String
    public var itag: Int
    public var mimeType: String
    public var url: String
    public var contentLength: Int
    public var durationSec: Double?
    public var title: String?
    public var channel: String?
    public var thumbnailUrl: String?
    public var userAgent: String // send with media requests
}

public enum PlayerParseResult: Sendable, Equatable {
    case audio(ResolvedAudio)
    case unplayable(status: String?, reason: String?)
}

public struct PlayabilityAttempt: Sendable, Equatable {
    public var client: String
    public var status: String?
    public var reason: String?
}

public struct PlayabilityError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let message: String
    public let attempts: [PlayabilityAttempt]
    public var description: String { message }
    public var errorDescription: String? { message }
}

private let mp4a402 = JSRegex(#"mp4a\.40\.2"#)
private let clenParam = JSRegex(#"[?&]clen=(\d+)"#)

extension YouTube {
    public static func buildPlayerRequest(client: InnertubeClient, videoId: String, visitorData: String) -> HTTPRequest {
        var ctx = client.context
        ctx["hl"] = "en"
        ctx["gl"] = "US"
        ctx["visitorData"] = .string(visitorData)
        let body: JSONValue = [
            "videoId": .string(videoId),
            "context": ["client": .object(ctx)],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        return HTTPRequest(
            url: "\(base)/youtubei/v1/player?prettyPrint=false",
            method: "POST",
            headers: [
                "content-type": "application/json",
                "user-agent": client.userAgent,
                "x-youtube-client-name": String(client.nameId),
                "x-youtube-client-version": client.clientVersion,
                "x-goog-visitor-id": visitorData,
            ],
            body: body.jsonData())
    }

    /// The audio-only format iOS decodes natively: AAC in MP4. itag 140 first,
    /// then other audio/mp4 by bitrate; skips ciphered, DRC and dubbed tracks.
    public static func pickAudioFormat(_ formats: [AdaptiveFormat]) -> AdaptiveFormat? {
        let ok = formats.filter { f in
            (f.mimeType?.hasPrefix("audio/mp4") ?? false) && f.url != nil && !f.isDrc
                && !(f.xtags ?? "").contains("drc") && (f.audioTrack.map { $0.audioIsDefault != false } ?? true)
        }
        // Stable sort by descending score (JS Array.sort is stable).
        return ok.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.first?.element
    }

    static func score(_ f: AdaptiveFormat) -> Double {
        let isAac: Double = mp4a402.test(f.mimeType ?? "") ? 1 : 0
        return (f.itag == 140 ? 1e9 : 0) + isAac * 1e8 + (f.averageBitrate ?? f.bitrate ?? 0)
    }

    public static func parsePlayerResponse(videoId: String, client: InnertubeClient, json: JSONValue) -> PlayerParseResult {
        let ps = json["playabilityStatus"]
        if ps?["status"]?.string != "OK" {
            return .unplayable(status: ps?["status"]?.string, reason: ps?["reason"]?.string ?? ps?["messages"]?[0]?.string)
        }
        let formats = (json["streamingData"]?["adaptiveFormats"]?.array ?? []).map(AdaptiveFormat.init(json:))
        guard let f = pickAudioFormat(formats), let url = f.url else {
            return .unplayable(status: "NO_FORMAT", reason: "no direct audio/mp4 format")
        }
        let vd = json["videoDetails"] ?? .object(JSONObject())
        let clen: Double
        if let c = f.contentLength {
            clen = jsNumber(c)
        } else if let m = clenParam.exec(url), let g = m.groups[1] {
            clen = jsNumber(g)
        } else {
            clen = .nan
        }
        guard clen.isFinite, clen > 0 else {
            return .unplayable(status: "NO_FORMAT", reason: "audio format has no contentLength")
        }
        let lengthSeconds = jsNumber(vd["lengthSeconds"])
        return .audio(
            ResolvedAudio(
                videoId: videoId,
                client: client.key,
                itag: f.itag,
                mimeType: f.mimeType ?? "",
                url: url,
                contentLength: Int(clen),
                durationSec: lengthSeconds.isFinite && lengthSeconds > 0 ? lengthSeconds : nil,
                title: vd["title"]?.string,
                channel: vd["author"]?.string,
                thumbnailUrl: bestThumbnail(vd["thumbnail"]?["thumbnails"]),
                userAgent: client.userAgent))
    }

    /// Tries each client in order until one returns a playable direct m4a URL.
    public static func resolveAudio(
        videoId: String, http: HTTPClient, clients: [String]? = nil, visitorData: String? = nil
    ) async throws -> ResolvedAudio {
        let vd: String
        if let visitorData { vd = visitorData } else { vd = try await getVisitorData(http) }
        var attempts: [PlayabilityAttempt] = []
        for key in clients ?? defaultClientOrder {
            guard let client = Self.clients[key] else { continue }
            do {
                let res = try await http.send(buildPlayerRequest(client: client, videoId: videoId, visitorData: vd))
                if !res.ok {
                    attempts.append(PlayabilityAttempt(client: key, status: "HTTP \(res.status)"))
                    continue
                }
                switch parsePlayerResponse(videoId: videoId, client: client, json: try res.json()) {
                case .audio(let a): return a
                case .unplayable(let status, let reason):
                    attempts.append(PlayabilityAttempt(client: key, status: status, reason: reason))
                }
            } catch {
                attempts.append(PlayabilityAttempt(client: key, status: "ERROR", reason: errorMessage(error)))
            }
        }
        let summary = attempts.map { a in
            "\(a.client): \(a.status ?? "?")\(a.reason.map { " (\($0))" } ?? "")"
        }.joined(separator: "; ")
        throw PlayabilityError(message: "YouTube: no playable audio for \(videoId). \(summary)", attempts: attempts)
    }
}

// MARK: - Download planning

public struct ByteChunk: Sendable, Equatable {
    public var start: Int // inclusive
    public var end: Int // inclusive
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

extension YouTube {
    public static func planChunks(contentLength: Int, chunkBytes: Int = YouTube.chunkBytes) -> [ByteChunk] {
        guard contentLength > 0 else { return [] }
        precondition(chunkBytes > 0, "chunkBytes must be > 0")
        return stride(from: 0, to: contentLength, by: chunkBytes).map {
            ByteChunk(start: $0, end: Swift.min($0 + chunkBytes, contentLength) - 1)
        }
    }

    /// The `range` query param (not a Range header) is what YouTube's own clients use.
    public static func chunkUrl(_ url: String, _ c: ByteChunk) -> String {
        "\(url)\(url.contains("?") ? "&" : "?")range=\(c.start)-\(c.end)"
    }

    public static func mediaHeaders(userAgent: String) -> [String: String] {
        ["user-agent": userAgent, "accept": "*/*"]
    }

    /// ISO-BMFF files (mp4/m4a) start with a box whose type is 'ftyp'.
    public static func isMp4(_ bytes: Data) -> Bool {
        let b = [UInt8](bytes.prefix(8))
        return b.count >= 8 && b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70
    }

    public static func mp4Brand(_ bytes: Data) -> String? {
        guard isMp4(bytes), bytes.count >= 12 else { return nil }
        let b = [UInt8](bytes.prefix(12))
        return String(String.UnicodeScalarView(b[8..<12].map { Unicode.Scalar($0) }))
    }
}

// MARK: - Small helpers

private let nonDigits = JSRegex("[^0-9]")

extension YouTube {
    /// "4:15" → 255, "1:02:03" → 3723.
    public static func parseClock(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.jsTrimmed.components(separatedBy: ":").map { jsNumber(nonDigits.replaceAll($0, "")) }
        if parts.isEmpty || parts.contains(where: { !$0.isFinite }) { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func textOf(_ t: JSONValue?) -> String? {
        guard let t, t.truthy else { return nil }
        if let s = t["simpleText"]?.string { return s }
        if let runs = t["runs"]?.array {
            let s = runs.map { $0["text"]?.string ?? "" }.joined()
            return s.isEmpty ? nil : s
        }
        return nil
    }

    /// Largest thumbnail; protocol-relative URLs get https, query strings dropped.
    public static func bestThumbnail(_ thumbs: JSONValue?) -> String? {
        guard let list = thumbs?.array, !list.isEmpty else { return nil }
        let area = { (t: JSONValue) -> Double in (t["width"]?.number ?? 0) * (t["height"]?.number ?? 0) }
        var best = list[0]
        for t in list.dropFirst() where area(t) > area(best) { best = t }
        let url = best["url"]?.string ?? ""
        return url.hasPrefix("//") ? "https:\(url)" : String(url.split(separator: "?", omittingEmptySubsequences: false)[0])
    }

    public struct Thumbnail: Sendable {
        public var url: String
        public var width: Double?
        public var height: Double?
        public init(url: String, width: Double? = nil, height: Double? = nil) {
            self.url = url
            self.width = width
            self.height = height
        }
    }

    public static func bestThumbnail(_ thumbs: [Thumbnail]) -> String? {
        bestThumbnail(.array(thumbs.map { t in
            var o = JSONObject()
            o["url"] = .string(t.url)
            if let w = t.width { o["width"] = .number(w) }
            if let h = t.height { o["height"] = .number(h) }
            return .object(o)
        }))
    }
}

// MARK: - Download loop (IO injected)

public protocol ChunkIO: Sendable {
    /// Fetches one byte range; must throw on non-2xx. `onBytes` reports bytes
    /// received so far for this chunk (optional, for smooth progress).
    func fetchRange(url: String, headers: [String: String], onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data
    /// Appends a verified chunk to the destination.
    func append(_ bytes: Data) async throws
}

public struct DownloadOptions: Sendable {
    public var chunkBytes: Int
    public var retries: Int // per chunk
    public var onProgress: (@Sendable (Double) -> Void)?
    public var sleep: @Sendable (_ ms: Int) async -> Void

    public init(
        chunkBytes: Int = YouTube.chunkBytes, retries: Int = 3, onProgress: (@Sendable (Double) -> Void)? = nil,
        sleep: (@Sendable (_ ms: Int) async -> Void)? = nil
    ) {
        self.chunkBytes = chunkBytes
        self.retries = retries
        self.onProgress = onProgress
        self.sleep = sleep ?? { ms in try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
    }
}

extension YouTube {
    /// Downloads `contentLength` bytes in ranged chunks, verifying each chunk's
    /// size and the ftyp box, retrying with backoff (1 s, 2 s, 4 s…). Returns
    /// the number of bytes appended.
    @discardableResult
    public static func downloadAudio(
        url: String, contentLength: Int, userAgent: String, io: ChunkIO, options: DownloadOptions = DownloadOptions()
    ) async throws -> Int {
        let plan = planChunks(contentLength: contentLength, chunkBytes: options.chunkBytes)
        let headers = mediaHeaders(userAgent: userAgent)
        var done = 0
        options.onProgress?(0)
        for c in plan {
            let want = c.end - c.start + 1
            var bytes: Data?
            var lastErr: Error?
            var attempt = 0
            while attempt <= options.retries && bytes == nil {
                if attempt > 0 { await options.sleep(1000 * (1 << (attempt - 1))) }
                do {
                    let base = done
                    let progress = options.onProgress
                    let b = try await io.fetchRange(url: chunkUrl(url, c), headers: headers) { n in
                        progress?(Swift.min(1, Double(base + n) / Double(contentLength)))
                    }
                    if b.count != want { throw SourceError("range \(c.start)-\(c.end): got \(b.count) B, want \(want)") }
                    if c.start == 0 && !isMp4(b) { throw SourceError("downloaded data is not an MP4/M4A (no ftyp box)") }
                    bytes = b
                } catch {
                    lastErr = error
                }
                attempt += 1
            }
            guard let bytes else { throw lastErr ?? SourceError("download failed") }
            try await io.append(bytes)
            done += bytes.count
            options.onProgress?(Double(done) / Double(contentLength))
        }
        return done
    }

    public static func downloadAudio(_ audio: ResolvedAudio, io: ChunkIO, options: DownloadOptions = DownloadOptions()) async throws -> Int {
        try await downloadAudio(url: audio.url, contentLength: audio.contentLength, userAgent: audio.userAgent, io: io, options: options)
    }
}

/// ChunkIO over an `HTTPClient`, writing verified chunks through `sink`
/// (e.g. a FileHandle append). Progress is reported once per chunk.
public struct HTTPChunkIO: ChunkIO {
    let http: HTTPClient
    let sink: @Sendable (Data) async throws -> Void

    public init(http: HTTPClient, sink: @escaping @Sendable (Data) async throws -> Void) {
        self.http = http
        self.sink = sink
    }

    public func fetchRange(url: String, headers: [String: String], onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        let res = try await http.send(HTTPRequest(url: url, headers: headers))
        if !res.ok { throw SourceError("HTTP \(res.status)") }
        onBytes(res.body.count)
        return res.body
    }

    public func append(_ bytes: Data) async throws { try await sink(bytes) }
}
