import SwiftUI

/// Clementine's look: warm citrus accents on calm, slightly warm neutrals, and springy motion.
/// Every view should take its colors and animations from here so the app feels like one piece.
enum Theme {
    // MARK: Palette

    /// Primary accent, the fruit.
    static let tangerine = Color(hex: 0xFF9A3C)
    /// Deeper end of the accent gradient.
    static let blood = Color(hex: 0xFF5E3A)
    /// Soft highlight, the pith.
    static let peach = Color(hex: 0xFFD3A8)
    /// Success, the leaf.
    static let leaf = Color(hex: 0x34C77B)
    /// Errors, a cherry red that sits well next to orange.
    static let cherry = Color(hex: 0xE5484D)

    static let accent = LinearGradient(colors: [tangerine, blood], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accentSoft = LinearGradient(colors: [peach.opacity(0.9), tangerine.opacity(0.85)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
    static let success = LinearGradient(colors: [Color(hex: 0x5BE09B), leaf], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let failure = LinearGradient(colors: [Color(hex: 0xFF7A7E), cherry], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Neutral surface for wheel slices and cards: warm cream in light mode, warm charcoal in dark mode.
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x2B2420).opacity(0.82) : Color(hex: 0xFFFBF6).opacity(0.86)
    }

    /// Hairline borders that catch the light.
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.10) : .white.opacity(0.75)
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xD9CBBE).opacity(0.85) : Color(hex: 0x6B5646)
    }

    /// Warm-tinted shadow so depth reads as glow, not grime.
    static let glow = Color(hex: 0xFF7A2F).opacity(0.45)

    // MARK: Motion

    /// Default for things appearing and moving.
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.74)
    /// Quick, for hover and selection.
    static let snappy = Animation.spring(response: 0.22, dampingFraction: 0.82)
    /// Gentle, for color and opacity changes.
    static let ease = Animation.easeInOut(duration: 0.2)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
