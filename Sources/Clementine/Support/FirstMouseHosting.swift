import AppKit
import SwiftUI

/// Hosts SwiftUI in Clementine's windows.
///
/// Our windows usually appear while another app (Finder) stays active, and AppKit treats a click on an inactive
/// app's window as a "first mouse" click, which a hosting view ignores unless it opts in. Opting in means the first
/// click on a Clementine window acts on the control under it instead of only bringing the window forward.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSWindow {
    /// Installs a SwiftUI view as the window's content. By default the window takes the view's ideal size and
    /// follows it as it changes; pass other options for windows that size themselves.
    func host<V: View>(_ view: V, sizing: NSHostingSizingOptions = [.minSize, .intrinsicContentSize, .maxSize]) {
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.sizingOptions = sizing
        contentView = hosting
    }
}
