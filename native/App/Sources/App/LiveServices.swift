// Real implementations of the service protocols (State/Services.swift),
// adapting the Platform layer (AVAudioEngine, camera, export, Photos), the
// on-device separation engine and LumberCore (DSP, mixing, WAV) to what the
// screens expect. Heavy work (decoding, rendering the drum chain, mixing a
// whole song) runs off the main actor in detached tasks.

import AVFoundation
import Foundation
import LumberCore
import UIKit

// MARK: - Recording

@MainActor
final class LiveAudioEngine: AudioEngineService {
    private let session = AudioSessionManager.shared
    private let engine: TakeEngine
    private let store = LatencyStore.shared
    private lazy var calibrator = LatencyCalibrator(engine: engine, store: store)
    private var residualMs = 0.0 // calibration residual used for the current take

    init() {
        engine = TakeEngine(session: AudioSessionManager.shared)
    }

    func prepare() async throws {
        guard await session.requestMicrophonePermission() else {
            throw ServiceError.failed("Lumber needs the microphone to record drums. Allow it in Settings → Lumber (native).")
        }
        try engine.prepare()
    }

    func loadSong(at url: URL) async throws -> Double {
        try engine.songDuration(url)
    }

    func currentRoute() -> AudioRouteInfo {
        Self.info(session.refreshRoute())
    }

    func routeChanges() -> AsyncStream<AudioRouteInfo> {
        AsyncStream { continuation in
            let id = session.addListener { event in
                if case .routeChanged(let route) = event { continuation.yield(Self.info(route)) }
            }
            continuation.onTermination = { _ in
                Task { @MainActor in AudioSessionManager.shared.removeListener(id) }
            }
        }
    }

    var isRunning: Bool { engine.isRunning }

    func start(_ request: TransportRequest, onAutoStop: @escaping @MainActor @Sendable () -> Void) async throws {
        engine.onAutoStop = { onAutoStop() }
        residualMs = store.residualMs(for: session.refreshRoute())
        let options = TakeOptions(
            songURL: request.songURL,
            startSec: request.startSec,
            loop: request.loop.map { TakeLoop(start: $0.start, end: $0.end) },
            countIn: request.countIn.map { TakeCountIn(bpm: $0.bpm, beats: $0.beats) },
            record: request.record,
            takesDirectory: FileManager.default.temporaryDirectory,
            // Latency = what iOS reports for the route + the calibrated residual.
            calibrationResidualMs: residualMs
        )
        try await engine.start(options)
    }

    func position() -> Double? { engine.songPosition }
    func countInRemaining() -> Double { engine.countInRemaining }

    func transportTiming() -> TransportTiming? {
        guard let t = engine.transportTiming else { return nil }
        // The calibration residual is the round trip iOS doesn't report; with a
        // built-in mic nearly all of it is on the output side.
        let output = max(0, t.outputLatencySec + residualMs / 1000)
        return TransportTiming(songStartSec: t.songStartSec, songStartHostTime: t.songStartHostSec, outputLatencySec: output)
    }

    func stop() async throws -> RecordedTake? {
        guard let r = try engine.stop() else { return nil }
        return RecordedTake(
            drumsURL: r.drumsURL,
            songStartSec: r.songStartSec,
            drumOffsetSec: r.drumOffsetSec,
            latencyMs: r.latencyMs,
            sampleRate: r.sampleRate,
            durationSec: r.durationSec
        )
    }

    func calibrate() async throws -> CalibrationResult {
        let c = try await calibrator.run(save: true)
        return CalibrationResult(
            routeKey: c.routeKey, latencyMs: c.roundTripMs, confidence: c.confidence,
            spreadMs: c.spreadMs, isReliable: c.isReliable
        )
    }

    private static func info(_ r: AudioRoute) -> AudioRouteInfo {
        AudioRouteInfo(key: r.key, name: r.name, isHeadphones: r.isHeadphones, isBluetooth: r.isBluetooth)
    }
}

// MARK: - Camera

@MainActor
final class LiveCamera: CameraService {
    private let recorder = CameraRecorder()
    private var recording: Task<Void, Error>?

    var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }

    var facing: CameraFacing = .front {
        didSet {
            guard facing != oldValue else { return }
            let target: CaptureFacing = facing == .front ? .front : .back
            Task { try? await recorder.setFacing(target) }
        }
    }

    func requestAccess() async -> Bool { await CameraRecorder.requestAccess() }

    func startPreview() async throws {
        try await recorder.startSession(facing: facing == .front ? .front : .back)
    }

    func stopPreview() {
        Task { await recorder.stopSession() }
    }

    func startRecording() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).mov")
        recording = Task { try await recorder.startRecording(to: url) }
    }

    func stopRecording() async -> CameraClip? {
        do {
            try await recording?.value
            recording = nil
            let clip = try await recorder.stopRecording()
            return CameraClip(
                url: clip.url, startHostTime: clip.startHostSec, durationSec: clip.durationSec,
                facing: clip.facing == .front ? .front : .back
            )
        } catch {
            recording = nil
            return nil
        }
    }

    func makePreviewView() -> UIView {
        let view = CaptureLayerView()
        view.previewLayer.session = recorder.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
}

/// A UIView backed by an AVCaptureVideoPreviewLayer.
final class CaptureLayerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - Edit preview

/// Decoded project audio at the editing rate, shared by preview and export.
struct ProjectAudio: Sendable {
    var bed: [[Float]] // song, or no-drums stem
    var originalDrums: [[Float]]?
    var take: [[Float]] // raw mic recording
    var sampleRate: Double

    static func load(_ r: ProjectAudioRequest) async throws -> ProjectAudio {
        let rate = AudioFileIO.editingSampleRate
        let bed = try await AudioFileIO.decodeDetached(r.bedURL, sampleRate: rate, channelCount: 2)
        var orig: DecodedAudio?
        if let stems = r.stems {
            orig = try await AudioFileIO.decodeDetached(stems.drums, sampleRate: rate, channelCount: 2)
        }
        let take = try await AudioFileIO.decodeDetached(r.takeURL, sampleRate: rate)
        return ProjectAudio(bed: bed.channels, originalDrums: orig?.channels, take: take.channels, sampleRate: rate)
    }
}

enum KnobBridge {
    /// App knob keys are the TS snake_case term names, as are BlanketTerm raw values.
    static func values(_ dict: [String: Double]) -> BlanketValues {
        var out = BlanketValues()
        for (k, v) in dict { if let t = BlanketTerm(rawValue: k) { out[t] = v } }
        return out
    }

    static func render(_ take: [[Float]], sampleRate: Double, knobs: [String: Double]) async -> [[Float]] {
        let values = values(knobs)
        return await Task.detached(priority: .userInitiated) {
            DSP.renderBlanket(take, sampleRate: sampleRate, values: values)
        }.value
    }
}

@MainActor
final class LiveMixPreview: MixPreviewService {
    private let player = PreviewPlayer(session: AudioSessionManager.shared)
    private var audio: ProjectAudio?
    private var songPeaks: [Float] = [] // mono abs, one value per ~10 ms
    private var drumPeaks: [Float] = []
    private static let peakHop = 480 // 10 ms at 48 kHz
    private var levels = MixLevels(songGain: 0.8, drumGain: 1, originalDrums: 0)
    private var offset = 0.0

    func load(_ request: ProjectAudioRequest) async throws -> LoadedProjectAudio {
        player.unload()
        let a = try await ProjectAudio.load(request)
        audio = a
        songPeaks = Self.envelope(a.bed)
        drumPeaks = Self.envelope(a.take)
        try player.load(
            bed: a.bed, originalDrums: a.originalDrums, drums: a.take,
            sampleRate: a.sampleRate, drumOffsetSec: offset, levels: Self.playerLevels(levels)
        )
        let frames = { (c: [[Float]]) in Double(c.first?.count ?? 0) / a.sampleRate }
        return LoadedProjectAudio(
            songDurationSec: frames(a.bed), drumsDurationSec: frames(a.take),
            sampleRate: a.sampleRate, hasStems: a.originalDrums != nil
        )
    }

    func peaks(_ lane: WaveLane, start: Double, end: Double, columns: Int, drumOffsetSec: Double) -> [Float] {
        guard columns > 0, end > start else { return [] }
        let env = lane == .song ? songPeaks : drumPeaks
        let shift = lane == .drums ? drumOffsetSec : 0
        let perSec = AudioFileIO.editingSampleRate / Double(Self.peakHop)
        var out = [Float](repeating: 0, count: columns)
        let span = (end - start) / Double(columns)
        for c in 0..<columns {
            let a = Int(((start + Double(c) * span) - shift) * perSec)
            let b = Int(((start + Double(c + 1) * span) - shift) * perSec)
            var m: Float = 0
            if b > 0 && a < env.count {
                for i in max(0, a)..<min(env.count, max(a + 1, b)) { m = max(m, env[i]) }
            }
            out[c] = m
        }
        return out
    }

    func setLevels(_ l: MixLevels) {
        levels = l
        player.setLevels(Self.playerLevels(l))
    }

    func setDrumOffset(_ seconds: Double) {
        offset = seconds
        player.setDrumOffset(seconds)
    }

    func renderDrums(knobValues: [String: Double]) async throws {
        guard let a = audio else { return }
        let rendered = await KnobBridge.render(a.take, sampleRate: a.sampleRate, knobs: knobValues)
        player.replaceDrums(rendered, sampleRate: a.sampleRate)
    }

    var isPlaying: Bool { player.isPlaying }
    var duration: Double { player.duration }
    func play(from seconds: Double) { try? player.play(from: seconds) }
    func stop() { player.pause() }
    func seek(to seconds: Double) { player.seek(to: seconds) }
    func position() -> Double { player.position }

    func unload() {
        player.unload()
        audio = nil
        songPeaks = []
        drumPeaks = []
    }

    private static func playerLevels(_ l: MixLevels) -> PreviewPlayer.Levels {
        var p = PreviewPlayer.Levels()
        p.songGain = Float(l.songGain)
        p.drumGain = Float(l.drumGain)
        p.originalDrums = Float(l.originalDrums)
        return p
    }

    /// Max-abs envelope of the channel mix, one value per `peakHop` frames.
    private static func envelope(_ channels: [[Float]]) -> [Float] {
        let n = channels.first?.count ?? 0
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: (n + peakHop - 1) / peakHop)
        for ch in channels {
            for i in 0..<n {
                let v = abs(ch[i])
                if v > out[i / peakHop] { out[i / peakHop] = v }
            }
        }
        return out
    }
}

// MARK: - Export

@MainActor
final class LiveExport: ExportService {
    func export(_ request: ExportRequest, progress: @escaping ProgressHandler) async throws -> ExportedFile {
        progress(0.02)
        let a = try await ProjectAudio.load(request.audio)
        progress(0.15)
        let drums = await KnobBridge.render(a.take, sampleRate: a.sampleRate, knobs: request.mix.values)
        progress(0.45)
        let mix = request.mix
        let offset = request.drumOffsetSec
        let mixed: [[Float]] = await Task.detached(priority: .userInitiated) {
            DSP.mixTake(DSP.MixOptions(
                song: a.bed, drums: drums, sampleRate: a.sampleRate, drumOffsetSec: offset,
                songGain: mix.songGain, drumGain: mix.drumGain,
                originalDrums: a.originalDrums.map { DSP.OriginalDrums(drums: $0, noDrums: a.bed, amount: mix.originalDrums) }
            ))
        }.value
        progress(0.6)
        let duration = Double(mixed.first?.count ?? 0) / a.sampleRate
        let tmp = FileManager.default.temporaryDirectory
        let base = Self.safeName(request.title)
        let wav = tmp.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).wav")
        try await Task.detached { try AudioFileIO.writeWAV(mixed, sampleRate: a.sampleRate, to: wav, format: .int24) }.value

        switch request.format {
        case .wav:
            progress(1)
            return ExportedFile(url: wav, durationSec: duration, thumbnailURL: nil)

        case .m4a:
            let out = tmp.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).m4a")
            let url = try await MediaExporter.exportM4A(wavURL: wav, to: out) { p in
                Task { @MainActor in progress(0.6 + 0.4 * p) }
            }
            try? FileManager.default.removeItem(at: wav)
            return ExportedFile(url: url, durationSec: duration, thumbnailURL: nil)

        case .video:
            guard let video = request.video else { throw ServiceError.failed("This take has no video.") }
            // Output starts where both the song and the clip exist.
            let outStart = max(0, video.offsetSec)
            let videoStart = outStart - video.offsetSec
            let info = try await MediaExporter.videoInfo(video.url)
            let length = min(duration - outStart, info.durationSec - videoStart)
            guard length > 0.1 else { throw ServiceError.failed("The video and the song don't overlap.") }
            let startFrame = Int(outStart * a.sampleRate)
            let cut: [[Float]] = mixed.map { Array($0[min(startFrame, $0.count)...]) }
            let cutURL = tmp.appendingPathComponent("\(base)-cut-\(UUID().uuidString.prefix(6)).wav")
            try await Task.detached { try AudioFileIO.writeWAV(cut, sampleRate: a.sampleRate, to: cutURL, format: .int24) }.value
            let out = tmp.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).mp4")
            let url = try await MediaExporter.muxVideo(
                MuxRequest(videoURL: video.url, audioURL: cutURL, outputURL: out, videoStartSec: videoStart, durationSec: length)
            ) { p in
                Task { @MainActor in progress(0.6 + 0.4 * p) }
            }
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: cutURL)
            let thumb = tmp.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).jpg")
            let thumbURL = try? await MediaExporter.writeThumbnailJPEG(for: url, to: thumb)
            return ExportedFile(url: url, durationSec: length, thumbnailURL: thumbURL)
        }
    }

    private static func safeName(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? "lumber" : String(name.prefix(40))
    }
}

// MARK: - Photos

@MainActor
final class LivePhotos: PhotoLibraryService {
    func saveVideo(at url: URL) async throws -> PhotosSaveOutcome {
        guard await PhotoLibrary.requestAddOnlyAccess() else { return .denied }
        try await PhotoLibrary.saveVideo(at: url)
        return .saved
    }
}

// MARK: - Drum removal

@MainActor
final class LiveSeparation: SeparationService {
    private let engine = SeparationEngine.shared

    var modeLabel: String { engine.currentModeLabel() }

    func cachedResult(forSong songURL: URL) -> SeparationOutput? {
        engine.cached(songKey: Self.key(songURL)).map(Self.output)
    }

    func checkForCrash() -> String? { engine.checkForCrash() }

    func separateDrums(songURL: URL, into directory: URL, progress: @escaping ProgressHandler) async throws -> SeparationOutput {
        let engine = self.engine
        let key = Self.key(songURL)
        let files = try await Task.detached(priority: .userInitiated) {
            try await engine.separate(songURL: songURL, songKey: key) { p in
                Task { @MainActor in progress(p) }
            }
        }.value
        return Self.output(files)
    }

    /// Stems are cached by the song file's name, which is stable across app
    /// updates (the container path isn't).
    private static func key(_ url: URL) -> String {
        var h: UInt32 = 0x811c9dc5
        for b in url.lastPathComponent.utf8 { h = (h ^ UInt32(b)) &* 0x01000193 }
        return String(format: "%08x", h)
    }

    private static func output(_ f: StemFiles) -> SeparationOutput {
        SeparationOutput(drumsURL: f.drums, noDrumsURL: f.noDrums, sampleRate: Double(f.sampleRate))
    }
}
