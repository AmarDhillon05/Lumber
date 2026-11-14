// Glue for "Describe the sound". Port of src/ai/mixPrompt.ts: analyse the
// project's audio once, then turn a prompt into a mix suggestion with Claude
// when there's a key and a connection, or with the offline interpreter.

import Foundation

/// Decoded project audio (src/audio/sources.ts ProjectAudio).
public struct MixProjectAudio: Sendable {
    public var sampleRate: Double
    public var drums: [[Float]] // raw take
    public var song: [[Float]]? // full song (when no stems)
    public var stems: (drums: [[Float]], noDrums: [[Float]])?

    public init(sampleRate: Double, drums: [[Float]], song: [[Float]]?, stems: (drums: [[Float]], noDrums: [[Float]])? = nil) {
        self.sampleRate = sampleRate
        self.drums = drums
        self.song = song
        self.stems = stems
    }
}

public enum MixSource: String, Sendable {
    case claude, offline
}

public struct PromptMixOutcome: Sendable {
    public var suggestion: MixSuggestion
    public var source: MixSource
    /// Why the offline interpreter was used, or a Claude error.
    public var notice: String?
}

public enum PromptMix {
    /// Descriptors for the take and the part of the song under it (the
    /// drumless stem when the song has been separated).
    public static func analyzeProject(_ audio: MixProjectAudio, drumOffsetSec: Double) -> MixAnalysis {
        let sr = audio.sampleRate
        let drums = AudioAnalysis.analyze(audio.drums, sampleRate: sr)
        let bed = audio.stems?.noDrums ?? audio.song
        var song: AudioDescriptors?
        if let bed, let first = bed.first, !first.isEmpty {
            let bedSec = Double(first.count) / sr
            let takeSec = Double(audio.drums.first?.count ?? 0) / sr
            // Song region under the take; fall back to the start when the take runs past the end.
            var start = Swift.max(0, drumOffsetSec)
            if start >= bedSec - 1 { start = 0 }
            song = AudioAnalysis.analyze(bed, sampleRate: sr, options: AnalyzeOptions(startSec: start, maxSec: Swift.max(5, Swift.min(30, takeSec))))
        }
        return MixAnalysis(drums: drums, song: song, songIsDrumless: audio.stems != nil)
    }

    /// Claude first when a key is set; on any failure the offline interpreter
    /// answers instead and `notice` says why.
    public static func run(
        _ input: ClaudeMixInput, apiKey: String?, model: ClaudeModel = .default, http: HTTPClient
    ) async -> PromptMixOutcome {
        func offline(_ notice: String?) -> PromptMixOutcome {
            let r = LocalMix.interpret(
                LocalMixInput(prompt: input.prompt, values: input.values, songGain: input.songGain, drumGain: input.drumGain, analysis: input.analysis))
            return PromptMixOutcome(suggestion: r.suggestion, source: .offline, notice: notice)
        }
        guard let apiKey, !apiKey.isEmpty else {
            return offline("No Anthropic API key — used the offline interpreter. Add a key in AI settings to use Claude.")
        }
        do {
            let s = try await ClaudeMix.suggest(input, apiKey: apiKey, model: model, http: http)
            return PromptMixOutcome(suggestion: s, source: .claude, notice: nil)
        } catch {
            return offline("\(ClaudeMix.classify(error).message) Used the offline interpreter instead.")
        }
    }
}
