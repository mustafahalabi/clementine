import AppKit
import SwiftUI

/// The small floating card each job gets, stacked in the top-right corner.
/// It slides in from the screen edge, and slides back out when closed.
@MainActor
final class ProgressPanel: NSObject, NSWindowDelegate {
    private static var open: [ProgressPanel] = []
    /// Space between stacked cards.
    private static let gap: CGFloat = 10
    #if DEBUG
    /// Where the stack goes instead of the main screen's corner (UI tests park it off-screen).
    static var stackArea: NSRect?
    #endif

    let window: NSPanel
    private let job: RunningJob
    private var closing = false
    private var placed = false
    private var closeTimer: Timer?
    private var closeDeadline = Date.distantFuture

    static func show(_ job: RunningJob) -> ProgressPanel {
        let panel = ProgressPanel(job: job)
        open.append(panel)
        if let content = panel.window.contentView {
            panel.window.setContentSize(content.fittingSize) // size before placing, or it's placed as 0×0
        }
        restack()
        panel.window.animateIn(from: CGVector(dx: 36, dy: 0), duration: 0.42)
        return panel
    }

    private init(job: RunningJob) {
        self.job = job
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: JobView.width, height: 80),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.host(JobView(job: job, cancel: { [weak self] in self?.cancel() }, dismiss: { [weak self] in self?.close() }),
                    movableByBackground: true)
    }

    /// Slides the card off to the right, then closes it.
    func close() {
        guard !closing else { return }
        closing = true
        window.animateOut(to: CGVector(dx: 40, dy: 0), duration: 0.28) { [weak self] in self?.window.close() }
    }

    /// Closes after `delay`, but never while the pointer is over the card: it waits for the pointer to leave, plus a beat.
    func close(after delay: TimeInterval) {
        closeDeadline = Date().addingTimeInterval(delay)
        guard closeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDeadline() }
        }
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
    }

    private func checkDeadline() {
        let now = Date()
        if window.frame.contains(NSEvent.mouseLocation) {
            closeDeadline = max(closeDeadline, now.addingTimeInterval(1.2))
        } else if now >= closeDeadline {
            closeTimer?.invalidate()
            closeTimer = nil
            close()
        }
    }

    private func cancel() {
        job.task?.cancel()
        close()
    }

    /// A card that grows (an error message, "Show details…") pushes the ones below it down.
    func windowDidResize(_ notification: Notification) {
        guard !closing else { return }
        Self.restack()
        window.invalidateShadow()
    }

    func windowWillClose(_ notification: Notification) {
        closeTimer?.invalidate()
        closeTimer = nil
        if job.state == .running { job.task?.cancel() }
        Self.open.removeAll { $0 === self }
        Self.restack()
    }

    /// Stacks the cards down from the top-right corner by their real heights (failed cards are taller and stay
    /// open, so fixed slots let the next card cover their buttons). Cards on their way out keep their spot.
    private static func restack() {
        #if DEBUG
        let area = stackArea ?? NSScreen.main?.visibleFrame
        #else
        let area = NSScreen.main?.visibleFrame
        #endif
        guard let area else { return }
        var top = area.maxY - 16
        for panel in open {
            let size = panel.window.frame.size
            panel.move(to: NSPoint(x: area.maxX - size.width - 16, y: top - size.height))
            top -= size.height + gap
        }
    }

    private func move(to origin: NSPoint) {
        guard window.frame.origin != origin else { return }
        // New cards land in place (animateIn slides them); existing ones glide to make room.
        // Frame animations are paced by the display, so a window that's on no screen (UI tests) moves directly.
        if placed && window.isVisible && window.screen != nil && !Theme.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrameOrigin(origin)
            }
        } else {
            window.setFrameOrigin(origin)
        }
        placed = true
    }
}

struct JobView: View {
    static let width: CGFloat = 340
    private static let radius: CGFloat = 18

    /// Errors longer than this many lines collapse behind "Show details…".
    static let collapsedLines = 4

    @ObservedObject var job: RunningJob
    let cancel: () -> Void
    let dismiss: () -> Void
    /// Rendering hook: start with the error details open.
    var expanded = false
    @State private var showDetails: Bool?
    @Environment(\.colorScheme) private var scheme

    private var tone: CitrusProgressBar.Tone {
        switch job.state {
        case .running: .running
        case .done: .done
        case .failed: .failed
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(job.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    status
                }
                Text(job.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText(scheme))
                    // A finished card may explain itself ("Already as small as it gets…"); file names stay on one line.
                    .lineLimit(job.state == .done ? 2 : 1)
                    .truncationMode(.middle)
                    .padding(.top, 1)
                    .contentTransition(.opacity)

                switch job.state {
                case .running, .done:
                    HStack(spacing: 10) {
                        CitrusProgressBar(value: job.progress, tone: tone)
                            .opacity(job.undone ? 0.35 : 1)
                        if job.state == .running {
                            Button(action: cancel) { Image(systemName: "xmark") }
                                .buttonStyle(CircleIconButtonStyle(size: 18))
                                .help("Cancel")
                                .accessibilityLabel("Cancel")
                                .transition(.scale.combined(with: .opacity))
                        } else if job.undo != nil && !job.undone {
                            undoButton
                        }
                    }
                    .frame(height: 18)
                    .padding(.top, 8)
                case .failed(let message):
                    failure(message)
                }
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .background { cardBackground }
        .animation(Theme.spring, value: job.state)
        .animation(Theme.spring, value: job.undone)
        .onChange(of: job.state) { _, state in announce(state) }
    }

    /// Tells VoiceOver how a job ended; the card itself never takes focus.
    private func announce(_ state: RunningJob.State) {
        let text: String
        switch state {
        case .running: return
        case .done: text = "\(job.title) done"
        case .failed(let message):
            text = "\(job.title) failed. \(message.split(separator: "\n").first.map(String.init) ?? "")"
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private var undoButton: some View {
        Button { job.undo?() } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(UndoPillStyle())
        .help("Move the new files to the Trash")
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private var badge: some View {
        let symbol = switch job.state {
        case .running: job.symbol
        case .done: job.undone ? "arrow.uturn.backward" : "checkmark"
        case .failed: "exclamationmark"
        }
        let undone = job.undone && tone == .done
        return ZStack {
            GradientBadge(symbol: symbol, size: 38, circle: true).opacity(tone == .running || undone ? 1 : 0)
            GradientBadge(symbol: symbol, size: 38, fill: Theme.success, glow: Theme.leaf, circle: true).opacity(tone == .done && !undone ? 1 : 0)
            GradientBadge(symbol: symbol, size: 38, fill: Theme.failure, glow: Theme.cherry, circle: true).opacity(tone == .failed ? 1 : 0)
        }
        .symbolEffect(.bounce, value: tone)
        .scaleEffect(tone == .done ? 1.06 : 1)
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .running:
            if let progress = job.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .contentTransition(.numericText(value: progress))
                    .animation(.smooth, value: progress)
            }
        case .done:
            Text(job.undone ? "Undone" : "Done")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(job.undone ? Theme.secondaryText(scheme) : Theme.leafText)
                .contentTransition(.opacity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .failed:
            Text("Failed")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.cherryText)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Whether `message` is long enough to collapse (by explicit lines, or by wrapping at the card's width).
    static func isLong(_ message: String) -> Bool {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let wrapped = lines.reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 48))) }
        return wrapped > collapsedLines
    }

    private func failure(_ message: String) -> some View {
        let long = Self.isLong(message)
        let open = long && (showDetails ?? expanded)
        return VStack(alignment: .trailing, spacing: 10) {
            Group {
                if open {
                    // Everything, scrolling past a sensible height so the card never outgrows the screen.
                    ScrollView {
                        errorText(message).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    errorText(message)
                        .lineLimit(Self.collapsedLines)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.cherry.opacity(scheme == .dark ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cherry.opacity(0.25), lineWidth: 1).allowsHitTesting(false))
            HStack(spacing: 8) {
                if long {
                    Button(open ? "Show less" : "Show details…") {
                        withAnimation(Theme.spring) { showDetails = !open }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .contentShape(Rectangle())
                    .uiTestID("job.details.\(job.title)")
                    Spacer(minLength: 0)
                }
                // Partial failures can still take back the files that did get made.
                if job.undo != nil && !job.undone {
                    Button { job.undo?() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(SoftButtonStyle())
                        .help("Move the files that were made to the Trash")
                        .uiTestID("job.undo.\(job.title)")
                }
                Button("Close", action: dismiss)
                    .buttonStyle(SoftButtonStyle())
                    .uiTestID("job.close.\(job.title)")
            }
            .controlSize(.small)
        }
        .padding(.top, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11.5))
            .foregroundStyle(.primary.opacity(0.85))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let wash: Color = switch tone {
        case .running: Theme.tangerine
        case .done: job.undone ? Theme.tangerine : Theme.leaf
        case .failed: Theme.cherry
        }
        return ZStack {
            VisualEffectBackground(material: .popover, cornerRadius: Self.radius)
            shape.fill(Theme.surface(scheme))
            shape.fill(LinearGradient(colors: [wash.opacity(scheme == .dark ? 0.16 : 0.12), .clear],
                                      startPoint: .topLeading, endPoint: .center))
            shape.strokeBorder(Theme.edge(scheme), lineWidth: 1)
            shape.inset(by: 1).strokeBorder(Theme.hairline(scheme).opacity(0.6), lineWidth: 0.5)
        }
    }
}

/// A compact tinted capsule that fills with the accent on hover, for the Undo offer on finished cards.
private struct UndoPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration)
    }

    private struct Pill: View {
        let configuration: Configuration
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(hovering ? Color.white : (scheme == .dark ? Theme.peach : Color(hex: 0xC2410C)))
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background {
                    ZStack {
                        Capsule().fill(Theme.tangerine.opacity(scheme == .dark ? 0.2 : 0.14))
                        Capsule().fill(Theme.accent).opacity(hovering ? 1 : 0)
                    }
                }
                .overlay(Capsule().strokeBorder(Theme.tangerine.opacity(hovering ? 0 : 0.35), lineWidth: 0.75).allowsHitTesting(false))
                .shadow(color: hovering ? Theme.glow : .clear, radius: 5, y: 1)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Theme.snappy, value: configuration.isPressed)
                .animation(Theme.ease, value: hovering)
        }
    }
}
