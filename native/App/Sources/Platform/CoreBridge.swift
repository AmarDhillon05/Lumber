// The only Platform file that imports LumberCore. Everything the platform
// layer needs from the pure core goes through here, so adapting to the
// core's final API names is a one-file change.
//
// Expected LumberCore API (Timing/Calibration.swift, port of src/audio/calibration.ts):
//
//   public struct LatencyEstimate: Sendable {
//       public var latencyMs: Double     // measured round trip
//       public var confidence: Double    // peak-to-median of the coarse correlation
//       public var spreadMs: Double      // per-click lag spread
//   }
//   public enum Calibration {
//       public static let clickCount: Int          // 8
//       public static let intervalSec: Double      // 0.5
//       public static func estimateLatency(
//           recorded: [Float], sampleRate: Double, clickFileTimes: [Double],
//           maxLagSec: Double = 0.6, template: [Float]? = nil
//       ) -> LatencyEstimate
//       public static func isReliable(_ e: LatencyEstimate) -> Bool   // confidence >= 8 && spreadMs <= 2
//   }

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
        let e = Calibration.estimateLatency(
            recorded: recorded,
            sampleRate: sampleRate,
            clickFileTimes: clickFileTimes,
            maxLagSec: 0.6,
            template: template
        )
        return Estimate(
            latencyMs: e.latencyMs,
            confidence: e.confidence,
            spreadMs: e.spreadMs,
            isReliable: Calibration.isReliable(e)
        )
    }
}
