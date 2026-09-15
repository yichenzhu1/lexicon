import AppKit
import SwiftUI

/// One continuous surface behind the sidebar's title row and list.
struct SidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let isTranslucent: Bool

    var body: some View {
        Group {
            if isTranslucent && !reduceTransparency {
                SidebarVisualEffect()
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SidebarVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> BackgroundView {
        let view = BackgroundView()
        // Behind-window blending samples the desktop and other windows;
        // AppKit handles the backdrop without making the reading pane clear.
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: BackgroundView, context: Context) {}

    final class BackgroundView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
