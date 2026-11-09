import Foundation

@main struct InteractionTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        var immediate = InteractionPolicy()
        expect(immediate.update(inside: true, expanded: false, locked: false, hover: true,
                                autoCollapse: true, delay: 0, now: 0) == true,
               "zero-delay hover expands on the first pointer event")
        var state = InteractionPolicy()
        func update(_ inside: Bool, _ expanded: Bool, _ at: Double, locked: Bool = false, hover: Bool = true, collapse: Bool = true) -> Bool? {
            state.update(inside: inside, expanded: expanded, locked: locked, hover: hover, autoCollapse: collapse, delay: 0.15, now: at)
        }
        expect(update(true, false, 0) == nil, "entry must wait")
        expect(update(true, false, 0.14) == nil, "under hover threshold")
        expect(update(true, false, 0.16) == true, "hover expands")
        expect(update(false, true, 1) == nil, "exit grace begins")
        expect(update(false, true, 1.10) == nil, "brief exits do not collapse")
        expect(update(false, true, 1.13) == false, "leave collapses even with reminder / settings window outside policy")
        expect(update(false, true, 1.31, locked: true) == nil, "keyboard / menu lock")
        expect(update(false, true, 1.32, collapse: false) == nil, "disabled auto collapse")
        state.dismiss()
        expect(update(true, false, 2) == nil, "escape blocks reentry")
        expect(update(true, false, 3) == nil, "escape does not reopen under stationary pointer")
        _ = update(false, false, 4)
        _ = update(true, false, 5)
        expect(update(true, false, 5.16) == true, "exit then reentry clears suppression")
        expect(update(true, false, 7, hover: false) == nil, "hover disabled")
        expect(InteractionPolicy.stableOrder(current: ["b", "a"], held: ["a", "b"]) == ["a", "b"], "activity updates cannot move hovered targets")
        expect(InteractionPolicy.stableOrder(current: ["c", "b"], held: ["a", "b"]) == ["b", "c"], "removed targets disappear and new rows append")
        expect(InteractionPolicy.stableOrder(current: ["c", "b"], held: []) == ["c", "b"], "release restores live ordering")
        var prefs = IslePreferences()
        expect(prefs.panelWidth == 640 && prefs.reveal && prefs.hoverDelay == 0, "owner defaults")
        prefs.filters = [FilterRule(kind: "directory", pattern: "/hidden"), FilterRule(kind: "prefix", pattern: "Automation:")]
        expect(prefs.hidden(cwd: "/tmp/hidden/project", prompt: "hello"), "directory filter")
        expect(prefs.hidden(cwd: "/tmp/visible", prompt: "automation: run"), "prefix case insensitive")
        expect(!prefs.hidden(cwd: "/tmp/visible", prompt: "hello automation: run"), "prefix is not contains")
        prefs.filters[0].enabled = false
        expect(!prefs.hidden(cwd: "/tmp/hidden/project", prompt: "hello"), "disabled filter")
        prefs.quietHours = true
        expect(!prefs.soundAllowed(hour: 23) && !prefs.soundAllowed(hour: 7) && prefs.soundAllowed(hour: 8), "midnight quiet range")
        prefs.quietStart = 10; prefs.quietEnd = 12
        expect(!prefs.soundAllowed(hour: 10) && prefs.soundAllowed(hour: 12), "same day quiet boundaries")
        prefs.quietStart = 12
        expect(!prefs.soundAllowed(hour: 0) && !prefs.soundAllowed(hour: 23), "equal hours means all day quiet")
        prefs.quietHours = false; prefs.quiet = true
        expect(!prefs.soundAllowed(hour: 15), "focus overrides quiet hours")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("preferences.json")
        let store = AppPreferences(url: url)
        store.value = prefs
        store.value.panelWidth = 704
        store.value.fontSize = 13
        store.value.hoverDelay = 0.15
        store.value.expandAnimationDuration = 0
        let readback = AppPreferences(url: url)
        expect(readback.value.hoverDelay == 0.15 && readback.value.panelAnimationDuration(expanded: true, reduceMotion: false) == 0,
               "instant expansion persists independently of hover delay")
        expect(readback.value.panelAnimationDuration(expanded: false, reduceMotion: false) == 0.22,
               "instant expansion leaves the closing duration alone")
        expect(readback.value.panelWidth == 704 && readback.value.fontSize == 13 && readback.value.filters == prefs.filters, "persisted authoritative readback")
        var old = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        old.removeValue(forKey: "smartSuppression"); old.removeValue(forKey: "hideFullscreen")
        old.removeValue(forKey: "expandAnimationDuration")
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        let migrated = AppPreferences(url: url)
        expect(migrated.value.fontSize == 13 && migrated.value.smartSuppression && migrated.value.hideFullscreen, "new defaults do not erase persisted settings")
        expect(migrated.value.hoverDelay == 0.15 && migrated.value.panelAnimationDuration(expanded: true, reduceMotion: false) == 0.22,
               "legacy preferences use the default animation and retain hover delay")
        expect(migrated.value.panelAnimationDuration(expanded: true, reduceMotion: true) == 0,
               "reduce motion takes priority over the animation duration")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        expect(permissions?.intValue == 0o600, "preferences private")
        print("PASS: pointer, suppression, lock, filter, quiet-hours, persistence and permissions assertions")
    }
}
