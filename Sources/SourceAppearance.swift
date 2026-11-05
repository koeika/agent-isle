import AppKit

enum SourceAppearance {
    static let providers = [("codex", "Codex"), ("claude", "Claude Code"), ("cursor", "Cursor")]
    static let defaults = ["codex": "34DDB7", "claude": "E8A17B", "cursor": "A78BFA"]
    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "34DDB7" }
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    static func color(_ hex: String, provider: String) -> NSColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let fallback = defaults[provider] ?? "34DDB7"
        let rgb = value.count == 6 ? UInt32(value, radix: 16) ?? UInt32(fallback, radix: 16)! : UInt32(fallback, radix: 16)!
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
