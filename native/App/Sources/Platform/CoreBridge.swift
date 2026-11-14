// The only Platform file that imports LumberCore. Everything the platform
// layer needs from the pure core goes through here, so a change in the
// core's API is a one-file change.
//
// LumberCore API used (native/core-dsp, Timing/Calibration.swift, port of
// src/audio/calibration.ts):
//
//   Timing.estimateLatency(_ recorded: [Float], sampleRate: Double,
//                          clickFileTimes: [Double], maxLagSec: Double = 0.6,
//                          template: [Float]? = nil) -> Timing.LatencyEstimate
//   Timing.LatencyEstimate { latencyMs, confidence, spreadMs, isReliable }
//
// The click itself (Timing.makeClick / ClickOptions) is mirrored by
// ClickSynth in TakeClock.swift (identical math), so the waveform played and
// the matched-filter template are the same; the template is passed explicitly.

import LumberCore

enum CoreBridge {
    struct Estimate: Sendable, Equatable {
        var latencyMs: Double
        var confidence: Double
        var spreadMs: Double
        var isReliable: Bool
    }

    /// Matched-filter + click-train cross-correlation (LumberCore Timing).
    /// CPU-heavy (FFT over the recording): call off the main actor.
    static func estimateLatency(
        recorded: [Float],
        sampleRate: Double,
        clickFileTimes: [Double],
        template: [Float]
    ) -> Estimate {
        let e = Timing.estimateLatency(
            recorded,
            sampleRate: sampleRate,
            clickFileTimes: clickFileTimes,
            maxLagSec: 0.6,
            template: template
        )
        return Estimate(latencyMs: e.latencyMs, confidence: e.confidence, spreadMs: e.spreadMs, isReliable: e.isReliable)
    }
}
