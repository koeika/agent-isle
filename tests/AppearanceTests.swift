import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct AppearanceTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let automatic = NotchLayout(screen: screen, notchWidth: 185, notchHeight: 32)
        let tiny = NotchLayout(screen: screen, notchWidth: 185, notchHeight: 32, horizontalAdjustment: 1, verticalAdjustment: 1)
        expect(tiny.compactWidth == automatic.compactWidth + 1, "1pt width adjustment must change actual compact width")
        expect(tiny.compactHeight == automatic.compactHeight + 1, "1pt height adjustment must change actual compact height")
        let smaller = NotchLayout(screen: screen, notchWidth: 185, notchHeight: 32, horizontalAdjustment: -64, verticalAdjustment: -8)
        expect(smaller.compactWidth == 289 && smaller.compactHeight == 24, "negative adjustments reduce geometry")
        expect(smaller.notchWidth == 185 && smaller.contentInset >= 32 && smaller.wingWidth == 52, "camera exclusion remains safe while wings shrink")
        let taller = NotchLayout(screen: screen, notchWidth: 185, notchHeight: 32, verticalAdjustment: 12)
        expect(taller.contentInset == 44 && taller.frame(expanded: true).maxY == screen.maxY, "expanded top inset follows taller compact bar")
        let flat = NotchLayout(screen: screen, notchWidth: 0, notchHeight: 0, horizontalAdjustment: 30, verticalAdjustment: 10)
        expect(flat.compactWidth == 326 && flat.compactHeight == 40, "non-notch display calibration also works")
        for style in AvatarStyle.allCases {
            expect(style.pixels.count == 9 && style.pixels.allSatisfy { $0.count == 11 }, "preset pixel dimensions")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("test-logo.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.5).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 512)).fill()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: source)
        let original = try Data(contentsOf: source)
        let storage = temp.appendingPathComponent("appearance")
        let name = try AvatarAssets.importLogo(source, directory: storage)
        let target = storage.appendingPathComponent(name)
        let unchanged = try Data(contentsOf: source)
        expect(unchanged == original, "import must not modify original")
        let imported = NSBitmapImageRep(data: try Data(contentsOf: target))!
        expect(imported.pixelsWide == 512 && imported.pixelsHigh == 256, "large logo is bounded and keeps aspect ratio")
        expect(imported.hasAlpha, "transparent PNG retains alpha channel")
        expect(abs((imported.colorAt(x: 128, y: 128)?.alphaComponent ?? 0) - 0.5) < 0.03, "logo transparency preserved")
        let mode = (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as! NSNumber).intValue
        expect(mode == 0o600, "normalized logo private permissions")
        let jpeg = temp.appendingPathComponent("fixture.jpg")
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: jpeg)
        let jpegName = try AvatarAssets.importLogo(jpeg, directory: storage)
        expect(AvatarAssets.image(jpegName, directory: storage) != nil, "JPEG import")
        let heic = temp.appendingPathComponent("fixture.heic")
        guard let destination = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil) else { throw AvatarImportError.invalid }
        CGImageDestinationAddImage(destination, bitmap.cgImage!, nil)
        expect(CGImageDestinationFinalize(destination), "HEIC fixture encoding")
        let heicName = try AvatarAssets.importLogo(heic, directory: storage)
        expect(AvatarAssets.image(heicName, directory: storage) != nil, "HEIC import")
        let webp = temp.appendingPathComponent("fixture.webp")
        try Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvB8AAEAdQvMpUv7SBiOh/AAA=")!.write(to: webp)
        let webpName = try AvatarAssets.importLogo(webp, directory: storage)
        expect(AvatarAssets.image(webpName, directory: storage) != nil, "WebP import")
        try FileManager.default.removeItem(at: source)
        expect(AvatarAssets.image(name, directory: storage) != nil, "imported logo survives deletion of original")
        expect(AvatarAssets.image("../test.png", directory: storage) == nil, "logo path traversal rejected")
        let bad = temp.appendingPathComponent("broken.png"); try Data("not an image".utf8).write(to: bad)
        do { _ = try AvatarAssets.importLogo(bad, directory: storage); expect(false, "bad image rejected") } catch AvatarImportError.invalid {} catch { throw error }
        let oversized = temp.appendingPathComponent("large.png"); FileManager.default.createFile(atPath: oversized.path, contents: Data())
        let handle = try FileHandle(forWritingTo: oversized); try handle.truncate(atOffset: 10_000_001); try handle.close()
        do { _ = try AvatarAssets.importLogo(oversized, directory: storage); expect(false, "oversized image rejected") } catch AvatarImportError.tooLarge {} catch { throw error }
        expect(AvatarAssets.image(name, directory: storage) != nil, "failed imports preserve existing logo")
        let store = AppPreferences(url: temp.appendingPathComponent("preferences.json"))
        store.value.avatarStyle = "custom"; store.value.customLogo = name; store.value.notchWidthAdjustment = -12; store.value.notchHeightAdjustment = 4
        let restored = AppPreferences(url: store.url)
        expect(restored.value.avatarStyle == "custom" && restored.value.customLogo == name && restored.value.notchWidthAdjustment == -12 && restored.value.notchHeightAdjustment == 4, "avatar and signed calibration survive restart")
        print("PASS: signed notch calibration, camera-safe layout, presets, normalized logo import, transparency, invalid/oversized input and persisted choices")
    }
}
