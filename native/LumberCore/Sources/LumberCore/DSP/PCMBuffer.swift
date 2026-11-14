// De-interleaved PCM plus its sample rate, and the `DSP` namespace that the
// free-standing DSP functions (effects, FFT, mixing, resampling) live in.
//
// Numerics: the TypeScript originals store samples in Float32Array but do all
// arithmetic in Float64 (JS numbers). The Swift ports mirror that exactly —
// intermediates in `Double`, every store rounded to `Float` — so results agree
// with the TS goldens to the last bit in most cases.

import Foundation

/// Namespace for Lumber's pure DSP functions (`DSP.compress`, `DSP.fft`, `DSP.mixTake`, …).
public enum DSP {}

/// De-interleaved audio: one `[Float]` per channel, all the same length.
public struct PCMBuffer: Sendable, Equatable {
    public var channels: [[Float]]
    public var sampleRate: Double

    public init(channels: [[Float]], sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
    }

    /// Frames per channel (0 when there are no channels).
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var channelCount: Int { channels.count }
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}

extension DSP {
    @inline(__always) static func dbToLin(_ db: Double) -> Double { pow(10, db / 20) }
    static let eps = 1e-12
}
