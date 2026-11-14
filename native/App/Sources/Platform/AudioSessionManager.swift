// The app's AVAudioSession: one configuration for playing a song and
// recording drums at the same time.
//
//   category .playAndRecord — mic and playback run together on one IO unit
//                             (one sample clock for input and output)
//   mode     .measurement   — no AGC / voice processing / EQ on the mic, which
//                             would squash drum transients
//   options  .defaultToSpeaker   — speaker instead of the earpiece when no
//                                  headphones are connected
//            .allowBluetoothA2DP — Bluetooth headphones for output (mic stays
//                                  built in, full-band)
//            .allowBluetooth     — HFP, opt-in only (`allowBluetoothHFP`): it
//                                  moves the mic to the headset at 16 kHz
//
// Publishes the current output route (for headphone warnings and the
// per-route latency table) and forwards interruptions / route changes /
// media-services resets to listeners (TakeEngine, PreviewPlayer).

import AVFoundation
import Observation

/// Snapshot of the current audio route.
public struct AudioRoute: Sendable, Equatable, Codable {
    /// Stable per-output key for the latency table ("Speaker", "Headphones:…", "BluetoothA2DPOutput:AirPods").
    public var key: String
    /// Output port name shown to the user.
    public var name: String
    /// AVAudioSession.Port raw value of the first output.
    public var portType: String
    public var isHeadphones: Bool
    public var isBluetooth: Bool
    /// Name of the input port (built-in mic, headset mic, …), if any.
    public var inputName: String?
    /// Latencies the session reports for this route (seconds).
    public var outputLatencySec: Double
    public var inputLatencySec: Double
    public var ioBufferDurationSec: Double
    public var sampleRate: Double

    public init(
        key: String, name: String, portType: String, isHeadphones: Bool, isBluetooth: Bool,
        inputName: String?, outputLatencySec: Double, inputLatencySec: Double,
        ioBufferDurationSec: Double, sampleRate: Double
    ) {
        self.key = key
        self.name = name
        self.portType = portType
        self.isHeadphones = isHeadphones
        self.isBluetooth = isBluetooth
        self.inputName = inputName
        self.outputLatencySec = outputLatencySec
        self.inputLatencySec = inputLatencySec
        self.ioBufferDurationSec = ioBufferDurationSec
        self.sampleRate = sampleRate
    }

    /// Output + input latency reported by the session (ms), before calibration.
    public var reportedRoundTripMs: Double { (outputLatencySec + inputLatencySec) * 1000 }

    public static let unknown = AudioRoute(
        key: "unknown", name: "Unknown output", portType: "", isHeadphones: false, isBluetooth: false,
        inputName: nil, outputLatencySec: 0, inputLatencySec: 0, ioBufferDurationSec: 0, sampleRate: 48_000
    )
}

@MainActor
@Observable
public final class AudioSessionManager {
    public enum Event: Sendable, Equatable {
        /// The output route changed (headphones plugged / unplugged, Bluetooth connected, …).
        case routeChanged(AudioRoute)
        /// A phone call, Siri, an alarm… took the audio hardware. Engines have stopped.
        case interruptionBegan
        /// The interruption ended; `shouldResume` is the system's hint.
        case interruptionEnded(shouldResume: Bool)
        /// The media server restarted: every engine must be rebuilt.
        case mediaServicesReset
    }

    public static let shared = AudioSessionManager()

    /// Current route, refreshed on every route change.
    public private(set) var route: AudioRoute = .unknown
    public private(set) var isActive = false
    public private(set) var isInterrupted = false

    /// Allow Bluetooth HFP (headset mic, 16 kHz). Off by default: A2DP output
    /// with the built-in mic is much better for drums. Applied on next `activate()`.
    @ObservationIgnored public var allowBluetoothHFP = false {
        didSet { if oldValue != allowBluetoothHFP { isConfigured = false } }
    }
    /// Keep the built-in mic as input even when a wired headset with a mic is
    /// connected (the phone sits near the kit; the headset mic is on the drummer).
    @ObservationIgnored public var preferBuiltInMic = true

    public static let preferredSampleRate = 48_000.0
    public static let preferredIOBufferDuration = 0.005

    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var listeners: [UUID: @MainActor (Event) -> Void] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    public init() {
        route = Self.currentRoute()
        observe()
    }

    // MARK: Configuration

    /// Configures (once) and activates the session. Cheap to call before every take.
    public func activate() throws {
        let s = AVAudioSession.sharedInstance()
        if !isConfigured {
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
            if allowBluetoothHFP { options.insert(.allowBluetooth) }
            try s.setCategory(.playAndRecord, mode: .measurement, options: options)
            try? s.setPreferredSampleRate(Self.preferredSampleRate)
            try? s.setPreferredIOBufferDuration(Self.preferredIOBufferDuration)
            isConfigured = true
        }
        if !isActive {
            try s.setActive(true)
            isActive = true
        }
        applyPreferredInput()
        refreshRoute()
    }

    /// Deactivates the session so other apps' audio can resume.
    public func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
    }

    public var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Asks for microphone access if undetermined; returns whether it is granted.
    public func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Re-reads the route (latencies change with the route and IO buffer).
    @discardableResult
    public func refreshRoute() -> AudioRoute {
        let r = Self.currentRoute()
        route = r
        return r
    }

    // MARK: Listeners

    /// Registers a handler for session events. Keep the token to remove it.
    @discardableResult
    public func addListener(_ handler: @escaping @MainActor (Event) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    public func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    // MARK: Internals

    /// Reads the session's current route. Safe from any thread.
    public nonisolated static func currentRoute() -> AudioRoute {
        let s = AVAudioSession.sharedInstance()
        let r = s.currentRoute
        let input = r.inputs.first?.portName
        guard let out = r.outputs.first else {
            return AudioRoute(
                key: "Speaker", name: "Speaker", portType: "Speaker", isHeadphones: false, isBluetooth: false,
                inputName: input, outputLatencySec: s.outputLatency, inputLatencySec: s.inputLatency,
                ioBufferDurationSec: s.ioBufferDuration, sampleRate: s.sampleRate
            )
        }
        let type = out.portType.rawValue
        return AudioRoute(
            key: RouteNaming.key(portType: type, portName: out.portName),
            name: out.portName,
            portType: type,
            isHeadphones: RouteNaming.isHeadphones(portType: type),
            isBluetooth: RouteNaming.isBluetooth(portType: type),
            inputName: input,
            outputLatencySec: s.outputLatency,
            inputLatencySec: s.inputLatency,
            ioBufferDurationSec: s.ioBufferDuration,
            sampleRate: s.sampleRate
        )
    }

    private func applyPreferredInput() {
        guard preferBuiltInMic else { return }
        let s = AVAudioSession.sharedInstance()
        guard let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        if s.preferredInput?.portType != .builtInMic {
            try? s.setPreferredInput(mic)
        }
    }

    private func emit(_ event: Event) {
        for handler in listeners.values { handler(event) }
    }

    private func observe() {
        let nc = NotificationCenter.default
        // queue: .main → the blocks run on the main thread, so assumeIsolated holds.
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleRouteChange() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            let began = type == .began
            let shouldResume = options.contains(.shouldResume)
            MainActor.assumeIsolated { self.handleInterruption(began: began, shouldResume: shouldResume) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleMediaServicesReset() }
        })
    }

    private func handleRouteChange() {
        // A route change can reset the preferred input (e.g. headset plugged in).
        if isActive { applyPreferredInput() }
        emit(.routeChanged(refreshRoute()))
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            isInterrupted = true
            isActive = false
            emit(.interruptionBegan)
        } else {
            isInterrupted = false
            if shouldResume { try? activate() }
            emit(.interruptionEnded(shouldResume: shouldResume))
        }
    }

    private func handleMediaServicesReset() {
        isConfigured = false
        isActive = false
        try? activate()
        emit(.mediaServicesReset)
    }
}
