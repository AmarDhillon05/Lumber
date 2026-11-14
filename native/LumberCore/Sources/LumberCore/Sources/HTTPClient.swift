// Network access for song sources and the Claude call, behind a protocol so
// all request building / response handling is testable with fakes on Linux.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Equatable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// Overall timeout in seconds (nil: the client's default).
    public var timeout: Double?

    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: Double? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    public var bodyString: String? { body.map { String(decoding: $0, as: UTF8.self) } }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
        self.body = body
    }

    public init(status: Int, headers: [String: String] = [:], text: String) {
        self.init(status: status, headers: headers, body: Data(text.utf8))
    }

    /// `res.ok`
    public var ok: Bool { status >= 200 && status < 300 }
    /// `res.text()`
    public var text: String { String(decoding: body, as: UTF8.self) }
    /// `res.json()`
    public func json() throws -> JSONValue { try JSONValue.parse(body) }
}

/// Transport-level failure (no HTTP response).
public enum HTTPTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case timedOut
    case failed(String)

    public var description: String {
        switch self {
        case .timedOut: return "The request timed out"
        case .failed(let m): return m
        }
    }
}

public protocol HTTPClient: Sendable {
    /// Sends one request. Non-2xx statuses are returned, not thrown; transport
    /// failures throw (preferably `HTTPTransportError`).
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// `URLSession`-backed client (iOS and Linux).
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let defaultTimeout: Double

    public init(session: URLSession = .shared, defaultTimeout: Double = 60) {
        self.session = session
        self.defaultTimeout = defaultTimeout
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else { throw HTTPTransportError.failed("Bad URL: \(request.url)") }
        var r = URLRequest(url: url)
        r.httpMethod = request.method
        r.timeoutInterval = request.timeout ?? defaultTimeout
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = request.body
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: r) { data, response, error in
                    if let error {
                        let ns = error as NSError
                        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut {
                            cont.resume(throwing: HTTPTransportError.timedOut)
                        } else if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
                            cont.resume(throwing: CancellationError())
                        } else {
                            cont.resume(throwing: HTTPTransportError.failed(error.localizedDescription))
                        }
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        cont.resume(throwing: HTTPTransportError.failed("No HTTP response"))
                        return
                    }
                    var headers: [String: String] = [:]
                    for (k, v) in http.allHeaderFields {
                        if let k = k as? String { headers[k.lowercased()] = "\(v)" }
                    }
                    cont.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ t: URLSessionTask) {
        lock.lock()
        task = t
        let c = cancelled
        lock.unlock()
        if c { t.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

/// An error with a user-facing message (the TS code's `new Error(message)`).
public struct SourceError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// `String(e.message ?? e)` for any error.
func errorMessage(_ e: Error) -> String {
    if let l = e as? LocalizedError, let d = l.errorDescription { return d }
    return String(describing: e)
}
