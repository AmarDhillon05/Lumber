// Shared helpers for the Sources* and AI* tests: fixture loading, a recording
// fake HTTP client, and Codable → JSONValue conversion for comparisons.

import Foundation
import XCTest
@testable import LumberCore

enum Fixture {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func load(_ rel: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: dir.appendingPathComponent(rel)))
    }
}

/// JSON for any Encodable (nil optionals omitted, like JSON.stringify drops undefined).
func toJSON<T: Encodable>(_ v: T) throws -> JSONValue {
    try JSONValue.parse(JSONEncoder().encode(v))
}

/// JSONValue → Data → Decodable.
func fromJSON<T: Decodable>(_ type: T.Type, _ v: JSONValue) throws -> T {
    try JSONDecoder().decode(T.self, from: v.jsonData())
}

/// Recording fake HTTP client.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest, Int) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest, Int) throws -> HTTPResponse) {
        self.handler = handler
    }

    convenience init(status: Int = 200, json: JSONValue, headers: [String: String] = [:]) {
        self.init { _, _ in HTTPResponse(status: status, headers: headers, body: json.jsonData()) }
    }

    var requests: [HTTPRequest] {
        lock.withLock { _requests }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let n = lock.withLock {
            _requests.append(request)
            return _requests.count - 1
        }
        return try handler(request, n)
    }
}

func XCTAssertJSONEqual(_ a: JSONValue?, _ b: JSONValue?, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a, b, "\(msg)\n  got:  \(a?.jsonString() ?? "nil")\n  want: \(b?.jsonString() ?? "nil")", file: file, line: line)
}

func XCTAssertClose(_ a: Double?, _ b: Double?, _ tol: Double = 1e-9, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let a, let b else {
        XCTAssertEqual(a == nil, b == nil, "\(msg): \(String(describing: a)) vs \(String(describing: b))", file: file, line: line)
        return
    }
    XCTAssert(abs(a - b) <= tol * Swift.max(1, abs(b)), "\(msg): \(a) vs \(b)", file: file, line: line)
}

func assertThrows<T>(_ f: () async throws -> T, matching: String, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await f()
        XCTFail("expected an error matching \(matching)", file: file, line: line)
    } catch {
        let m = errorMessage(error)
        XCTAssert(m.contains(matching), "wrong error: \(m) (want \(matching))", file: file, line: line)
    }
}
