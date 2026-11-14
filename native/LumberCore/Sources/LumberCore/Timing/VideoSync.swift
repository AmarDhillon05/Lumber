// Port of src/video/sync.ts: placing the camera clip on the song timeline.
//
// Clocks: wall time (ms; the one clock both camera events and the audio engine
// can be read against), engine time (s; the song is scheduled on it), video
// time (s in the clip), song time (s; also the export timeline).
//   1. Sample (wall, engine) pairs while recording → wallToCtxOffset.
//   2. Progress events report the clip's duration; wall − duration is the first
//      frame's wall time plus non-negative noise, so a low percentile is used.
//      Fallback: the wall time recording was started.
//   3. Video time 0 belongs at song time
//      songStartSec + (videoStartCtx − songCtxStart) − outputLatency.

import Foundation

extension Timing {
    public struct WallCtxPair: Sendable, Equatable {
        public var wallMs: Double
        public var ctxSec: Double
        public init(wallMs: Double, ctxSec: Double) { self.wallMs = wallMs; self.ctxSec = ctxSec }
    }

    public struct ProgressSample: Sendable, Equatable {
        public var wallMs: Double
        public var durationSec: Double
        public init(wallMs: Double, durationSec: Double) { self.wallMs = wallMs; self.durationSec = durationSec }
    }

    /// engine = wall/1000 + offset; median over pairs with a running engine (ctxSec > 0).
    public static func wallToCtxOffset(_ pairs: [WallCtxPair]) -> Double? {
        let d = pairs.filter { $0.ctxSec.isFinite && $0.ctxSec > 0 }.map { $0.ctxSec - $0.wallMs / 1000 }
        return d.isEmpty ? nil : median(d)
    }

    /// q-quantile (0..1) with linear interpolation. Precondition: non-empty.
    public static func quantile(_ values: [Double], _ q: Double) -> Double {
        let v = values.sorted()
        if v.count == 1 { return v[0] }
        let pos = min(1, max(0, q)) * Double(v.count - 1)
        let i = Int(pos.rounded(.down))
        let f = pos - Double(i)
        return i + 1 < v.count ? v[i] + (v[i + 1] - v[i]) * f : v[i]
    }

    /// Wall time (ms) of the clip's first frame from progress events, or nil.
    public static func estimateVideoStartWall(_ samples: [ProgressSample], q: Double = 0.1) -> Double? {
        let d = samples.filter { $0.durationSec > 0 && $0.durationSec.isFinite }
            .map { $0.wallMs - $0.durationSec * 1000 }
        return d.isEmpty ? nil : quantile(d, q)
    }

    /// Built-in mic input latency on iPhone (ms).
    public static let inputLatencyMs = 8.0

    /// Output (heard-later) share of the round-trip latency, seconds, ≥ 0.
    public static func outputLatencySec(roundTripMs: Double, inputMs: Double = inputLatencyMs) -> Double {
        max(0, roundTripMs - inputMs) / 1000
    }

    public struct VideoOffsetInput: Sendable, Equatable {
        public var songStartSec: Double
        public var songCtxStart: Double
        public var videoStartCtx: Double
        public var outputLatencySec: Double
        public init(songStartSec: Double, songCtxStart: Double, videoStartCtx: Double, outputLatencySec: Double) {
            self.songStartSec = songStartSec; self.songCtxStart = songCtxStart
            self.videoStartCtx = videoStartCtx; self.outputLatencySec = outputLatencySec
        }
    }

    public static func computeVideoOffset(_ i: VideoOffsetInput) -> Double {
        i.songStartSec + (i.videoStartCtx - i.songCtxStart) - i.outputLatencySec
    }

    public struct VideoTimingInput: Sendable, Equatable {
        public var pairs: [WallCtxPair]
        public var progress: [ProgressSample]
        /// Wall time recording was started.
        public var recordCallWallMs: Double
        public var songStartSec: Double
        public var songCtxStart: Double
        /// Round-trip latency compensated for the drums.
        public var latencyMs: Double
        public init(pairs: [WallCtxPair], progress: [ProgressSample], recordCallWallMs: Double,
                    songStartSec: Double, songCtxStart: Double, latencyMs: Double) {
            self.pairs = pairs; self.progress = progress; self.recordCallWallMs = recordCallWallMs
            self.songStartSec = songStartSec; self.songCtxStart = songCtxStart; self.latencyMs = latencyMs
        }
    }

    public struct VideoTiming: Sendable, Equatable {
        public enum Source: String, Sendable { case progress, call }
        /// Song time of video time 0.
        public var offsetSec: Double
        public var source: Source
        /// From the last progress event (0 if none).
        public var durationSec: Double
    }

    public static func videoTiming(_ i: VideoTimingInput) -> VideoTiming? {
        guard let off = wallToCtxOffset(i.pairs) else { return nil }
        let fromProgress = estimateVideoStartWall(i.progress)
        // The first frame can't precede the call that started the recording.
        let usable = fromProgress.map { $0 >= i.recordCallWallMs - 50 } ?? false
        let startWall = usable ? fromProgress! : i.recordCallWallMs
        let durationSec = i.progress.reduce(0) { max($0, $1.durationSec) }
        return VideoTiming(
            offsetSec: computeVideoOffset(VideoOffsetInput(
                songStartSec: i.songStartSec, songCtxStart: i.songCtxStart,
                videoStartCtx: startWall / 1000 + off,
                outputLatencySec: outputLatencySec(roundTripMs: i.latencyMs))),
            source: usable ? .progress : .call,
            durationSec: durationSec)
    }

    /// Recorded offset plus the per-project nudge (positive = video later).
    public static func finalVideoOffsetSec(_ offsetSec: Double, nudgeMs: Double?) -> Double {
        offsetSec + (nudgeMs ?? 0) / 1000
    }

    public struct VideoExportPlan: Sendable, Equatable {
        public var audioStartSec: Double // where to cut the mix (song time)
        public var videoStartSec: Double // where to cut the clip (video time)
        public var durationSec: Double
    }

    /// Overlap of the clip (placed at videoOffsetSec) and the mix [0, mixDurationSec); nil if ≤ 50 ms.
    public static func planVideoExport(videoOffsetSec: Double, videoDurationSec: Double,
                                       mixDurationSec: Double) -> VideoExportPlan? {
        let lo = max(0, videoOffsetSec)
        let hi = min(mixDurationSec, videoOffsetSec + videoDurationSec)
        guard hi - lo > 0.05 else { return nil }
        return VideoExportPlan(audioStartSec: lo, videoStartSec: lo - videoOffsetSec, durationSec: hi - lo)
    }

    /// Preview: where the clip should be for a song position and how long to
    /// wait before it starts; nil once past the clip.
    public static func videoStartFor(songSec: Double, videoOffsetSec: Double,
                                     videoDurationSec: Double) -> (delaySec: Double, videoSec: Double)? {
        let t = songSec - videoOffsetSec
        if videoDurationSec > 0 && t >= videoDurationSec { return nil }
        return t >= 0 ? (0, t) : (-t, 0)
    }

    /// Sample range [start, end) of a mix to keep for the export.
    public static func sampleRange(_ plan: VideoExportPlan, sampleRate: Double, totalSamples: Int) -> Range<Int> {
        let a = max(0, min(totalSamples, DSP.jsRound(plan.audioStartSec * sampleRate)))
        let b = max(a, min(totalSamples, a + DSP.jsRound(plan.durationSec * sampleRate)))
        return a..<b
    }
}
