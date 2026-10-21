import AppKit

/// Entrance and exit animations for windows, done on the window frame and alpha so they work for any content.
/// With Reduce Motion on, windows only fade.
extension NSWindow {
    /// Orders the window in, gliding from `offset` away to where it is now while fading up.
    func animateIn(from offset: CGVector, duration: TimeInterval = 0.34) {
        let target = frame
        let shift = Theme.reduceMotion ? .zero : offset
        alphaValue = 0
        setFrame(target.offsetBy(dx: shift.dx, dy: shift.dy), display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) // fast out, long settle
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    /// Fades the window out while gliding `offset` away, then calls `completion` (typically the real close).
    func animateOut(to offset: CGVector, duration: TimeInterval = 0.22, completion: @escaping @MainActor () -> Void) {
        let shift = Theme.reduceMotion ? .zero : offset
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            animator().alphaValue = 0
            animator().setFrame(frame.offsetBy(dx: shift.dx, dy: shift.dy), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })
    }
}
