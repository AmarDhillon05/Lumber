// A waveform lane: peak bars (0...1) mirrored around the center, a label and
// a playhead line. Port of src/components/Waveform.tsx.

import SwiftUI

struct WaveformLane: View {
    let peaks: [Float]
    let color: Color
    let label: String
    var playhead: Double? // 0...1 across the lane; hidden outside

    var body: some View {
        Canvas { context, size in
            let n = peaks.count
            if n > 0 {
                let w = size.width / CGFloat(n)
                let mid = size.height / 2
                for (i, p) in peaks.enumerated() {
                    let h = max(1, CGFloat(min(1, max(0, p))) * (size.height - 6))
                    let rect = CGRect(x: CGFloat(i) * w + w * 0.15, y: mid - h / 2, width: max(1, w * 0.7), height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(2, w * 0.35)), with: .color(color))
                }
            }
            if let playhead, playhead >= 0, playhead <= 1 {
                let x = CGFloat(playhead) * size.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(Theme.text), lineWidth: 1.5)
            }
        }
        .frame(height: 64)
        .background(Theme.surfaceDeep, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.surfaceDeep.opacity(0.85), in: Capsule())
                .padding(5)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}
