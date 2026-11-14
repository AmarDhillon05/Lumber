// Shared building blocks (src/components/ui.tsx): cards, buttons, sliders,
// progress bar, hint/error text and the error alert.

import SwiftUI

// MARK: - Card section

struct CardSection<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: - Buttons

enum LumberButtonKind {
    case primary, secondary, danger, ghost
}

struct LumberButtonStyle: ButtonStyle {
    var kind: LumberButtonKind = .secondary
    var small = false
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButtonLabel(configuration: configuration, kind: kind, small: small, fill: fill)
    }
}

private struct StyledButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let kind: LumberButtonKind
    let small: Bool
    let fill: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(small ? .subheadline.weight(.semibold) : .body.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 12 : 16)
            .padding(.vertical, small ? 7 : 12)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: kind == .secondary ? 1 : 0))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary, .danger: Theme.onAccent
        case .secondary: Theme.textSoft
        case .ghost: Theme.accentSoft
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accent
        case .danger: Theme.danger
        case .secondary: Theme.cardRaised
        case .ghost: Color.clear
        }
    }

    private var border: Color { Theme.border }
}

extension View {
    func lumberButton(_ kind: LumberButtonKind = .secondary, small: Bool = false, fill: Bool = false) -> some View {
        buttonStyle(LumberButtonStyle(kind: kind, small: small, fill: fill))
    }
}

// MARK: - Text

struct HintText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.dangerSoft)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Progress

struct ProgressBar: View {
    let progress: Double
    var color: Color = Theme.blue

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceDeep)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.15), value: progress)
    }
}

// MARK: - Slider

/// A labelled slider. By default it commits on release (`onChange` once per
/// drag); `live: true` reports every move.
struct LabeledSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var tint: Color = Theme.accent
    var live = false
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    let onChange: (Double) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var draft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSoft)
                Spacer()
                Text(format(draft ?? value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
            slider
                .tint(tint)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var binding: Binding<Double> {
        Binding(
            get: { min(range.upperBound, max(range.lowerBound, draft ?? value)) },
            set: { v in
                draft = v
                if live { onChange(v) }
            }
        )
    }

    private func editingChanged(_ editing: Bool) {
        guard !editing else { return }
        if let d = draft, !live { onChange(d) }
        draft = nil
    }

    @ViewBuilder private var slider: some View {
        if let step {
            Slider(value: binding, in: range, step: step, onEditingChanged: editingChanged)
        } else {
            Slider(value: binding, in: range, onEditingChanged: editingChanged)
        }
    }
}

// MARK: - Chips

struct Chip: View {
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? Theme.onAccent : Theme.textSoft)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? Theme.accent : Theme.card, in: Capsule())
                .overlay(Capsule().stroke(selected ? Theme.accent : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Screen chrome

extension View {
    /// Dark background and navigation bar for a screen.
    func lumberScreen(_ title: String) -> some View {
        self
            .background(Theme.surface.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// An OK alert shown while `message` is non-nil.
    func errorAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(message.wrappedValue ?? "") }
        )
    }
}
