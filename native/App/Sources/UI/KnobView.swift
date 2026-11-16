// One Blanket term as a row of big buttons: name (tap for what it does),
// a bar showing the setting, the number (tap to reset to 0) and − / + in
// steps of 1 (of 10; hold to repeat). Two-sided terms (EQ: boost / cut) run
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(info.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(moved ? Theme.text : Theme.textSoft)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                    }
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

            // The number doubles as reset: tap it to go back to 0.
            Button { set(0) } label: {
                Text(steps == 0 ? "0" : (steps > 0 && info.bipolar ? "+\(steps)" : "\(steps)"))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(moved ? Theme.accentSoft : Theme.textFaint)
                    .frame(width: 36, height: 40)
                    .background(moved ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!moved)
            .accessibilityLabel("Reset \(info.label)")

            stepButton("minus", enabled: value > lower + 0.001) { set(value - Self.step) }
            stepButton("plus", enabled: value < 0.999) { set(value + Self.step) }

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
                .frame(width: 46, height: 40)
                .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .foregroundStyle(Theme.text)
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
                Capsule().fill(Theme.cardRaised)
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                if bipolar {
                    Rectangle().fill(Theme.textFaint).frame(width: 2, height: 10).offset(x: origin - 1)
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
