// Linux tests for the app's own logic: the timing math in
// Platform/TakeClock.swift and the State layer (AppModel with mock services).
// Both are Foundation-only, so they compile here without Xcode:
//
//   native/AppLogicTests/run.sh
//
// Exits non-zero when a check fails. CI runs it in the Linux job.

import Foundation

// MARK: - Tiny harness

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ ok: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("  ✘ line \(line): \(message())")
    }
}

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9, _ what: String, line: Int = #line) {
    check(abs(a - b) <= tol, "\(what): \(a) vs \(b) (tol \(tol))", line: line)
}

func test(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch {
        failures += 1
        print("  ✘ threw \(error)")
    }
}

@MainActor
func testAsync(_ name: String, _ body: @MainActor () async throws -> Void) async {
    print("• \(name)")
    do { try await body() } catch {
        failures += 1
        print("  ✘ threw \(error)")
    }
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("applogic-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

// MARK: - Latency split

test("latency split: parts add up, residual counted once on the output side") {
    for (out, inp, res) in [(0.005, 0.002, 0.0), (0.18, 0.01, 40.0), (0.02, 0.01, -5.0), (0.15, 0.012, 120.0)] {
        let total = LatencyMath.compensationSec(reportedOutputSec: out, reportedInputSec: inp, residualMs: res)
        let p = LatencyMath.split(reportedOutputSec: out, reportedInputSec: inp, residualMs: res)
        near(p.outputSec + p.inputSec, total, 1e-12, "sum")
        near(p.inputSec, inp, 1e-12, "input is the reported input")
        near(p.outputSec, out + res / 1000, 1e-12, "output = reported + residual")
    }
}

test("latency split: never negative") {
    let p = LatencyMath.split(reportedOutputSec: 0.01, reportedInputSec: 0.01, residualMs: -50)
    check(p.outputSec >= 0 && p.inputSec >= 0, "negative part \(p)")
    near(p.outputSec + p.inputSec, 0, 1e-12, "clamped to 0")
}

// MARK: - Simulated take: one hit, seen by the mic and the camera

/// A drummer hits at song time `hitSong`. Everything below is what the
/// hardware would stamp; the app's formulas must put the hit back at `hitSong`
/// in both the drum file and the video.
func simulateTake(
    reportedOut: Double, reportedIn: Double, residualMs: Double,
    songStartSec: Double, hitSong: Double, preRoll: Double, videoLead: Double
) -> (drumHitSong: Double, videoHitSong: Double, stateVideoHitSong: Double) {
    let H_s = 5000.0 // host time the song sample at songStartSec is rendered
    // True delays: what iOS reports, plus what calibration found on top (output side).
    let trueOut = reportedOut + residualMs / 1000
    let trueIn = reportedIn
    // The drummer hears song time s at H_s + (s − songStartSec) + trueOut and hits then.
    let hitHost = H_s + (hitSong - songStartSec) + trueOut
    // Mic: the hit is stamped trueIn later. The file started before the count-in.
    let fileStart = H_s - preRoll
    let hitFile = hitHost + trueIn - fileStart
    // Camera: frames carry capture time. The clip started a bit before the song.
    let videoStart = H_s - videoLead
    let hitVideo = hitHost - videoStart

    let parts = LatencyMath.split(reportedOutputSec: reportedOut, reportedInputSec: reportedIn, residualMs: residualMs)
    let drumOffset = TakeClock.drumOffset(
        songStartSec: songStartSec, songStartHostSec: H_s, fileStartHostSec: fileStart,
        latencySec: parts.outputSec + parts.inputSec
    )
    let videoOffset = TakeClock.videoOffset(
        songStartSec: songStartSec, songStartHostSec: H_s, videoStartHostSec: videoStart,
        outputLatencySec: parts.outputSec
    )
    // The State layer's copy (what finishTake stores), fed the engine's timing as is.
    let timing = TransportTiming(songStartSec: songStartSec, songStartHostTime: H_s, outputLatencySec: parts.outputSec)
    let stateOffset = timing.videoOffset(videoStartHostTime: videoStart)
    return (drumOffset + hitFile, videoOffset + hitVideo, stateOffset + hitVideo)
}

test("sync: wired, Bluetooth and negative-residual routes put the hit back where it was played") {
    let routes: [(String, Double, Double, Double)] = [
        ("wired", 0.004, 0.002, 1.5),
        ("AirPods", 0.160, 0.010, 45),
        ("over-reported", 0.030, 0.010, -12),
    ]
    for (name, out, inp, res) in routes {
        for hit in [12.25, 31.0, 47.75] {
            let r = simulateTake(reportedOut: out, reportedIn: inp, residualMs: res,
                                 songStartSec: 10, hitSong: hit, preRoll: 2.3, videoLead: 0.9)
            near(r.drumHitSong, hit, 1e-9, "\(name) drum hit")
            near(r.videoHitSong, hit, 1e-9, "\(name) video hit (TakeClock)")
            near(r.stateVideoHitSong, hit, 1e-9, "\(name) video hit (State)")
        }
    }
}

test("sync: State's videoOffset matches TakeClock for arbitrary inputs") {
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<200 {
        let s = Double.random(in: 0...300, using: &rng)
        let h = Double.random(in: 1000...90000, using: &rng)
        let v = h + Double.random(in: -5...5, using: &rng)
        let o = Double.random(in: 0...0.4, using: &rng)
        let a = TransportTiming(songStartSec: s, songStartHostTime: h, outputLatencySec: o).videoOffset(videoStartHostTime: v)
        let b = TakeClock.videoOffset(songStartSec: s, songStartHostSec: h, videoStartHostSec: v, outputLatencySec: o)
        near(a, b, 1e-9, "offset")
    }
}

// MARK: - AppModel with mock services

/// Export stand-in that records the request it was given.
@MainActor
final class CapturingExport: ExportService {
    var last: ExportRequest?
    func export(_ request: ExportRequest, progress: @escaping ProgressHandler) async throws -> ExportedFile {
        last = request
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).bin")
        try Data([1, 2, 3]).write(to: url)
        return ExportedFile(url: url, durationSec: 1, thumbnailURL: nil)
    }
}

/// Auto mix stand-in returning a fixed result and recording the request.
@MainActor
final class FixedAutoMix: AutoMixService {
    var result: AutoMixResult
    var last: AutoMixRequest?
    init(_ result: AutoMixResult) { self.result = result }
    func run(_ request: AutoMixRequest) async throws -> AutoMixResult {
        last = request
        return result
    }
}

@MainActor
func makeModel(export: any ExportService = MockExportService(),
               autoMix: any AutoMixService = MockAutoMixService()) -> (AppModel, URL) {
    let docs = tempDir()
    let m = Services.mock()
    let services = Services(
        sources: m.sources, spotify: m.spotify, audio: m.audio, camera: m.camera, preview: m.preview,
        separation: m.separation, promptMix: m.promptMix, autoMix: autoMix, export: export, photos: m.photos
    )
    return (AppModel(services: services, files: DocumentStore(documents: docs)), docs)
}

@MainActor
func addSongAndTake(_ model: AppModel, docs: URL, timing: TransportTiming?, clipStart: Double?) throws -> Project {
    let songFile = model.files.dir(.songs).appendingPathComponent("song.wav")
    try SilentWav.write(to: songFile, seconds: 2, sampleRate: 48_000)
    model.addSong(ImportedSong(id: "file:test", title: "Test song", artist: nil, durationSec: 2,
                               artworkUrl: nil, source: .file, fileURL: songFile))
    let drums = docs.appendingPathComponent("drums.wav")
    try SilentWav.write(to: drums, seconds: 1, sampleRate: 48_000)
    let clipURL = docs.appendingPathComponent("clip.mov")
    try Data([0]).write(to: clipURL)
    let recorded = RecordedTake(drumsURL: drums, songStartSec: 10, drumOffsetSec: 8.123,
                                latencyMs: 25, sampleRate: 48_000, durationSec: 1)
    let clip = CameraClip(url: clipURL, startHostTime: clipStart, durationSec: 30, facing: .front)
    try model.finishTake(songId: "file:test", recorded: recorded, clip: clip, timing: timing)
    guard let project = model.projects.first else { throw ServiceError.failed("no project created") }
    return project
}

await testAsync("finishTake stores the video offset from the engine timing, latency included") {
    let (model, docs) = makeModel()
    let timing = TransportTiming(songStartSec: 10, songStartHostTime: 5000, outputLatencySec: 0.205)
    let project = try addSongAndTake(model, docs: docs, timing: timing, clipStart: 4999.25)
    guard let take = model.take(project.takeId) else { return check(false, "take missing") }
    near(take.drumOffsetSec, 8.123, 1e-12, "drum offset kept as recorded")
    guard let v = take.video else { return check(false, "video missing") }
    let expected = TakeClock.videoOffset(songStartSec: 10, songStartHostSec: 5000, videoStartHostSec: 4999.25,
                                         outputLatencySec: 0.205)
    near(v.offsetSec, expected, 1e-9, "video offset")
    near(v.offsetSec, 10 - 0.75 - 0.205, 1e-9, "video offset by hand")
    check(FileManager.default.fileExists(atPath: model.url(v.uri).path), "clip moved into lumber/videos")
    check(model.url(v.uri).path.contains("/lumber/videos/"), "clip folder \(v.uri)")
    check(FileManager.default.fileExists(atPath: model.url(take.drumsUri).path), "drums moved into lumber/takes")
}

await testAsync("finishTake drops a clip it can't place (no timing or no start time)") {
    for (timing, start) in [(nil, 4999.0), (TransportTiming(songStartSec: 0, songStartHostTime: 1), nil)] as [(TransportTiming?, Double?)] {
        let (model, docs) = makeModel()
        let project = try addSongAndTake(model, docs: docs, timing: timing, clipStart: start)
        check(model.take(project.takeId)?.video == nil, "unplaceable clip was kept")
        check(!FileManager.default.fileExists(atPath: docs.appendingPathComponent("clip.mov").path), "clip file not cleaned up")
    }
}

await testAsync("export: audio and video nudges reach the export request") {
    let export = CapturingExport()
    let (model, docs) = makeModel(export: export)
    let timing = TransportTiming(songStartSec: 10, songStartHostTime: 5000, outputLatencySec: 0.1)
    let project = try addSongAndTake(model, docs: docs, timing: timing, clipStart: 4999.5)
    model.updateMix(project.id) {
        $0.nudgeMs = 12
        $0.videoNudgeMs = -66
    }
    _ = try await model.exportMix(.video, projectId: project.id) { _ in }
    guard let r = export.last, let take = model.take(project.takeId), let v = take.video else {
        return check(false, "no export request")
    }
    near(r.drumOffsetSec, 8.123 + 0.012, 1e-9, "drum offset + nudge")
    near(r.video?.offsetSec ?? .nan, v.offsetSec - 0.066, 1e-9, "video offset + video nudge")
    check(r.format == .video, "format")
    check(r.audio.stems == nil, "no stems yet")

    _ = try await model.exportMix(.wav, projectId: project.id) { _ in }
    check(export.last?.video == nil, "audio export carries no video")
    check(model.recordings.count == 2, "both exports saved to Recordings (\(model.recordings.count))")
}

await testAsync("export: stems switch the bed to the drumless stem") {
    let export = CapturingExport()
    let (model, docs) = makeModel(export: export)
    let project = try addSongAndTake(model, docs: docs, timing: nil, clipStart: nil)
    let stems = model.files.dir(.stems)
    let d = stems.appendingPathComponent("drums.wav"), n = stems.appendingPathComponent("no_drums.wav")
    try SilentWav.write(to: d, seconds: 2, sampleRate: 44_100)
    try SilentWav.write(to: n, seconds: 2, sampleRate: 44_100)
    model.setStems("file:test", SeparationOutput(drumsURL: d, noDrumsURL: n, sampleRate: 44_100))
    _ = try await model.exportMix(.wav, projectId: project.id) { _ in }
    check(export.last?.audio.bedURL.lastPathComponent == "no_drums.wav", "bed is \(export.last?.audio.bedURL.lastPathComponent ?? "nil")")
}

// MARK: - Auto mix in Edit

await testAsync("auto mix: applies nudge, knobs and faders as one undoable change") {
    var knobs = KnobCatalog.zeroValues()
    knobs["brightness"] = 0.4
    let fake = FixedAutoMix(AutoMixResult(nudgeDeltaMs: 37.4, values: knobs, songGain: 0.62, drumGain: 1.3,
                                          notes: ["Moved the drums +37 ms"]))
    let (model, docs) = makeModel(autoMix: fake)
    let project = try addSongAndTake(model, docs: docs, timing: nil, clipStart: nil)
    model.updateMix(project.id) {
        $0.nudgeMs = 5
        $0.presetId = "warm"
    }
    let session = EditSession(projectId: project.id, model: model)
    await session.autoMix([.align, .tone, .level])

    near(fake.last?.drumOffsetSec ?? .nan, 8.123 + 0.005, 1e-9, "request uses the current offset incl. nudge")
    check(fake.last?.steps == [.align, .tone, .level], "steps passed through")
    guard let mix = model.project(project.id)?.mix else { return check(false, "project missing") }
    near(mix.nudgeMs, 42, 1e-9, "nudge 5 + 37.4, rounded to whole ms")
    near(mix.values["brightness"] ?? .nan, 0.4, 1e-12, "knobs applied")
    check(mix.values.count == KnobCatalog.zeroValues().count, "knob map filled")
    check(mix.presetId == nil, "preset cleared by tone change")
    near(mix.songGain, 0.62, 1e-12, "song gain")
    near(mix.drumGain, 1.3, 1e-12, "drum gain")
    check(session.autoMixNotes == ["Moved the drums +37 ms"], "notes shown: \(session.autoMixNotes)")
    check(session.undoCount == 1, "one undo step")

    session.undo()
    guard let back = model.project(project.id)?.mix else { return check(false, "project missing") }
    near(back.nudgeMs, 5, 1e-12, "undo restores the nudge")
    check(back.presetId == "warm", "undo restores the preset")
    near(back.values["brightness"] ?? .nan, 0, 1e-12, "undo restores knobs")
    near(back.songGain, 0.8, 1e-12, "undo restores song gain")
}

await testAsync("auto mix: a correction beyond the nudge range is clamped and explained") {
    let fake = FixedAutoMix(AutoMixResult(nudgeDeltaMs: 420, values: nil, songGain: nil, drumGain: nil, notes: []))
    let (model, docs) = makeModel(autoMix: fake)
    let project = try addSongAndTake(model, docs: docs, timing: nil, clipStart: nil)
    let session = EditSession(projectId: project.id, model: model)
    await session.autoMix([.align])
    near(model.project(project.id)?.mix.nudgeMs ?? .nan, EditSession.nudgeRangeMs, 1e-12, "clamped")
    check(session.autoMixNotes.contains { $0.contains("calibration") }, "explains the clamp")
    near(model.project(project.id)?.mix.songGain ?? .nan, 0.8, 1e-12, "faders untouched when level didn't run")
}

await testAsync("auto mix: a failure changes nothing and shows the error") {
    let (model, docs) = makeModel() // the mock throws
    let project = try addSongAndTake(model, docs: docs, timing: nil, clipStart: nil)
    let session = EditSession(projectId: project.id, model: model)
    let before = model.project(project.id)?.mix
    await session.autoMix([.level])
    check(model.project(project.id)?.mix == before, "mix unchanged")
    check(session.undoCount == 0, "no undo step")
    check(session.autoMixNotes.first?.contains("isn't available") == true, "error shown: \(session.autoMixNotes)")
    check(session.autoMixBusy == nil, "not stuck busy")
}

test("master defaults on, and an explicit off sticks") {
    var m = MixSettings.defaults()
    check(m.masterOn, "default on")
    m.master = false
    check(!m.masterOn, "off")
    let decoded = try JSONDecoder().decode(MixSettings.self, from: JSONEncoder().encode(m))
    check(decoded.master == false, "persists")
}

// MARK: - Demo content

await testAsync("demo seeding fills an empty library once") {
    let (model, _) = makeModel()
    try model.seedDemoIfEmpty()
    check(model.songs.count == 2, "two songs (\(model.songs.count))")
    check(model.projects.count == 1 && model.takes.count == 1, "one take with a project")
    for song in model.songs {
        let d = SilentWav.duration(of: model.url(song.uri)) ?? 0
        near(d, song.durationSec ?? -1, 0.01, "\(song.title) file length")
    }
    let take = try XCTUnwrapLike(model.takes.first)
    near(SilentWav.duration(of: model.url(take.drumsUri)) ?? 0, 16, 0.01, "take length")
    check(model.audioRequest(for: model.projects[0]) != nil, "project resolves to files")
    try model.seedDemoIfEmpty()
    check(model.songs.count == 2, "second call is a no-op")
}

func XCTUnwrapLike<T>(_ v: T?) throws -> T {
    guard let v else { throw ServiceError.failed("unexpected nil") }
    return v
}

// MARK: - Crash notice

await testAsync("crash notice: dying in the foreground is reported with what the app was doing") {
    let suite = "lumber-tests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return check(false, "no defaults suite") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let docs = tempDir()

    // First launch: nothing to report.
    let first = AppModel(services: .mock(), files: DocumentStore(documents: docs), defaults: defaults)
    first.checkLastSession()
    check(first.crashNotice == nil, "fresh install has no notice")
    first.noteActivity("removing the drums from “Song”")
    // ...and the app dies here (no background marker).

    let second = AppModel(services: .mock(), files: DocumentStore(documents: docs), defaults: defaults)
    second.checkLastSession()
    check(second.crashNotice?.contains("removing the drums from “Song”") == true,
          "notice names the activity: \(second.crashNotice ?? "nil")")
    second.dismissCrashNotice()
    check(second.crashNotice == nil, "dismiss clears it")

    // Going to the background, then being killed there, is normal.
    second.markSession(foreground: false)
    let third = AppModel(services: .mock(), files: DocumentStore(documents: docs), defaults: defaults)
    third.checkLastSession()
    check(third.crashNotice == nil, "a background kill isn't a crash")

    // Finishing an activity goes back to idle.
    third.noteActivity("exporting WAV")
    third.noteActivity(nil)
    check(third.currentActivity == AppModel.idleActivity, "idle after the activity ends")
}

// MARK: - Record backing track

await testAsync("record plays the drumless stem when there is one, unless turned off") {
    let (model, docs) = makeModel()
    _ = try addSongAndTake(model, docs: docs, timing: nil, clipStart: nil)
    let session = RecordSession(songId: "file:test", model: model)
    check(!session.hasStems, "no stems yet")
    check(session.backingURL?.lastPathComponent == "song.wav", "full song without stems")

    let stems = model.files.dir(.stems)
    let d = stems.appendingPathComponent("drums.wav"), n = stems.appendingPathComponent("no_drums.wav")
    try SilentWav.write(to: d, seconds: 2, sampleRate: 44_100)
    try SilentWav.write(to: n, seconds: 2, sampleRate: 44_100)
    model.setStems("file:test", SeparationOutput(drumsURL: d, noDrumsURL: n, sampleRate: 44_100))
    check(session.hasStems, "stems now")
    check(model.settings.withoutDrums, "default: without drums")
    check(session.backingURL?.lastPathComponent == "no_drums.wav", "drumless by default: \(session.backingURL?.lastPathComponent ?? "nil")")

    await session.setPlayWithoutDrums(false)
    check(session.backingURL?.lastPathComponent == "song.wav", "full song when turned off")
    check(model.settings.playWithoutDrums == false, "setting saved")
    let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(model.settings))
    check(decoded.playWithoutDrums == false, "setting survives a restart")
}

// MARK: - Done

print(failures == 0 ? "\nAll \(checks) checks passed." : "\n\(failures) of \(checks) checks FAILED.")
exit(failures == 0 ? 0 : 1)
