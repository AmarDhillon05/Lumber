// One Blanket term as a row of big buttons: name (tap for what it does),
// a bar showing the setting, − / + in steps of 1 (of 10; hold to repeat),
// and a reset button once it's moved. Two-sided terms (EQ: boost / cut) run
// −10…+10 from the middle; the rest run 0…10.
//
// Replaces the rotary knobs, which were fiddly to turn inside a scroll view.

import SwiftUI

struct KnobView: View {
    let info: KnobTermInfo
    let value: Double
    let onChange: (Double) -> Void

    static let step = 0.1
    @State private var showInfo = false

    private var lower: Double { info.bipolar ? -1 : 0 }
    private var steps: Int { Int((value / Self.step).rounded()) }
    private var moved: Bool { abs(value) > 0.001 }

    var body: some View {
        HStack(spacing: 10) {
            Button { showInfo = true } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(info.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(moved ? Theme.text : Theme.textSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    LevelBar(value: value, bipolar: info.bipolar)
                        .frame(height: 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showInfo) {
                Text(info.description)
                    .font(.footnote)
                    .padding()
                    .presentationCompactAdaptation(.popover)
            }

            Text(steps == 0 ? "0" : (steps > 0 && info.bipolar ? "+\(steps)" : "\(steps)"))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(moved ? Theme.accentSoft : Theme.textFaint)
                .frame(width: 32)

            stepButton("minus", enabled: value > lower + 0.001) { set(value - Self.step) }
            stepButton("plus", enabled: value < 0.999) { set(value + Self.step) }

            Button { set(0) } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 28, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textMuted)
            .opacity(moved ? 1 : 0)
            .disabled(!moved)
            .accessibilityLabel("Reset \(info.label)")
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: steps)
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(steps)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + Self.step)
            case .decrement: set(value - Self.step)
            @unknown default: break
            }
        }
    }

    private func set(_ v: Double) {
        let clamped = max(lower, min(1, v))
        onChange((clamped / Self.step).rounded() * Self.step)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.bold))
                .frame(width: 44, height: 40)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .foregroundStyle(enabled ? Theme.text : Theme.textFaint)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "plus" ? "More \(info.label)" : "Less \(info.label)")
    }
}

/// Track with a fill from the middle (two-sided) or from the left.
private struct LevelBar: View {
    let value: Double
    let bipolar: Bool

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let origin = bipolar ? w / 2 : 0
            let span = bipolar ? w / 2 : w
            let len = CGFloat(abs(value)) * span
            let x = value >= 0 ? origin : origin - len
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                if bipolar {
                    Rectangle().fill(Theme.border).frame(width: 1.5).offset(x: origin - 0.75)
                }
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.blue], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(len, 0))
                    .offset(x: x)
                    .animation(.easeOut(duration: 0.15), value: value)
            }
        }
    }
}
