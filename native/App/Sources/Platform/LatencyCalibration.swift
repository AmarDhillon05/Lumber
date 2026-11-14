// Round-trip latency calibration per output route.
//
// Plays N clicks through the current output while recording the mic on the
// exact path a take uses (TakeEngine.recordClickTrain), then finds the clicks
// in the recording by cross-correlation (LumberCore). The measured round
// trip L is split into what the session reports for the route
// (outputLatency + inputLatency) and a residual R = L − reported. Takes then
// compensate reported-now + R, so a later change of IO buffer or codec
// latency that the session does report is still handled correctly.

import Foundation

/// One calibration result for one output route.
public struct LatencyCalibration: Sendable, Codable, Equatable {
    public var routeKey: String
    public var routeName: String
    /// Measured round trip (ms).
    public var roundTripMs: Double
    /// What the session reported for the route at the time (ms).
    public var reportedMs: Double
    /// roundTripMs − reportedMs: what takes add on top of the reported latency.
    public var residualMs: Double
    public var confidence: Double
    public var spreadMs: Double
    public var isReliable: Bool
    public var measuredAt: Date
}

/// Per-route calibrations, persisted in UserDefaults.
@MainActor
public final class LatencyStore {
    public static let shared = LatencyStore()

    private let defaults: UserDefaults
    private let key: String
    private var table: [String: LatencyCalibration]

    public init(defaults: UserDefaults = .standard, key: String = "lumber.latencyCalibrations.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: LatencyCalibration].self, from: data) {
            table = decoded
        } else {
            table = [:]
        }
    }

    public var all: [LatencyCalibration] { Array(table.values) }

    public func calibration(for routeKey: String) -> LatencyCalibration? { table[routeKey] }

    /// Residual to pass as `TakeOptions.calibrationResidualMs` (0 if never calibrated).
    public func residualMs(for route: AudioRoute) -> Double { table[route.key]?.residualMs ?? 0 }

    public func save(_ c: LatencyCalibration) {
        table[c.routeKey] = c
        persist()
    }

    public func remove(routeKey: String) {
        table[routeKey] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(table) { defaults.set(data, forKey: key) }
    }
}

@MainActor
public final class LatencyCalibrator {
    public static let clickCount = 8
    public static let intervalSec = 0.5

    private let engine: TakeEngine
    private let store: LatencyStore

    public init(engine: TakeEngine, store: LatencyStore? = nil) {
        self.engine = engine
        self.store = store ?? .shared
    }

    /// Runs one calibration on the current output. Saves it for the route
    /// when `save` is true and the estimate is reliable.
    /// Run on the speaker (or with headphones held to the mic) in a quiet room.
    public func run(save: Bool = true) async throws -> LatencyCalibration {
        let rec = try await engine.recordClickTrain(count: Self.clickCount, intervalSec: Self.intervalSec)
        let estimate = await Task.detached(priority: .userInitiated) {
            CoreBridge.estimateLatency(
                recorded: rec.samples,
                sampleRate: rec.sampleRate,
                clickFileTimes: rec.clickFileTimes,
                template: rec.template
            )
        }.value
        let reported = rec.route.reportedRoundTripMs
        let result = LatencyCalibration(
            routeKey: rec.route.key,
            routeName: rec.route.name,
            roundTripMs: estimate.latencyMs,
            reportedMs: reported,
            residualMs: LatencyMath.residualMs(measuredRoundTripMs: estimate.latencyMs, reportedRoundTripMs: reported),
            confidence: estimate.confidence,
            spreadMs: estimate.spreadMs,
            isReliable: estimate.isReliable,
            measuredAt: Date()
        )
        if save && result.isReliable { store.save(result) }
        return result
    }
}
