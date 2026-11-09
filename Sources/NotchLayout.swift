import AppKit

struct NotchLayout {
    static let alertHeight: CGFloat = 58
    let screen: NSRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let horizontalAdjustment: CGFloat
    let verticalAdjustment: CGFloat
    var wingWidth: CGFloat { (compactWidth - (hasNotch ? notchWidth : 0)) / 2 }
    var hasNotch: Bool { notchHeight > 0 && notchWidth > 0 }
    var compactWidth: CGFloat { min(screen.width, (hasNotch ? notchWidth + 168 : 296) + max(-64, min(160, horizontalAdjustment))) }
    var compactHeight: CGFloat { max(24, (hasNotch ? max(notchHeight, 32) : 30) + max(-8, min(40, verticalAdjustment))) }
    var contentInset: CGFloat { hasNotch ? max(notchHeight, compactHeight) : 4 }
    func frame(expanded: Bool, alert: Bool = false, width preferredWidth: CGFloat = 640, height preferredHeight: CGFloat = 650, alertHeight: CGFloat = NotchLayout.alertHeight) -> NSRect {
        let width = expanded || alert ? min(max(360, preferredWidth), screen.width - 24) : compactWidth
        let height = expanded ? min(max(160, preferredHeight) + contentInset, screen.height - 40) : compactHeight + (alert ? alertHeight : 0)
        return NSRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
    }
    init(screen: NSRect, notchWidth: CGFloat, notchHeight: CGFloat, horizontalAdjustment: CGFloat = 0, verticalAdjustment: CGFloat = 0) {
        self.screen = screen
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.horizontalAdjustment = horizontalAdjustment
        self.verticalAdjustment = verticalAdjustment
    }
    init(_ display: NSScreen) {
        horizontalAdjustment = 0
        verticalAdjustment = 0
        screen = display.frame
        notchHeight = display.safeAreaInsets.top
        if notchHeight > 0, let left = display.auxiliaryTopLeftArea, let right = display.auxiliaryTopRightArea {
            notchWidth = max(0, right.minX - left.maxX)
        } else { notchWidth = 0 }
    }
}
