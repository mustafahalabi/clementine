import SwiftUI

extension View {
    /// Tags a control so `Clementine --ui-test` can find and click it. Records the view's frame in debug builds;
    /// does nothing in release builds.
    @ViewBuilder
    func uiTestID(_ id: String) -> some View {
        #if DEBUG
        background(GeometryReader { geometry in
            Color.clear
                .onAppear { UITestRegistry.frames[id] = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { _, frame in UITestRegistry.frames[id] = frame }
                .onDisappear { UITestRegistry.frames[id] = nil }
        })
        #else
        self
        #endif
    }
}

#if DEBUG
/// Frames of tagged views, in their window's top-left coordinates (SwiftUI's global space).
@MainActor
enum UITestRegistry {
    static var frames: [String: CGRect] = [:]
}
#endif
