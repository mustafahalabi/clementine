import AppKit

/// A window that takes keyboard focus without needing Clementine to become the active app.
///
/// Our windows open while Finder (or the menu bar) is frontmost, and since macOS 14 `NSApp.activate`
/// is only a request the system may decline, so a regular window can end up visible but deaf to typing.
/// A non-activating panel that can become key gets the keystrokes anyway (the Spotlight technique).
final class FocusablePanel: NSPanel {
    private var closing = false

    init(contentRect: NSRect = .zero, resizable: Bool = false) {
        var style: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // Content runs under a transparent title bar, leaving just the close button, so each window reads as a card.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Brings the window forward, rising into place and fading in if it wasn't on screen.
    func present() {
        NSApp.activate()
        if isVisible && !closing {
            makeKeyAndOrderFront(nil)
            return
        }
        closing = false
        animateIn(from: CGVector(dx: 0, dy: -14), duration: 0.3)
        makeKey()
    }

    /// Fades out before closing for real (willClose observers fire at the end, as usual).
    override func close() {
        guard isVisible else { return super.close() }
        guard !closing else { return }
        closing = true
        let home = frame
        animateOut(to: CGVector(dx: 0, dy: -8), duration: 0.16) { [weak self] in
            guard let self, self.closing else { return } // presented again mid-fade
            self.finishClose(restoring: home)
        }
    }

    private func finishClose(restoring home: NSRect) {
        super.close()
        closing = false
        alphaValue = 1
        setFrame(home, display: false) // so the next present() starts from the same spot
    }
}
