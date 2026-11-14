import Foundation
import XCTest
@testable import LumberCore

final class SourcesYouTubeTests: XCTestCase {
    var fx: JSONValue!

    override func setUpWithError() throws { fx = try Fixture.load("sources/youtube.json") }

    // MARK: golden fixtures

    func testClientsMatchTS() throws {
        let list = try XCTUnwrap(fx["clients"]?.array)
        XCTAssertEqual(list.count, YouTube.clients.count)
        for c in list {
            let key = try XCTUnwrap(c["key"]?.string)
            let mine = try XCTUnwrap(YouTube.clients[key], key)
            XCTAssertEqual(Double(mine.nameId), c["nameId"]?.number)
            XCTAssertEqual(mine.userAgent, c["userAgent"]?.string)
            XCTAssertEqual(mine.context.keys, c["context"]?.object?.keys, "key order \(key)")
            XCTAssertJSONEqual(.object(mine.context), c["context"])
        }
        XCTAssertEqual(YouTube.defaultClientOrder, ["VISIONOS", "ANDROID_VR", "IOS"])
    }

    func testVisitorData() throws {
        for c in try XCTUnwrap(fx["visitorData"]?.array) {
            let input = c["input"]!.string!
            if let want = c["value"]?.string {
                XCTAssertEqual(try YouTube.parseVisitorData(input), want)
            } else {
                XCTAssertThrowsError(try YouTube.parseVisitorData(input), input)
            }
        }
    }

    func testClock() throws {
        for c in try XCTUnwrap(fx["clock"]?.array) {
            XCTAssertEqual(YouTube.parseClock(c["input"]?.string), c["expected"]?.number, c["input"]!.string!)
        }
        XCTAssertNil(YouTube.parseClock(nil))
    }

    func testChunkPlans() throws {
        for c in try XCTUnwrap(fx["chunks"]?.array) {
            let n = Int(c["contentLength"]!.number!)
            let plan = c["chunkBytes"]?.number.map { YouTube.planChunks(contentLength: n, chunkBytes: Int($0)) } ?? YouTube.planChunks(contentLength: n)
            let want = c["expected"]!.array!.map { ByteChunk(start: Int($0["start"]!.number!), end: Int($0["end"]!.number!)) }
            XCTAssertEqual(plan, want, "\(n)")
        }
        for c in try XCTUnwrap(fx["chunkUrls"]?.array) {
            let chunk = ByteChunk(start: Int(c["start"]!.number!), end: Int(c["end"]!.number!))
            XCTAssertEqual(YouTube.chunkUrl(c["url"]!.string!, chunk), c["expected"]?.string)
        }
    }

    func testThumbnails() throws {
        for c in try XCTUnwrap(fx["thumbnails"]?.array) {
            XCTAssertEqual(YouTube.bestThumbnail(c["input"]), c["expected"]?.string, c["input"]!.jsonString())
        }
    }

    func testSearchRequestBytesMatch() throws {
        let s = try XCTUnwrap(fx["searchRequest"])
        let r = YouTube.buildSearchRequest(query: s["query"]!.string!, visitorData: s["visitorData"]!.string!)
        XCTAssertEqual(r.url, s["url"]?.string)
        XCTAssertEqual(r.method, s["method"]?.string)
        XCTAssertEqual(r.headers, s["headers"]!.object!.pairs.reduce(into: [:]) { $0[$1.0] = $1.1.string! })
        XCTAssertEqual(r.bodyString, s["body"]?.string)
    }

    func testPlayerRequestBytesMatch() throws {
        for p in try XCTUnwrap(fx["playerRequests"]?.array) {
            let client = YouTube.clients[p["client"]!.string!]!
            let r = YouTube.buildPlayerRequest(client: client, videoId: p["videoId"]!.string!, visitorData: p["visitorData"]!.string!)
            XCTAssertEqual(r.url, p["url"]?.string)
            XCTAssertEqual(r.method, "POST")
            XCTAssertEqual(r.headers, p["headers"]!.object!.pairs.reduce(into: [:]) { $0[$1.0] = $1.1.string! })
            XCTAssertEqual(r.bodyString, p["body"]?.string, client.key)
        }
    }

    func testSearchResponses() throws {
        for c in try XCTUnwrap(fx["searchResponses"]?.array) {
            XCTAssertJSONEqual(try toJSON(YouTube.parseSearchResponse(c["input"]!)), c["expected"])
        }
    }

    func testPickFormat() throws {
        for c in try XCTUnwrap(fx["pickFormat"]?.array) {
            let formats = c["formats"]!.array!.map(AdaptiveFormat.init(json:))
            let f = YouTube.pickAudioFormat(formats)
            let got: JSONValue = f.map { ["itag": .number(Double($0.itag)), "url": .string($0.url!)] } ?? .null
            XCTAssertJSONEqual(got, c["expected"])
        }
    }

    func testPlayerResponses() throws {
        for c in try XCTUnwrap(fx["playerResponses"]?.array) {
            let client = YouTube.clients[c["client"]!.string!]!
            let r = YouTube.parsePlayerResponse(videoId: c["videoId"]!.string!, client: client, json: c["input"]!)
            let got: JSONValue
            switch r {
            case .audio(let a): got = try toJSON(a)
            case .unplayable(let status, let reason):
                var o = JSONObject()
                if let status { o["status"] = .string(status) }
                if let reason { o["reason"] = .string(reason) }
                got = .object(o)
            }
            XCTAssertJSONEqual(got, c["expected"], c["videoId"]!.string!)
        }
    }

    func testMp4() throws {
        for c in try XCTUnwrap(fx["mp4"]?.array) {
            let bytes = Data(c["bytes"]!.array!.map { UInt8($0.number!) })
            XCTAssertEqual(YouTube.isMp4(bytes), c["isMp4"]?.bool)
            XCTAssertEqual(YouTube.mp4Brand(bytes), c["brand"]?.string)
        }
    }

    // MARK: ports of tests/sources.test.ts

    func testParseClockBasics() {
        XCTAssertEqual(YouTube.parseClock("4:15"), 255)
        XCTAssertEqual(YouTube.parseClock("1:02:03"), 3723)
        XCTAssertEqual(YouTube.parseClock("0:07"), 7)
    }

    func testPlanChunksCoversEveryByte() {
        XCTAssertEqual(YouTube.planChunks(contentLength: 0), [])
        XCTAssertEqual(YouTube.planChunks(contentLength: 10, chunkBytes: 4), [.init(start: 0, end: 3), .init(start: 4, end: 7), .init(start: 8, end: 9)])
        let p = YouTube.planChunks(contentLength: 4_075_204)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].end, 4_075_203)
    }

    func testPickAudioFormatPrefers140() {
        let f = { (itag: Int, mime: String, o: (inout AdaptiveFormat) -> Void) -> AdaptiveFormat in
            var x = AdaptiveFormat(itag: itag, url: "https://g/v?clen=100", mimeType: mime, bitrate: 130000)
            o(&x)
            return x
        }
        let formats = [
            f(251, "audio/webm; codecs=\"opus\"") { _ in },
            f(140, "audio/mp4; codecs=\"mp4a.40.2\"") { $0.isDrc = true },
            f(140, "audio/mp4; codecs=\"mp4a.40.2\"") { $0.audioTrack = .init(audioIsDefault: false) },
            f(140, "audio/mp4; codecs=\"mp4a.40.2\"") { $0.url = "https://g/v?clen=100&ok" },
            f(139, "audio/mp4; codecs=\"mp4a.40.5\"") { $0.bitrate = 50000 },
            f(141, "audio/mp4; codecs=\"mp4a.40.2\"") { $0.url = nil; $0.signatureCipher = "s=.." },
        ]
        let best = YouTube.pickAudioFormat(formats)!
        XCTAssertEqual(best.itag, 140)
        XCTAssertEqual(best.url, "https://g/v?clen=100&ok")
        XCTAssertNil(YouTube.pickAudioFormat([formats[0]]))
        XCTAssertEqual(YouTube.pickAudioFormat([formats[4]])?.itag, 139)
    }

    actor RecordingIO: ChunkIO {
        let data: Data
        var failOnce = true
        var out = Data()
        var urls: [String] = []
        init(data: Data) { self.data = data }

        nonisolated func fetchRange(url: String, headers: [String: String], onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
            try await fetch(url: url, headers: headers)
        }

        func fetch(url: String, headers: [String: String]) throws -> Data {
            XCTAssertEqual(headers["user-agent"], "ua")
            urls.append(url)
            let m = url.range(of: #"range=(\d+)-(\d+)"#, options: .regularExpression)!
            let nums = url[m].dropFirst(6).split(separator: "-").map { Int($0)! }
            if nums[0] == 10 && failOnce {
                failOnce = false
                throw SourceError("HTTP 503")
            }
            return data.subdata(in: nums[0]..<nums[1] + 1)
        }

        func append(_ bytes: Data) { out.append(bytes) }
    }

    final class ProgressLog: @unchecked Sendable {
        let lock = NSLock()
        var values: [Double] = []
        func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    }

    func testDownloadChunkedRetriesProgressFtyp() async throws {
        var bytes = [UInt8]((0..<25).map { UInt8($0) })
        bytes.replaceSubrange(4..<8, with: [0x66, 0x74, 0x79, 0x70])
        let io = RecordingIO(data: Data(bytes))
        let progress = ProgressLog()
        let n = try await YouTube.downloadAudio(
            url: "https://g/v?x=1", contentLength: 25, userAgent: "ua", io: io,
            options: DownloadOptions(chunkBytes: 10, onProgress: { progress.add($0) }, sleep: { _ in }))
        XCTAssertEqual(n, 25)
        let out = await io.out
        XCTAssertEqual([UInt8](out), bytes)
        let urls = await io.urls
        XCTAssertEqual(urls.count, 4) // 3 chunks + 1 retry
        XCTAssertEqual(urls.first, "https://g/v?x=1&range=0-9")
        XCTAssertEqual(progress.values.last, 1)

        struct Zeros: ChunkIO {
            func fetchRange(url: String, headers: [String: String], onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data { Data(count: 8) }
            func append(_ bytes: Data) async throws {}
        }
        await assertThrows({
            try await YouTube.downloadAudio(url: "https://g/v", contentLength: 8, userAgent: "ua", io: Zeros(), options: DownloadOptions(retries: 0))
        }, matching: "ftyp")
    }

    func testDownloadBackoffSchedule() async throws {
        final class Sleeps: @unchecked Sendable {
            let lock = NSLock()
            var ms: [Int] = []
        }
        let sleeps = Sleeps()
        struct Short: ChunkIO {
            func fetchRange(url: String, headers: [String: String], onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data { Data(count: 3) }
            func append(_ bytes: Data) async throws {}
        }
        await assertThrows({
            try await YouTube.downloadAudio(
                url: "u", contentLength: 8, userAgent: "ua", io: Short(),
                options: DownloadOptions(sleep: { ms in sleeps.lock.withLock { sleeps.ms.append(ms) } }))
        }, matching: "range 0-7: got 3 B, want 8")
        XCTAssertEqual(sleeps.ms, [1000, 2000, 4000])
    }

    func testHTTPChunkIOWritesThroughSink() async throws {
        let http = FakeHTTP { req, _ in
            XCTAssertEqual(req.headers["accept"], "*/*")
            return req.url == "https://g/v?a=1&range=0-11" ? HTTPResponse(status: 200, body: Data([0, 0, 0, 0, 0x66, 0x74, 0x79, 0x70, 1, 2, 3, 4])) : HTTPResponse(status: 403)
        }
        final class Sink: @unchecked Sendable {
            var data = Data()
        }
        let sink = Sink()
        let io = HTTPChunkIO(http: http) { sink.data.append($0) }
        let n = try await YouTube.downloadAudio(url: "https://g/v?a=1", contentLength: 12, userAgent: "ua", io: io)
        XCTAssertEqual(n, 12)
        XCTAssertEqual(sink.data.count, 12)
        await assertThrows({
            try await YouTube.downloadAudio(url: "https://g/v?b", contentLength: 12, userAgent: "ua", io: io, options: DownloadOptions(retries: 0))
        }, matching: "HTTP 403")
    }

    func testResolveAudioFallsThroughClients() async throws {
        let ok: JSONValue = [
            "playabilityStatus": ["status": "OK"],
            "videoDetails": ["title": "T", "author": "A", "lengthSeconds": "200"],
            "streamingData": ["adaptiveFormats": [["itag": 140, "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"", "url": "https://g/v?clen=4000"]]],
        ]
        let http = FakeHTTP { req, _ in
            let body = try JSONValue.parse(req.body!)
            switch body["context"]?["client"]?["clientName"]?.string {
            case "VISIONOS": return HTTPResponse(status: 500)
            case "ANDROID_VR": return HTTPResponse(status: 200, body: (["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "bot"]] as JSONValue).jsonData())
            default: return HTTPResponse(status: 200, body: ok.jsonData())
            }
        }
        let a = try await YouTube.resolveAudio(videoId: "vid", http: http, visitorData: "VD")
        XCTAssertEqual(a.client, "IOS")
        XCTAssertEqual(a.contentLength, 4000)
        XCTAssertEqual(a.durationSec, 200)
        XCTAssertEqual(http.requests.map { $0.headers["x-youtube-client-name"] }, ["101", "28", "5"])

        let none = FakeHTTP { _, _ in HTTPResponse(status: 200, text: "not json") }
        do {
            _ = try await YouTube.resolveAudio(videoId: "v", http: none, clients: ["IOS", "NOPE"], visitorData: "VD")
            XCTFail("expected PlayabilityError")
        } catch let e as PlayabilityError {
            XCTAssertEqual(e.attempts.count, 1)
            XCTAssertEqual(e.attempts[0].status, "ERROR")
            XCTAssert(e.message.hasPrefix("YouTube: no playable audio for v. IOS: ERROR ("), e.message)
        }
    }

    func testSearchVideosFetchesVisitorDataFirst() async throws {
        let http = FakeHTTP { req, _ in
            if req.url.hasSuffix("/sw.js_data") {
                return HTTPResponse(status: 200, text: #")]}'[[null,null,[[[0,0,0,0,0,0,0,0,0,0,0,0,0,"VIS"]]]]]"#)
            }
            XCTAssertEqual(req.headers["x-goog-visitor-id"], "VIS")
            let vr: JSONValue = ["videoRenderer": ["videoId": "abc", "title": ["simpleText": "Song"], "lengthText": ["simpleText": "3:00"]]]
            return HTTPResponse(status: 200, body: (["contents": [vr]] as JSONValue).jsonData())
        }
        let hits = try await YouTube.searchVideos("q", http: http)
        XCTAssertEqual(hits, [VideoHit(videoId: "abc", title: "Song", durationSec: 180)])
        let bad = FakeHTTP { _, _ in HTTPResponse(status: 503) }
        await assertThrows({ try await YouTube.searchVideos("q", http: bad, visitorData: "v") }, matching: "YouTube search HTTP 503")
    }

    // MARK: JSON helpers the port relies on

    func testJSONStringifyCompat() throws {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (1, "1"), (0.1, "0.1"), (1e-7, "1e-7"), (0.000001, "0.000001"), (1e21, "1e+21"),
            (123456789012345680000, "123456789012345680000"), (1.5e300, "1.5e+300"), (-2.5e-8, "-2.5e-8"), (255.5, "255.5"),
            (5e-324, "5e-324"), (0.30000000000000004, "0.30000000000000004"),
        ]
        for (x, s) in cases { XCTAssertEqual(jsNumberString(x), s) }
        XCTAssertEqual(JSONValue.string("a\"b\\c\n\u{01}/é🥁").jsonString(), #""a\"b\\c\n\u0001/é🥁""#)
        let parsed = try JSONValue.parse(#"{"b":1,"a":[true,null,"🥁"],"b":2}"#)
        XCTAssertEqual(parsed.object?.keys, ["b", "a"])
        XCTAssertEqual(parsed.jsonString(), #"{"b":2,"a":[true,null,"🥁"]}"#)
        XCTAssertThrowsError(try JSONValue.parse("{"))
        XCTAssertEqual(jsNumber(""), 0)
        XCTAssertEqual(jsNumber(" 0x1F "), 31)
        XCTAssert(jsNumber("12abc").isNaN)
        XCTAssert(jsNumber("inf").isNaN)
        XCTAssertEqual(jsRound(-2.5), -2)
        XCTAssertEqual(jsRound(2.5), 3)
    }
}
