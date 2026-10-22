import SwiftUI

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let size = model.canvasSize
        let outer = model.outerRadius
        ZStack {
            if model.actions.isEmpty {
                EmptyNotice(mode: model.mode)
                    .offset(y: model.innerRadius + 26)
                if model.interactive {
                    ModeChip(mode: model.mode, switchable: true, hovered: model.chipHovered)
                        .offset(y: outer + 24)
                }
            } else {
                Backdrop(radius: outer + 8)
                Ring(model: model, size: size)
                    .id("\(model.mode)-\(model.session)")
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.86).combined(with: .opacity),
                        removal: .scale(scale: 1.08).combined(with: .opacity)))
                ModeChip(mode: model.mode, switchable: model.interactive, hovered: model.chipHovered)
                    .offset(y: outer + 24)
            }
            Hub(model: model)
        }
        .frame(width: size, height: size)
        .scaleEffect(model.visible ? 1 : 0.8)
        .opacity(model.visible ? 1 : 0)
        .blur(radius: model.visible ? 0 : 8)
        .animation(Theme.spring, value: model.visible)
        .animation(Theme.spring, value: model.mode)
    }
}

/// Frosted disc behind the slices, warmed by a faint tangerine glow.
private struct Backdrop: View {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Circle().fill(RadialGradient(colors: [Theme.tangerine.opacity(scheme == .dark ? 0.16 : 0.12), .clear],
                                             center: .center, startRadius: radius * 0.35, endRadius: radius)))
            .overlay(Circle().strokeBorder(Theme.hairline(scheme), lineWidth: 1).allowsHitTesting(false))
            .frame(width: radius * 2, height: radius * 2)
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.2), radius: 26, y: 12)
    }
}

/// All slices for the current mode. Rebuilt (and cross-faded) when the mode changes.
private struct Ring: View {
    @ObservedObject var model: WheelModel
    let size: CGFloat

    var body: some View {
        ZStack {
            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                SliceView(model: model, index: index, action: action, size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SliceView: View {
    @ObservedObject var model: WheelModel
    let index: Int
    let action: Action
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var hovered: Bool { model.hovered == index }
    private var angle: Double { Double(index) * model.segmentAngle }

    var body: some View {
        let slice = Slice(index: index, count: model.actions.count, inner: model.innerRadius, outer: model.outerRadius)
        // Hovered slices slide outward along their own direction.
        let pop: CGFloat = hovered ? 7 : 0
        let offset = CGSize(width: pop * CGFloat(sin(angle)), height: -pop * CGFloat(cos(angle)))
        let dimmed = model.hovered != nil && !hovered

        ZStack {
            Group {
                if hovered {
                    // Lighter by the hub, deeper at the rim, the same for every slice.
                    let fill = RadialGradient(colors: [Theme.tangerine, Theme.blood], center: .center,
                                              startRadius: model.innerRadius, endRadius: model.outerRadius)
                    slice.fill(fill)
                    slice.stroke(fill, style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                } else {
                    slice.fill(Theme.surface(scheme))
                    slice.stroke(Theme.surface(scheme), style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                }
            }
            .shadow(color: hovered ? Theme.glow : .clear, radius: 14, y: 4)
            slice.stroke(hovered ? Color.white.opacity(0.35) : Theme.hairline(scheme), lineWidth: 0.75)

            SliceLabel(action: action, mode: model.mode, hovered: hovered)
                .position(labelPosition)
        }
        .frame(width: size, height: size)
        .offset(offset)
        .opacity(dimmed ? 0.88 : 1)
        // Fan in one after another when the wheel opens.
        .scaleEffect(appeared || reduceMotion ? 1 : 0.7)
        .rotationEffect(.degrees(appeared || reduceMotion ? 0 : -14))
        .opacity(appeared ? 1 : 0)
        .animation(Theme.snappy, value: hovered)
        .animation(Theme.ease, value: dimmed)
        .onAppear {
            withAnimation(Theme.spring.delay(reduceMotion ? 0 : Double(index) * 0.022)) { appeared = true }
        }
    }

    private var labelPosition: CGPoint {
        let radius = (model.innerRadius + model.outerRadius) / 2 + 4
        return CGPoint(x: size / 2 + radius * CGFloat(sin(angle)), y: size / 2 - radius * CGFloat(cos(angle)))
    }
}

/// A ring segment centered on 12 o'clock + index × (360° / count).
struct Slice: Shape {
    let index: Int
    let count: Int
    let inner: CGFloat
    let outer: CGFloat
    /// Wider than the visible gap: the rounded stroke drawn on top eats into it and softens the corners.
    var gap: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let span = 2 * Double.pi / Double(count)
        let middle = Double(index) * span
        // The stroke grows the shape by 2.5pt on every side, so draw it that much smaller.
        let outerRadius = outer - 2.5, innerRadius = inner + 2.5
        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
        }
        // Constant-width gaps: the angular gap shrinks as the radius grows.
        let outerHalf = span / 2 - Double(gap / 2 / outerRadius)
        let innerHalf = span / 2 - Double(gap / 2 / innerRadius)
        let steps = 24
        var path = Path()
        for step in 0...steps {
            let angle = middle - outerHalf + 2 * outerHalf * Double(step) / Double(steps)
            step == 0 ? path.move(to: point(outerRadius, angle)) : path.addLine(to: point(outerRadius, angle))
        }
        for step in 0...steps {
            path.addLine(to: point(innerRadius, middle + innerHalf - 2 * innerHalf * Double(step) / Double(steps)))
        }
        path.closeSubpath()
        return path
    }
}

private struct SliceLabel: View {
    let action: Action
    let mode: WheelMode
    let hovered: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if mode == .convert || action.symbol == nil {
                Text(action.title)
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .tracking(0.3)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: action.symbol!)
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.bounce, value: hovered)
                        .foregroundStyle(hovered ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.accent))
                    Text(action.title.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .tracking(0.4)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 64)
            }
        }
        .foregroundStyle(hovered ? Color.white : (scheme == .dark ? Color(hex: 0xF4E9DF) : Color(hex: 0x4A3628)))
        .shadow(color: hovered ? .black.opacity(0.18) : .clear, radius: 2, y: 1)
        .scaleEffect(hovered ? 1.1 : 1)
    }
}

/// The middle: a thumbnail of what's being dragged. Shows what will happen when hovering a slice; dropping here cancels.
private struct Hub: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    private var target: Action? {
        model.hovered.flatMap { $0 < model.actions.count ? model.actions[$0] : nil }
    }

    var body: some View {
        let diameter = (model.innerRadius - 7) * 2
        ZStack {
            Circle().fill(Theme.surface(scheme))
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .scaleEffect(target == nil ? 1 : 1.06)
            }
            // Darken the thumbnail behind the "what happens" caption.
            Circle()
                .fill(.black.opacity(target == nil ? 0 : 0.45))
            caption
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(AngularGradient(colors: [Theme.tangerine, Theme.peach, Theme.blood, Theme.tangerine],
                                              center: .center), lineWidth: 3)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .padding(-3).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        .animation(Theme.snappy, value: target?.id)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = true }
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let target {
            VStack(spacing: 1) {
                Text(model.mode == .convert ? "Convert to" : "Apply")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .opacity(0.85)
                Text(target.title)
                    .font(.system(size: model.mode == .convert ? 17 : 12.5, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .id(target.id)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            VStack {
                Spacer()
                Text(model.summary)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline(scheme), lineWidth: 0.5).allowsHitTesting(false))
                    .padding(.bottom, 11)
            }
            .transition(.opacity)
        }
    }
}

/// Says which wheel is up, under the ring. In click mode it's also the switch to the other wheel (or Tab).
private struct ModeChip: View {
    let mode: WheelMode
    var switchable = false
    var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Label(mode == .convert ? "CONVERT" : "TOOLS",
                  systemImage: mode == .convert ? "arrow.triangle.2.circlepath" : "wand.and.stars")
            if switchable {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8, weight: .black))
                    .opacity(hovered ? 1 : 0.7)
                    .padding(.leading, 5)
                    .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.35)).frame(width: 0.75, height: 10) }
            }
        }
        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
        .tracking(0.8)
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.accent, in: Capsule())
        .overlay(Capsule().fill(.white.opacity(hovered ? 0.16 : 0)))
        .shadow(color: Theme.glow.opacity(hovered ? 1 : 0.8), radius: hovered ? 9 : 6, y: 2)
        .scaleEffect(hovered ? 1.06 : 1)
        .contentTransition(.interpolate)
        .animation(Theme.snappy, value: hovered)
    }
}

private struct EmptyNotice: View {
    let mode: WheelMode

    var body: some View {
        Label(mode == .convert ? "No conversions for this file" : "No tools for this file", systemImage: "nosign")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}
