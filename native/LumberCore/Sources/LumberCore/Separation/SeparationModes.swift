// How drum removal runs, and stepping down to a safer mode after a crash.
// Port of src/separation/modes.ts.
//
// A hard crash (iOS killing the app for memory) can't be caught, so the app
// leaves a breadcrumb while it works. If the next launch finds a breadcrumb
// that never got cleared, that run died, and the next run uses a safer mode:
//   coreml   — Core ML (Neural Engine/GPU) with CPU fallback. Fastest.
//   cpu      — ONNX Runtime CPU only, 2 threads.
//   cpuSlow  — CPU, 1 thread, short pause between chunks. Slowest, lightest.
// Every mode turns off ONNX Runtime's memory arena (with it on, a CPU run kept
// ~5 GB after two 7.8 s chunks).

import Foundation

public enum SeparationMode: String, Codable, Sendable, CaseIterable {
    case coreml
    case cpu
    case cpuSlow = "cpu-slow"

    public var label: String {
        switch self {
        case .coreml: "Core ML"
        case .cpu: "CPU"
        case .cpuSlow: "safe mode (slow)"
        }
    }

    /// What the app's ONNX Runtime session should use in this mode.
    public var sessionConfig: SeparationSessionConfig {
        switch self {
        case .coreml: SeparationSessionConfig(useCoreML: true, intraOpThreads: 0, basicOptimization: false)
        case .cpu: SeparationSessionConfig(useCoreML: false, intraOpThreads: 2, basicOptimization: true)
        case .cpuSlow: SeparationSessionConfig(useCoreML: false, intraOpThreads: 1, basicOptimization: true)
        }
    }

    public var pauseBetweenChunks: Duration { self == .cpuSlow ? .milliseconds(250) : .zero }
}

public struct SeparationSessionConfig: Sendable, Equatable {
    public var useCoreML: Bool
    /// 0 = ONNX Runtime default.
    public var intraOpThreads: Int
    public var basicOptimization: Bool
    /// Always off: see the note above.
    public var cpuMemArena: Bool { false }
    public var memPattern: Bool { false }
}

public struct SeparationBreadcrumb: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case load, decode, run }
    public var mode: SeparationMode
    public var stage: Stage
    public var chunk: Int?
    public var total: Int?
    public var startedAt: Date

    public init(mode: SeparationMode, stage: Stage, chunk: Int? = nil, total: Int? = nil, startedAt: Date = Date()) {
        self.mode = mode
        self.stage = stage
        self.chunk = chunk
        self.total = total
        self.startedAt = startedAt
    }
}

public struct SeparationModeState: Codable, Sendable, Equatable {
    public var mode: SeparationMode = .coreml
    public var inProgress: SeparationBreadcrumb?
    public var lastCrash: SeparationBreadcrumb?
    public init(mode: SeparationMode = .coreml, inProgress: SeparationBreadcrumb? = nil, lastCrash: SeparationBreadcrumb? = nil) {
        self.mode = mode
        self.inProgress = inProgress
        self.lastCrash = lastCrash
    }

    /// Called once before a run: if the previous run never finished, it
    /// crashed, so record it and step down one mode (never back up).
    public func recoveringFromCrash() -> (state: SeparationModeState, crashed: SeparationBreadcrumb?) {
        guard let crashed = inProgress else { return (self, nil) }
        let all = SeparationMode.allCases
        let worst = max(all.firstIndex(of: crashed.mode) ?? 0, all.firstIndex(of: mode) ?? 0)
        let next = all[min(all.count - 1, worst + 1)]
        return (SeparationModeState(mode: next, inProgress: nil, lastCrash: crashed), crashed)
    }
}

public func separationCrashMessage(_ crash: SeparationBreadcrumb, next: SeparationMode) -> String {
    let where_: String
    if crash.stage == .run, let total = crash.total {
        where_ = "at chunk \(crash.chunk ?? 0) of \(total)"
    } else if crash.stage == .load {
        where_ = "while loading the model"
    } else {
        where_ = "while decoding the song"
    }
    return "Last drum removal crashed \(where_) using \(crash.mode.label). Retrying with \(next.label)."
}
