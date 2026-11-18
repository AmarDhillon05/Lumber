// Record screen logic: transport for one song — start position, loop region,
// 1-bar count-in, Play / Record / Stop, camera, latency calibration and nudge.
// Port of src/screens/RecordScreen.tsx (UI in UI/RecordScreen.swift).

import Foundation
import Observation

@MainActor
@Observable
final class RecordSession {
    enum Mode: Hashable, Sendable {
        case loading, idle, playing, recording, calibrating
    }

    let songId: String
    private let model: AppModel

    var duration: Double = 0
    var startSec: Double = 0
    var loopOn = false
    var loopStart: Double = 0
    var loopEnd: Double = 0
    var bpmText: String
    var cameraOn = false
    var error: String?
    var cameraError: String?

    private(set) var mode: Mode = .loading
    private(set) var position: Double = 0
    private(set) var countInRemaining: Double = 0
    private(set) var route: AudioRouteInfo?
    private var filming = false

    init(songId: String, model: AppModel) {
        self.songId = songId
        self.model = model
        bpmText = RecordSession.format(bpm: model.settings.bpm)
    }

    private var audio: any AudioEngineService { model.services.audio }
    var camera: any CameraService { model.services.camera }

    var song: LibrarySong? { model.song(songId) }

    /// The song has a drumless stem to play along to.
    var hasStems: Bool { song?.stems != nil }

    /// What Record plays: the drumless stem when there is one and the setting
    /// is on, else the song. Same length and timeline either way.
    var backingURL: URL? {
        guard let song else { return nil }
        if let stems = song.stems, model.settings.withoutDrums { return model.url(stems.noDrumsUri) }
        return model.url(song.uri)
    }

    func setPlayWithoutDrums(_ on: Bool) async {
        guard !isRunning else { return }
        model.updateSettings { $0.playWithoutDrums = on }
        // Swap what the engine plays; start point and loop stay as they are.
        guard let url = backingURL else { return }
        do {
            duration = try await audio.loadSong(at: url)
        } catch {
            self.error = "Could not load the backing track: \(error.localizedDescription)"
        }
    }
    var settings: Settings { model.settings }
    var isRunning: Bool { mode == .playing || mode == .recording }
    var isBusy: Bool { mode != .idle }

    var bpm: Double { RecordSession.clampBpm(Double(bpmText.replacingOccurrences(of: ",", with: ".")) ?? .nan) }

    var latency: (baseMs: Double, calibrated: Bool, totalMs: Double) {
        model.latency(for: route ?? .unknown)
    }

    /// The time shown big: the playhead while running, else where it'll start.
    var displayPosition: Double { isRunning ? position : (loopOn ? loopStart : startSec) }

    /// Beats of count-in left, for the "count-in 3" label.
    var countInBeatsLeft: Int {
        guard countInRemaining > 0 else { return 0 }
        return Int((countInRemaining / (60 / bpm)).rounded(.up))
    }

    static func clampBpm(_ bpm: Double) -> Double {
        guard bpm.isFinite else { return 120 }
        return min(300, max(30, bpm))
    }

    static func format(bpm: Double) -> String {
        bpm == bpm.rounded() ? String(Int(bpm)) : String(format: "%.1f", bpm)
    }

    // MARK: Lifecycle

    func load() async {
        guard let song else {
            mode = .idle
            return
        }
        do {
            try await audio.prepare()
            let d = try await audio.loadSong(at: backingURL ?? model.url(song.uri))
            duration = d
            // Local imports arrive without a duration; fill it from the decode.
            if song.durationSec == nil { model.updateSong(songId) { $0.durationSec = d } }
            loopStart = 0
            loopEnd = min(d, 30)
        } catch {
            self.error = "Could not load song: \(error.localizedDescription)"
        }
        route = audio.currentRoute()
        mode = .idle
    }

    /// Runs until cancelled (the view's .task).
    func watchRoutes() async {
        for await r in audio.routeChanges() {
            route = r
        }
    }

    /// Playhead updates while running (the view's .task(id: mode)).
    func tick() async {
        while isRunning, !Task.isCancelled {
            if let p = audio.position() { position = p }
            countInRemaining = audio.countInRemaining()
            try? await Task.sleep(for: .milliseconds(80))
        }
        countInRemaining = 0
    }

    /// Leaving the screen never leaves the transport or camera running.
    func leave() {
        let audio = self.audio
        let camera = self.camera
        let wasFilming = filming
        filming = false
        if audio.isRunning || wasFilming {
            mode = .idle
            Task { @MainActor in
                _ = try? await audio.stop()
                if wasFilming, let clip = await camera.stopRecording() {
                    try? FileManager.default.removeItem(at: clip.url)
                }
            }
        }
    }

    // MARK: Transport

    func start(record: Bool) async {
        guard let song, mode == .idle, duration > 0 else { return }
        error = nil
        cameraError = nil
        let bpm = self.bpm
        bpmText = RecordSession.format(bpm: bpm)
        model.updateSettings { $0.bpm = bpm }
        let from = loopOn ? loopStart : startSec
        position = from
        mode = .loading
        model.noteActivity("\(record ? "recording" : "playing") “\(song.title)”\(record && cameraOn ? " with the camera" : "")")

        // Started first: cameras are slow to roll.
        if record && cameraOn {
            do {
                try camera.startRecording()
                filming = true
            } catch {
                cameraError = "Camera wasn't ready, so this take has no video. \(error.localizedDescription)"
            }
        }

        let request = TransportRequest(
            songId: song.id,
            songURL: backingURL ?? model.url(song.uri),
            startSec: from,
            loop: loopOn ? LoopRegion(start: loopStart, end: loopEnd) : nil,
            countIn: model.settings.countIn ? CountIn(bpm: bpm, beats: 4) : nil,
            record: record,
            latencyMs: latency.totalMs
        )
        do {
            try await audio.start(request) { [weak self] in
                Task { @MainActor in await self?.stop() }
            }
            mode = record ? .recording : .playing
        } catch {
            mode = .idle
            model.noteActivity(nil)
            self.error = error.localizedDescription
            await discardClip()
        }
    }

    func stop() async {
        guard isRunning else { return }
        let wasRecording = mode == .recording
        mode = .idle
        model.noteActivity(wasRecording ? "saving a take" : nil)
        defer { model.noteActivity(nil) }
        let timing = audio.transportTiming()
        do {
            let recorded = try await audio.stop()
            let clip = filming ? await camera.stopRecording() : nil
            filming = false
            if wasRecording, let recorded {
                try model.finishTake(songId: songId, recorded: recorded, clip: clip, timing: timing)
            } else if let clip {
                try? FileManager.default.removeItem(at: clip.url)
            }
        } catch {
            self.error = error.localizedDescription
            await discardClip()
        }
    }

    private func discardClip() async {
        guard filming else { return }
        filming = false
        if let clip = await camera.stopRecording() {
            try? FileManager.default.removeItem(at: clip.url)
        }
    }

    // MARK: Settings

    func setCountIn(_ on: Bool) {
        model.updateSettings { $0.countIn = on }
    }

    func nudgeLatency(_ ms: Double) {
        model.updateSettings { $0.latencyNudgeMs += ms }
    }

    func commitBpm() {
        bpmText = RecordSession.format(bpm: bpm)
    }

    func setLoopStart(_ v: Double) { loopStart = min(v, loopEnd - 0.5) }
    func setLoopEnd(_ v: Double) { loopEnd = max(v, loopStart + 0.5) }

    func calibrate() async {
        guard mode == .idle else { return }
        mode = .calibrating
        error = nil
        do {
            let r = try await audio.calibrate()
            if r.isReliable {
                model.recordCalibration(r)
                route = audio.currentRoute()
            } else {
                error = String(
                    format: "Clicks not detected clearly (confidence %.1f, spread %.1f ms). Turn the volume up and try again.",
                    r.confidence, r.spreadMs
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
        mode = .idle
    }

    // MARK: Camera

    func setCamera(_ on: Bool) async {
        cameraError = nil
        guard on else {
            cameraOn = false
            camera.stopPreview()
            return
        }
        guard camera.isAvailable else {
            cameraError = "The camera isn't available in this build."
            cameraOn = false
            return
        }
        guard await camera.requestAccess() else {
            cameraError = "Camera access is off. Allow it in Settings → Lumber (native) → Camera."
            cameraOn = false
            return
        }
        do {
            try await camera.startPreview()
            cameraOn = true
        } catch {
            cameraError = error.localizedDescription
            cameraOn = false
        }
    }

    func flipCamera() {
        camera.facing = camera.facing == .front ? .back : .front
    }
}
