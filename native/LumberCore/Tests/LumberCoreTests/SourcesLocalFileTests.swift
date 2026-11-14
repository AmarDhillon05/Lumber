import Foundation
import XCTest
@testable import LumberCore

final class SourcesLocalFileTests: XCTestCase {
    func testNamesMatchTS() throws {
        let fx = try Fixture.load("sources/localfile.json")
        for c in try XCTUnwrap(fx["names"]?.array) {
            let n = c["name"]!.string!
            XCTAssertEqual(LocalFile.extensionOf(n), c["ext"]?.string, n)
            XCTAssertEqual(LocalFile.isSupportedAudioName(n), c["supported"]?.bool, n)
            XCTAssertEqual(LocalFile.titleFromFileName(n), c["title"]?.string, n)
            XCTAssertEqual(LocalFile.storedFileName(hashHex: "abcdef0123456789ffff", originalName: n), c["stored"]?.string, n)
        }
        for c in try XCTUnwrap(fx["sha256"]?.array) {
            XCTAssertEqual(SHA256Hasher.hex(Array(c["input"]!.string!.utf8)), c["hex"]?.string)
        }
    }

    func testHelpers() throws {
        XCTAssertEqual(LocalFile.extensionOf("Song.M4A"), "m4a")
        XCTAssertTrue(LocalFile.isSupportedAudioName("a.aiff"))
        XCTAssertFalse(LocalFile.isSupportedAudioName("a.flac"))
        XCTAssertEqual(LocalFile.titleFromFileName("01_Back In Black.mp3"), "01 Back In Black")
        XCTAssertEqual(LocalFile.storedFileName(hashHex: "abcdef0123456789ffff", originalName: "x.WAV"), "file-abcdef0123456789.wav")
        XCTAssertEqual(LocalFile.songId(hashHex: "abcdef0123456789ffff"), "file:abcdef0123456789")
    }

    func testStreamedFileHash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumber-hash-\(UUID().uuidString)")
        let bytes = (0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try LocalFile.sha256Hex(fileAt: url), SHA256Hasher.hex(bytes))
        // Incremental updates in odd sizes equal one-shot hashing.
        var h = SHA256Hasher()
        h.update(bytes[0..<7])
        h.update(bytes[7..<130])
        h.update(bytes[130...])
        XCTAssertEqual(h.finalize(), SHA256Hasher.hash(bytes))
    }
}
