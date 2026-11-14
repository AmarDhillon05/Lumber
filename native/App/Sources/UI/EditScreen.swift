// Edit / Export: song + drum lanes with alignment nudge, faders, presets,
// the Blanket knob grid by category, "Describe the sound", exports (WAV /
// M4A / video) and Save raw take. Logic in State/EditSession.swift.

import SwiftUI

struct EditScreen: View {
    @Environment(AppModel.self) private var model
    let projectId: String
    @State private var session: EditSession?

    var body: some View {
        Group {
            if let session {
                EditContent(session: session)
            } else {
                Color.clear
            }
        }
        .lumberScreen(model.project(projectId)?.name ?? "Edit")
        .onAppear {
            if session == nil { session = EditSession(projectId: projectId, model: model) }
        }
    }
}

private struct EditContent: View {
    @Bindable var session: EditSession
    @State private var knobActive = false

    var body: some View {
        Group {
            if session.project == nil || session.take == nil {
                Text("Take not found")
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let mix = session.mix, session.audio != nil {
                editor(mix)
            } else {
                VStack(spacing: 8) {
                    if let error = session.loadError {
                        ErrorText(error)
                    } else {
                        ProgressView().tint(Theme.accent)
                        HintText("Loading audio…")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await session.load() }
        .task(id: session.playing) { await session.tick() }
        .onDisappear { session.unload() }
        .errorAlert("Lumber", message: $session.alertMessage)
    }

    private func editor(_ mix: MixSettings) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                lanes
                transportAndExport
                if let take = session.take, take.video != nil {
                    videoSection(mix)
                }
                alignmentSection(mix)
                mixSection(mix)
                PromptMixBox(session: session)
                presetsSection(mix)
                ForEach(KnobCategory.allCases, id: \.self) { category in
                    let terms = KnobCatalog.terms(in: category)
                    if !terms.isEmpty {
                        knobSection(category, terms: terms, mix: mix)
                    }
                }
            }
            .padding(Theme.gutter)
            .padding(.bottom, 48)
        }
        .scrollDisabled(knobActive)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Lanes + transport

    private var lanes: some View {
        let w = session.window
        return VStack(spacing: 6) {
            WaveformLane(peaks: session.songPeaks, color: Theme.song,
                         label: session.hasStems ? "SONG (no drums)" : "SONG", playhead: session.playheadFraction)
            WaveformLane(peaks: session.drumPeaks, color: Theme.drums, label: "DRUMS", playhead: session.playheadFraction)
            HStack {
                HintText(fmtTime(w.start))
                Spacer()
                HintText(session.rendering ? "rendering drums…" : "")
                Spacer()
                HintText(fmtTime(w.end))
            }
        }
    }

    private var transportAndExport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(session.playing ? "Stop" : "▶ Preview") { session.togglePlay() }
                    .lumberButton(.primary, fill: true)
                exportButton(.wav, title: "Export WAV")
            }
            HStack(spacing: 8) {
                exportButton(.m4a, title: "Export M4A")
                if session.take?.video != nil {
                    exportButton(.video, title: "Export video")
                }
            }
            if session.exporting != nil {
                ProgressBar(progress: session.exportProgress, color: Theme.blue)
            }
            Button(session.savingTake ? "Saving…" : (session.take?.video != nil ? "Save raw take (drums + video)" : "Save raw take")) {
                session.saveRawTake()
            }
            .lumberButton(.ghost, small: true)
            .disabled(session.savingTake)

            if !session.saved.isEmpty {
                SavedBanner(saved: session.saved) { session.saved = [] }
            }

            LabeledSlider(
                label: "Playhead",
                value: session.playhead,
                range: 0...max(0.1, session.songDuration),
                format: fmtTime,
                onChange: { session.seek(to: $0) }
            )
        }
    }

    private func exportButton(_ format: ExportFormat, title: String) -> some View {
        let busy = session.exporting == format
        return Button(busy ? (format == .video ? "Video \(Int((session.exportProgress * 100).rounded()))%" : "Exporting…") : title) {
            Task { await session.export(format) }
        }
        .lumberButton(fill: true)
        .disabled(session.exporting != nil)
    }

    // MARK: Sections

    private func videoSection(_ mix: MixSettings) -> some View {
        let nudge = mix.videoNudgeMs ?? 0
        return CardSection("Video") {
            HintText("Video offset \(nudge > 0 ? "+" : "")\(Int(nudge.rounded())) ms on top of the recorded sync. Nudge until hits line up with the sound.")
            HStack(spacing: 8) {
                Button("−1 fr") { session.nudgeVideo(-EditSession.frameMs) }.lumberButton(small: true)
                Button("−10") { session.nudgeVideo(-10) }.lumberButton(small: true)
                Button("0") { session.resetVideoNudge() }.lumberButton(.ghost, small: true)
                Button("+10") { session.nudgeVideo(10) }.lumberButton(small: true)
                Button("+1 fr") { session.nudgeVideo(EditSession.frameMs) }.lumberButton(small: true)
            }
        }
    }

    private func alignmentSection(_ mix: MixSettings) -> some View {
        let take = session.take
        return CardSection("Alignment") {
            HintText("Drums start at \(fmtTime(session.drumOffset)) (recorded offset \(Int(((take?.drumOffsetSec ?? 0) * 1000).rounded())) ms incl. \(Int((take?.latencyMs ?? 0).rounded())) ms latency; nudge \(mix.nudgeMs > 0 ? "+" : "")\(Int(mix.nudgeMs.rounded())) ms)")
            HStack(spacing: 8) {
                Button("−10") { session.nudge(-10) }.lumberButton(small: true)
                Button("−1") { session.nudge(-1) }.lumberButton(small: true)
                Button("0") { session.setNudge(0) }.lumberButton(.ghost, small: true)
                Button("+1") { session.nudge(1) }.lumberButton(small: true)
                Button("+10") { session.nudge(10) }.lumberButton(small: true)
            }
            LabeledSlider(
                label: "Nudge (ms)",
                value: mix.nudgeMs,
                range: -EditSession.nudgeRangeMs...EditSession.nudgeRangeMs,
                step: 1,
                tint: Theme.drums,
                format: { "\(Int($0.rounded()))" },
                onChange: { session.setNudge($0) }
            )
        }
    }

    private func mixSection(_ mix: MixSettings) -> some View {
        CardSection("Mix") {
            LabeledSlider(label: "Song", value: mix.songGain, range: 0...1.5, tint: Theme.song, live: true,
                          onChange: { session.setSongGain($0) })
            LabeledSlider(label: "Drums", value: mix.drumGain, range: 0...1.5, tint: Theme.drums, live: true,
                          onChange: { session.setDrumGain($0) })
            LabeledSlider(label: "Original drums", value: mix.originalDrums, range: 0...1, live: true,
                          format: { "\(Int(($0 * 100).rounded()))%" },
                          onChange: { session.setOriginalDrums($0) })
                .disabled(!session.hasStems)
            if !session.hasStems {
                HintText("Run “Remove original drums” in the library to enable.")
            }
        }
    }

    private func presetsSection(_ mix: MixSettings) -> some View {
        CardSection("Presets") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(KnobCatalog.presets) { preset in
                        Chip(title: preset.label, selected: mix.presetId == preset.id) {
                            session.applyPreset(preset)
                        }
                    }
                    Chip(title: "Reset") { session.resetKnobs() }
                }
            }
            if let preset = KnobCatalog.preset(mix.presetId) {
                HintText(preset.description)
            }
        }
    }

    private func knobSection(_ category: KnobCategory, terms: [KnobTermInfo], mix: MixSettings) -> some View {
        CardSection(category.rawValue) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 4)], spacing: 12) {
                ForEach(terms) { info in
                    KnobView(
                        info: info,
                        value: mix.values[info.key] ?? 0,
                        onChange: { session.setKnob(info.key, $0) },
                        onActiveChange: { knobActive = $0 }
                    )
                }
            }
        }
    }
}

// MARK: - Describe the sound

private struct PromptMixBox: View {
    @Bindable var session: EditSession
    @State private var editingKey = false
    @State private var keyDraft = ""
    @State private var keyVersion = 0 // re-reads the mode label after the key changes

    var body: some View {
        CardSection {
            HStack {
                Text("Describe the sound")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(session.promptModeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentSoft)
                    .id(keyVersion)
                Button {
                    keyDraft = ""
                    editingKey = true
                } label: {
                    Image(systemName: "key.fill").foregroundStyle(Theme.accentSoft)
                }
                .accessibilityLabel("Anthropic API key")
            }
            .alert("Anthropic API key", isPresented: $editingKey) {
                SecureField("sk-ant-…", text: $keyDraft)
                Button("Save") {
                    try? LivePromptMix.setAPIKey(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                    keyVersion += 1
                }
                Button("Remove key", role: .destructive) {
                    try? LivePromptMix.setAPIKey(nil)
                    keyVersion += 1
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stored in the iOS keychain on this phone. Without a key, an offline interpreter maps sound words to knob moves.")
            }
            HStack(spacing: 8) {
                TextField("e.g. punchy and dry", text: $session.prompt, axis: .vertical)
                    .lineLimit(1...3)
                    .submitLabel(.go)
                    .onSubmit { Task { await session.runPrompt() } }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .foregroundStyle(Theme.text)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                Button("Go") { Task { await session.runPrompt() } }
                    .lumberButton(.primary, small: true)
                    .disabled(session.prompt.trimmingCharacters(in: .whitespaces).isEmpty || session.promptBusy)
            }
            if session.prompt.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(EditSession.promptExamples, id: \.self) { example in
                            Chip(title: example) { session.prompt = example }
                        }
                    }
                }
            }
            if session.promptBusy {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.accent)
                    HintText("Listening to the take and the song…")
                }
            }
            if let result = session.promptResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.source == .claude ? "Claude" : "Offline interpreter")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.blueSoft)
                    Text(result.explanation)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSoft)
                    if let notice = result.notice {
                        HintText(notice)
                    }
                }
            }
            if let status = session.promptStatus {
                HintText(status)
            }
            if session.undoCount > 0 {
                Button(session.undoCount > 1 ? "Undo (\(session.undoCount))" : "Undo") { session.undoPrompt() }
                    .lumberButton(.ghost, small: true)
                    .disabled(session.promptBusy)
            }
        }
    }
}

// MARK: - Saved banner

private struct SavedBanner: View {
    let saved: [Recording]
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(saved.count == 1 ? "Saved to Recordings" : "Saved \(saved.count) files to Recordings")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.success)
                ForEach(saved) { rec in
                    Text(rec.title)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                if let first = saved.first {
                    NavigationLink(value: Route.recordings(openId: first.id)) {
                        Text("Open Recordings ›")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accentSoft)
                    }
                }
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Theme.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.success.opacity(0.5), lineWidth: 1))
    }
}
