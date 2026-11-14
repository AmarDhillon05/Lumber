// Pure timing helpers for the platform services: no AVFoundation, so this
// file type-checks (and can be tested) on Linux too.
//
// Clocks (all in seconds):
//   host time  — mach_absolute_time() converted with AVAudioTime.seconds(forHostTime:).
//                AVAudioEngine render/tap timestamps, AVAudioPlayerNode.play(at:)
//                and (after CMSyncConvertTime) the camera's synchronizationClock
//                all live in it. It is the one clock everything is placed on.
//   file time  — position inside the recorded drum WAV (0 = first mic sample).
//   song time  — position inside the song file; also the export timeline.
//
// Several of these mirror functions LumberCore's Timing module is expected to
// own (median, quantile, transportPosition, drumStartFor, clampBpm, makeClick).
// They are duplicated here only so the platform layer has no hard dependency
// on names that do not exist yet. TODO: use LumberCore once Timing/DSP land.

import Foundation

/// A loop region on the song timeline (seconds).
public struct LoopRegion: Sendable, Codable, Equatable, Hashable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var isValid: Bool { end > start && start >= 0 }
    public var length: Double { end - start }
}

/// Count-in clicks before the song.
public struct CountIn: Sendable, Codable, Equatable, Hashable {
    public var bpm: Double
    public var beats: Int

    public init(bpm: Double, beats: Int) {
        self.bpm = bpm
        self.beats = beats
    }
}

public enum TakeClock {
    /// Song-timeline position where drum-file sample 0 belongs.
    ///
    /// - `songStartHostSec` is the host time at which the song sample at
    ///   `songStartSec` is rendered to the output (what `play(at:)` was given).
    /// - `fileStartHostSec` is the host time stamped on drum-file sample 0 by
    ///   the input node (tap `when.hostTime` of the first buffer).
    /// - `latencySec` is the full round trip: output latency (render → speaker
    ///   / headphone) + input latency (mic → stamped buffer) + whatever
    ///   calibration measured on top of what the session reports.
    ///
    /// The drummer plays to the song as heard, i.e. song time s is heard at
    ///   H_s + (s − songStartSec) + outLat.
    /// The hit made at that instant is stamped in the input at that time
    /// + inLat, i.e. at file time f where
    ///   fileStartHostSec + f = H_s + (s − songStartSec) + outLat + inLat.
    /// Solving for s at f = 0:
    ///   s0 = songStartSec + (fileStartHostSec − H_s) − (outLat + inLat).
    /// Usually s0 < songStartSec: the recording starts before count-in.
    public static func drumOffset(
        songStartSec: Double,
        songStartHostSec: Double,
        fileStartHostSec: Double,
        latencySec: Double
    ) -> Double {
        songStartSec + (fileStartHostSec - songStartHostSec) - latencySec
    }

    /// Song-timeline position where video time 0 belongs.
    ///
    /// The camera stamps frames with their capture time (no latency to add):
    /// a hit seen in frame v happened at host videoStartHostSec + v, in
    /// response to song audio rendered outputLatencySec earlier. Same
    /// derivation as `drumOffset` with inLat = 0.
    public static func videoOffset(
        songStartSec: Double,
        songStartHostSec: Double,
        videoStartHostSec: Double,
        outputLatencySec: Double
    ) -> Double {
        songStartSec + (videoStartHostSec - songStartHostSec) - outputLatencySec
    }

    /// Song position of a running transport (seconds). Before the song starts
    /// (count-in) it returns `songStartSec`; inside a loop it wraps.
    public static func transportPosition(
        nowHostSec: Double,
        songStartHostSec: Double,
        songStartSec: Double,
        loop: LoopRegion?
    ) -> Double {
        let pos = songStartSec + max(0, nowHostSec - songStartHostSec)
        guard let loop, loop.isValid, pos >= loop.end else { return pos }
        return loop.start + (pos - loop.start).truncatingRemainder(dividingBy: loop.length)
    }

    public static func clampBpm(_ bpm: Double) -> Double {
        guard bpm.isFinite else { return 120 }
        return min(300, max(30, bpm))
    }

    public static func beatSeconds(bpm: Double) -> Double { 60 / clampBpm(bpm) }

    /// Length of the count-in (seconds); the song starts this long after the first click.
    public static func countInSeconds(_ countIn: CountIn?) -> Double {
        guard let countIn, countIn.beats > 0 else { return 0 }
        return Double(countIn.beats) * beatSeconds(bpm: countIn.bpm)
    }

    /// Click start times (seconds from the first click).
    public static func countInClickTimes(_ countIn: CountIn?) -> [Double] {
        guard let countIn, countIn.beats > 0 else { return [] }
        let beat = beatSeconds(bpm: countIn.bpm)
        return (0..<countIn.beats).map { Double($0) * beat }
    }

    /// Preview: where to start the drum buffer and how long to wait first.
    public static func drumStartFor(songSec: Double, drumOffsetSec: Double) -> (delaySec: Double, offsetSec: Double) {
        let t = songSec - drumOffsetSec
        return t >= 0 ? (0, t) : (-t, 0)
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let v = values.sorted()
        let mid = v.count / 2
        return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
    }

    /// q-quantile (0...1) with linear interpolation.
    public static func quantile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let v = values.sorted()
        if v.count == 1 { return v[0] }
        let pos = min(1, max(0, q)) * Double(v.count - 1)
        let i = Int(pos.rounded(.down))
        let f = pos - Double(i)
        return i + 1 < v.count ? v[i] + (v[i + 1] - v[i]) * f : v[i]
    }

    /// Root-mean-square distance of `values` from `center` (seconds), for diagnostics.
    public static func spread(_ values: [Double], around center: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.reduce(0) { $0 + ($1 - center) * ($1 - center) }
        return (s / Double(values.count)).squareRoot()
    }
}

// MARK: - Click synthesis

/// The metronome click: a sine burst with a fast exponential decay.
/// Exact port of `src/audio/click.ts` so calibration's matched filter uses
/// the very waveform that was played. TODO: use LumberCore's click once it exists.
public struct ClickSound: Sendable, Equatable {
    public var freq: Double
    public var durationMs: Double
    public var gain: Double

    public init(freq: Double, durationMs: Double, gain: Double) {
        self.freq = freq
        self.durationMs = durationMs
        self.gain = gain
    }

    public static let accent = ClickSound(freq: 1600, durationMs: 35, gain: 0.9)
    public static let beat = ClickSound(freq: 1000, durationMs: 30, gain: 0.7)
}

public enum ClickSynth {
    public static func make(sampleRate: Double, _ click: ClickSound) -> [Float] {
        let n = max(1, Int((sampleRate * click.durationMs / 1000).rounded()))
        let tau = Double(n) / 6 // ~-52 dB by the end
        let attack = Double(max(1, Int((sampleRate * 0.0005).rounded()))) // 0.5 ms ramp
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = Double(i)
            let env = exp(-x / tau) * min(1, x / attack)
            out[i] = Float(click.gain * env * sin(2 * Double.pi * click.freq * x / sampleRate))
        }
        return out
    }

    /// Mono buffer with a click starting at each of `times` (seconds from the
    /// buffer start, rounded to the nearest sample). The first click uses
    /// `first` (accent), the rest `rest`.
    public static func train(
        sampleRate: Double,
        times: [Double],
        first: ClickSound = .accent,
        rest: ClickSound = .beat
    ) -> [Float] {
        guard !times.isEmpty else { return [] }
        let a = make(sampleRate: sampleRate, first)
        let b = make(sampleRate: sampleRate, rest)
        let starts = times.map { max(0, Int(($0 * sampleRate).rounded())) }
        var length = 0
        for (i, s) in starts.enumerated() { length = max(length, s + (i == 0 ? a.count : b.count)) }
        var out = [Float](repeating: 0, count: length)
        for (i, s) in starts.enumerated() {
            let click = i == 0 ? a : b
            for k in 0..<click.count { out[s + k] += click[k] }
        }
        return out
    }
}

// MARK: - Routes and latency

public enum RouteNaming {
    /// AVAudioSession.Port raw values that mean "the drummer hears the song
    /// in their ears, not through the room".
    public static let headphonePorts: Set<String> = [
        "Headphones", "BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE", "USBAudio", "LineOut",
    ]

    /// Stable key for the per-route latency table. Same shape as the RN app
    /// ("Speaker" or "<portType>:<portName>") so saved calibrations carry over.
    public static func key(portType: String, portName: String) -> String {
        portType == "Speaker" ? "Speaker" : "\(portType):\(portName)"
    }

    public static func isHeadphones(portType: String) -> Bool { headphonePorts.contains(portType) }
    public static func isBluetooth(portType: String) -> Bool { portType.hasPrefix("Bluetooth") }
}

public enum LatencyMath {
    /// What calibration measured on top of what the session reports (ms). Can
    /// be negative if the session over-reports.
    public static func residualMs(measuredRoundTripMs: Double, reportedRoundTripMs: Double) -> Double {
        measuredRoundTripMs - reportedRoundTripMs
    }

    /// Total round trip to compensate: reported now + residual measured earlier.
    /// Using the residual (not the old total) keeps the compensation right if
    /// the IO buffer or Bluetooth codec latency changed since calibration.
    public static func compensationSec(reportedOutputSec: Double, reportedInputSec: Double, residualMs: Double) -> Double {
        max(0, reportedOutputSec + reportedInputSec + residualMs / 1000)
    }
}
