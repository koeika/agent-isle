import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AvatarStyle: String, CaseIterable {
    case robot, cat, ghost, sparkle
    var title: String { switch self { case .robot: return "机器人"; case .cat: return "猫咪"; case .ghost: return "幽灵"; case .sparkle: return "星光" } }
    var pixels: [String] {
        switch self {
        case .robot: return ["  XX   XX  ", " XXXXXXXXX ", "XXXXXXXXXXX", "XXX XXX XXX", "XXX XXX XXX", "XXXXXXXXXXX", " XXXXXXXXX ", "  XX   XX  ", " XX     XX "]
        case .cat: return ["XX       XX", "XXX     XXX", "XXXXXXXXXXX", "XXX XXX XXX", "XXX XXX XXX", "XXXXX XXXXX", " XXXXXXXXX ", "  XXXXXXX  ", "   XX XX   "]
        case .ghost: return ["   XXXXX   ", " XXXXXXXXX ", "XXXXXXXXXXX", "XXX XXX XXX", "XXX XXX XXX", "XXXXXXXXXXX", "XXXX X XXXX", "XXXXXXXXXXX", "XX XX XX XX"]
        case .sparkle: return ["     X     ", "    XXX    ", "    XXX    ", "  XXXXXXX  ", "XXXXXXXXXXX", "  XXXXXXX  ", "    XXX    ", "    XXX    ", "     X     "]
        }
    }
}

enum AvatarImportError: LocalizedError {
    case invalid, tooLarge, saveFailed
    var errorDescription: String? {
        switch self {
        case .invalid: return "无法读取图片。请选择有效的 PNG、JPEG、HEIC 或 WebP 图片。"
        case .tooLarge: return "图片不能超过 10 MB，长宽不能超过 16384 像素。"
        case .saveFailed: return "无法保存自定义 Logo，请重试。"
        }
    }
}

enum AvatarAssets {
    static var directory: URL { AppPreferences.directory.appendingPathComponent("Appearance") }
    static let cache = NSCache<NSString, NSImage>()
    static func image(_ name: String, directory: URL = directory) -> NSImage? {
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".png"), !name.contains("/") else { return nil }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let image = cache.object(forKey: url.path as NSString) { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }
    /// Downsamples before decoding fully, preserves transparency/aspect ratio,
    /// and copies a normalized PNG; never retains the original external path.
    static func importLogo(_ source: URL, directory: URL = directory) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue <= 10_000_000 else { throw AvatarImportError.tooLarge }
        guard let input = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(input), [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.webP.identifier].contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber, width.intValue > 0, height.intValue > 0 else { throw AvatarImportError.invalid }
        guard width.intValue <= 16384, height.intValue <= 16384 else { throw AvatarImportError.tooLarge }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { throw AvatarImportError.invalid }
        let rep = NSBitmapImageRep(cgImage: thumbnail)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw AvatarImportError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "logo-" + UUID().uuidString + ".png"
        let target = directory.appendingPathComponent(name)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        guard image(name, directory: directory) != nil else { throw AvatarImportError.saveFailed }
        return name
    }
    static func menuImage(style: String, customLogo: String) -> NSImage {
        if style == "custom", let custom = image(customLogo) {
            let icon = NSImage(size: NSSize(width: 20, height: 20))
            icon.lockFocus()
            let ratio = min(18 / custom.size.width, 18 / custom.size.height)
            let size = NSSize(width: custom.size.width * ratio, height: custom.size.height * ratio)
            custom.draw(in: NSRect(x: (20-size.width)/2, y: (20-size.height)/2, width: size.width, height: size.height))
            icon.unlockFocus()
            return icon
        }
        let pixels = (AvatarStyle(rawValue: style) ?? .robot).pixels
        return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor(red: 0.2, green: 0.85, blue: 0.7, alpha: 1).setFill()
            for (y,row) in pixels.enumerated() {
                for (x,char) in row.enumerated() where char == "X" { NSBezierPath(rect: NSRect(x: CGFloat(x+1)*1.5, y: CGFloat(10-y)*1.5, width: 1.4, height: 1.4)).fill() }
            }
            return true
        }
    }
}
