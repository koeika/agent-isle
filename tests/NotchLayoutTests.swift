import AppKit

@main struct LayoutTests {
    static func main() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let notch = NotchLayout(screen: screen, notchWidth: 210, notchHeight: 37)
        precondition(notch.frame(expanded: false).maxY == screen.maxY)
        precondition(notch.frame(expanded: true).maxY == screen.maxY)
        precondition(notch.frame(expanded: true).width == 640)
        precondition(notch.compactWidth - notch.notchWidth == 168)
        precondition(notch.contentInset >= notch.notchHeight)
        let alert = notch.frame(expanded: false, alert: true)
        precondition(alert.height == notch.compactHeight + 58)
        precondition(alert.height < 110 && alert.width == 640)
        let flat = NotchLayout(screen: NSRect(x: -1920, y: 100, width: 1920, height: 1080), notchWidth: 0, notchHeight: 0)
        precondition(flat.frame(expanded: false).maxY == 1180)
        precondition(flat.compactWidth == 296 && flat.compactHeight == 30)
        let small = NotchLayout(screen: NSRect(x: 0, y: 0, width: 600, height: 500), notchWidth: 0, notchHeight: 0)
        precondition(small.frame(expanded: true).width <= 576)
        precondition(AlertPolicy.priority("waiting") > AlertPolicy.priority("completed"))
        precondition(!AlertPolicy.expires("waiting") && AlertPolicy.expires("completed"))
        print("PASS: top attachment, camera clearance, 640pt width, compact single-row alert and flat-screen fallback")
    }
}
