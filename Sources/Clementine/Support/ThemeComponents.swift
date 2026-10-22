import AppKit
import SwiftUI

/// Building blocks for Clementine's windows, so the progress cards, sheets and settings share one look.
extension Theme {
    /// Window background: a warm off-white in light mode, deep roasted brown in dark mode.
    static func backdrop(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1C1714) : Color(hex: 0xFBF6F0)
    }

    /// Raised cards sitting on the backdrop.
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x2A231F) : .white
    }

    /// Card borders that read in both modes (the plain hairline is white, which vanishes on white cards).
    static func edge(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.08) : Color(hex: 0x6B4A2E).opacity(0.10)
    }

    /// Whether the user asked for less motion; AppKit-side code checks this, SwiftUI views use the environment.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// A white SF Symbol on a glossy gradient tile, the icon treatment used in every window header.
struct GradientBadge: View {
    let symbol: String
    var size: CGFloat = 36
    var fill: LinearGradient = Theme.accent
    var glow: Color = Theme.glow
    var circle = false

    var body: some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        ZStack {
            shape.fill(fill)
            shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            shape.stroke(Color.white.opacity(0.22), lineWidth: 0.5)
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .frame(width: size, height: size)
        .shadow(color: glow.opacity(0.55), radius: size * 0.18, y: size * 0.08)
    }
}

/// Warm window background with a soft peach glow falling from the top edge.
struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.backdrop(scheme)
            RadialGradient(colors: [(scheme == .dark ? Theme.tangerine.opacity(0.14) : Theme.peach.opacity(0.45)), .clear],
                           center: .init(x: 0.15, y: 0), startRadius: 0, endRadius: 360)
        }
        .ignoresSafeArea()
    }
}

/// A rounded card with a fill and a fine border.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 12
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.edge(scheme), lineWidth: 1).allowsHitTesting(false))
    }
}

extension View {
    func card(radius: CGFloat = 12) -> some View { modifier(CardBackground(radius: radius)) }
}

// MARK: Buttons

/// The primary action: a gradient capsule that brightens on hover and dips when pressed.
struct AccentButtonStyle: ButtonStyle {
    var fill: LinearGradient = Theme.accent
    var glow: Color = Theme.glow

    func makeBody(configuration: Configuration) -> some View {
        AccentButton(configuration: configuration, fill: fill, glow: glow)
    }

    private struct AccentButton: View {
        let configuration: Configuration
        let fill: LinearGradient
        let glow: Color
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovering = false

        /// A light sheen, kept faint so white text stays at ≥ 4.5:1; none with Increase Contrast.
        private var sheen: Double { contrast == .increased ? 0 : (hovering ? 0.16 : 0.10) }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background {
                    Capsule().fill(fill)
                        .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(sheen), .clear],
                                                               startPoint: .top, endPoint: .bottom)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5).allowsHitTesting(false))
                }
                .shadow(color: glow.opacity(enabled ? (hovering ? 0.55 : 0.35) : 0), radius: hovering ? 8 : 5, y: 2)
                .saturation(enabled ? 1 : 0.15)
                .opacity(enabled ? 1 : 0.55)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .brightness(configuration.isPressed ? -0.05 : 0)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Theme.snappy, value: configuration.isPressed)
                .animation(Theme.ease, value: hovering)
                .animation(Theme.ease, value: enabled)
        }
    }
}

/// Secondary actions: a quiet capsule that fills in on hover.
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SoftButton(configuration: configuration)
    }

    private struct SoftButton: View {
        let configuration: Configuration
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.10 : 0.055)))
                .overlay(Capsule().strokeBorder(Theme.edge(scheme), lineWidth: 1).allowsHitTesting(false))
                .opacity(enabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Theme.snappy, value: configuration.isPressed)
                .animation(Theme.ease, value: hovering)
        }
    }
}

/// A small round icon button (cancel on progress cards).
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        CircleIconButton(configuration: configuration, size: size)
    }

    private struct CircleIconButton: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(hovering ? Color.white : Color.secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(Color.primary.opacity(0.08))))
                .scaleEffect(configuration.isPressed ? 0.88 : (hovering ? 1.08 : 1))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(Theme.snappy, value: hovering)
                .animation(Theme.snappy, value: configuration.isPressed)
        }
    }
}

// MARK: Progress

/// A capsule progress bar: accent gradient with a travelling sheen while running, a sweeping segment when the
/// amount of work is unknown, leaf green when done and cherry when failed.
struct CitrusProgressBar: View {
    enum Tone { case running, done, failed }

    /// nil sweeps indeterminately.
    let value: Double?
    var tone: Tone = .running
    var height: CGFloat = 6
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.08))
                if let value, tone == .running || value > 0 {
                    fill
                        .frame(width: max(height, width * min(max(value, 0), 1)))
                        .overlay { if tone == .running && !reduceMotion { sheen } }
                        .clipShape(Capsule())
                        .animation(.smooth(duration: 0.45), value: value)
                } else if tone == .running {
                    sweep(width: width)
                } else {
                    fill
                }
            }
        }
        .frame(height: height)
        .animation(Theme.ease, value: tone)
    }

    /// The three gradients stacked and crossfaded, since gradients themselves don't interpolate.
    private var fill: some View {
        ZStack {
            Capsule().fill(Theme.accentVivid).opacity(tone == .running ? 1 : 0)
            Capsule().fill(Theme.success).opacity(tone == .done ? 1 : 0)
            Capsule().fill(Theme.failure).opacity(tone == .failed ? 1 : 0)
        }
        .shadow(color: (tone == .done ? Theme.leaf : tone == .failed ? Theme.cherry : Theme.tangerine).opacity(0.45), radius: 3)
    }

    private var sheen: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let period = 1.6
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let band = max(40, geo.size.width * 0.35)
                LinearGradient(colors: [.clear, .white.opacity(0.42), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: -band + phase * (geo.size.width + band))
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func sweep(width: CGFloat) -> some View {
        if reduceMotion {
            Capsule().fill(Theme.accentVivid).opacity(0.45)
        } else {
            TimelineView(.animation) { context in
                let period = 1.3
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let eased = 0.5 - cos(t * .pi) / 2
                let segment = width * 0.34
                Capsule().fill(Theme.accentVivid)
                    .frame(width: segment)
                    .offset(x: -segment + eased * (width + segment))
            }
            .clipShape(Capsule())
        }
    }
}

// MARK: Bits

/// The grey-and-white squares that show where an image is transparent.
struct Checkerboard: View {
    var cell: CGFloat = 8
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let dark = scheme == .dark
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark ? Color(white: 0.20) : .white))
            var squares = Path()
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    squares.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(squares, with: .color(dark ? Color(white: 0.25) : Color(white: 0.92)))
        }
    }
}

/// A keyboard key, for showing shortcuts like ⇧ and ⌥.
struct Keycap: View {
    let key: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.8))
            .frame(minWidth: 24, minHeight: 22)
            .padding(.horizontal, 3)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: scheme == .dark ? [Color(white: 0.30), Color(white: 0.22)] : [.white, Color(hex: 0xF3ECE5)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 0, y: 1.5)
            }
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.edge(scheme), lineWidth: 1).allowsHitTesting(false))
    }
}

/// Behind-window blur for borderless panels, clipped to rounded corners via a mask image
/// (so the window shadow follows the corners too).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
