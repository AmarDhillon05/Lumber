// Films the drummer during a take: AVCaptureSession + AVCaptureMovieFileOutput,
// front or back camera, VIDEO ONLY — no audio input, so AVAudioEngine keeps
// the mic (and the capture session never touches the app's audio session).
//
// ── Placing the clip on the song timeline ──────────────────────────────────
// Frames are stamped with their capture time on the session's
// `synchronizationClock` (a CMClock; on iOS normally the host clock). Every
// estimate below is converted with CMSyncConvertTime → host clock →
// CMClockConvertHostTimeToSystemUnits → AVAudioTime.seconds(forHostTime:),
// i.e. the same host-time seconds as TakeEngine's H_s and tap timestamps.
// Start of the clip (video time 0), best source first:
//   1. iOS 18+: the delegate's `startPTS` — PTS of the first recorded frame.
//   2. recordedDuration polling (every 10 ms on the session queue):
//      clockNow − recordedDuration ≥ first-frame PTS (+ pipeline delay, frame
//      quantization); the 10th percentile is the estimate. Within ~1 frame.
//   3. Host time of didStartRecording, else of the startRecording call.
// TakeResult.attachingVideo then computes
//   videoOffsetSec = songStartSec + (videoStartHostSec − H_s) − outputLatency
// (TakeClock.videoOffset). Any remaining bias is the per-project video nudge.

import AVFoundation
import Observation

public enum CaptureFacing: String, Sendable, Codable, CaseIterable {
    case front, back

    var position: AVCaptureDevice.Position { self == .front ? .front : .back }
}

public enum ClipSyncSource: String, Sendable, Codable {
    case startPTS, recordedDuration, startCallback
}

/// A finished camera clip.
public struct CapturedClip: Sendable, Equatable, Codable {
    public var url: URL
    public var facing: CaptureFacing
    /// Host time (seconds, AVAudioTime domain) of the clip's first frame.
    public var startHostSec: Double
    public var durationSec: Double
    public var syncSource: ClipSyncSource
}

@MainActor
@Observable
public final class CameraRecorder {
    public private(set) var facing: CaptureFacing = .front
    public private(set) var isSessionRunning = false
    public private(set) var isRecording = false

    private let core = CaptureCore()

    public init() {}

    /// The capture session, for `CameraPreviewLayerView`.
    public var captureSession: AVCaptureSession { core.session }

    public static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Configures the camera and starts the preview.
    public func startSession(facing: CaptureFacing = .front) async throws {
        guard await Self.requestAccess() else { throw PlatformError.cameraPermissionDenied }
        let core = self.core
        try await core.perform {
            try core.configure(facing: facing)
            if !core.session.isRunning { core.session.startRunning() }
        }
        self.facing = facing
        isSessionRunning = true
    }

    public func stopSession() async {
        let core = self.core
        _ = try? await core.perform {
            if core.session.isRunning { core.session.stopRunning() }
        }
        isSessionRunning = false
    }

    /// Switches cameras (not while recording).
    public func setFacing(_ facing: CaptureFacing) async throws {
        guard !isRecording else { throw PlatformError.busy }
        guard facing != self.facing || !isSessionRunning else { return }
        let core = self.core
        try await core.perform { try core.configure(facing: facing) }
        self.facing = facing
    }

    /// Starts writing a QuickTime movie (video only) to `url` (replaced if present).
    /// Call right after `TakeEngine.start` so the clip covers the count-in.
    public func startRecording(to url: URL) async throws {
        guard isSessionRunning else { throw PlatformError.cameraUnavailable }
        guard !isRecording else { throw PlatformError.busy }
        let core = self.core
        let facing = self.facing
        try await core.perform { try core.beginRecording(to: url, facing: facing) }
        isRecording = true
    }

    /// Stops and returns the clip once the file is complete.
    public func stopRecording() async throws -> CapturedClip {
        guard isRecording else { throw PlatformError.notRecording }
        defer { isRecording = false }
        let f = try await core.endRecording()
        let duration = await Self.duration(of: f.url)
        return CapturedClip(url: f.url, facing: f.facing, startHostSec: f.startHostSec, durationSec: duration, syncSource: f.source)
    }

    nonisolated static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration), d.isNumeric else { return 0 }
        return d.seconds
    }
}

// MARK: - Capture core (session queue)

/// Owns the AVCaptureSession and its outputs. Session work runs on `queue`
/// (startRunning blocks); recording state is guarded by `lock` because the
/// delegate callbacks arrive on AVFoundation's own queue.
final class CaptureCore: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    struct Finished: Sendable {
        var url: URL
        var facing: CaptureFacing
        var startHostSec: Double
        var source: ClipSyncSource
    }

    private struct Recording {
        var url: URL
        var facing: CaptureFacing
        var callHostSec: Double
        var startCallbackHostSec: Double?
        var startPTSHostSec: Double?
        var durationEstimates: [Double] = []
        var continuation: CheckedContinuation<Finished, Error>?
        var result: Result<Finished, Error>?
    }

    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "lumber.camera.session", qos: .userInitiated)
    private var input: AVCaptureDeviceInput?
    private let lock = NSLock()
    private var recording: Recording?
    private var pollTimer: DispatchSourceTimer?

    /// Runs `body` on the session queue.
    func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    // Session queue only.
    func configure(facing: CaptureFacing) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: facing.position) else {
            throw PlatformError.cameraUnavailable
        }
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw PlatformError.recordingFailed(error.localizedDescription)
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Video only: never let capture reconfigure the app's audio session.
        session.automaticallyConfiguresApplicationAudioSession = false
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        if let old = input { session.removeInput(old) }
        guard session.canAddInput(newInput) else {
            if let old = input, session.canAddInput(old) { session.addInput(old) }
            throw PlatformError.cameraUnavailable
        }
        session.addInput(newInput)
        input = newInput
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw PlatformError.cameraUnavailable }
            session.addOutput(output)
        }
        // Portrait clips (the app is portrait-only). Mirroring stays at the
        // system default (front clips are recorded unmirrored, like the RN app).
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
    }

    // Session queue only.
    func beginRecording(to url: URL, facing: CaptureFacing) throws {
        guard !output.isRecording else { throw PlatformError.busy }
        guard output.connection(with: .video) != nil else { throw PlatformError.cameraUnavailable }
        try? FileManager.default.removeItem(at: url)
        lock.lock()
        recording = Recording(url: url, facing: facing, callHostSec: TakeEngine.hostNowSec())
        lock.unlock()
        output.startRecording(to: url, recordingDelegate: self)
        startPolling()
    }

    func endRecording() async throws -> Finished {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Finished, Error>) in
            queue.async {
                self.lock.lock()
                guard var r = self.recording else {
                    self.lock.unlock()
                    cont.resume(throwing: PlatformError.notRecording)
                    return
                }
                if let done = r.result {
                    // Already finished on its own (error, disk full, …).
                    self.recording = nil
                    self.lock.unlock()
                    cont.resume(with: done)
                    return
                }
                r.continuation = cont
                self.recording = r
                self.lock.unlock()
                self.output.stopRecording()
            }
        }
    }

    // MARK: Start-time estimation

    private var clock: CMClock { session.synchronizationClock ?? CMClockGetHostTimeClock() }

    private func startPolling() {
        stopPolling()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
        timer.setEventHandler { [weak self] in self?.poll() }
        lock.lock()
        pollTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func stopPolling() {
        lock.lock()
        let t = pollTimer
        pollTimer = nil
        lock.unlock()
        t?.cancel()
    }

    private func poll() {
        let clock = self.clock
        let now = CMClockGetTime(clock)
        let recorded = output.recordedDuration
        guard recorded.isNumeric, recorded.seconds > 0,
              let start = Self.hostSeconds(CMTimeSubtract(now, recorded), clock: clock)
        else { return }
        lock.lock()
        if var r = recording, r.result == nil, r.durationEstimates.count < 3000 {
            r.durationEstimates.append(start)
            recording = r
        }
        lock.unlock()
    }

    /// A time on `clock` as host-time seconds (AVAudioTime domain).
    static func hostSeconds(_ t: CMTime, clock: CMClock) -> Double? {
        guard t.isNumeric else { return nil }
        let host = CMSyncConvertTime(t, from: clock, to: CMClockGetHostTimeClock())
        guard host.isNumeric else { return nil }
        return AVAudioTime.seconds(forHostTime: CMClockConvertHostTimeToSystemUnits(host))
    }

    private static func pickStart(_ r: Recording) -> (Double, ClipSyncSource) {
        let polled = TakeClock.quantile(r.durationEstimates, 0.1)
        if let pts = r.startPTSHostSec, polled.map({ abs($0 - pts) < 0.15 }) ?? true {
            return (pts, .startPTS)
        }
        // The first frame can't precede the call that started the recording.
        if let polled, polled >= r.callHostSec - 0.05 { return (polled, .recordedDuration) }
        return (r.startCallbackHostSec ?? r.callHostSec, .startCallback)
    }

    // MARK: AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = TakeEngine.hostNowSec()
        lock.lock()
        if recording?.startCallbackHostSec == nil { recording?.startCallbackHostSec = now }
        lock.unlock()
    }

    @available(iOS 18.0, *)
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        startPTS: CMTime,
        from connections: [AVCaptureConnection]
    ) {
        let now = TakeEngine.hostNowSec()
        let pts = Self.hostSeconds(startPTS, clock: clock)
        lock.lock()
        if recording?.startCallbackHostSec == nil { recording?.startCallbackHostSec = now }
        recording?.startPTSHostSec = pts
        lock.unlock()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        stopPolling()
        let ok: Bool
        if let error {
            ok = ((error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true
        } else {
            ok = true
        }
        lock.lock()
        guard var r = recording else {
            lock.unlock()
            return
        }
        let result: Result<Finished, Error>
        if ok {
            let (start, source) = Self.pickStart(r)
            result = .success(Finished(url: outputFileURL, facing: r.facing, startHostSec: start, source: source))
        } else {
            result = .failure(PlatformError.recordingFailed(error?.localizedDescription ?? "Unknown error"))
        }
        if let cont = r.continuation {
            recording = nil
            lock.unlock()
            cont.resume(with: result)
        } else {
            r.result = result
            recording = r
            lock.unlock()
        }
    }
}
