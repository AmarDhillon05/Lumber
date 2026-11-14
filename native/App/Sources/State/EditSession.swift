// Edit / Export screen logic: preview playback, waveform lanes, alignment
// nudge, faders, presets and knobs (debounced re-render), "Describe the
// sound", exports and Save raw take. Port of src/screens/EditScreen.tsx,
// src/video/EditVideo.tsx and src/ai/PromptMix.tsx (UI in UI/EditScreen.swift).

import Foundation
import Observation

@MainActor
@Observable
final class EditSession {
    static let columns = 90
    static let nudgeRangeMs: Double = 300
    static let videoNudgeRangeMs: Double = 1500
    static let frameMs: Double = 33 // one frame at 30 fps
    static let promptExamples = [
        "punchy and dry like a 90s rock record",
        "less boomy, more room",
        "warm and vintage",
        "brighter, cut through the song",
    ]
    private static let maxUndo = 10

    let projectId: String
    private let model: AppModel

    private(set) var audio: LoadedProjectAudio?
    private(set) var loadError: String?
    private(set) var rendering = false
    private(set) var playing = false
    var playhead: Double = 0
    private(set) var songPeaks: [Float] = []
    private(set) var drumPeaks: [Float] = []

    private(set) var exporting: ExportFormat?
    private(set) var exportProgress: Double = 0
    private(set) var savingTake = false
    var saved: [Recording] = []
    var alertMessage: String?

    var prompt = ""
    private(set) var promptBusy = false
    private(set) var promptResult: PromptMixResult?
    private(set) var promptStatus: String?
    private(set) var undoCount = 0

    private struct Snapshot {
        var values: [String: Double]
        var songGain: Double
        var drumGain: Double
        var presetId: String?
    }

    @ObservationIgnored private var history: [Snapshot] = []
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderedValues: [String: Double]?

    init(projectId: String, model: AppModel) {
        self.projectId = projectId
        self.model = model
    }

    private var preview: any MixPreviewService { model.services.preview }

    var project: Project? { model.project(projectId) }
    var take: Take? { project.flatMap { model.take($0.takeId) } }
    var song: LibrarySong? { project.flatMap { model.song($0.songId) } }
    var mix: MixSettings? { project?.mix }
    var hasStems: Bool { audio?.hasStems ?? false }
    var promptModeLabel: String { model.services.promptMix.modeLabel }

    /// Song time where the drum file's first sample plays (incl. nudge).
    var drumOffset: Double { project.map { model.drumOffsetSec($0) } ?? 0 }

    /// The song-time window the lanes show: the take plus a second each side.
    var window: (start: Double, end: Double) {
        let base = take?.drumOffsetSec ?? 0
        let songDur = audio?.songDurationSec ?? 0
        let drumDur = audio?.drumsDurationSec ?? 0
        let start = max(0, base - 1)
        let end = max(start + 1, min(songDur > 0 ? songDur : .infinity, base + drumDur + 1))
        return (start, end.isFinite ? end : start + 1)
    }

    var playheadFraction: Double {
        let w = window
        return (playhead - w.start) / (w.end - w.start)
    }

    var songDuration: Double { audio?.songDurationSec ?? 0 }

    // MARK: Lifecycle

    func load() async {
        guard audio == nil else { return }
        guard let project, let take, let request = model.audioRequest(for: project) else {
            loadError = "This take is missing."
            return
        }
        do {
            let loaded = try await preview.load(request)
            audio = loaded
            playhead = max(0, take.drumOffsetSec)
            preview.seek(to: playhead)
            applyLevels()
            refreshPeaks()
            scheduleRender(delayMs: 0)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func unload() {
        renderTask?.cancel()
        renderTask = nil
        preview.stop()
        preview.unload()
        playing = false
    }

    // MARK: Preview

    private func applyLevels() {
        guard audio != nil, let mix else { return }
        preview.setLevels(MixLevels(songGain: mix.songGain, drumGain: mix.drumGain, originalDrums: mix.originalDrums))
        preview.setDrumOffset(drumOffset)
    }

    private func refreshPeaks() {
        guard audio != nil else { return }
        let w = window
        songPeaks = preview.peaks(.song, start: w.start, end: w.end, columns: EditSession.columns, drumOffsetSec: 0)
        drumPeaks = preview.peaks(.drums, start: w.start, end: w.end, columns: EditSession.columns, drumOffsetSec: drumOffset)
    }

    /// Re-renders the drum chain once the knobs settle.
    private func scheduleRender(delayMs: Int = 250) {
        guard audio != nil, let values = mix?.values, values != renderedValues else { return }
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
            guard !Task.isCancelled, let self else { return }
            self.rendering = true
            do {
                try await self.preview.renderDrums(knobValues: values)
                if !Task.isCancelled { self.renderedValues = values }
            } catch {
                print("Lumber: drum render failed: \(error)")
            }
            if !Task.isCancelled { self.rendering = false }
        }
    }

    func togglePlay() {
        guard audio != nil else { return }
        if preview.isPlaying {
            preview.stop()
            playing = false
        } else {
            preview.play(from: playhead)
            playing = true
        }
    }

    func stopPreview() {
        preview.stop()
        playing = false
    }

    /// Playhead updates while playing (the view's .task(id: playing)).
    func tick() async {
        while playing, !Task.isCancelled {
            let p = preview.position()
            playhead = p
            if p >= preview.duration {
                preview.stop()
                playing = false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func seek(to seconds: Double) {
        playhead = seconds
        preview.seek(to: seconds)
    }

    // MARK: Mix

    private func updateMix(_ change: (inout MixSettings) -> Void) {
        model.updateMix(projectId, change)
        applyLevels()
    }

    func setSongGain(_ v: Double) { updateMix { $0.songGain = v } }
    func setDrumGain(_ v: Double) { updateMix { $0.drumGain = v } }
    func setOriginalDrums(_ v: Double) { updateMix { $0.originalDrums = v } }

    func nudge(_ ms: Double) {
        updateMix { $0.nudgeMs = max(-EditSession.nudgeRangeMs, min(EditSession.nudgeRangeMs, $0.nudgeMs + ms)) }
        refreshPeaks()
    }

    func setNudge(_ ms: Double) {
        updateMix { $0.nudgeMs = max(-EditSession.nudgeRangeMs, min(EditSession.nudgeRangeMs, ms.rounded())) }
        refreshPeaks()
    }

    func nudgeVideo(_ ms: Double) {
        updateMix {
            let next = ($0.videoNudgeMs ?? 0) + ms
            $0.videoNudgeMs = max(-EditSession.videoNudgeRangeMs, min(EditSession.videoNudgeRangeMs, next))
        }
    }

    func resetVideoNudge() { updateMix { $0.videoNudgeMs = 0 } }

    func setKnob(_ key: String, _ value: Double) {
        updateMix {
            $0.values[key] = max(-1, min(1, value))
            $0.presetId = nil
        }
        scheduleRender()
    }

    func applyPreset(_ preset: MixPreset) {
        updateMix {
            $0.values = KnobCatalog.values(for: preset)
            $0.presetId = preset.id
        }
        scheduleRender()
    }

    func resetKnobs() {
        updateMix {
            $0.values = KnobCatalog.zeroValues()
            $0.presetId = nil
        }
        scheduleRender()
    }

    // MARK: Export

    func export(_ format: ExportFormat) async {
        guard exporting == nil else { return }
        stopPreview()
        exporting = format
        exportProgress = 0
        do {
            let rec = try await model.exportMix(format, projectId: projectId) { [weak self] p in
                self?.exportProgress = p
            }
            saved = [rec]
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
        }
        exporting = nil
    }

    /// The take as recorded — no rendering, just copies of its files.
    func saveRawTake() {
        guard !savingTake else { return }
        savingTake = true
        do {
            saved = try model.saveRawTake(projectId: projectId, drumsDurationSec: audio?.drumsDurationSec ?? 0)
        } catch {
            alertMessage = "Save failed: \(error.localizedDescription)"
        }
        savingTake = false
    }

    // MARK: Describe the sound

    func runPrompt() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !promptBusy, let project, let request = model.audioRequest(for: project) else { return }
        promptBusy = true
        promptStatus = nil
        do {
            let result = try await model.services.promptMix.interpret(
                PromptMixRequest(prompt: text, mix: project.mix, audio: request, drumOffsetSec: drumOffset)
            )
            let m = project.mix
            history.append(Snapshot(values: m.values, songGain: m.songGain, drumGain: m.drumGain, presetId: m.presetId))
            if history.count > EditSession.maxUndo { history.removeFirst(history.count - EditSession.maxUndo) }
            undoCount = history.count
            updateMix {
                $0.values = KnobCatalog.filledValues(result.values)
                if let g = result.songGain { $0.songGain = g }
                if let g = result.drumGain { $0.drumGain = g }
                $0.presetId = nil
            }
            promptResult = result
            scheduleRender()
        } catch {
            promptResult = nil
            promptStatus = error.localizedDescription
        }
        promptBusy = false
    }

    func undoPrompt() {
        guard let last = history.popLast() else { return }
        undoCount = history.count
        updateMix {
            $0.values = last.values
            $0.songGain = last.songGain
            $0.drumGain = last.drumGain
            $0.presetId = last.presetId
        }
        promptResult = nil
        promptStatus = "Undone."
        scheduleRender()
    }
}
