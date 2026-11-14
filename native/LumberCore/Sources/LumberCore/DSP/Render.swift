// Port of src/dsp/render.ts + renderBlanket.ts: offline render of an effect
// chain. The TS ran biquad/gain/reverb specs through an OfflineAudioContext;
// here they are computed directly with Web Audio semantics (see Biquad.swift,
// Reverb.swift). Custom specs run the Effects.swift code, in chain order.

import Foundation

extension DSP {
    /// Render `chain` over `source` and return the processed channels (same
    /// count and length as the source). `reverbSeed` seeds the reverb IR noise.
    public static func renderChain(_ source: [[Float]], sampleRate sr: Double, chain: [EffectSpec],
                                   reverbSeed: UInt32 = defaultReverbSeed) -> [[Float]] {
        var channels = source
        guard !channels.isEmpty else { return channels }
        for spec in chain {
            switch spec {
            case .biquad(let b):
                let c = BiquadCoefficients.webAudio(kind: b.kind, frequency: b.frequency, q: b.q ?? 1,
                                                    gainDb: b.gainDb ?? 0, sampleRate: sr)
                for ch in 0..<channels.count { channels[ch] = biquad(channels[ch], c) }
            case .gain(let db):
                let g = Double(Float(pow(10, db / 20))) // GainNode.gain is a float AudioParam
                for ch in 0..<channels.count {
                    channels[ch].withUnsafeMutableBufferPointer { x in
                        for i in 0..<x.count { x[i] = Float(Double(x[i]) * g) }
                    }
                }
            case .reverb(let r):
                channels = reverb(channels, sampleRate: sr, r, seed: reverbSeed)
            case .resonance(let amount):
                let q = amount * 30
                if q > 0 {
                    for f in detectResonances(channels, sampleRate: sr) {
                        let c = BiquadCoefficients.webAudio(kind: .notch, frequency: f, q: q, sampleRate: sr)
                        for ch in 0..<channels.count { channels[ch] = biquad(channels[ch], c) }
                    }
                }
            case .compressor(let p): compress(&channels, sampleRate: sr, p)
            case .gate(let p): gate(&channels, sampleRate: sr, p)
            case .upwardCompressor(let p): upwardCompress(&channels, sampleRate: sr, p)
            case .saturation(let drive): saturate(&channels, drive: drive)
            case .presence(let p): presence(&channels, sampleRate: sr, p)
            case .width(let amount): width(&channels, amount: amount)
            case .spectralGate(let p): spectralGate(&channels, p)
            }
        }
        return channels
    }

    /// Render a buffer through `chain`.
    public static func renderChain(_ buffer: PCMBuffer, chain: [EffectSpec],
                                   reverbSeed: UInt32 = defaultReverbSeed) -> PCMBuffer {
        PCMBuffer(channels: renderChain(buffer.channels, sampleRate: buffer.sampleRate, chain: chain,
                                        reverbSeed: reverbSeed),
                  sampleRate: buffer.sampleRate)
    }

    /// Build the Blanket chain from knob values (render order, 0s skipped) and
    /// render it. An all-zero map is a pass-through copy.
    public static func renderBlanket(_ pcm: [[Float]], sampleRate: Double, values: BlanketValues,
                                     intensity: Double = BlanketChain.intensity,
                                     reverbSeed: UInt32 = defaultReverbSeed) -> [[Float]] {
        renderChain(pcm, sampleRate: sampleRate, chain: BlanketChain.build(values, intensity: intensity),
                    reverbSeed: reverbSeed)
    }
}
