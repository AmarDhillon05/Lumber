// The play + record engine: one AVAudioEngine plays the song (and count-in
// clicks) and records the mic, so input and output run on one IO unit and
// one clock.
//
// ── Sync, and why it beats the RN version ────────────────────────────────
// The RN app could not read the recorder's start time, so it sampled
// (ctx.currentTime, recorder.duration) pairs every 25 ms and took a median —
// good to about one IO buffer (~5–20 ms) on a good day. Here every event is
// stamped by Core Audio itself in host time (mach_absolute_time ticks):
//
//   H_c   host time the first count-in click renders: `clickPlayer.play(at: H_c)`
//   H_s   host time the song sample at `songStartSec` renders:
//         `songPlayer.play(at: H_s)`, H_s = H_c + countIn (exact ticks).
//         Both players resolve their host start to a sample time in the
//         same render cycle, so clicks and song are sample-locked.
//   F0    host time of drum-file sample 0: each tap buffer carries
//         `when.hostTime` = capture time of its first frame; F0 is the median
//         over the first 64 buffers of (when.hostTime − frames written before
//         it). A dropped or oddly stamped buffer can't move the median.
//   L     round-trip latency = outputLatency + inputLatency (reported by
//         AVAudioSession for the current route; render/tap host times
//         exclude them) + the calibration residual for this route (what a
//         click loopback measured beyond the reported numbers, e.g.
//         Bluetooth codec delay).
//
//   drumOffsetSec = songStartSec + (F0 − H_s) − L        (TakeClock.drumOffset)
//
// i.e. drum-file sample f belongs at song time drumOffsetSec + f / sampleRate.
// The only remaining error is acoustic (distance to the mic) and whatever the
// route mis-reports, which calibration measures. At stop we also cross-check
// H_s against the player's own render timeline (lastRenderTime →
// playerTime(forNodeTime:)); if the song started late (scheduling deadline
// missed) the measured start is used instead.
//
// Calibration (`recordClickTrain`) runs this exact path, so the residual it
// measures is the residual a take sees.

import AVFoundation
import Observation

// MARK: - Public types

/// How a take starts and what it records.
public struct TakeOptions: Sendable {
    public var songURL: URL
    /// Song position to start from (seconds).
    public var startSec: Double
    /// Loop region. While only playing, the song loops forever; while
    /// recording, one pass is recorded and `onAutoStop` fires at the loop end.
    public var loop: TakeLoop?
    public var countIn: TakeCountIn?
    public var record: Bool
    /// Where take WAVs are written (created if missing).
    public var takesDirectory: URL
    /// Calibration residual for the current route (ms), from `LatencyStore`.
    public var calibrationResidualMs: Double
    public var recordingFormat: WAVSampleFormat
    /// Song level while recording (0...1).
    public var songVolume: Float

    public init(
        songURL: URL,
        startSec: Double = 0,
        loop: TakeLoop? = nil,
        countIn: TakeCountIn? = nil,
        record: Bool = true,
        takesDirectory: URL,
        calibrationResidualMs: Double = 0,
        recordingFormat: WAVSampleFormat = .float32,
        songVolume: Float = 1
    ) {
        self.songURL = songURL
        self.startSec = startSec
        self.loop = loop
        self.countIn = countIn
        self.record = record
        self.takesDirectory = takesDirectory
        self.calibrationResidualMs = calibrationResidualMs
        self.recordingFormat = recordingFormat
        self.songVolume = songVolume
    }
}

/// When the song started and how late it was heard; lets other recorders
/// (the camera) be placed on the song timeline.
public struct EngineTransportTiming: Sendable, Equatable, Codable {
    /// Song position the transport started from.
    public var songStartSec: Double
    /// Host time (seconds) at which that song position was rendered.
    public var songStartHostSec: Double
    /// Render → ear (reported output latency + calibration residual), seconds.
    public var outputLatencySec: Double
    /// Mic → stamped input buffer (reported), seconds.
    public var inputLatencySec: Double

    public var latencySec: Double { outputLatencySec + inputLatencySec }
}

public enum TakeSyncSource: String, Sendable, Codable {
    /// Tap buffers' `AVAudioTime.hostTime` (normal case).
    case inputTimestamps
    /// Tap timestamps were invalid; callback clock used (less precise).
    case callbackClock
}

/// Numbers worth logging while verifying sync on a device.
public struct TakeDiagnostics: Sendable, Equatable, Codable {
    public var reportedOutputLatencyMs: Double
    public var reportedInputLatencyMs: Double
    public var ioBufferDurationMs: Double
    public var calibrationResidualMs: Double
    /// Measured − scheduled song start (ms); nil if the song never started.
    public var songStartDeviationMs: Double?
    /// Spread of the per-buffer file-start estimates (ms).
    public var fileStartSpreadMs: Double
    public var routeKey: String
}

/// A finished take: the drum WAV and where it sits on the song timeline.
public struct TakeResult: Sendable, Equatable, Codable {
    public var drumsURL: URL
    /// Song position playback started from.
    public var songStartSec: Double
    /// Song time where drum-file sample 0 belongs (latency compensated).
    public var drumOffsetSec: Double
    public var sampleRate: Double
    public var channelCount: Int
    public var durationSec: Double
    /// Round trip that was compensated (ms).
    public var latencyMs: Double
    public var videoURL: URL?
    /// Song time where video time 0 belongs.
    public var videoOffsetSec: Double?
    public var videoDurationSec: Double?
    public var videoFacing: CaptureFacing?
    public var videoSyncSource: ClipSyncSource?
    public var timing: EngineTransportTiming
    public var syncSource: TakeSyncSource
    public var diagnostics: TakeDiagnostics

    /// This take with a camera clip placed on the song timeline (TakeClock.videoOffset).
    public func attachingVideo(_ clip: CapturedClip) -> TakeResult {
        var r = self
        r.videoURL = clip.url
        r.videoOffsetSec = TakeClock.videoOffset(
            songStartSec: timing.songStartSec,
            songStartHostSec: timing.songStartHostSec,
            videoStartHostSec: clip.startHostSec,
            outputLatencySec: timing.outputLatencySec
        )
        r.videoDurationSec = clip.durationSec
        r.videoFacing = clip.facing
        r.videoSyncSource = clip.syncSource
        return r
    }
}

/// Mono mic recording of a click train, for latency calibration.
public struct ClickTrainRecording: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    /// Where each click would sit in `samples` with zero latency (seconds).
    public var clickFileTimes: [Double]
    /// The click waveform that was played (the matched-filter template).
    public var template: [Float]
    public var route: AudioRoute
}

// MARK: - Engine

@MainActor
@Observable
public final class TakeEngine {
    public private(set) var isRunning = false
    public private(set) var isRecording = false
    public private(set) var isCalibrating = false

    /// Fires when the transport reaches its end (song end, or loop end while
    /// recording). The owner should call `stop()` to collect the take.
    @ObservationIgnored public var onAutoStop: (@MainActor () -> Void)?
    /// Fires when the engine was stopped underneath a running transport
    /// (interruption, route change). Call `stop()` to keep what was recorded.
    @ObservationIgnored public var onInterrupted: (@MainActor (String) -> Void)?

    /// Scheduling headroom between "now" and the first rendered sample.
    public static let leadSec = 0.35
    static let flowTimeoutSec = 3.0
    static let tapBufferSize: AVAudioFrameCount = 4096

    private let session: AudioSessionManager
    private let engine = AVAudioEngine()
    private let songPlayer = AVAudioPlayerNode()
    private let clickPlayer = AVAudioPlayerNode()

    @ObservationIgnored private var songFile: AVAudioFile?
    @ObservationIgnored private var songFileURL: URL?
    @ObservationIgnored private var connectedSongFormat: AVAudioFormat?
    @ObservationIgnored private var connectedClickFormat: AVAudioFormat?
    @ObservationIgnored private var recorder: InputTapRecorder?
    @ObservationIgnored private var transport: Transport?
    @ObservationIgnored private var autoStopTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var sessionListener: UUID?

    private struct Transport {
        var startSec: Double
        var loop: TakeLoop?
        var record: Bool
        var songStartHost: UInt64
        var songStartHostSec: Double
        var endHostSec: Double? // nil: loops until stopped
        var reportedOutputSec: Double
        var reportedInputSec: Double
        var residualMs: Double
        var route: AudioRoute
    }

    public init(session: AudioSessionManager? = nil) {
        self.session = session ?? .shared
        engine.attach(songPlayer)
        engine.attach(clickPlayer)
        observeEngine()
        sessionListener = self.session.addListener { [weak self] event in
            self?.handleSessionEvent(event)
        }
    }

    // MARK: Public API

    /// Song position (seconds) of the running transport, nil when stopped.
    /// During the count-in it is the start position. Poll it from the UI
    /// (e.g. a TimelineView); it is computed from the host clock.
    public var songPosition: Double? {
        guard let t = transport else { return nil }
        return TakeClock.transportPosition(
            nowHostSec: Self.hostNowSec(),
            songStartHostSec: t.songStartHostSec,
            songStartSec: t.startSec,
            loop: t.record ? nil : t.loop
        )
    }

    /// Seconds until the song starts (count-in remaining), 0 once it plays.
    public var countInRemaining: Double {
        guard let t = transport else { return 0 }
        return max(0, t.songStartHostSec - Self.hostNowSec())
    }

    /// Timing of the running transport, for placing other recorders (camera).
    public var transportTiming: EngineTransportTiming? {
        guard let t = transport else { return nil }
        return Self.timing(for: t, songStartHostSec: t.songStartHostSec)
    }

    /// Activates the session and builds the graph ahead of time (optional).
    public func prepare() throws {
        try session.activate()
        configureGraph(songFormat: nil)
        engine.prepare()
    }

    /// Duration of a song file in seconds (opens and caches it).
    public func songDuration(_ url: URL) throws -> Double {
        let f = try openSong(url)
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// Starts playback (and recording, if `options.record`). Returns once the
    /// song and count-in are scheduled; the mic is already flowing then.
    public func start(_ options: TakeOptions) async throws {
        if isRunning || isCalibrating { _ = try? stop() }
        try session.activate()
        if options.record {
            guard await session.requestMicrophonePermission() else { throw PlatformError.microphonePermissionDenied }
        }
        let file = try openSong(options.songURL)
        let format = file.processingFormat
        let songRate = format.sampleRate
        let totalFrames = file.length
        let songDuration = Double(totalFrames) / songRate
        guard totalFrames > 0, songRate > 0 else { throw PlatformError.songUnreadable("The song is empty") }

        configureGraph(songFormat: format)

        var loop: TakeLoop? = nil
        if let l = options.loop, l.isValid, l.start < songDuration {
            loop = TakeLoop(start: l.start, end: min(l.end, songDuration))
        }
        var startSec = min(max(0, options.startSec), max(0, songDuration - 0.05))
        if let l = loop, !options.record, startSec >= l.end { startSec = l.start }

        // Mic first: the file must be running before the count-in.
        var rec: InputTapRecorder? = nil
        if options.record {
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw PlatformError.noAudioInput }
            try FileManager.default.createDirectory(at: options.takesDirectory, withIntermediateDirectories: true)
            let url = options.takesDirectory.appendingPathComponent("take-\(Self.fileStamp()).wav")
            let r = try InputTapRecorder(fileURL: url, format: inFormat, sampleFormat: options.recordingFormat)
            input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inFormat, block: r.makeTapBlock())
            rec = r
        }

        do {
            try startEngine()
            if let rec { try await waitForAudio(rec) }
        } catch {
            if let rec {
                engine.inputNode.removeTap(onBus: 0)
                rec.discard()
            }
            engine.stop()
            throw error
        }

        // Latencies are read now, after the engine (and route) settled.
        let route = session.refreshRoute()
        let s = AVAudioSession.sharedInstance()
        let reportedOut = s.outputLatency
        let reportedIn = s.inputLatency

        // Schedule: count-in at H_c, song at H_s = H_c + countIn.
        let countInSec = TakeClock.countInSeconds(options.countIn)
        let clickStartHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: Self.leadSec)
        let songStartHost = clickStartHost + AVAudioTime.hostTime(forSeconds: countInSec)

        if countInSec > 0, let clickFormat = connectedClickFormat {
            let samples = ClickSynth.train(
                sampleRate: clickFormat.sampleRate,
                times: TakeClock.countInClickTimes(options.countIn)
            )
            if let buffer = Self.monoBuffer(samples, format: clickFormat) {
                clickPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
                clickPlayer.play(at: AVAudioTime(hostTime: clickStartHost))
            }
        }

        let startFrame = AVAudioFramePosition((startSec * songRate).rounded())
        let endSongSec = loop?.end ?? songDuration
        let endFrame = min(totalFrames, AVAudioFramePosition((endSongSec * songRate).rounded()))
        if endFrame > startFrame {
            songPlayer.scheduleSegment(
                file, startingFrame: startFrame,
                frameCount: AVAudioFrameCount(endFrame - startFrame),
                at: nil, completionHandler: nil
            )
        }
        if let l = loop, !options.record, let loopBuffer = try? Self.readRegion(options.songURL, l) {
            songPlayer.scheduleBuffer(loopBuffer, at: nil, options: .loops, completionHandler: nil)
        }
        songPlayer.volume = max(0, min(1, options.songVolume))
        songPlayer.play(at: AVAudioTime(hostTime: songStartHost))

        let songStartHostSec = AVAudioTime.seconds(forHostTime: songStartHost)
        let endHostSec: Double? = (loop != nil && !options.record) ? nil : songStartHostSec + (endSongSec - startSec)
        transport = Transport(
            startSec: startSec, loop: loop, record: options.record,
            songStartHost: songStartHost, songStartHostSec: songStartHostSec, endHostSec: endHostSec,
            reportedOutputSec: reportedOut, reportedInputSec: reportedIn,
            residualMs: options.calibrationResidualMs, route: route
        )
        recorder = rec
        isRunning = true
        isRecording = rec != nil
        scheduleAutoStop(endHostSec)
    }

    /// Stops playback. When recording, closes the WAV and returns the take.
    @discardableResult
    public func stop() throws -> TakeResult? {
        generation += 1
        autoStopTask?.cancel()
        autoStopTask = nil
        let measuredStart = measuredSongStartHostSec()
        songPlayer.stop()
        clickPlayer.stop()
        let rec = recorder
        recorder = nil
        if rec != nil { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        let t = transport
        transport = nil
        isRunning = false
        isRecording = false
        guard let rec, let t else { return nil }

        let summary = try rec.finish()
        guard let url = summary.fileURL else { return nil }

        // Prefer the exact scheduled start; fall back to the measured one if
        // the song started late (missed deadline → play(at:) starts ASAP).
        var songStartHostSec = t.songStartHostSec
        var deviationMs: Double? = nil
        if let measured = measuredStart {
            let d = (measured - t.songStartHostSec) * 1000
            deviationMs = d
            if abs(d) > 20 { songStartHostSec = measured }
        }
        let timing = Self.timing(for: t, songStartHostSec: songStartHostSec)
        let offset = TakeClock.drumOffset(
            songStartSec: t.startSec,
            songStartHostSec: songStartHostSec,
            fileStartHostSec: summary.fileStartHostSec,
            latencySec: timing.latencySec
        )
        return TakeResult(
            drumsURL: url,
            songStartSec: t.startSec,
            drumOffsetSec: offset,
            sampleRate: summary.sampleRate,
            channelCount: summary.channelCount,
            durationSec: Double(summary.frames) / summary.sampleRate,
            latencyMs: timing.latencySec * 1000,
            videoURL: nil, videoOffsetSec: nil, videoDurationSec: nil, videoFacing: nil, videoSyncSource: nil,
            timing: timing,
            syncSource: summary.syncSource,
            diagnostics: TakeDiagnostics(
                reportedOutputLatencyMs: t.reportedOutputSec * 1000,
                reportedInputLatencyMs: t.reportedInputSec * 1000,
                ioBufferDurationMs: t.route.ioBufferDurationSec * 1000,
                calibrationResidualMs: t.residualMs,
                songStartDeviationMs: deviationMs,
                fileStartSpreadMs: summary.startSpreadMs,
                routeKey: t.route.key
            )
        )
    }

    /// Calibration: plays `count` clicks `intervalSec` apart through the
    /// current output while recording the mic in memory, on the same path a
    /// take uses. Feed the result to LumberCore's latency estimator.
    public func recordClickTrain(count: Int, intervalSec: Double) async throws -> ClickTrainRecording {
        if isRunning || isCalibrating { _ = try? stop() }
        try session.activate()
        guard await session.requestMicrophonePermission() else { throw PlatformError.microphonePermissionDenied }
        configureGraph(songFormat: nil)
        guard let clickFormat = connectedClickFormat else { throw PlatformError.engineFailed("No output format") }

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw PlatformError.noAudioInput }
        let trainSec = Double(max(0, count - 1)) * intervalSec
        let rec = InputTapRecorder(memoryFormat: inFormat, expectedSeconds: trainSec + Self.leadSec + 2)
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inFormat, block: rec.makeTapBlock())
        isCalibrating = true
        defer {
            clickPlayer.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isCalibrating = false
        }
        try startEngine()
        try await waitForAudio(rec)

        let route = session.refreshRoute()
        let times = (0..<count).map { Double($0) * intervalSec }
        let template = ClickSynth.make(sampleRate: clickFormat.sampleRate, .beat)
        let samples = ClickSynth.train(sampleRate: clickFormat.sampleRate, times: times, first: .beat, rest: .beat)
        guard let buffer = Self.monoBuffer(samples, format: clickFormat) else {
            throw PlatformError.engineFailed("Could not build the click buffer")
        }
        let clickStartHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: Self.leadSec)
        clickPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        clickPlayer.play(at: AVAudioTime(hostTime: clickStartHost))

        try await Task.sleep(nanoseconds: UInt64((Self.leadSec + trainSec + 0.8) * 1e9))

        let summary = try rec.finish()
        let clickStartSec = AVAudioTime.seconds(forHostTime: clickStartHost)
        return ClickTrainRecording(
            samples: summary.samples,
            sampleRate: summary.sampleRate,
            // Input and output share the session rate on iOS; if they ever
            // differ the times are still in seconds, which is what matters.
            clickFileTimes: times.map { clickStartSec + $0 - summary.fileStartHostSec },
            template: summary.sampleRate == clickFormat.sampleRate
                ? template : ClickSynth.make(sampleRate: summary.sampleRate, .beat),
            route: route
        )
    }

    // MARK: Graph

    private func configureGraph(songFormat: AVAudioFormat?) {
        if engine.isRunning { engine.stop() }
        _ = engine.inputNode // enables input on the IO unit, so latency is the same with or without recording
        let mixer = engine.mainMixerNode
        var rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate <= 0 { rate = AVAudioSession.sharedInstance().sampleRate }
        if let clickFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
           connectedClickFormat != clickFormat {
            engine.disconnectNodeOutput(clickPlayer)
            engine.connect(clickPlayer, to: mixer, format: clickFormat)
            connectedClickFormat = clickFormat
        }
        if let songFormat, connectedSongFormat != songFormat {
            engine.disconnectNodeOutput(songPlayer)
            engine.connect(songPlayer, to: mixer, format: songFormat)
            connectedSongFormat = songFormat
        }
    }

    private func startEngine() throws {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw PlatformError.engineFailed(error.localizedDescription)
        }
    }

    private func openSong(_ url: URL) throws -> AVAudioFile {
        if let f = songFile, songFileURL == url { return f }
        do {
            let f = try AVAudioFile(forReading: url)
            songFile = f
            songFileURL = url
            return f
        } catch {
            throw PlatformError.songUnreadable(error.localizedDescription)
        }
    }

    /// Waits until the tap delivered audio (the mic is live) or times out.
    private func waitForAudio(_ rec: InputTapRecorder) async throws {
        let deadline = Self.hostNowSec() + Self.flowTimeoutSec
        while !rec.hasAudio {
            if Self.hostNowSec() > deadline { throw PlatformError.microphoneProducedNoAudio }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Host time at which the song player's sample 0 rendered, from its own
    /// render timeline. nil before it started.
    private func measuredSongStartHostSec() -> Double? {
        guard transport != nil,
              let nodeTime = songPlayer.lastRenderTime,
              nodeTime.isHostTimeValid,
              let playerTime = songPlayer.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid,
              playerTime.sampleRate > 0,
              playerTime.sampleTime > 0
        else { return nil }
        return AVAudioTime.seconds(forHostTime: nodeTime.hostTime) - Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func scheduleAutoStop(_ endHostSec: Double?) {
        guard let endHostSec else { return }
        let gen = generation
        autoStopTask = Task { @MainActor [weak self] in
            let wait = endHostSec - Self.hostNowSec() + 0.05
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            guard let self, !Task.isCancelled, self.generation == gen, self.isRunning else { return }
            self.onAutoStop?()
        }
    }

    // MARK: Interruptions

    private func observeEngine() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleEngineStopped("The audio route changed") }
        })
    }

    private func handleSessionEvent(_ event: AudioSessionManager.Event) {
        switch event {
        case .interruptionBegan: handleEngineStopped("Audio was interrupted")
        case .mediaServicesReset:
            // Every node is invalid after a reset; rebuild connections lazily.
            connectedSongFormat = nil
            connectedClickFormat = nil
            songFile = nil
            songFileURL = nil
            handleEngineStopped("Audio services were reset")
        default: break
        }
    }

    private func handleEngineStopped(_ reason: String) {
        // Graph formats may have changed with the route.
        connectedClickFormat = nil
        guard isRunning || isCalibrating else { return }
        onInterrupted?(reason)
    }

    // MARK: Helpers

    private static func timing(for t: Transport, songStartHostSec: Double) -> EngineTransportTiming {
        let parts = LatencyMath.split(
            reportedOutputSec: t.reportedOutputSec, reportedInputSec: t.reportedInputSec, residualMs: t.residualMs
        )
        return EngineTransportTiming(
            songStartSec: t.startSec,
            songStartHostSec: songStartHostSec,
            outputLatencySec: parts.outputSec,
            inputLatencySec: parts.inputSec
        )
    }

    nonisolated static func hostNowSec() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    nonisolated static func fileStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: Date()))-\(UUID().uuidString.prefix(4))"
    }

    nonisolated static func monoBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for c in 0..<Int(format.channelCount) {
            samples.withUnsafeBufferPointer { p in
                if let base = p.baseAddress { data[c].update(from: base, count: samples.count) }
            }
        }
        return buffer
    }

    /// Reads a song region into memory (for the `.loops` buffer). Uses its own
    /// AVAudioFile so the player's scheduled segment file is never touched.
    nonisolated static func readRegion(_ url: URL, _ region: TakeLoop) throws -> AVAudioPCMBuffer? {
        let f = try AVAudioFile(forReading: url)
        let rate = f.processingFormat.sampleRate
        let a = max(0, AVAudioFramePosition((region.start * rate).rounded()))
        let b = min(f.length, AVAudioFramePosition((region.end * rate).rounded()))
        guard b > a, let buffer = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(b - a)) else {
            return nil
        }
        f.framePosition = a
        try f.read(into: buffer, frameCount: AVAudioFrameCount(b - a))
        return buffer.frameLength > 0 ? buffer : nil
    }
}
