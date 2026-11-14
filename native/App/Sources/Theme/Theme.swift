// Dark slate-indigo theme (src/theme.ts): near-black blue-gray surfaces, cool
// gray text, purple as the main accent and blue as the second. Dark only.

import SwiftUI

enum Theme {
    static let surface = Color(hex: 0x0E0E16) // screen background
    static let surfaceDeep = Color(hex: 0x08080E) // waveform wells
    static let card = Color(hex: 0x171724) // cards, inputs, secondary buttons
    static let cardRaised = Color(hex: 0x20202F)
    static let border = Color(hex: 0x2B2B3D)

    static let text = Color(hex: 0xF3F3FA)
    static let textSoft = Color(hex: 0xD3D3E3)
    static let textMuted = Color(hex: 0x9B9BB4)
    static let textFaint = Color(hex: 0x6F6F8A)
    static let placeholder = Color(hex: 0x585870)

    static let accent = Color(hex: 0x8B5CF6) // purple: primary buttons, links, active state
    static let accentSoft = Color(hex: 0xC4B5FD)
    static let onAccent = Color.white
    static let blue = Color(hex: 0x3B82F6) // secondary accent: progress, selection
    static let blueSoft = Color(hex: 0x93C5FD)
    static let glow = Color(hex: 0xA78BFA) // knob highlight while touched / non-zero

    static let song = Color(hex: 0x60A5FA) // song lane (blue)
    static let drums = Color(hex: 0xA78BFA) // drum lane (purple)

    static let danger = Color(hex: 0xF43F5E)
    static let dangerSoft = Color(hex: 0xFDA4AF)
    static let dangerDeep = Color(hex: 0x9F1239)
    static let success = Color(hex: 0x34D399)
    static let warning = Color(hex: 0xFBBF24)

    // Knobs: cool gunmetal with a violet cast.
    static let steelFace = Color(hex: 0x3A3A52)
    static let steelRimLight = Color(hex: 0x8C8CAB)
    static let steelRimSide = Color(hex: 0x5C5C79)
    static let steelRimDark = Color(hex: 0x16162A)
    static let steelHub = Color(hex: 0x2C2C42)
    static let steelHubDark = Color(hex: 0x18182A)
    static let steelHubLight = Color(hex: 0x5A5A7A)
    static let steelPointer = Color(hex: 0xECE9FF)

    static let radius: CGFloat = 12
    static let gutter: CGFloat = 16
}

extension Color {
    /// sRGB color from 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
