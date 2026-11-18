// Record: transport for one song — start position, loop region, count-in and
// tempo, Camera toggle, latency calibration and nudge, Play / Record / Stop.
// Logic in State/RecordSession.swift.

import SwiftUI

struct RecordScreen: View {
    @Environment(AppModel.self) private var model
    let songId: String
    @State private var session: RecordSession?

    var body: some View {
        Group {
            if let session {
                RecordContent(session: session)
            } else {
                Color.clear
            }
        }
        .lumberScreen(model.song(songId)?.title ?? "Record")
        .onAppear {
            if session == nil { session = RecordSession(songId: songId, model: model) }
        }
    }
}

private struct RecordContent: View {
    @Bindable var session: RecordSession
    @State private var confirmCalibrate = false
    @FocusState private var bpmFocused: Bool

    var body: some View {
        if session.song == nil {
            Text("Song not found")
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
                .task { await session.load() }
                .task { await session.watchRoutes() }
                .task(id: session.mode) { await session.tick() }
                .onDisappear { session.leave() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                warnings
                transport
                backingSection
                CameraPanel(session: session)
                startSection
                loopSection
                countInSection
                latencySection
            }
            .padding(Theme.gutter)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    bpmFocused = false
                    session.commitBpm()
                }
            }
        }
        .confirmationDialog("Calibrate latency", isPresented: $confirmCalibrate, titleVisibility: .visible) {
            Button("Start") { Task { await session.calibrate() } }
        } message: {
            Text("Unplug headphones (or hold an earbud right at the bottom mic) and keep the room quiet. Lumber will play 8 clicks and listen for them.")
        }
    }

    // MARK: Sections

    @ViewBuilder private var warnings: some View {
        if let route = session.route, !route.isHeadphones {
            Banner(text: "🎧 Plug in headphones before recording — otherwise the song bleeds into the drum mic.", color: Theme.warning)
        }
        if session.route?.isBluetooth == true {
            Banner(text: "Bluetooth adds 150–250 ms of delay. Calibrate for this output, or prefer wired headphones.", color: Theme.border)
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fmtTime(session.displayPosition))
                    .font(.system(size: 40, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                Text("/ \(fmtTime(session.duration))")
                    .font(.callout)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                if session.isRunning, session.countInBeatsLeft > 0 {
                    Text("count-in \(session.countInBeatsLeft)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                } else if session.mode == .recording {
                    Text("● REC")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.danger)
                }
            }
            HStack(spacing: 8) {
                if session.isRunning {
                    Button("Stop") { Task { await session.stop() } }
                        .lumberButton(.danger, fill: true)
                } else {
                    Button("Play") { Task { await session.start(record: false) } }
                        .lumberButton(fill: true)
                        .disabled(session.isBusy || session.duration <= 0)
                    Button("● Record") { Task { await session.start(record: true) } }
                        .lumberButton(.danger, fill: true)
                        .disabled(session.isBusy || session.duration <= 0)
                }
            }
            if session.mode == .loading || session.mode == .calibrating {
                ProgressView().tint(Theme.accent)
            }
            if let error = session.error {
                ErrorText(error)
            }
        }
    }

    private var startSection: some View {
        CardSection("Start") {
            LabeledSlider(
                label: "Start at",
                value: session.startSec,
                range: 0...max(0.1, session.duration),
                format: fmtTime,
                onChange: { session.startSec = $0 }
            )
            .disabled(session.isRunning || session.loopOn)
        }
    }

    private var loopSection: some View {
        CardSection("Loop") {
            Toggle("Loop region (records one pass)", isOn: $session.loopOn)
                .font(.subheadline)
                .foregroundStyle(Theme.textSoft)
                .tint(Theme.accent)
                .disabled(session.isRunning)
            if session.loopOn {
                LabeledSlider(
                    label: "Loop start",
                    value: session.loopStart,
                    range: 0...max(0.1, session.duration),
                    format: fmtTime,
                    onChange: { session.setLoopStart($0) }
                )
                .disabled(session.isRunning)
                LabeledSlider(
                    label: "Loop end",
                    value: session.loopEnd,
                    range: 0...max(0.1, session.duration),
                    format: fmtTime,
                    onChange: { session.setLoopEnd($0) }
                )
                .disabled(session.isRunning)
            }
        }
    }

    private var backingSection: some View {
        CardSection("Backing track") {
            if session.hasStems {
                Toggle("Play without the original drums", isOn: Binding(
                    get: { session.settings.withoutDrums },
                    set: { on in Task { await session.setPlayWithoutDrums(on) } }
                ))
                .font(.subheadline)
                .foregroundStyle(Theme.textSoft)
                .tint(Theme.accent)
                .disabled(session.isRunning)
                HintText(session.settings.withoutDrums
                    ? "You hear the song with its drums removed. Turn off to play along with the original drummer."
                    : "You hear the full song, original drums included.")
            } else {
                HintText("Playing the full song. Use Remove drums in the Library to play along without the original drummer.")
            }
        }
    }

    private var countInSection: some View {
        CardSection("Count-in") {
            Toggle("1 bar (4 clicks) before the song", isOn: Binding(
                get: { session.settings.countIn },
                set: { session.setCountIn($0) }
            ))
            .font(.subheadline)
            .foregroundStyle(Theme.textSoft)
            .tint(Theme.accent)
            .disabled(session.isRunning)
            HStack {
                Text("Tempo (BPM)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSoft)
                Spacer()
                TextField("120", text: $session.bpmText)
                    .keyboardType(.decimalPad)
                    .focused($bpmFocused)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 80)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                    .disabled(session.isRunning)
                    .onChange(of: bpmFocused) { _, focused in
                        if !focused { session.commitBpm() }
                    }
            }
        }
    }

    private var latencySection: some View {
        let latency = session.latency
        let nudge = session.settings.latencyNudgeMs
        return CardSection("Latency") {
            Text("Output: \(session.route?.name ?? "…") — \(latency.calibrated ? "\(format1(latency.baseMs)) ms (calibrated)" : "\(format1(latency.baseMs)) ms (estimate, not calibrated)")")
                .font(.footnote)
                .foregroundStyle(Theme.textSoft)
            Text("Manual nudge: \(nudge > 0 ? "+" : "")\(format1(nudge)) ms → compensating \(String(format: "%.1f", latency.totalMs)) ms")
                .font(.footnote)
                .foregroundStyle(Theme.textSoft)
            HStack(spacing: 8) {
                Button("−5 ms") { session.nudgeLatency(-5) }.lumberButton(small: true)
                Button("−1") { session.nudgeLatency(-1) }.lumberButton(small: true)
                Button("+1") { session.nudgeLatency(1) }.lumberButton(small: true)
                Button("+5 ms") { session.nudgeLatency(5) }.lumberButton(small: true)
            }
            Button("Calibrate this output") { confirmCalibrate = true }
                .lumberButton(fill: true)
                .disabled(session.isBusy)
        }
    }

    private func format1(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

private struct Banner: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.textSoft)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 1))
    }
}
