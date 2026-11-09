import AppKit
import Combine

struct FilterRule: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: String
    var pattern: String
    var enabled = true
    func matches(cwd: String, prompt: String) -> Bool {
        guard enabled, !pattern.isEmpty else { return false }
        switch kind {
        case "directory": return cwd.localizedCaseInsensitiveContains(pattern)
        case "prefix": return prompt.lowercased().hasPrefix(pattern.lowercased())
        default: return prompt.localizedCaseInsensitiveContains(pattern)
        }
    }
}
struct IslePreferences: Codable, Equatable {
    static let defaultExpandAnimationDuration = 0.22
    static let expandAnimationRange = 0.0...1.0
    var enabledProviders = ["codex", "claude"]
    var providerColors = ["codex": "34DDB7", "claude": "E8A17B", "cursor": "A78BFA", "dsh": "5B9BFF"]
    var hoverExpand = true
    var hoverDelay = 0.0
    var expandAnimationDuration = Self.defaultExpandAnimationDuration
    var autoCollapse = true
    var smartSuppression = true
    var hideFullscreen = true
    var hideIdle = false
    var disableJump = false
    var reveal = true
    var revealSeconds = 5.0
    var outsideDismiss = false
    var cleanupHours = 2.0
    var quiet = false
    var quietWhenLocked = true
    var detailed = true
    var screenID = "auto"
    var fontSize = 11.0
    var cardHeight = 90.0
    var panelHeight = 520.0
    var panelWidth = 640.0
    var projectName = true
    var activityDetail = true
    // Legacy absolute dimensions remain decodable but are no longer used by
    // the calibration UI. Signed offsets preserve camera exclusion separately.
    var notchWidth = 0.0
    var notchHeight = 0.0
    var notchWidthAdjustment = 0.0
    var notchHeightAdjustment = 0.0
    var avatarStyle = "robot"
    var customLogo = ""
    var shortcuts = true
    var reverseShortcut = true
    var shortcutModifier = "control"
    var shortcutKey = "g"
    var hints = true
    var quietHours = false
    var quietStart = 22
    var quietEnd = 8
    var completeSound = "Agent Isle"
    var inputSound = "Agent Isle"
    var errorSound = "Agent Isle"
    var filters: [FilterRule] = []
    func panelAnimationDuration(expanded: Bool, reduceMotion: Bool) -> Double {
        if reduceMotion { return 0 }
        if !expanded { return Self.defaultExpandAnimationDuration }
        return min(Self.expandAnimationRange.upperBound, max(Self.expandAnimationRange.lowerBound, expandAnimationDuration))
    }
    func hidden(cwd: String, prompt: String) -> Bool { filters.contains { $0.matches(cwd: cwd, prompt: prompt) } }
    func soundAllowed(hour: Int) -> Bool {
        guard !quiet, quietHours else { return !quiet }
        if quietStart == quietEnd { return false }
        return !(quietStart < quietEnd ? hour >= quietStart && hour < quietEnd : hour >= quietStart || hour < quietEnd)
    }
    func soundName(_ status: String) -> String { status == "waiting" ? inputSound : status == "error" ? errorSound : completeSound }
}
final class AppPreferences: ObservableObject {
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Isle") }
    @Published var value: IslePreferences { didSet { save(); onChange?() } }
    @Published var error = ""
    var onChange: (() -> Void)?
    let url: URL
    init(url: URL = AppPreferences.directory.appendingPathComponent("preferences.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let defaultsData = try? JSONEncoder().encode(IslePreferences()),
           var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] {
            merged.merge(saved) { _, saved in saved }
            if let encoded = try? JSONSerialization.data(withJSONObject: merged), let loaded = try? JSONDecoder().decode(IslePreferences.self, from: encoded) { value = loaded }
            else { value = IslePreferences() }
        }
        else { value = IslePreferences() }
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            error = ""
        } catch { self.error = "无法保存设置：" + error.localizedDescription }
    }
}
