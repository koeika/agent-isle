import AppKit
import SwiftUI

/// Hide AppKit's automatic rings inside our custom painted controls, without
/// changing the user's system keyboard-navigation or accessibility settings.
final class RinglessHostingView<Content: View>: NSHostingView<Content> {
    var onPointerBoundary: ((NSEvent) -> Void)?
    private var boundaryArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let boundaryArea { removeTrackingArea(boundaryArea) }
        guard onPointerBoundary != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        boundaryArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === boundaryArea, let onPointerBoundary { onPointerBoundary(event) }
        else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === boundaryArea, let onPointerBoundary { onPointerBoundary(event) }
        else { super.mouseExited(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let onPointerBoundary { onPointerBoundary(event) }
        else { super.mouseMoved(with: event) }
    }

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
