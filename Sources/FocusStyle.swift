import AppKit
import SwiftUI

/// Hide AppKit's automatic rings inside our custom painted controls, without
/// changing the user's system keyboard-navigation or accessibility settings.
final class RinglessHostingView<Content: View>: NSHostingView<Content> {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeRings(self)
    }
    override func layout() {
        super.layout()
        removeRings(self)
    }
    private func removeRings(_ view: NSView) {
        view.focusRingType = .none
        for child in view.subviews { removeRings(child) }
    }
    override var focusRingMaskBounds: NSRect { .zero }
    override func drawFocusRingMask() {}
}
