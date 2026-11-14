// Rotary knob for one Blanket term (src/components/BlanketKnob.tsx): drag up
// to turn clockwise, down to turn back; double-tap resets to 0. Value -1...1.
//
// Never fights scrolling: the drag is a high-priority gesture with zero
// minimum distance, so it owns the touch from the first contact, and while
// it's held the knob reports `active` so the screen also disables scrolling
// (`.scrollDisabled`). A swipe that starts between knobs still scrolls.

import SwiftUI

struct KnobView: View {
    let info: KnobTermInfo
    let value: Double
    let onChange: (Double) -> Void
    var onActiveChange: (Bool) -> Void = { _ in }

    private static let sweep = 135.0 // degrees from center to each extreme
    private static let dragRange = 200.0 // points of vertical drag for the full -1...1
    private static let doubleTapSec = 0.3
    private static let tapSlop = 8.0

    @State private var active = false
    @State private var startValue: Double = 0
    @State private var lastTap = Date.distantPast
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 4) {
            dial
                .frame(width: 56, height: 56)
                .scaleEffect(active ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: active)
                .contentShape(Circle().inset(by: -10))
                .highPriorityGesture(drag)
                .accessibilityElement()
                .accessibilityLabel(info.label)
                .accessibilityValue(String(format: "%.2f", value))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onChange(min(1, value + 0.05))
                    case .decrement: onChange(max(-1, value - 0.05))
                    @unknown default: break
                    }
                }
            Text(info.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(active || abs(value) > 0.001 ? Theme.accentSoft : Theme.textMuted)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28, alignment: .top)
                .onTapGesture { showInfo = true }
                .popover(isPresented: $showInfo) {
                    Text(info.description)
                        .font(.footnote)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                }
            Text(String(format: "%+.2f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textFaint)
        }
        .frame(width: 78)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                if !active {
                    active = true
                    startValue = value
                    onActiveChange(true)
                }
                let delta = -Double(g.translation.height) / (Self.dragRange / 2)
                let next = max(-1, min(1, startValue + delta))
                if abs(next - value) > 0.0005 { onChange((next * 1000).rounded() / 1000) }
            }
            .onEnded { g in
                active = false
                onActiveChange(false)
                let moved = hypot(Double(g.translation.width), Double(g.translation.height))
                guard moved < Self.tapSlop else { return }
                let now = Date()
                if now.timeIntervalSince(lastTap) < Self.doubleTapSec {
                    onChange(0)
                    lastTap = .distantPast
                } else {
                    lastTap = now
                }
            }
    }

    private var dial: some View {
        let angle = value * Self.sweep
        let lit = active || abs(value) > 0.001
        return ZStack {
            // Track
            KnobArc(from: -Self.sweep, to: Self.sweep)
                .stroke(Theme.steelRimDark, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            // Value arc from center (0 = straight up)
            KnobArc(from: min(0, angle), to: max(0, angle))
                .stroke(lit ? Theme.glow : Theme.steelRimSide, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            Circle()
                .fill(LinearGradient(colors: [Theme.steelRimLight, Theme.steelRimDark],
                                     startPoint: .top, endPoint: .bottom))
                .padding(8)
            Circle()
                .fill(RadialGradient(colors: [Theme.steelHubLight, Theme.steelHub, Theme.steelHubDark],
                                     center: .topLeading, startRadius: 2, endRadius: 40))
                .padding(10)
            Capsule()
                .fill(Theme.steelPointer)
                .frame(width: 3, height: 12)
                .offset(y: -11)
                .rotationEffect(.degrees(angle))
        }
        .shadow(color: lit ? Theme.glow.opacity(active ? 0.6 : 0.25) : .clear, radius: active ? 8 : 4)
    }
}

/// An arc on the knob's rim; angles in degrees clockwise from 12 o'clock.
private struct KnobArc: Shape {
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard to > from else { return p }
        let r = min(rect.width, rect.height) / 2 - 2
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: r,
                 startAngle: .degrees(from - 90), endAngle: .degrees(to - 90), clockwise: false)
        return p
    }
}
