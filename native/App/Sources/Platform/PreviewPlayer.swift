// Editor preview: plays the backing (song, or the no-drums stem), the
// separated original drums (optional) and the processed drum take as three
// AVAudioPlayerNodes, each through its own gain stage, so faders move in real
// time. Knob changes re-render the drum chain offline (LumberCore) and the
// new buffer is swapped in with `replaceDrums`; alignment (nudge) changes
// restart the players at the current playhead, like the RN Preview.
//
// Graph:  bedPlayer  → bedGain  ┐
//         origPlayer → origGain ├→ mainMixer → output
//         drumPlayer → drumGain ┘
// Gains are AVAudioUnitEQ.globalGain (dB): AVAudioMixing.volume caps at 1,
// but song/drum gain go up to 1.5. Linear 0 maps to the -96 dB floor.
//
// Audio is held as ~0.5 s AVAudioPCMBuffer chunks: starting mid-song copies
// one partial chunk and schedules the rest by reference, so a seek never
// copies the whole song.
//
// All players start at one host time (`play(at:)`), the drums at that host
// time + their delay when they begin later in the song than the playhead.

import AVFoundation
import Observation

@MainActor
@Observable
public final class PreviewPlayer {
    public struct Levels: Sendable, Equatable, Codable {
        /// Backing level, 0...1.5.
        public var songGain: Float
        /// Processed drum take level, 0...1.5.
        public var drumGain: Float
        /// Original (separated) drums, 0...1, scaled by songGain; only with stems.
        public var originalDrums: Float

        public init(songGain: Float = 1, drumGain: Float = 1, originalDrums: Float = 0) {
            self.songGain = songGain
            self.drumGain = drumGain
            self.originalDrums = originalDrums
        }
    }

    /// Lets a video player be slaved to the audio: song time `songSec`
    /// renders at host time `hostTime` (mach ticks), at rate 1.
    /// Use with AVPlayer.setRate(1, time:, atHostTime: CMClockMakeHostTimeFromSystemUnits(hostTime)).
    public struct PlaybackAnchor: Sendable, Equatable {
        public var songSec: Double
        public var hostTime: UInt64
    }

    public private(set) var isPlaying = false
    public private(set) var isLoaded = false
    /// Length of the backing (seconds).
    public private(set) var duration: Double = 0
    public private(set) var levels = Levels()
    /// Song time where drum sample 0 sits (take offset + nudge).
    public private(set) var drumOffsetSec: Double = 0
    public private(set) var anchor: PlaybackAnchor?

    static let leadSec = 0.05

    private let session: AudioSessionManager
    private let engine = AVAudioEngine()
    private let bedPlayer = AVAudioPlayerNode()
    private let origPlayer = AVAudioPlayerNode()
    private let drumPlayer = AVAudioPlayerNode()
    private let bedGain = PreviewPlayer.makeGainUnit()
    private let origGain = PreviewPlayer.makeGainUnit()
    private let drumGain = PreviewPlayer.makeGainUnit()

    @ObservationIgnored private var bed: ChunkedPCM?
    @ObservationIgnored private var orig: ChunkedPCM?
    @ObservationIgnored private var drums: ChunkedPCM?
    @ObservationIgnored private var startHostSec = 0.0
    @ObservationIgnored private var startSongSec = 0.0
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var sessionListener: UUID?

    public init(session: AudioSessionManager? = nil) {
        self.session = session ?? .shared
        for node in [bedPlayer, origPlayer, drumPlayer] { engine.attach(node) }
        for node in [bedGain, origGain, drumGain] { engine.attach(node) }
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleEngineStopped() }
        })
        sessionListener = self.session.addListener { [weak self] event in
            switch event {
            case .interruptionBegan, .mediaServicesReset: self?.handleEngineStopped()
            default: break
            }
        }
    }

    // MARK: Loading

    /// Loads the three sources (deinterleaved float channels at `sampleRate`,
    /// normally 48 kHz from AudioFileIO / LumberCore).
    public func load(
        bed: [[Float]],
        originalDrums: [[Float]]?,
        drums: [[Float]],
        sampleRate: Double,
        drumOffsetSec: Double,
        levels: Levels = Levels()
    ) throws {
        stopPlayers()
        guard let bedPCM = ChunkedPCM(channels: bed, sampleRate: sampleRate) else {
            throw PlatformError.engineFailed("The song has no audio")
        }
        self.bed = bedPCM
        self.orig = originalDrums.flatMap { ChunkedPCM(channels: $0, sampleRate: sampleRate) }
        self.drums = ChunkedPCM(channels: drums, sampleRate: sampleRate)
        self.drumOffsetSec = drumOffsetSec
        duration = bedPCM.durationSec
        startSongSec = 0
        anchor = nil

        if engine.isRunning { engine.stop() }
        connect(bedPlayer, bedGain, format: bedPCM.format)
        connect(origPlayer, origGain, format: orig?.format ?? bedPCM.format)
        connect(drumPlayer, drumGain, format: self.drums?.format ?? bedPCM.format)
        setLevels(levels)
        isLoaded = true
    }

    /// Swaps in a re-rendered drum buffer (same take, new DSP settings).
    public func replaceDrums(_ channels: [[Float]], sampleRate: Double) {
        let wasPlaying = isPlaying
        let pos = position
        let newDrums = ChunkedPCM(channels: channels, sampleRate: sampleRate)
        if newDrums?.format != drums?.format, let f = newDrums?.format {
            // Channel count or rate changed: reconnect (needs the engine stopped).
            stopPlayers()
            engine.stop()
            connect(drumPlayer, drumGain, format: f)
        }
        drums = newDrums
        if wasPlaying { try? play(from: pos) }
    }

    public func unload() {
        stopPlayers()
        engine.stop()
        bed = nil
        orig = nil
        drums = nil
        isLoaded = false
        duration = 0
        startSongSec = 0
    }

    // MARK: Transport

    /// Current playhead (seconds), from the host clock while playing.
    public var position: Double {
        guard isPlaying else { return startSongSec }
        return min(duration, startSongSec + max(0, TakeEngine.hostNowSec() - startHostSec))
    }

    /// Plays from `songSec` (default: the current playhead; from 0 at the end).
    public func play(from songSec: Double? = nil) throws {
        guard let bed else { return }
        try session.activate()
        stopPlayers()
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { throw PlatformError.engineFailed(error.localizedDescription) }
        }
        var from = songSec ?? startSongSec
        if from >= duration - 0.05 && songSec == nil { from = 0 }
        from = min(max(0, from), max(0, duration - 0.05))

        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: Self.leadSec)
        if bed.schedule(on: bedPlayer, fromSec: from) {
            bedPlayer.play(at: AVAudioTime(hostTime: startHost))
        }
        if let orig, orig.schedule(on: origPlayer, fromSec: from) {
            origPlayer.play(at: AVAudioTime(hostTime: startHost))
        }
        if let drums {
            let d = TakeClock.drumStartFor(songSec: from, drumOffsetSec: drumOffsetSec)
            if drums.schedule(on: drumPlayer, fromSec: d.offsetSec) {
                drumPlayer.play(at: AVAudioTime(hostTime: startHost + AVAudioTime.hostTime(forSeconds: d.delaySec)))
            }
        }
        startHostSec = AVAudioTime.seconds(forHostTime: startHost)
        startSongSec = from
        anchor = PlaybackAnchor(songSec: from, hostTime: startHost)
        isPlaying = true
        scheduleEnd(after: duration - from)
    }

    public func pause() {
        guard isPlaying else { return }
        let pos = position
        stopPlayers()
        startSongSec = pos
    }

    /// Moves the playhead; keeps playing if playing.
    public func seek(to songSec: Double) {
        let t = min(max(0, songSec), duration)
        if isPlaying { try? play(from: t) } else { startSongSec = t }
    }

    public func setLevels(_ l: Levels) {
        levels = l
        Self.setGain(bedGain, l.songGain)
        Self.setGain(origGain, orig == nil ? 0 : l.songGain * l.originalDrums)
        Self.setGain(drumGain, l.drumGain)
    }

    /// New drum placement (take offset + nudge). Restarts at the playhead if playing.
    public func setDrumOffset(_ sec: Double) {
        guard sec != drumOffsetSec else { return }
        drumOffsetSec = sec
        if isPlaying { try? play(from: position) }
    }

    // MARK: Internals

    private func connect(_ player: AVAudioPlayerNode, _ gain: AVAudioUnitEQ, format: AVAudioFormat) {
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(gain)
        engine.connect(player, to: gain, format: format)
        engine.connect(gain, to: engine.mainMixerNode, format: format)
    }

    private func stopPlayers() {
        generation += 1
        endTask?.cancel()
        endTask = nil
        if isPlaying { startSongSec = position }
        bedPlayer.stop()
        origPlayer.stop()
        drumPlayer.stop()
        isPlaying = false
        anchor = nil
    }

    private func scheduleEnd(after seconds: Double) {
        let gen = generation
        endTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds + Self.leadSec) * 1e9))
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.stopPlayers()
            self.startSongSec = self.duration
        }
    }

    private func handleEngineStopped() {
        guard isPlaying else { return }
        let pos = position
        stopPlayers()
        startSongSec = pos
    }

    private nonisolated static func makeGainUnit() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].bypass = true
        return eq
    }

    private nonisolated static func setGain(_ eq: AVAudioUnitEQ, _ linear: Float) {
        // globalGain range is -96...24 dB.
        let db: Float = linear <= 0 ? -96 : max(-96, min(24, 20 * log10(linear)))
        eq.globalGain = db
    }
}

/// Deinterleaved float audio as ~0.5 s AVAudioPCMBuffers.
final class ChunkedPCM {
    let format: AVAudioFormat
    let chunks: [AVAudioPCMBuffer]
    let chunkFrames: Int
    let totalFrames: Int

    var durationSec: Double { Double(totalFrames) / format.sampleRate }

    init?(channels: [[Float]], sampleRate: Double, chunkSeconds: Double = 0.5) {
        let total = channels.map(\.count).max() ?? 0
        guard !channels.isEmpty, total > 0, sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count))
        else { return nil }
        let size = max(1024, Int(chunkSeconds * sampleRate))
        var chunks: [AVAudioPCMBuffer] = []
        chunks.reserveCapacity(total / size + 1)
        var start = 0
        while start < total {
            let n = min(size, total - start)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let dst = b.floatChannelData
            else { return nil }
            for (c, ch) in channels.enumerated() {
                let have = max(0, min(n, ch.count - start))
                ch.withUnsafeBufferPointer { p in
                    if have > 0, let base = p.baseAddress { dst[c].update(from: base + start, count: have) }
                }
                if have < n { (dst[c] + have).update(repeating: 0, count: n - have) }
            }
            b.frameLength = AVAudioFrameCount(n)
            chunks.append(b)
            start += n
        }
        self.format = format
        self.chunks = chunks
        self.chunkFrames = size
        self.totalFrames = total
    }

    /// Schedules everything from `fromSec` on `player` (call before play(at:)).
    /// Returns false when there is nothing left to play.
    func schedule(on player: AVAudioPlayerNode, fromSec: Double) -> Bool {
        let frame = Int((fromSec * format.sampleRate).rounded())
        guard frame >= 0, frame < totalFrames else { return false }
        let first = frame / chunkFrames
        let offset = frame % chunkFrames
        if offset == 0 {
            player.scheduleBuffer(chunks[first], at: nil, options: [], completionHandler: nil)
        } else {
            let src = chunks[first]
            let n = Int(src.frameLength) - offset
            guard n > 0,
                  let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let s = src.floatChannelData, let d = part.floatChannelData
            else { return false }
            for c in 0..<Int(format.channelCount) { d[c].update(from: s[c] + offset, count: n) }
            part.frameLength = AVAudioFrameCount(n)
            player.scheduleBuffer(part, at: nil, options: [], completionHandler: nil)
        }
        for i in (first + 1)..<chunks.count {
            player.scheduleBuffer(chunks[i], at: nil, options: [], completionHandler: nil)
        }
        return true
    }
}
