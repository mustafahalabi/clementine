import AppKit
import SwiftUI

/// The small floating card each job gets, stacked in the top-right corner.
/// It slides in from the screen edge, and slides back out when closed.
@MainActor
final class ProgressPanel: NSObject, NSWindowDelegate {
    private static var open: [ProgressPanel] = []

    private let window: NSPanel
    private let job: RunningJob
    private var slot = 0
    private var closing = false

    static func show(_ job: RunningJob) -> ProgressPanel {
        let panel = ProgressPanel(job: job)
        let taken = Set(open.map(\.slot))
        panel.slot = (0...).first { !taken.contains($0) }!
        open.append(panel)
        if let content = panel.window.contentViewController?.view {
            panel.window.setContentSize(content.fittingSize) // size before placing, or it's placed as 0×0
        }
        panel.place()
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
        let host = NSHostingController(rootView: JobView(job: job, cancel: { [weak self] in self?.cancel() },
                                                         dismiss: { [weak self] in self?.close() }))
        host.sizingOptions = .preferredContentSize
        window.contentViewController = host
    }

    /// Slides the card off to the right, then closes it.
    func close() {
        guard !closing else { return }
        closing = true
        window.animateOut(to: CGVector(dx: 40, dy: 0), duration: 0.28) { [weak self] in self?.window.close() }
    }

    private func cancel() {
        job.task?.cancel()
        close()
    }

    /// Keep the panel pinned to its corner when the content grows (e.g. an error message).
    func windowDidResize(_ notification: Notification) {
        guard !closing else { return }
        place()
        window.invalidateShadow()
    }

    func windowWillClose(_ notification: Notification) {
        if job.state == .running { job.task?.cancel() }
        Self.open.removeAll { $0 === self }
    }

    private func place() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = window.frame.size
        let top = screen.maxY - 16 - CGFloat(slot) * 140 // fixed slots so panels of different heights never overlap
        window.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: top - size.height))
    }
}

struct JobView: View {
    static let width: CGFloat = 340
    private static let radius: CGFloat = 18

    @ObservedObject var job: RunningJob
    let cancel: () -> Void
    let dismiss: () -> Void
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 1)
                    .contentTransition(.opacity)

                switch job.state {
                case .running, .done:
                    HStack(spacing: 10) {
                        CitrusProgressBar(value: job.progress, tone: tone)
                        if job.state == .running {
                            Button(action: cancel) { Image(systemName: "xmark") }
                                .buttonStyle(CircleIconButtonStyle(size: 18))
                                .help("Cancel")
                                .transition(.scale.combined(with: .opacity))
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
    }

    private var badge: some View {
        let symbol = switch job.state {
        case .running: job.symbol
        case .done: "checkmark"
        case .failed: "exclamationmark"
        }
        return ZStack {
            GradientBadge(symbol: symbol, size: 38, circle: true).opacity(tone == .running ? 1 : 0)
            GradientBadge(symbol: symbol, size: 38, fill: Theme.success, glow: Theme.leaf, circle: true).opacity(tone == .done ? 1 : 0)
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
            Text("Done")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.leaf)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .failed:
            Text("Failed")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.cherry)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.cherry.opacity(scheme == .dark ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cherry.opacity(0.25), lineWidth: 1))
            Button("Close", action: dismiss)
                .buttonStyle(SoftButtonStyle())
                .controlSize(.small)
        }
        .padding(.top, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let wash: Color = switch tone {
        case .running: Theme.tangerine
        case .done: Theme.leaf
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
