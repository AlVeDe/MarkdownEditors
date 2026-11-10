import AppKit
import SwiftUI

/// Shows an `NSView` that outlives the SwiftUI view hierarchy.
///
/// The editor and the preview are created once per window and moved between
/// layouts (split, editor only, preview only). Returning the long-lived view
/// directly from `makeNSView` is fragile: during a layout change SwiftUI may
/// create the new representable before dismantling the old one, and the old
/// one's teardown would then pull the view out of its new home. Each
/// representable therefore gets its own container and adopts the hosted view
/// into it.
struct HostedView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.adopt(view)
        return container
    }

    func updateNSView(_ container: ContainerView, context: Context) {
        container.adopt(view)
    }

    final class ContainerView: NSView {
        private var hosted: NSView?

        func adopt(_ view: NSView) {
            hosted = view
            if view.superview !== self {
                view.removeFromSuperview()
                view.frame = bounds
                view.autoresizingMask = [.width, .height]
                addSubview(view)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Re-adopt when this container becomes visible again after another
            // container borrowed the view.
            if window != nil, let hosted { adopt(hosted) }
        }
    }
}
