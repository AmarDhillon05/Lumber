import Foundation
import XCTest
@testable import LumberCore

final class SourcesLinksTests: XCTestCase {
    var fx: JSONValue!

    override func setUpWithError() throws { fx = try Fixture.load("sources/links.json") }

    static func json(_ l: ParsedLink?) -> JSONValue {
        switch l {
        case nil: return .null
        case .youtube(let id): return ["kind": "youtube", "videoId": .string(id)]
        case .spotify(let id): return ["kind": "spotify", "trackId": .string(id)]
        case .spotifyShort(let url): return ["kind": "spotify-short", "url": .string(url)]
        }
    }

    // MARK: golden fixtures

    func testParseLinkMatchesTS() throws {
        for c in try XCTUnwrap(fx["parseLink"]?.array) {
            let input = c["input"]!.string!
            XCTAssertJSONEqual(Self.json(Links.parseLink(input)), c["expected"], input)
        }
    }

    func testDecodeEntitiesMatchesTS() throws {
        for c in try XCTUnwrap(fx["decodeEntities"]?.array) {
            XCTAssertEqual(Links.decodeEntities(c["input"]!.string!), c["expected"]?.string)
        }
    }

    func testSpotifyPagesMatchTS() throws {
        for c in try XCTUnwrap(fx["spotifyPages"]?.array) {
            let id = c["trackId"]!.string!
            if let want = c["value"] {
                XCTAssertJSONEqual(try toJSON(Links.parseSpotifyTrackPage(trackId: id, html: c["html"]!.string!)), want, id)
            } else {
                XCTAssertThrowsError(try Links.parseSpotifyTrackPage(trackId: id, html: c["html"]!.string!)) {
                    XCTAssertEqual(errorMessage($0), c["error"]?.string)
                }
            }
        }
    }

    func testRankingMatchesTS() throws {
        for c in try XCTUnwrap(fx["ranking"]?.array) {
            let track = try fromJSON(SpotifyTrack.self, c["track"]!)
            let hits = try fromJSON([VideoHit].self, c["hits"]!)
            let scores = c["scores"]!.array!.map { $0.number! }
            for (h, s) in zip(hits, scores) { XCTAssertClose(Links.scoreMatch(track, h), s, 1e-12, h.videoId) }
            XCTAssertEqual(Links.rankMatches(track, hits).map(\.videoId), c["expected"]!.array!.map { $0.string! }, track.title)
        }
    }

    // MARK: ports of tests/links.test.ts

    static let page = """
        <html><head>
        <meta property="og:title" content="Don&#x27;t Stop Me Now &amp; More"/>
        <meta property="og:description" content="Queen · Jazz · Song · 1978"/>
        <meta property="og:image" content="https://i.scdn.co/image/abc"/>
        <meta name="music:duration" content="209"/>
        <meta name="music:musician_description" content="Queen, Guest Artist"/>
        </head></html>
        """

    func testLinkShapes() {
        for l in ["https://www.youtube.com/watch?v=pAgnJDJN4VA&t=10s", "youtube.com/watch?feature=share&v=pAgnJDJN4VA", "https://youtu.be/pAgnJDJN4VA?si=xyz",
                  "https://music.youtube.com/watch?v=pAgnJDJN4VA&list=RD", "https://m.youtube.com/shorts/pAgnJDJN4VA"] {
            XCTAssertEqual(Links.parseLink(l), .youtube(videoId: "pAgnJDJN4VA"), l)
        }
        for l in ["https://open.spotify.com/track/08mG3Y1vljYA6bvDt4Wqkj?si=abc", "https://open.spotify.com/intl-de/track/08mG3Y1vljYA6bvDt4Wqkj", "spotify:track:08mG3Y1vljYA6bvDt4Wqkj"] {
            XCTAssertEqual(Links.parseLink(l), .spotify(trackId: "08mG3Y1vljYA6bvDt4Wqkj"), l)
        }
        XCTAssertEqual(Links.parseLink("https://spotify.link/AbCdEf"), .spotifyShort(url: "https://spotify.link/AbCdEf"))
        XCTAssertNil(Links.parseLink("back in black"))
        XCTAssertNil(Links.parseLink("https://open.spotify.com/album/1wOhTFS4m9tbPGlKbwGaBg"))
        XCTAssertNil(Links.parseLink("https://example.com/watch?v=pAgnJDJN4VA"))
    }

    func testReadsSpotifyPage() throws {
        let t = try Links.parseSpotifyTrackPage(trackId: "id", html: Self.page)
        XCTAssertEqual(t.title, "Don't Stop Me Now & More")
        XCTAssertEqual(t.artists, ["Queen", "Guest Artist"])
        XCTAssertEqual(t.durationSec, 209)
        XCTAssertEqual(t.artworkUrl, "https://i.scdn.co/image/abc")
        XCTAssertEqual(Links.decodeEntities("&quot;a&quot; &#65;"), "\"a\" A")
    }

    static let fakeNetwork = FakeHTTP { req, _ in
        let url = req.url
        if url.contains("open.spotify.com/track/") { return HTTPResponse(status: 200, text: page) }
        if url.contains("spotify.link/") { return HTTPResponse(status: 200, text: #"<a href="https://open.spotify.com/intl-fr/track/7hQJA50XrCWABAu5v6QZ4i?si=1">"#) }
        if url.contains("sw.js_data") { return HTTPResponse(status: 200, text: #")]}'[[null,null,[[[0,0,0,0,0,0,0,0,0,0,0,0,0,"VISITOR123"]]]]]"#) }
        if url.contains("/youtubei/v1/search") {
            let vr = { (id: String, title: String, owner: String, len: String) -> JSONValue in
                ["videoRenderer": ["videoId": .string(id), "title": ["runs": [["text": .string(title)]]], "ownerText": ["runs": [["text": .string(owner)]]], "lengthText": ["simpleText": .string(len)]]]
            }
            let body: JSONValue = ["contents": [vr("a", "Don't Stop Me Now (Live)", "Queen", "3:45"), vr("b", "Queen - Don't Stop Me Now (Official Video)", "Queen Official", "3:29")]]
            return HTTPResponse(status: 200, body: body.jsonData())
        }
        if url.hasPrefix("https://www.youtube.com/oembed") {
            XCTAssertEqual(url, "https://www.youtube.com/oembed?format=json&url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DpAgnJDJN4VA")
            return HTTPResponse(status: 200, text: #"{"title":"Back In Black","author_name":"AC/DC","thumbnail_url":"https://i.ytimg.com/x.jpg"}"#)
        }
        return HTTPResponse(status: 404)
    }

    func testResolvesSpotifyLinkEndToEnd() async throws {
        let maybe = try await Links.resolveLink("https://open.spotify.com/track/7hQJA50XrCWABAu5v6QZ4i", http: Self.fakeNetwork)
        let r = try XCTUnwrap(maybe)
        XCTAssertEqual(r.label, "Spotify: Queen, Guest Artist – Don't Stop Me Now & More")
        XCTAssertEqual(r.results.first?.externalId, "b")
        XCTAssertEqual(r.results.first?.source, .youtube)
        let search = Self.fakeNetwork.requests.first { $0.url.contains("/search") }
        XCTAssertNotNil(search)
        let body = try JSONValue.parse(search!.body!)
        XCTAssertEqual(body["query"]?.string, "Queen - Don't Stop Me Now & More")
    }

    func testResolvesShortAndYouTubeLinks() async throws {
        let short = try await Links.resolveLink("https://spotify.link/AbC", http: Self.fakeNetwork)
        XCTAssertEqual(short?.results.count, 2)
        let ytMaybe = try await Links.resolveLink("https://youtu.be/pAgnJDJN4VA", http: Self.fakeNetwork)
        let yt = try XCTUnwrap(ytMaybe)
        XCTAssertEqual(yt.label, "YouTube link")
        XCTAssertEqual(yt.results, [SearchResult(externalId: "pAgnJDJN4VA", title: "Back In Black", artist: "AC/DC", artworkUrl: "https://i.ytimg.com/x.jpg", source: .youtube)])
        let none = try await Links.resolveLink("just a search", http: Self.fakeNetwork)
        XCTAssertNil(none)
        let notTrack = FakeHTTP { _, _ in HTTPResponse(status: 200, text: "<html>album</html>") }
        await assertThrows({ try await Links.resolveLink("https://spotify.link/x", http: notTrack) }, matching: "not a track")
    }
}
