import AppKit
import SwiftUI

/// Hosts SwiftUI in Clementine's windows.
///
/// Our windows usually appear while another app (Finder) stays active, and AppKit treats a click on an inactive
/// app's window as a "first mouse" click, which a hosting view ignores unless it opts in. Opting in means the first
/// click on a Clementine window acts on the control under it instead of only bringing the window forward.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    /// Whether a drag on empty parts of the view moves the window. Off by default: SwiftUI content counts as
    /// "window background", so otherwise dragging a trim handle or a page thumbnail would move the window instead.
    var movesWindow = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { movesWindow }
}

extension NSWindow {
    /// Installs a SwiftUI view as the window's content. By default the window takes the view's ideal size and
    /// follows it as it changes; pass other options for windows that size themselves. Windows move by their title
    /// bar strip; `movableByBackground` also lets a drag anywhere move them (for cards without controls to drag).
    func host<V: View>(_ view: V, sizing: NSHostingSizingOptions = [.minSize, .intrinsicContentSize, .maxSize],
                       movableByBackground: Bool = false) {
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.sizingOptions = sizing
        hosting.movesWindow = movableByBackground
        contentView = hosting
        // Take the content's size now, so a following center() places the window by its real size.
        if sizing.contains(.intrinsicContentSize) {
            setContentSize(hosting.fittingSize)
        }
    }
}
