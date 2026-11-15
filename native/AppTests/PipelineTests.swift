// Runs the app's real services (the same ones Services.live() wires up) on an
// iOS Simulator: Files import, decoding, the Blanket render for every preset,
// WAV / M4A / video export, and drum removal through ONNX Runtime. What the
// simulator can't do (mic, camera, Neural Engine, Spotify login) still needs
// the phone.
//
// The export tests check timing, not just that a file appears: a click in the
// take and a white frame in the clip are placed at the same song time, and
// must come out at the same instant in the exported file.

import AVFoundation
import XCTest
@testable import LumberNative

@MainActor
final class PipelineTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = try MediaFixtures.dir()
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func request(song: URL, take: URL) -> ProjectAudioRequest {
        ProjectAudioRequest(songURL: song, stems: nil, takeURL: take)
    }

    // MARK: Import + preview

    func testImportFileCopiesAndReadsDuration() async throws {
        let song = try MediaFixtures.song(seconds: 6, in: dir)
        let library = try MediaFixtures.dir("library-\(UUID().uuidString)")
        let imported = try await LiveSongSources().importFile(at: song, into: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.fileURL.path))
        XCTAssertEqual(imported.durationSec ?? 0, 6, accuracy: 0.05)
        XCTAssertEqual(imported.source, .file)
        // Same content → same id (re-importing doesn't duplicate the song).
        let again = try await LiveSongSources().importFile(at: song, into: library)
        XCTAssertEqual(again.id, imported.id)
    }

    func testPreviewLoadsAndRendersEveryPreset() async throws {
        let song = try MediaFixtures.song(seconds: 6, in: dir)
        let take = try MediaFixtures.take(seconds: 3, clickAt: 0.5, in: dir)
        let preview = LiveMixPreview()
        let loaded = try await preview.load(request(song: song, take: take))
        XCTAssertEqual(loaded.songDurationSec, 6, accuracy: 0.05)
        XCTAssertEqual(loaded.drumsDurationSec, 3, accuracy: 0.01)
        XCTAssertFalse(loaded.hasStems)

        // The drum lane shows the click where the offset puts it.
        let peaks = preview.peaks(.drums, start: 0, end: 6, columns: 60, drumOffsetSec: 2)
        let loudest = peaks.indices.max { peaks[$0] < peaks[$1] } ?? -1
        XCTAssertEqual(loudest, 25, "click at song 2.5 s should be in column 25 of 60 over 6 s")

        for preset in KnobCatalog.presets {
            try await preview.renderDrums(knobValues: KnobCatalog.values(for: preset))
        }
        try await preview.renderDrums(knobValues: KnobCatalog.zeroValues())
        preview.unload()
    }

    // MARK: Export

    private func exportAudio(_ format: ExportFormat, drumOffset: Double) async throws -> (URL, [[Float]]) {
        let song = try MediaFixtures.song(seconds: 8, in: dir)
        let take = try MediaFixtures.take(seconds: 3, clickAt: 0.5, in: dir)
        let r = ExportRequest(format: format, title: "Test \(format)", audio: request(song: song, take: take),
                              mix: .defaults(), drumOffsetSec: drumOffset, video: nil)
        let file = try await LiveExport().export(r) { _ in }
        let decoded = try AudioFileIO.decode(file.url, sampleRate: 48_000)
        return (file.url, decoded.channels)
    }

    func testExportWAVPlacesTheTakeAtItsOffset() async throws {
        let (url, audio) = try await exportAudio(.wav, drumOffset: 2.0)
        XCTAssertEqual(url.pathExtension, "wav")
        XCTAssertEqual(Double(audio.first?.count ?? 0) / 48_000, 8, accuracy: 0.05)
        let peak = MediaFixtures.peakTime(audio, sampleRate: 48_000)
        XCTAssertEqual(peak, 2.5, accuracy: 0.01, "click at file 0.5 s + offset 2.0 s")
        let max = audio.flatMap { $0 }.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(max, 0.9, "limited to −1 dBFS")
        XCTAssertGreaterThan(max, 0.3, "the click survived the chain")
    }

    func testExportWAVWithNegativeOffset() async throws {
        // The take started before song time 0 (recorded from the top with pre-roll).
        let (_, audio) = try await exportAudio(.wav, drumOffset: -0.3)
        XCTAssertEqual(MediaFixtures.peakTime(audio, sampleRate: 48_000), 0.2, accuracy: 0.01)
    }

    func testExportM4A() async throws {
        let (url, audio) = try await exportAudio(.m4a, drumOffset: 2.0)
        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertEqual(Double(audio.first?.count ?? 0) / 48_000, 8, accuracy: 0.1)
        let peak = MediaFixtures.peakTime(audio, sampleRate: 48_000)
        print("M4A click at \(peak) s (expected 2.5)")
        XCTAssertEqual(peak, 2.5, accuracy: 0.03)
    }

    /// Video export: the click and the flash are placed at the same song time,
    /// so they must coincide in the .mp4 (within a frame).
    private func checkVideoSync(videoOffset: Double, drumOffset: Double, expectedOut: Double, expectedLength: Double) async throws {
        let song = try MediaFixtures.song(seconds: 8, in: dir)
        let take = try MediaFixtures.take(seconds: 3, clickAt: 0.5, in: dir)
        let clip = try await MediaFixtures.flashVideo(seconds: 3, flashFrame: 30, in: dir) // flash at 1.0 s
        let r = ExportRequest(format: .video, title: "Sync test", audio: request(song: song, take: take),
                              mix: .defaults(), drumOffsetSec: drumOffset,
                              video: ExportVideoInput(url: clip, offsetSec: videoOffset))
        let file = try await LiveExport().export(r) { _ in }
        let tracksV = try await MediaFixtures.trackCount(file.url, .video)
        let tracksA = try await MediaFixtures.trackCount(file.url, .audio)
        XCTAssertEqual(tracksV, 1)
        XCTAssertEqual(tracksA, 1)
        XCTAssertEqual(file.durationSec, expectedLength, accuracy: 0.05)
        XCTAssertNotNil(file.thumbnailURL)

        let audioPeak = try await MediaFixtures.audioPeakTime(inMovie: file.url)
        let flash = try await MediaFixtures.flashTime(inMovie: file.url)
        print("video offset \(videoOffset): click at \(audioPeak) s, flash at \(flash) s, expected \(expectedOut) s")
        XCTAssertEqual(flash, expectedOut, accuracy: 0.034, "flash lands on its song time")
        XCTAssertEqual(audioPeak, expectedOut, accuracy: 0.034, "click lands on its song time")
        XCTAssertEqual(audioPeak, flash, accuracy: 0.045, "picture and sound line up within a frame")
    }

    func testVideoExportLinesUpPictureAndSound() async throws {
        // Clip starts at song 1.5 s: flash (video 1.0) and click (file 0.5 + 2.0) both at song 2.5.
        // Output starts where both exist (song 1.5), so they land at 1.0 s.
        try await checkVideoSync(videoOffset: 1.5, drumOffset: 2.0, expectedOut: 1.0, expectedLength: 3.0)
    }

    func testVideoExportWhenTheClipStartsBeforeTheSong() async throws {
        // Clip starts 0.5 s before song 0: flash at song 0.5; click at file 0.5 + 0.0.
        try await checkVideoSync(videoOffset: -0.5, drumOffset: 0.0, expectedOut: 0.5, expectedLength: 2.5)
    }

    // MARK: Drum removal

    func testDrumRemovalOnAShortClip() async throws {
        let song = try MediaFixtures.groove(seconds: 9, in: dir)
        let engine = SeparationEngine.shared
        engine.useCPUModeForTesting()
        let key = "test-\(UUID().uuidString.prefix(8))"
        let started = Date()
        let stems = try await engine.separate(songURL: song, songKey: key) { _ in }
        print("drum removal (CPU) on 9 s took \(Date().timeIntervalSince(started)) s")

        let mix = try AudioFileIO.decode(song, sampleRate: 44_100, channelCount: 2).channels
        let drums = try AudioFileIO.decode(stems.drums, sampleRate: 44_100, channelCount: 2).channels
        let rest = try AudioFileIO.decode(stems.noDrums, sampleRate: 44_100, channelCount: 2).channels
        XCTAssertEqual(drums[0].count, mix[0].count, accuracy: 64)
        XCTAssertEqual(rest[0].count, mix[0].count, accuracy: 64)
        XCTAssertFalse(drums.flatMap { $0 }.contains { !$0.isFinite }, "NaN/inf in drums")
        XCTAssertFalse(rest.flatMap { $0 }.contains { !$0.isFinite }, "NaN/inf in no-drums")

        // The stems add back up to (roughly) the song.
        let n = min(mix[0].count, drums[0].count, rest[0].count)
        var residual = [Float](repeating: 0, count: n)
        for i in 0..<n { residual[i] = drums[0][i] + rest[0][i] - mix[0][i] }
        let ratio = MediaFixtures.rms(residual) / MediaFixtures.rms(Array(mix[0][0..<n]))
        print("stem reconstruction error \(20 * log10(max(ratio, 1e-9))) dB")
        XCTAssertLessThan(ratio, 0.3)
        XCTAssertGreaterThan(MediaFixtures.rms(drums[0]), 0.005, "drums stem is silent")

        // Cached: a second call returns the same files without running again.
        let again = try await engine.separate(songURL: song, songKey: key) { _ in }
        XCTAssertEqual(again, stems)
        XCTAssertNil(engine.checkForCrash(), "a finished run leaves no crash breadcrumb")

        try? FileManager.default.removeItem(at: stems.drums.deletingLastPathComponent())
    }
}
