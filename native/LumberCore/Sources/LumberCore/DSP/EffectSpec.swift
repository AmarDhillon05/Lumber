// Port of src/dsp/types.ts: effect chain specs. Each EffectChain/Blanket call
// appends one; rendering is deferred so one chain can drive both preview and
// export. Codable in the same JSON shape as the TS objects
// (`{"kind":"peaking","frequency":90,"q":1.2,"gainDb":1.5}`).

import Foundation

/// The Web Audio BiquadFilterNode types the chain uses.
public enum BiquadKind: String, Sendable, Codable, CaseIterable {
    case highpass, lowpass, bandpass, notch, peaking, lowshelf, highshelf
}

public struct BiquadSpec: Sendable, Equatable, Codable {
    public var kind: BiquadKind
    /// Hz (center or cutoff).
    public var frequency: Double
    /// Web Audio Q; nil = node default (1). dB for lowpass/highpass.
    public var q: Double?
    /// Peaking / shelves only; nil = 0 dB.
    public var gainDb: Double?

    public init(kind: BiquadKind, frequency: Double, q: Double? = nil, gainDb: Double? = nil) {
        self.kind = kind; self.frequency = frequency; self.q = q; self.gainDb = gainDb
    }
}

public struct ReverbSpec: Sendable, Equatable, Codable {
    public var roomSize: Double // 0..1
    public var damping: Double // 0..1
    public var wetLevel: Double // 0..1
    public var dryLevel: Double // 0..1
    public init(roomSize: Double, damping: Double, wetLevel: Double, dryLevel: Double) {
        self.roomSize = roomSize; self.damping = damping; self.wetLevel = wetLevel; self.dryLevel = dryLevel
    }
}

/// Parameters shared by the compressor and the gate.
public struct DynamicsParams: Sendable, Equatable, Codable {
    public var thresholdDb: Double
    public var ratio: Double
    public var attackMs: Double
    public var releaseMs: Double
    public init(thresholdDb: Double, ratio: Double, attackMs: Double, releaseMs: Double) {
        self.thresholdDb = thresholdDb; self.ratio = ratio; self.attackMs = attackMs; self.releaseMs = releaseMs
    }
}

public struct UpwardCompressorParams: Sendable, Equatable, Codable {
    public var thresholdDb: Double
    public var ratio: Double
    /// Cap on the makeup boost so silence isn't lifted.
    public var maxGainDb: Double
    public var attackMs: Double
    public var releaseMs: Double
    public init(thresholdDb: Double, ratio: Double, maxGainDb: Double, attackMs: Double, releaseMs: Double) {
        self.thresholdDb = thresholdDb; self.ratio = ratio; self.maxGainDb = maxGainDb
        self.attackMs = attackMs; self.releaseMs = releaseMs
    }
}

public struct PresenceParams: Sendable, Equatable, Codable {
    public var lowHz: Double
    public var highHz: Double
    public var drive: Double
    public var blend: Double
    public init(lowHz: Double, highHz: Double, drive: Double, blend: Double) {
        self.lowHz = lowHz; self.highHz = highHz; self.drive = drive; self.blend = blend
    }
}

public struct SpectralGateParams: Sendable, Equatable, Codable {
    /// 0..1
    public var propDecrease: Double
    /// true = denoise (global floor), false = roominess (time-local floor).
    public var stationary: Bool
    public init(propDecrease: Double, stationary: Bool) {
        self.propDecrease = propDecrease; self.stationary = stationary
    }
}

/// One step of an effect chain.
public enum EffectSpec: Sendable, Equatable {
    // Rendered by the built-in "native" path (Web Audio semantics).
    case biquad(BiquadSpec)
    case gain(db: Double)
    case reverb(ReverbSpec)
    // Custom DSP.
    case compressor(DynamicsParams)
    case gate(DynamicsParams)
    case upwardCompressor(UpwardCompressorParams)
    /// y = tanh(x·drive) / drive
    case saturation(drive: Double)
    case presence(PresenceParams)
    /// Side gain: 1× at 0, 2× at 1.
    case width(amount: Double)
    case spectralGate(SpectralGateParams)
    /// Notch Q = amount · 30 on detected resonances.
    case resonance(amount: Double)

    /// The TS `kind` string.
    public var kind: String {
        switch self {
        case .biquad(let b): return b.kind.rawValue
        case .gain: return "gain"
        case .reverb: return "reverb"
        case .compressor: return "compressor"
        case .gate: return "gate"
        case .upwardCompressor: return "upwardCompressor"
        case .saturation: return "saturation"
        case .presence: return "presence"
        case .width: return "width"
        case .spectralGate: return "spectralGate"
        case .resonance: return "resonance"
        }
    }

    /// Biquad / gain / reverb (the TS `isNativeSpec`).
    public var isNative: Bool {
        switch self {
        case .biquad, .gain, .reverb: return true
        default: return false
        }
    }
}

extension EffectSpec: Codable {
    private enum K: String, CodingKey {
        case kind, frequency, q, gainDb, db, roomSize, damping, wetLevel, dryLevel
        case thresholdDb, ratio, attackMs, releaseMs, maxGainDb, drive, lowHz, highHz, blend
        case amount, propDecrease, stationary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decode(String.self, forKey: .kind)
        if let bk = BiquadKind(rawValue: kind) {
            self = .biquad(BiquadSpec(kind: bk, frequency: try c.decode(Double.self, forKey: .frequency),
                                      q: try c.decodeIfPresent(Double.self, forKey: .q),
                                      gainDb: try c.decodeIfPresent(Double.self, forKey: .gainDb)))
            return
        }
        func d(_ k: K) throws -> Double { try c.decode(Double.self, forKey: k) }
        switch kind {
        case "gain": self = .gain(db: try d(.db))
        case "reverb":
            self = .reverb(ReverbSpec(roomSize: try d(.roomSize), damping: try d(.damping),
                                      wetLevel: try d(.wetLevel), dryLevel: try d(.dryLevel)))
        case "compressor", "gate":
            let p = DynamicsParams(thresholdDb: try d(.thresholdDb), ratio: try d(.ratio),
                                   attackMs: try d(.attackMs), releaseMs: try d(.releaseMs))
            self = kind == "gate" ? .gate(p) : .compressor(p)
        case "upwardCompressor":
            self = .upwardCompressor(UpwardCompressorParams(
                thresholdDb: try d(.thresholdDb), ratio: try d(.ratio), maxGainDb: try d(.maxGainDb),
                attackMs: try d(.attackMs), releaseMs: try d(.releaseMs)))
        case "saturation": self = .saturation(drive: try d(.drive))
        case "presence":
            self = .presence(PresenceParams(lowHz: try d(.lowHz), highHz: try d(.highHz),
                                            drive: try d(.drive), blend: try d(.blend)))
        case "width": self = .width(amount: try d(.amount))
        case "spectralGate":
            self = .spectralGate(SpectralGateParams(propDecrease: try d(.propDecrease),
                                                    stationary: try c.decode(Bool.self, forKey: .stationary)))
        case "resonance": self = .resonance(amount: try d(.amount))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown effect kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .biquad(let b):
            try c.encode(b.frequency, forKey: .frequency)
            try c.encodeIfPresent(b.q, forKey: .q)
            try c.encodeIfPresent(b.gainDb, forKey: .gainDb)
        case .gain(let db): try c.encode(db, forKey: .db)
        case .reverb(let r):
            try c.encode(r.roomSize, forKey: .roomSize); try c.encode(r.damping, forKey: .damping)
            try c.encode(r.wetLevel, forKey: .wetLevel); try c.encode(r.dryLevel, forKey: .dryLevel)
        case .compressor(let p), .gate(let p):
            try c.encode(p.thresholdDb, forKey: .thresholdDb); try c.encode(p.ratio, forKey: .ratio)
            try c.encode(p.attackMs, forKey: .attackMs); try c.encode(p.releaseMs, forKey: .releaseMs)
        case .upwardCompressor(let p):
            try c.encode(p.thresholdDb, forKey: .thresholdDb); try c.encode(p.ratio, forKey: .ratio)
            try c.encode(p.maxGainDb, forKey: .maxGainDb)
            try c.encode(p.attackMs, forKey: .attackMs); try c.encode(p.releaseMs, forKey: .releaseMs)
        case .saturation(let drive): try c.encode(drive, forKey: .drive)
        case .presence(let p):
            try c.encode(p.lowHz, forKey: .lowHz); try c.encode(p.highHz, forKey: .highHz)
            try c.encode(p.drive, forKey: .drive); try c.encode(p.blend, forKey: .blend)
        case .width(let a): try c.encode(a, forKey: .amount)
        case .spectralGate(let p):
            try c.encode(p.propDecrease, forKey: .propDecrease); try c.encode(p.stationary, forKey: .stationary)
        case .resonance(let a): try c.encode(a, forKey: .amount)
        }
    }
}
