import Foundation
import XCTest
@testable import LumberCore

actor MemoryTokenStore: SpotifyTokenStore {
    var value: SpotifyTokens?
    init(_ v: SpotifyTokens?) { value = v }
    func load() async throws -> SpotifyTokens? { value }
    func save(_ tokens: SpotifyTokens) async throws { value = tokens }
    func clear() async throws { value = nil }
}

final class SourcesSpotifyTests: XCTestCase {
    var fx: JSONValue!
    let cfg = SpotifyConfig.lumberNative

    override func setUpWithError() throws { fx = try Fixture.load("sources/spotify.json") }

    // MARK: golden fixtures

    func testConfig() throws {
        XCTAssertEqual(cfg.clientId, fx["config"]?["clientId"]?.string)
        XCTAssertEqual(cfg.redirectUri, "lumbernative://spotify-callback")
    }

    func testVerifiersAndChallenges() throws {
        for c in try XCTUnwrap(fx["verifiers"]?.array) {
            let bytes = c["bytes"]!.array!.map { UInt8($0.number!) }
            if let want = c["value"]?.string {
                XCTAssertEqual(try SpotifyAuth.makeVerifier(bytes), want)
            } else {
                XCTAssertThrowsError(try SpotifyAuth.makeVerifier(bytes))
            }
        }
        for c in try XCTUnwrap(fx["challenges"]?.array) {
            XCTAssertEqual(SpotifyAuth.challenge(for: c["verifier"]!.string!), c["challenge"]?.string)
        }
        // RFC 7636 appendix B.
        XCTAssertEqual(SpotifyAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizeUrl() throws {
        let a = try XCTUnwrap(fx["authorizeUrl"])
        XCTAssertEqual(SpotifyAuth.buildAuthorizeUrl(cfg, challenge: a["challenge"]!.string!, state: a["state"]!.string!), a["expected"]?.string)
    }

    func testCallbacks() throws {
        for c in try XCTUnwrap(fx["callbacks"]?.array) {
            let url = c["url"]!.string!, state = c["state"]!.string!
            if let want = c["value"]?.string {
                XCTAssertEqual(try SpotifyAuth.parseCallback(url, expectedState: state), want, url)
            } else {
                XCTAssertThrowsError(try SpotifyAuth.parseCallback(url, expectedState: state)) { XCTAssertEqual(errorMessage($0), c["error"]?.string, url) }
            }
        }
    }

    func testTokenRequests() async throws {
        let prev = SpotifyTokens(accessToken: "old", refreshToken: "r1", expiresAt: 5, scope: "prev-scope")
        for c in try XCTUnwrap(fx["tokens"]?.array) {
            let name = c["name"]!.string!
            let status = Int(c["status"]!.number!), body = c["body"]!.string!
            let http = FakeHTTP { _, _ in HTTPResponse(status: status, text: body) }
            let result: Result<SpotifyTokens, Error>
            do {
                switch name {
                case "exchange": result = .success(try await SpotifyAuth.exchangeCode(http, cfg, code: "CODE/+=", verifier: "VER~._-", now: 1000))
                case "exchange-defaults": result = .success(try await SpotifyAuth.exchangeCode(http, cfg, code: "C", verifier: "V", now: 1000))
                default: result = .success(try await SpotifyAuth.refreshTokens(http, cfg, prev, now: 2000))
                }
            } catch {
                result = .failure(error)
            }
            let req = try XCTUnwrap(http.requests.first)
            let want = c["request"]!
            XCTAssertEqual(req.url, want["url"]?.string)
            XCTAssertEqual(req.method, want["method"]?.string)
            XCTAssertEqual(req.headers, ["content-type": "application/x-www-form-urlencoded"])
            XCTAssertEqual(req.bodyString, want["body"]?.string, name)
            switch result {
            case .success(let t): XCTAssertJSONEqual(try toJSON(t), c["value"], name)
            case .failure(let e): XCTAssertEqual(errorMessage(e), c["error"]?.string, name)
            }
        }
    }

    func testToTrack() throws {
        for c in try XCTUnwrap(fx["toTrack"]?.array) {
            let got = try SpotifyAPI.toTrack(c["input"]).map(toJSON) ?? .null
            XCTAssertJSONEqual(got, c["expected"], c["input"]!.jsonString())
        }
    }

    func testPages() async throws {
        for c in try XCTUnwrap(fx["pages"]?.array) {
            let http = FakeHTTP(json: c["body"]!)
            let api = SpotifyAPI(http: http) { _ in "T" }
            let offset = Int(c["offset"]?.number ?? 0)
            let got: JSONValue
            func pageJSON<T: Encodable>(_ p: SpotifyPage<T>) throws -> JSONValue {
                ["items": try toJSON(p.items), "next": p.next.map { .number(Double($0)) } ?? .null]
            }
            switch c["kind"]!.string! {
            case "playlistTracks": got = try pageJSON(try await api.playlistTracks(c["id"]!.string!, offset: offset))
            case "likedTracks": got = try pageJSON(try await api.likedTracks(offset: offset))
            case "playlists": got = try pageJSON(try await api.playlists(offset: offset))
            default: got = try await api.currentlyPlaying().map(toJSON) ?? .null
            }
            XCTAssertJSONEqual(got, c["expected"], c["kind"]!.string!)
            XCTAssertEqual(http.requests.first?.url, c["url"]?.string)
            XCTAssertEqual(http.requests.first?.headers["authorization"], "Bearer T")
        }
    }

    // MARK: ports of tests/spotify.test.ts

    func testVerifierAlphabet() throws {
        let v = try SpotifyAuth.makeVerifier((0..<64).map { UInt8($0 * 4) })
        XCTAssertEqual(v.count, 64)
        XCTAssertNotNil(v.range(of: #"^[A-Za-z0-9\-._~]+$"#, options: .regularExpression))
        XCTAssertEqual(SpotifyAuth.randomVerifier().count, 64)
    }

    func testAuthorizeUrlComponents() throws {
        let u = try XCTUnwrap(URLComponents(string: SpotifyAuth.buildAuthorizeUrl(cfg, challenge: "CHAL", state: "STATE")))
        XCTAssertEqual(u.host, "accounts.spotify.com")
        XCTAssertEqual(u.path, "/authorize")
        let q = Dictionary(uniqueKeysWithValues: (u.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], cfg.clientId)
        XCTAssertEqual(q["redirect_uri"], "lumbernative://spotify-callback")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], "CHAL")
        XCTAssertEqual(q["state"], "STATE")
        XCTAssert(q["scope"]!.contains("user-read-currently-playing"))
    }

    func testCallbackParsing() {
        XCTAssertEqual(try SpotifyAuth.parseCallback("lumbernative://spotify-callback?code=abc%2B1&state=S", expectedState: "S"), "abc+1")
        XCTAssertThrowsError(try SpotifyAuth.parseCallback("x?error=access_denied&state=S", expectedState: "S")) { XCTAssert(errorMessage($0).contains("cancelled")) }
        XCTAssertThrowsError(try SpotifyAuth.parseCallback("x?code=x&state=EVIL", expectedState: "S")) { XCTAssert(errorMessage($0).contains("state mismatch")) }
    }

    func testCodeExchangeSendsNoSecret() async throws {
        let http = FakeHTTP(json: ["access_token": "A", "refresh_token": "R", "expires_in": 3600, "scope": "s"])
        let t = try await SpotifyAuth.exchangeCode(http, cfg, code: "CODE", verifier: "VER", now: 1000)
        XCTAssertEqual(t, SpotifyTokens(accessToken: "A", refreshToken: "R", expiresAt: 1000 + 3_600_000, scope: "s"))
        let body = http.requests[0].bodyString!
        XCTAssert(body.contains("code_verifier=VER") && body.contains("grant_type=authorization_code"), body)
        XCTAssertFalse(body.contains("secret"))
    }

    func testSessionRefreshesNearExpiry() async throws {
        let store = MemoryTokenStore(SpotifyTokens(accessToken: "old", refreshToken: "r1", expiresAt: 1_000_000 + 30_000, scope: "s"))
        let http = FakeHTTP(json: ["access_token": "new", "expires_in": 3600])
        let s = SpotifySession(http: http, config: cfg, store: store, now: { 1_000_000 })
        let first = try await s.accessToken()
        XCTAssertEqual(first, "new")
        let saved = await store.value
        XCTAssertEqual(saved?.refreshToken, "r1")
        let second = try await s.accessToken() // now fresh: no second refresh
        XCTAssertEqual(second, "new")
        XCTAssertEqual(http.requests.count, 1)
        let forced = try await s.accessToken(forceRefresh: true)
        XCTAssertEqual(forced, "new")
        XCTAssertEqual(http.requests.count, 2)
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let store = MemoryTokenStore(SpotifyTokens(accessToken: "old", refreshToken: "r1", expiresAt: 0, scope: ""))
        let http = FakeHTTP { _, _ in
            Thread.sleep(forTimeInterval: 0.05)
            return HTTPResponse(status: 200, text: #"{"access_token":"new","expires_in":3600}"#)
        }
        let s = SpotifySession(http: http, config: cfg, store: store, now: { 1 })
        async let a = s.accessToken()
        async let b = s.accessToken()
        let (x, y) = try await (a, b)
        XCTAssertEqual([x, y], ["new", "new"])
        XCTAssertEqual(http.requests.count, 1)
    }

    func testRevokedRefreshClearsSession() async throws {
        let store = MemoryTokenStore(SpotifyTokens(accessToken: "old", refreshToken: "r1", expiresAt: 0, scope: "s"))
        let http = FakeHTTP(status: 400, json: ["error": "invalid_grant"])
        let s = SpotifySession(http: http, config: cfg, store: store, now: { 1 })
        await assertThrows({ try await s.accessToken() }, matching: "token error 400")
        let v = await store.value
        XCTAssertNil(v)
        await assertThrows({ try await s.accessToken() }, matching: "Not connected to Spotify")
        let connected = try await s.connected()
        XCTAssertFalse(connected)
    }

    func testServerErrorKeepsSession() async throws {
        let store = MemoryTokenStore(SpotifyTokens(accessToken: "old", refreshToken: "r1", expiresAt: 0, scope: "s"))
        let s = SpotifySession(http: FakeHTTP(status: 503, json: [:]), config: cfg, store: store, now: { 1 })
        await assertThrows({ try await s.accessToken() }, matching: "token error 503")
        let v = await store.value
        XCTAssertNotNil(v)
    }

    func testApiNothingPlayingPodcastAndTrack() async throws {
        let api204 = SpotifyAPI(http: FakeHTTP { _, _ in HTTPResponse(status: 204) }) { _ in "T" }
        let none = try await api204.currentlyPlaying()
        XCTAssertNil(none)
        let ep = SpotifyAPI(http: FakeHTTP(json: ["item": ["type": "episode", "id": "e"]])) { _ in "T" }
        let pod = try await ep.currentlyPlaying()
        XCTAssertNil(pod)
        let tr = SpotifyAPI(http: FakeHTTP(json: ["item": ["type": "track", "id": "x", "name": "Song", "artists": [["name": "A"], ["name": "B"]], "duration_ms": 204_500, "album": ["images": [["url": "img"]]]]])) { _ in "T" }
        let t = try await tr.currentlyPlaying()
        XCTAssertEqual(t, SpotifyTrack(trackId: "x", title: "Song", artists: ["A", "B"], durationSec: 205, artworkUrl: "img"))
    }

    func testApiRetriesOnceOn401() async throws {
        let http = FakeHTTP { _, n in n == 0 ? HTTPResponse(status: 401) : HTTPResponse(status: 200, text: #"{"items":[],"next":null}"#) }
        let api = SpotifyAPI(http: http) { force in force ? "fresh" : "stale" }
        _ = try await api.likedTracks()
        XCTAssertEqual(http.requests.map { $0.headers["authorization"] }, ["Bearer stale", "Bearer fresh"])
        let always401 = SpotifyAPI(http: FakeHTTP { _, _ in HTTPResponse(status: 401) }) { _ in "T" }
        await assertThrows({ try await always401.likedTracks() }, matching: "Spotify API 401 for /me/tracks")
    }

    func testApiErrorMessages() async throws {
        let forbidden = SpotifyAPI(http: FakeHTTP { _, _ in HTTPResponse(status: 403) }) { _ in "T" }
        await assertThrows({ try await forbidden.playlistTracks("x") }, matching: "your own playlists")
        let limited = SpotifyAPI(http: FakeHTTP { _, _ in HTTPResponse(status: 429) }) { _ in "T" }
        await assertThrows({ try await limited.playlists() }, matching: "rate limit")
    }

    func testTokensCodableMatchesRNKeychainFormat() throws {
        let raw = #"{"accessToken":"a","refreshToken":"r","expiresAt":1767225600000,"scope":"s"}"#
        let t = try JSONDecoder().decode(SpotifyTokens.self, from: Data(raw.utf8))
        XCTAssertEqual(t.expiresAt, 1_767_225_600_000)
    }
}
