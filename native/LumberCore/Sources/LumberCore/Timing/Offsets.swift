// Port of src/audio/offsets.ts: timing math for lining a drum take up with the song.
//
// Clocks (seconds):
//   engine time — the audio engine's clock (AudioContext.currentTime in TS;
//                 AVAudioEngine sample time / rate natively). Song playback is scheduled on it.
//   file time   — position in the recorded drum WAV (0 = first mic sample).
//   song time   — position in the song file.
// Mic and song share one engine, so file time and engine time differ by a
// constant (recStartCtx), estimated from (engine time, recorded duration) pairs.
// Output + input latency are lumped into one calibrated round trip.

import Foundation

/// Namespace for the take / video timing math.
public enum Timing {
    public struct ClockSample: Sendable, Equatable {
        /// Engine time when sampled.
        public var ctxTime: Double
        /// Recorder duration at the same moment.
        public var recSec: Double
        public init(ctxTime: Double, recSec: Double) { self.ctxTime = ctxTime; self.recSec = recSec }
    }

    /// Engine time of the recorder's first sample: median of ctxTime − recSec
    /// over pairs with recSec > 0. nil if none.
    public static func estimateRecorderStartCtx(_ samples: [ClockSample]) -> Double? {
        let diffs = samples.filter { $0.recSec > 0 }.map { $0.ctxTime - $0.recSec }
        return diffs.isEmpty ? nil : median(diffs)
    }

    /// Median (mean of the two middle values for even counts). Precondition: non-empty.
    public static func median(_ values: [Double]) -> Double {
        let v = values.sorted()
        let mid = v.count >> 1
        return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
    }

    public struct DrumOffsetInput: Sendable, Equatable {
        public var songStartSec: Double // song position playback started from
        public var songCtxStart: Double // engine time the song was scheduled to start
        public var recStartCtx: Double // engine time of the drum file's first sample
        public var latencySec: Double // round-trip latency to compensate
        public init(songStartSec: Double, songCtxStart: Double, recStartCtx: Double, latencySec: Double) {
            self.songStartSec = songStartSec; self.songCtxStart = songCtxStart
            self.recStartCtx = recStartCtx; self.latencySec = latencySec
        }
    }

    /// Song-timeline position of drum-file time 0.
    public static func computeDrumOffset(_ i: DrumOffsetInput) -> Double {
        i.songStartSec + (i.recStartCtx - i.songCtxStart) - i.latencySec
    }

    /// Song time → drum-file time for a take placed at `drumOffsetSec`.
    public static func songToDrumTime(_ songSec: Double, drumOffsetSec: Double) -> Double {
        songSec - drumOffsetSec
    }

    public struct Schedule: Sendable, Equatable {
        /// Engine times of count-in clicks (first is the accent).
        public var clickTimes: [Double]
        /// Engine time the song starts.
        public var songCtxStart: Double
        public var beatSec: Double
    }

    /// Count-in followed by the song, starting `leadSec` after `now`.
    public static func scheduleCountIn(now: Double, leadSec: Double, bpm: Double, countInBeats: Int) -> Schedule {
        let beatSec = 60 / clampBpm(bpm)
        let t0 = now + leadSec
        let beats = max(0, countInBeats)
        let clicks = (0..<beats).map { t0 + Double($0) * beatSec }
        return Schedule(clickTimes: clicks, songCtxStart: t0 + Double(beats) * beatSec, beatSec: beatSec)
    }

    /// BPM clamped to 30…300 (120 when not finite).
    public static func clampBpm(_ bpm: Double) -> Double {
        guard bpm.isFinite else { return 120 }
        return min(300, max(30, bpm))
    }

    public struct LoopRegion: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// Song position for a transport that started the song at `songCtxStart`
    /// from `songStartSec`; `songStartSec` during the count-in; wraps inside a loop.
    public static func transportPosition(now: Double, songCtxStart: Double, songStartSec: Double,
                                         loop: LoopRegion? = nil) -> Double {
        let elapsed = max(0, now - songCtxStart)
        let pos = songStartSec + elapsed
        guard let loop, loop.end > loop.start, pos >= loop.end else { return pos }
        let len = loop.end - loop.start
        return loop.start + jsRemainder(pos - loop.start, len)
    }

    /// JS `%` on doubles (truncated remainder, sign of the dividend).
    static func jsRemainder(_ a: Double, _ b: Double) -> Double { fmod(a, b) }

    /// Preview: where to start the drum buffer and how long to wait first.
    public static func drumStartFor(songSec: Double, drumOffsetSec: Double) -> (delaySec: Double, offsetSec: Double) {
        let t = songToDrumTime(songSec, drumOffsetSec: drumOffsetSec)
        return t >= 0 ? (0, t) : (-t, 0)
    }
}
