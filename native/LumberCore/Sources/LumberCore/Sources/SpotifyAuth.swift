// Spotify login with Authorization Code + PKCE. Port of src/sources/spotifyAuth.ts.
// Randomness, the browser (ASWebAuthenticationSession) and token storage
// (Keychain) are injected by the app.

import Foundation

public struct SpotifyConfig: Sendable, Equatable {
    public var clientId: String
    public var redirectUri: String
    public init(clientId: String, redirectUri: String) {
        self.clientId = clientId
        self.redirectUri = redirectUri
    }

    /// The native app's registration. Public by design (PKCE apps have no
    /// secret). The redirect differs from the React Native app's
    /// `lumber://spotify-callback`: `lumbernative://spotify-callback` must be
    /// added to the app's Redirect URIs in the Spotify developer dashboard.
    public static let lumberNative = SpotifyConfig(
        clientId: "5faec3aab4e245f7a29760f019501648", redirectUri: "lumbernative://spotify-callback")
}

/// Codable with the same JSON keys the React Native app stores in the keychain.
public struct SpotifyTokens: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Double // ms since epoch
    public var scope: String

    public init(accessToken: String, refreshToken: String, expiresAt: Double, scope: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

public protocol SpotifyTokenStore: Sendable {
    func load() async throws -> SpotifyTokens?
    func save(_ tokens: SpotifyTokens) async throws
    func clear() async throws
}

public enum SpotifyAuth {
    public static let accounts = "https://accounts.spotify.com"
    public static let scopes = [
        "user-read-currently-playing",
        "user-library-read",
        "playlist-read-private",
        "playlist-read-collaborative",
    ]

    // RFC 7636 unreserved characters.
    static let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// One character per random byte (43–128 bytes).
    public static func makeVerifier(_ randomBytes: [UInt8]) throws -> String {
        guard (43...128).contains(randomBytes.count) else { throw SourceError("verifier needs 43-128 bytes") }
        return String(randomBytes.map { unreserved[Int($0) % unreserved.count] })
    }

    /// A verifier from the system RNG.
    public static func randomVerifier(bytes: Int = 64) -> String {
        var g = SystemRandomNumberGenerator()
        return try! makeVerifier((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    /// base64 → base64url without padding.
    public static func toBase64Url(_ base64: String) -> String {
        var s = base64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// S256 code challenge for a verifier.
    public static func challenge(for verifier: String) -> String {
        toBase64Url(Data(SHA256Hasher.hash(Array(verifier.utf8))).base64EncodedString())
    }

    static func form(_ params: [(String, String)]) -> String {
        params.map { "\(encodeURIComponent($0.0))=\(encodeURIComponent($0.1))" }.joined(separator: "&")
    }

    public static func buildAuthorizeUrl(_ cfg: SpotifyConfig, challenge: String, state: String) -> String {
        "\(accounts)/authorize?" + form([
            ("response_type", "code"),
            ("client_id", cfg.clientId),
            ("redirect_uri", cfg.redirectUri),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge),
            ("scope", scopes.joined(separator: " ")),
            ("state", state),
        ])
    }

    /// `<redirect>?code=...&state=...` (or `?error=access_denied`) → the code.
    public static func parseCallback(_ url: String, expectedState: String) throws -> String {
        var query = ""
        if let q = url.firstIndex(of: "?") { query = String(url[url.index(after: q)...]).components(separatedBy: "#")[0] }
        var params: [String: String] = [:]
        for kv in query.components(separatedBy: "&") {
            let parts = kv.components(separatedBy: "=")
            let k = parts[0]
            let v = parts.count > 1 ? parts[1] : ""
            if !k.isEmpty { params[try decodeURIComponent(k)] = try decodeURIComponent(v.replacingOccurrences(of: "+", with: " ")) }
        }
        if let err = params["error"], !err.isEmpty {
            throw SourceError(err == "access_denied" ? "Spotify login was cancelled" : "Spotify login failed: \(err)")
        }
        if params["state"] != expectedState { throw SourceError("Spotify login failed: state mismatch") }
        guard let code = params["code"], !code.isEmpty else { throw SourceError("Spotify login failed: no code returned") }
        return code
    }

    static func tokenRequest(_ http: HTTPClient, _ params: [(String, String)], previous: SpotifyTokens?, now: Double) async throws -> SpotifyTokens {
        let res = try await http.send(
            HTTPRequest(
                url: "\(accounts)/api/token",
                method: "POST",
                headers: ["content-type": "application/x-www-form-urlencoded"],
                body: Data(form(params).utf8)))
        let json = (try? res.json()) ?? .object(JSONObject())
        if !res.ok {
            let detail = json["error_description"]?.string ?? json["error"]?.string ?? "unknown"
            throw SourceError("Spotify token error \(res.status): \(detail)")
        }
        return SpotifyTokens(
            accessToken: json["access_token"]?.string ?? "",
            // Refresh responses may omit refresh_token; keep the old one then.
            refreshToken: json["refresh_token"]?.string ?? previous?.refreshToken ?? "",
            expiresAt: now + (json["expires_in"]?.number ?? 3600) * 1000,
            scope: json["scope"]?.string ?? previous?.scope ?? "")
    }

    public static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    public static func exchangeCode(
        _ http: HTTPClient, _ cfg: SpotifyConfig, code: String, verifier: String, now: Double = nowMs()
    ) async throws -> SpotifyTokens {
        try await tokenRequest(
            http,
            [
                ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", cfg.redirectUri),
                ("client_id", cfg.clientId), ("code_verifier", verifier),
            ],
            previous: nil, now: now)
    }

    public static func refreshTokens(_ http: HTTPClient, _ cfg: SpotifyConfig, _ tokens: SpotifyTokens, now: Double = nowMs()) async throws -> SpotifyTokens {
        try await tokenRequest(
            http, [("grant_type", "refresh_token"), ("refresh_token", tokens.refreshToken), ("client_id", cfg.clientId)],
            previous: tokens, now: now)
    }
}

/// Hands out a valid access token, refreshing a minute before expiry
/// (concurrent callers share one refresh). A refresh Spotify rejects with 400
/// (revoked access) clears the store so the UI asks to connect again.
public actor SpotifySession {
    private let http: HTTPClient
    private let cfg: SpotifyConfig
    private let store: SpotifyTokenStore
    private let now: @Sendable () -> Double
    private var refreshing: Task<SpotifyTokens, Error>?

    public init(http: HTTPClient, config: SpotifyConfig, store: SpotifyTokenStore, now: @escaping @Sendable () -> Double = { SpotifyAuth.nowMs() }) {
        self.http = http
        self.cfg = config
        self.store = store
        self.now = now
    }

    public func connected() async throws -> Bool { try await store.load() != nil }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = try await store.load() else { throw SourceError("Not connected to Spotify") }
        if !forceRefresh && tokens.expiresAt - 60_000 > now() { return tokens.accessToken }
        let task: Task<SpotifyTokens, Error>
        if let r = refreshing {
            task = r
        } else {
            let (http, cfg, store, t0) = (http, cfg, store, now())
            task = Task {
                do {
                    let t = try await SpotifyAuth.refreshTokens(http, cfg, tokens, now: t0)
                    try await store.save(t)
                    return t
                } catch {
                    if errorMessage(error).contains("token error 400") { try? await store.clear() }
                    throw error
                }
            }
            refreshing = task
        }
        defer { if refreshing == task { refreshing = nil } }
        return try await task.value.accessToken
    }
}
