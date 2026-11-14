// Real-network checks, skipped unless LUMBER_LIVE=1 (never in CI):
//   LUMBER_LIVE=1 swift test --filter SourcesLiveTests

import Foundation
import XCTest
@testable import LumberCore

final class SourcesLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMBER_LIVE"] == "1", "set LUMBER_LIVE=1 for live network tests")
    }

    let http = URLSessionHTTPClient()

    func testYouTubeSearchAndResolve() async throws {
        let hits = try await YouTube.searchVideos("ac/dc back in black", http: http)
        XCTAssertGreaterThan(hits.count, 3)
        var resolved: ResolvedAudio?
        for h in hits.prefix(5) {
            if let a = try? await YouTube.resolveAudio(videoId: h.videoId, http: http) {
                resolved = a
                break
            }
        }
        let a = try XCTUnwrap(resolved, "no playable result")
        XCTAssertEqual(a.itag, 140)
        XCTAssert(a.mimeType.hasPrefix("audio/mp4"))
        // First chunk only: proves the URL downloads and is an MP4.
        let first = try await http.send(HTTPRequest(url: YouTube.chunkUrl(a.url, ByteChunk(start: 0, end: 1023)), headers: YouTube.mediaHeaders(userAgent: a.userAgent)))
        XCTAssertTrue(first.ok, "media HTTP \(first.status)")
        XCTAssertTrue(YouTube.isMp4(first.body))
    }

    func testSpotifyPageAndMatch() async throws {
        let track = try await Links.fetchSpotifyTrack(trackId: "08mG3Y1vljYA6bvDt4Wqkj", http: http) // AC/DC – Back In Black
        XCTAssertFalse(track.title.isEmpty)
        XCTAssertFalse(track.artists.isEmpty)
        let r = try await Links.findSpotifyTrackOnYouTube(track, http: http)
        XCTAssertFalse(r.results.isEmpty)
    }
}
