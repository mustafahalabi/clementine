import AppKit
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

    /// Fills that carry white text (buttons, chips, selected tabs, hovered slices): the fruit, a shade deeper.
    /// White on the old #FF9A3C was ~2.1:1; these stops are ≥ 3.0:1 at the lightest point (#EE6C14) and 3.9:1 at
    /// the deep end, the large/bold-text threshold, since every label on them is bold. With Increase Contrast they
    /// turn to a deep peel at ≥ 7:1. The bright tangerine stays for glows, washes, rings and progress bars.
    static let accentTopShade = Shade(normal: 0xEE6C14, increased: 0x9C3510)     // 3.1:1 / 7.2:1 against white
    static let accentBottomShade = Shade(normal: 0xE0501C, increased: 0x8A2C0E)  // 3.9:1 / 8.6:1
    /// For the rare regular-weight small text on orange: ≥ 4.5:1 even without Increase Contrast.
    static let accentDeepShade = Shade(normal: 0xBE4A0C, increased: 0x9C3510)    // 5.0:1 / 7.2:1
    /// Accent glyphs and bold accent labels on the app's own surfaces: orange on light (3.8:1 on cream), bright on
    /// dark; a deep peel or pale orange with Increase Contrast (≥ 7:1).
    static let accentTextShade = Shade(normal: 0xE0501C, increased: 0x8A2C0E,
                                       dark: 0xFFA25A, darkIncreased: 0xFFC598)

    /// Status words ("Done", "Failed", "Not found") and fills behind white status text, readable on both schemes.
    static let leafTextShade = Shade(normal: 0x1A7A48, increased: 0x146238, dark: 0x5BE09B, darkIncreased: 0x8AF0BC)
    static let cherryTextShade = Shade(normal: 0xC4282E, increased: 0x9E1C22, dark: 0xFF7A7E, darkIncreased: 0xFFA3A6)
    static let leafDeepShade = Shade(normal: 0x1A7A48, increased: 0x146238)  // 5.4:1 / 7.2:1 against white

    static let accentTop = accentTopShade.color
    static let accentBottom = accentBottomShade.color
    static let accentText = accentTextShade.color
    static let accentDeep = accentDeepShade.color
    static let leafText = leafTextShade.color
    static let cherryText = cherryTextShade.color
    static let leafDeep = leafDeepShade.color

    static let accent = LinearGradient(colors: [accentTop, accentBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// The bright fruit gradient, for fills that carry no text (progress bars).
    static let accentVivid = LinearGradient(colors: [tangerine, blood], startPoint: .topLeading, endPoint: .bottomTrailing)
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

    /// Whether the user turned on Increase Contrast; AppKit-side code checks this, SwiftUI resolves it per appearance.
    static var increaseContrast: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLEMENTINE_INCREASE_CONTRAST"] == "1" { return true } // renders
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// A color that follows light/dark and Increase Contrast at draw time.
    struct Shade {
        let normal: UInt32
        let increased: UInt32
        var dark: UInt32? = nil
        var darkIncreased: UInt32? = nil

        func hex(dark isDark: Bool, increased high: Bool) -> UInt32 {
            isDark ? (high ? (darkIncreased ?? increased) : (dark ?? normal)) : (high ? increased : normal)
        }

        var color: Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                        .accessibilityHighContrastDarkAqua])
                let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                let high = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
                    || Theme.increaseContrast
                let hex = self.hex(dark: isDark, increased: high)
                return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
        }
    }

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
