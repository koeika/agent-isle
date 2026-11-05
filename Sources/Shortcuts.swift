import AppKit
import Carbon

final class ShortcutController {
    weak var model: IsleModel?
    var hotKey: EventHotKeyRef?
    var reverseKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var local: Any?
    var flags: Any?
    var localFlags: Any?
    var cycled = false
    var configuration = ""
    var failure = ""
    var makeKey: (() -> Void)?
    static let codes: [String: UInt32] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]
    init(model: IsleModel) {
        self.model = model
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context = context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ShortcutController>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            if let event = event { GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) }
            owner.trigger(reverse: identifier.id == 2)
            return noErr
        }, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &handler)
        local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let model = self.model else { return event }
            if !model.recordingShortcut && model.preferences.value.shortcuts && event.modifierFlags.contains(self.modifier) && event.charactersIgnoringModifiers?.lowercased() == model.preferences.value.shortcutKey.lowercased() {
                self.trigger(reverse: event.modifierFlags.contains(.shift)); return nil
            }
            guard model.expanded, model.settingsWindow?.isKeyWindow != true, model.conversationWindow?.isKeyWindow != true else { return event }
            if event.keyCode == 53 { model.dismissPanel?(); return nil }
            guard model.preferences.value.shortcuts else { return event }
            switch event.keyCode {
            case 125: model.keyboardMode = true; model.moveSelection(1); return nil
            case 126: model.keyboardMode = true; model.moveSelection(-1); return nil
            case 36: model.jumpSelected(); return nil
            default:
                if event.modifierFlags.contains(self.modifier), let digit = Int(event.charactersIgnoringModifiers ?? ""), digit >= 1, digit <= min(9, model.visibleSessions.count) {
                    model.selectedKey = model.visibleSessions[digit - 1].key; model.jumpSelected(); return nil
                }
                return event
            }
        }
        flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flagsChanged($0) }
        localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flagsChanged($0); return $0 }
        register()
    }
    var modifier: NSEvent.ModifierFlags {
        switch model?.preferences.value.shortcutModifier { case "option": return .option; case "command": return .command; default: return .control }
    }
    func flagsChanged(_ event: NSEvent) {
        guard let model = model else { return }
        model.showHints = model.preferences.value.hints && event.modifierFlags.contains(modifier)
        if !event.modifierFlags.contains(modifier) && model.keyboardMode && cycled { model.jumpSelected(); cycled = false }
    }
    func register() {
        guard let prefs = model?.preferences.value else { return }
        let next = "\(prefs.shortcuts)-\(prefs.shortcutModifier)-\(prefs.shortcutKey)-\(prefs.reverseShortcut)"
        guard configuration != next else { return }; configuration = next
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let reverseKey = reverseKey { UnregisterEventHotKey(reverseKey); self.reverseKey = nil }
        guard prefs.shortcuts else { return }
        let flags: UInt32 = prefs.shortcutModifier == "option" ? UInt32(optionKey) : prefs.shortcutModifier == "command" ? UInt32(cmdKey) : UInt32(controlKey)
        guard let code = Self.codes[prefs.shortcutKey.lowercased()] else { failure = "请选择一个字母或数字"; return }
        let status = RegisterEventHotKey(code, flags, EventHotKeyID(signature: 0x4149534c, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status == noErr && prefs.reverseShortcut { RegisterEventHotKey(code, flags | UInt32(shiftKey), EventHotKeyID(signature: 0x4149534c, id: 2), GetApplicationEventTarget(), 0, &reverseKey) }
        failure = status == noErr ? "" : "快捷键已被占用（\(status)），请选择其他组合。"
        if !failure.isEmpty { model?.message = failure }
        model?.audit("shortcut-registration", ["success": status == noErr, "status": status])
    }
    func trigger(reverse: Bool = false) {
        guard let model = model else { return }
        if model.keyboardMode && model.expanded { cycled = true; model.moveSelection(reverse ? -1 : 1) }
        else { if reverse { return }; cycled = false; model.keyboardMode = true; model.selectedKey = nil; model.setExpanded(true); model.moveSelection(1) }
        makeKey?()
        model.audit("switcher-open", ["cycling": cycled])
    }
    deinit {
        if let reverseKey = reverseKey { UnregisterEventHotKey(reverseKey) }
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        if let handler = handler { RemoveEventHandler(handler) }
        for monitor in [local, flags, localFlags].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
    }
}
