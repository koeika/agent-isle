import AppKit
import Foundation

@main struct SourceReadTests {
    static func expect(_ value: @autoclosure () -> Bool, _ detail: String) {
        if !value() { fputs("FAIL: \(detail)\n", stderr); exit(1) }
    }
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let prefs = AppPreferences(url: folder.appendingPathComponent("preferences.json"))
        expect(prefs.value.enabledProviders == ["codex", "claude"], "new defaults exclude Cursor")
        prefs.value.enabledProviders = []
        prefs.value.providerColors["claude"] = "FF3300"
        let restored = AppPreferences(url: prefs.url)
        expect(restored.value.enabledProviders.isEmpty, "all-off persists")
        expect(restored.value.providerColors["claude"] == "FF3300", "source color persists")
        let color = SourceAppearance.color("#FF3300", provider: "claude")
        expect(SourceAppearance.hex(color) == "FF3300", "custom RGB roundtrip")
        expect(SourceAppearance.hex(SourceAppearance.color("invalid", provider: "cursor")) == "A78BFA", "invalid color falls back per source")
        let ledger = ReadReceipts(url: folder.appendingPathComponent("read-receipts.json"))
        expect(ledger.isUnread(key: "codex:task", completion: 100, unread: true), "new completed task unread")
        try ledger.mark(key: "codex:task", completion: 100)
        expect(!ledger.isUnread(key: "codex:task", completion: 100, unread: true), "view clears dot immediately")
        let saved = ReadReceipts(url: ledger.url)
        expect(!saved.isUnread(key: "codex:task", completion: 100, unread: true), "read state survives restart")
        expect(saved.isUnread(key: "codex:task", completion: 101, unread: true), "new completion reappears")
        expect(!saved.isUnread(key: "codex:task", completion: 101, unread: false), "backend read flag honored")
        let mode = (try FileManager.default.attributesOfItem(atPath: ledger.url.path)[.posixPermissions] as! NSNumber).intValue
        expect(mode == 0o600, "read receipts private")
        print("PASS: source opt-in defaults, all-off, colors, RGB fallback, read persistence and next-completion unread")
    }
}
