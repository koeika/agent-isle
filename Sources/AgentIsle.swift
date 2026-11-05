import AppKit
import SwiftUI
import UserNotifications
import ApplicationServices
import QuartzCore
import Combine

struct AgentSession: Decodable, Identifiable, Equatable {
    let id: String
    let provider: String
    let title: String
    let cwd: String
    let status: String
    let detail: String
    let updated: Double
    let origin: String
    let transcript: String
    let terminal: [String: String]?
    let confidence: String
    let hook_seen: Bool
    let user_message: String
    let assistant_message: String
    let summary: String
    let source: String
    let archived: Bool
    let unread: Bool?
    let completed_at: Double?
    var completionToken: Double { (completed_at ?? 0) > 0 ? completed_at! : updated }
    var key: String { provider + ":" + id }
    var providerName: String { ["codex": "Codex", "cursor": "Cursor", "claude": "Claude Code", "dsh": "DS Harness"][provider] ?? provider }
    var color: Color { ["codex": Color.mint, "cursor": Color(red: 0.65, green: 0.67, blue: 1), "claude": Color.orange, "dsh": Color.blue][provider] ?? .gray }
    var stateLabel: String {
        ["running": "进行中", "completed": "已完成", "waiting": "需要你", "idle": "待命", "cancelled": "已中止", "closed": "已关闭", "unknown": "待确认", "error": "出错了"][status] ?? status
    }
    var stateColor: Color {
        switch status {
        case "running": return .mint
        case "completed": return .green
        case "waiting": return .orange
        case "error": return .red
        default: return .gray
        }
    }
    var targetLabel: String {
        if terminal?["TTY"] != nil || terminal?["ITERM_SESSION_ID"] != nil { return "返回终端标签" }
        if provider == "dsh" { return "打开 DS Harness（不定位会话）" }
        if provider == "codex" || provider == "cursor" { return "打开此对话" }
        return "定位原会话"
    }
    var originLabel: String {
        if archived { return "已归档" }
        if source == "exec" { return "CLI / 外部任务" }
        if origin.isEmpty && provider == "codex" { return "本地会话" }
        return ""
    }
    var userPreview: String {
        if let range = user_message.range(of: "<user_query>"), let end = user_message.range(of: "</user_query>", range: range.upperBound..<user_message.endIndex) {
            return String(user_message[range.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return user_message.replacingOccurrences(of: "\n", with: " ")
    }
}

struct AgentAlert: Decodable {
    let key: String
    let status: String
    let title: String
    let provider: String
    let detail: String
    let at: Double
}

struct Snapshot: Decodable {
    let sessions: [AgentSession]
    let alerts: [AgentAlert]
    let focused_keys: [String]?
    let diagnostics: [[String: JSONValue]]?
}

enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else { self = .null }
    }
}

final class IsleModel: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var expanded = false
    @Published var pinned = false
    @Published var hovered = false {
        didSet { if hovered { freezeSessionOrder() } else if !keyboardMode { interactionOrder = [] } }
    }
    var interactionOrder: [String] = []
    @Published var filter = "all"
    @Published var banner: AgentAlert?
    @Published var message = "正在发现本机 AI 会话…"
    @Published var connected = false
    var focusedKeys: [String] = []
    let preferences = AppPreferences()
    let readReceipts = ReadReceipts(url: AppPreferences.directory.appendingPathComponent("read-receipts.json"))
    @Published var selectedKey: String?
    @Published var keyboardMode = false {
        didSet { if keyboardMode { freezeSessionOrder() } else if !hovered { interactionOrder = [] } }
    }
    @Published var showHints = false
    @Published var screenLocked = false
    var recordingShortcut = false
    var openSettings: (() -> Void)?
    var openGuide: (() -> Void)?
    var dismissPanel: (() -> Void)?
    var settingsWindow: NSWindow?
    @Published var muted = UserDefaults.standard.bool(forKey: "muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }
    @Published var notifications = UserDefaults.standard.bool(forKey: "notifications")
    @Published var integrationsBusy = false
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 0
    @Published var compactWidth: CGFloat = 296
    @Published var wingWidth: CGFloat = 84
    @Published var compactHeight: CGFloat = 30
    @Published var soundVolume = (UserDefaults.standard.object(forKey: "soundVolume") as? Double) ?? 0.85 {
        didSet { UserDefaults.standard.set(soundVolume, forKey: "soundVolume") }
    }
    var resize: (() -> Void)?
    var process: Process?
    var sound: NSSound?
    var conversationWindow: NSWindow?
    var collapseWork: DispatchWorkItem?
    var notificationQueue: [AgentAlert] = []
    var resources: URL { Bundle.main.resourceURL! }
    lazy var navigator = Navigator(resources: resources)
    var eligibleSessions: [AgentSession] {
        let prefs = preferences.value
        let cutoff = Date().timeIntervalSince1970 - prefs.cleanupHours * 3600
        return sessions.filter { session in
            prefs.enabledProviders.contains(session.provider) && !prefs.hidden(cwd: session.cwd, prompt: session.userPreview) &&
            (prefs.cleanupHours == 0 || session.updated >= cutoff || session.status == "running" || session.status == "waiting")
        }
    }
    var visibleSessions: [AgentSession] {
        let rows = eligibleSessions.filter { filter == "all" || $0.provider == filter }
        guard !interactionOrder.isEmpty else { return rows }
        let byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return InteractionPolicy.stableOrder(current: rows.map { $0.key }, held: interactionOrder).compactMap { byKey[$0] }
    }
    func freezeSessionOrder() {
        // Statuses stay live, but activity in other threads must not move the
        // target out from under the pointer or keyboard selection.
        if interactionOrder.isEmpty { interactionOrder = eligibleSessions.map { $0.key } }
    }
    init() {
        readReceipts.onChange = { [weak self] in self?.objectWillChange.send() }
        preferences.onChange = { [weak self] in
            guard let self = self else { return }
            self.objectWillChange.send()
            if let alert = self.banner, !self.eligibleSessions.contains(where: { $0.key == alert.key }) { self.dismissReminder() }
            self.notificationQueue.removeAll { alert in !self.eligibleSessions.contains(where: { $0.key == alert.key }) }
            if self.filter != "all" && !self.preferences.value.enabledProviders.contains(self.filter) { self.filter = "all" }
            self.resize?()
        }
    }
    var running: Int { eligibleSessions.filter { $0.status == "running" }.count }
    var waiting: Int { eligibleSessions.filter { $0.status == "waiting" }.count }
    var stateDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Isle") }

    func startMonitor() {
        guard process == nil else { return }
        let child = Process()
        PythonRuntime.configure(child, resources: resources)
        child.arguments = [resources.appendingPathComponent("agent_isle/monitor.py").path, "watch"]
        let output = Pipe(), errors = Pipe()
        child.standardOutput = output
        child.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if !bytes.isEmpty { DispatchQueue.main.async { self.message = "监听器报告错误 · 查看诊断文件" } }
        }
        child.terminationHandler = { proc in
            DispatchQueue.main.async {
                self.connected = false
                self.process = nil
                self.message = "监听器已停止（\(proc.terminationStatus)）· 在设置中重新连接"
            }
        }
        do {
            try child.run()
            process = child
            DispatchQueue.global(qos: .utility).async {
                var pending = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    while let range = pending.range(of: Data([10])) {
                        let line = pending.subdata(in: 0..<range.lowerBound)
                        pending.removeSubrange(0..<range.upperBound)
                        do {
                            let snapshot = try JSONDecoder().decode(Snapshot.self, from: line)
                            DispatchQueue.main.async { self.receive(snapshot) }
                        } catch {
                            DispatchQueue.main.async { self.message = "会话数据格式异常 · 可重新连接" }
                        }
                    }
                }
            }
        } catch {
            message = "无法启动 Python 3 监听器：\(error.localizedDescription)"
        }
    }

    func receive(_ snapshot: Snapshot) {
        if sessions != snapshot.sessions { sessions = snapshot.sessions; resize?() }
        focusedKeys = snapshot.focused_keys ?? []
        let wasConnected = connected
        connected = true
        if !wasConnected || message.hasPrefix("本机监听") || message.hasPrefix("部分来源") { message = "本机监听中 · 每秒更新 · 数据留在此 Mac" }
        if !(snapshot.diagnostics ?? []).isEmpty { message = "部分来源读取受限 · 可打开诊断文件检查" }
        notificationQueue.removeAll { $0.status == "waiting" && !isWaiting($0.key) }
        if let active = banner, active.status == "waiting", !isWaiting(active.key) {
            banner = nil
            collapseWork?.cancel()
            resize?()
        }
        var incoming = snapshot.alerts.filter { alert in eligibleSessions.contains { $0.key == alert.key } }
        if !wasConnected {
            incoming += eligibleSessions.filter { $0.status == "waiting" }.map {
                AgentAlert(key: $0.key, status: "waiting", title: $0.title, provider: $0.provider, detail: $0.detail, at: Date().timeIntervalSince1970)
            }
        }
        // Never let a completion in the same batch hide a question. Questions
        // stay visible until an answer/cancel is observed, even as tools run.
        if let question = incoming.last(where: { $0.status == "waiting" }) {
            if let active = banner, active.status == "waiting", active.key != question.key, isWaiting(active.key) {
                notificationQueue.append(active)
            }
            notificationQueue.removeAll { $0.key == question.key && $0.status == "waiting" }
            notificationQueue += incoming.filter { !($0.status == "waiting" && $0.key == question.key) }
            present(question)
        } else {
            notificationQueue += incoming
            if banner == nil { presentNext() }
        }
    }

    private func isWaiting(_ key: String) -> Bool { sessions.contains { $0.key == key && $0.status == "waiting" } }
    private func presentNext() {
        notificationQueue.removeAll { $0.status == "waiting" && !isWaiting($0.key) }
        guard let next = notificationQueue.indices.max(by: { AlertPolicy.priority(notificationQueue[$0].status) < AlertPolicy.priority(notificationQueue[$1].status) }) else { return }
        present(notificationQueue.remove(at: next))
    }
    private func present(_ alert: AgentAlert) {
        collapseWork?.cancel()
        guard !preferences.value.quiet && !(preferences.value.quietWhenLocked && screenLocked) else { return }
        if preferences.value.reveal { banner = alert }
        audit("alert", ["status": alert.status, "provider": alert.provider, "presentation": expanded ? "expanded" : "single-row", "sticky": !AlertPolicy.expires(alert.status)])
        resize?()
        play(alert.status)
        if notifications { notify(alert) }
        guard AlertPolicy.expires(alert.status) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.banner = nil
            self.presentNext()
            self.resize?()
            if self.banner == nil && !self.hovered && !self.pinned { self.setExpanded(false) }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.value.revealSeconds, execute: work)
    }

    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { expanded = value }
        resize?()
    }

    func play(_ status: String, force: Bool = false) {
        guard force || (!muted && preferences.value.soundAllowed(hour: Calendar.current.component(.hour, from: Date())) && !(preferences.value.quietWhenLocked && screenLocked)) else { return }
        let chosen = preferences.value.soundName(status)
        guard chosen != "Off" else { return }
        let file = ["completed": "complete", "waiting": "attention", "error": "error"][status] ?? "complete"
        sound?.stop()
        if chosen == "Agent Isle" {
            sound = NSSound(contentsOf: resources.appendingPathComponent("Sounds/\(file).wav"), byReference: false)
        } else if chosen.hasPrefix("custom:") {
            sound = NSSound(contentsOf: stateDir.appendingPathComponent("Sounds").appendingPathComponent(String(chosen.dropFirst(7))), byReference: false)
        } else { sound = NSSound(named: NSSound.Name(chosen)) }
        sound?.volume = Float(max(0, min(1, soundVolume)))
        let played = sound?.play() ?? false
        audit("sound", ["status": status, "played": played, "preview": force, "volume": soundVolume])
    }

    func preview() {
        guard banner?.status != "waiting" else { message = "当前有待输入任务，已保留其提醒；可在声音页单独试听。"; return }
        banner = AgentAlert(key: "demo", status: "completed", title: "提醒效果预览", provider: "codex", detail: "这是一条演示提醒，不是真实任务完成", at: Date().timeIntervalSince1970)
        resize?()
        play("completed", force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if self.banner?.key == "demo" { self.banner = nil; self.resize?() } }
    }

    func enableNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { granted, error in
            DispatchQueue.main.async {
                self.notifications = granted
                UserDefaults.standard.set(granted, forKey: "notifications")
                self.message = granted ? "已开启系统通知" : "系统通知未开启 · 顶部提醒仍可使用"
            }
        }
    }

    func notify(_ alert: AgentAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.status == "completed" ? "✓ 任务完成" : alert.status == "waiting" ? "需要你的确认" : "任务遇到错误"
        content.subtitle = alert.title
        content.body = String(alert.detail.prefix(160))
        content.userInfo = ["sessionKey": alert.key]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func integrations(_ action: String) {
        guard !integrationsBusy else { return }
        integrationsBusy = true
        DispatchQueue.global(qos: .utility).async {
            let child = Process(), pipe = Pipe()
            PythonRuntime.configure(child, resources: self.resources)
            child.arguments = [self.resources.appendingPathComponent("agent_isle/integrations.py").path, action] + (action == "install" ? ["--providers"] + self.preferences.value.enabledProviders : [])
            child.standardOutput = pipe
            child.standardError = pipe
            do {
                try child.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                DispatchQueue.main.async {
                    self.integrationsBusy = false
                    self.message = child.terminationStatus == 0 ? (action == "install" ? "接入已安装 · 请重启 Cursor / 新开 Claude Code 会话" : "已移除本应用 Hook · 其他配置保留") : "接入失败：" + String(data: data, encoding: .utf8)!.prefix(200)
                }
            } catch {
                DispatchQueue.main.async { self.integrationsBusy = false; self.message = error.localizedDescription }
            }
        }
    }

    var compactStatusText: String {
        if !connected { return "未连接" }
        if waiting > 0 { return "\(waiting) 待输入" }
        if running > 0 { return "\(running) 进行中" }
        let unread = eligibleSessions.filter { isUnread($0) }.count
        return unread > 0 ? "\(unread) 条待读" : "暂无进行中"
    }
    var compactStatusShort: String {
        if !connected { return "离线" }
        if waiting > 0 { return "\(waiting) 待你" }
        if running > 0 { return "\(running) 运行" }
        let unread = eligibleSessions.filter { isUnread($0) }.count
        return unread > 0 ? "\(unread) 待读" : "空闲"
    }
    var compactStatusColor: Color {
        if !connected || waiting > 0 { return .orange }
        if running > 0 { return .mint }
        return eligibleSessions.contains(where: { isUnread($0) }) ? .green : .gray
    }
    var compactStatusDetail: String {
        let counts = "\(running) 个任务进行中 · \(waiting) 个需要输入 · \(eligibleSessions.filter { isUnread($0) }.count) 个完成待读"
        return connected ? counts : "监听器未连接 · 上次记录：" + counts
    }
    var primarySourceColor: Color {
        let provider = eligibleSessions.first(where: { $0.status == "running" || $0.status == "waiting" })?.provider ?? eligibleSessions.first?.provider ?? "codex"
        return providerColor(provider)
    }
    func providerColor(_ provider: String) -> Color {
        Color(nsColor: SourceAppearance.color(preferences.value.providerColors[provider] ?? "", provider: provider))
    }
    func isUnread(_ session: AgentSession) -> Bool {
        session.status == "completed" && readReceipts.isUnread(key: session.key, completion: session.completionToken, unread: session.unread ?? false)
    }
    func markViewed(_ session: AgentSession) {
        guard session.status == "completed" else { return }
        do {
            try readReceipts.mark(key: session.key, completion: session.completionToken)
            if banner?.key == session.key && banner?.status == "completed" { dismissReminder() }
            notificationQueue.removeAll { $0.key == session.key && $0.status == "completed" && $0.at <= session.completionToken }
            audit("session-viewed", ["provider": session.provider, "completedAt": session.completionToken])
        } catch { message = "无法保存已读状态：" + error.localizedDescription }
    }
    func activate(_ session: AgentSession) {
        guard !preferences.value.disableJump else { return }
        jump(session)
    }
    func dismissReminder() {
        collapseWork?.cancel()
        banner = nil
        resize?()
    }
    func moveSelection(_ delta: Int) {
        let rows = visibleSessions
        guard !rows.isEmpty else { selectedKey = nil; return }
        let current = rows.firstIndex { $0.key == selectedKey }
        let index = current.map { ($0 + delta + rows.count) % rows.count } ?? (delta < 0 ? rows.count - 1 : 0)
        selectedKey = rows[index].key
        audit("selection", ["index": index, "provider": rows[index].provider])
    }
    func jumpSelected() {
        if let target = visibleSessions.first(where: { $0.key == selectedKey }) { activate(target); dismissPanel?() }
    }
    func jump(_ session: AgentSession) {
        audit("jump-request", ["provider": session.provider, "target": session.targetLabel, "sessionId": session.id])
        message = "正在定位原会话…"
        navigator.jump(session) { [weak self] result in
            guard let self = self else { return }
            self.message = result.message
            if result.exact || result.code == "codex_deeplink_sent" { self.markViewed(session) }
            var evidence = result.evidence
            evidence["provider"] = session.provider
            evidence["sessionId"] = session.id
            evidence["code"] = result.code
            evidence["exact"] = result.exact
            self.audit("jump-result", evidence)
        }
    }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    func conversation(_ session: AgentSession) {
        keyboardMode = false
        setExpanded(false)
        let window = conversationWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "最近对话 · " + session.providerName
        window.contentView = RinglessHostingView(rootView: ConversationView(session: session, model: self))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
        conversationWindow = window
        markViewed(session)
        audit("conversation-open", ["provider": session.provider, "hasAssistantMessage": !session.assistant_message.isEmpty])
    }
    func audit(_ event: String, _ fields: [String: Any] = [:]) {
        do {
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = stateDir.appendingPathComponent("activity.jsonl")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? NSNumber, size.intValue > 1_000_000 {
                let previous = stateDir.appendingPathComponent("activity.previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: url, to: previous)
            }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            var record = fields
            record["event"] = event
            record["at"] = Date().timeIntervalSince1970
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(10)
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
        } catch { fputs("Agent Isle diagnostics: \(error.localizedDescription)\n", stderr) }
    }
}

struct PixelBuddy: View {
    var color: Color = .mint
    var active = false
    var celebrate = false
    var style: AvatarStyle = .robot
    private var pixels: [String] { style.pixels }
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.18, paused: !active && !celebrate)) { timeline in
            let phase = timeline.date.timeIntervalSince1970
            Canvas { context, size in
                let unit = min(size.width / 13, size.height / 12)
                let dy = (active || celebrate) ? sin(phase * (celebrate ? 12 : 5)) * 2.5 : 0
                for (y, row) in pixels.enumerated() {
                    for (x, char) in row.enumerated() where char == "X" {
                        context.fill(Path(CGRect(x: CGFloat(x + 1) * unit, y: CGFloat(y + 1) * unit + dy, width: unit - 0.4, height: unit - 0.4)), with: .color(color))
                    }
                }
            }
        }.frame(width: 40, height: 38)
    }
}

struct Confetti: View {
    let start: Double
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { timeline in
            let elapsed = timeline.date.timeIntervalSince1970 - start
            Canvas { context, size in
                guard elapsed >= 0 && elapsed < 2.0 else { return }
                for i in 0..<30 {
                    let t = elapsed / 2
                    let angle = Double(i) * 2.39996
                    let speed = Double(35 + i % 7 * 18)
                    let x = size.width / 2 + cos(angle) * speed * elapsed
                    let y = size.height / 2 + sin(angle) * speed * elapsed + 80 * elapsed * elapsed
                    context.opacity = 1 - t
                    context.fill(Path(CGRect(x: x, y: y, width: 3, height: 5)), with: .color([Color.mint, .orange, .white, .yellow][i % 4]))
                }
            }
        }.allowsHitTesting(false)
    }
}

struct IsleView: View {
    @ObservedObject var model: IsleModel
    let surface = Color.black
    var body: some View {
        VStack(spacing: 0) {
            if model.expanded { expanded } else { collapsed }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(surface)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: model.expanded ? 26 : 14, bottomTrailingRadius: model.expanded ? 26 : 14, style: .continuous))
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }
    var collapsed: some View {
        VStack(spacing: 0) {
            Button { model.setExpanded(true) } label: { Group {
                if model.notchWidth > 0 {
                    HStack(spacing: 0) {
                        HStack(spacing: 4) {
                            AgentAvatar(preferences: model.preferences, color: model.primarySourceColor, active: model.running > 0).scaleEffect(0.65).frame(width: 27, height: 25)
                            Text(model.preferences.value.detailed ? String((model.eligibleSessions.first(where: { $0.status == "running" })?.detail ?? "待命").prefix(10)) : "\(model.running)").lineLimit(1).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(.mint)
                        }.frame(width: model.wingWidth)
                        Color.black.frame(width: model.notchWidth)
                        HStack(spacing: 5) {
                            Circle().fill(model.compactStatusColor).frame(width: 4, height: 4)
                            ViewThatFits(in: .horizontal) {
                                if model.connected && model.waiting > 0 && model.running > 0 {
                                    Text("\(model.running)运行 · \(model.waiting)待你").font(.system(size: 9, weight: .semibold)).fixedSize(horizontal: true, vertical: false)
                                }
                                Text(model.compactStatusText).fixedSize(horizontal: true, vertical: false)
                                Text(model.compactStatusShort).lineLimit(1).minimumScaleFactor(0.75)
                            }.font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundColor(model.compactStatusColor)
                        }.padding(.horizontal, 6).frame(width: model.wingWidth).help(model.compactStatusDetail)
                    }
                } else {
                    HStack(spacing: 8) {
                        AgentAvatar(preferences: model.preferences, color: model.primarySourceColor, active: model.running > 0).scaleEffect(0.6).frame(width: 27, height: 25)
                        Text("AGENT ISLE").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.2)
                        Spacer()
                        Text(model.compactStatusText).font(.system(size: 10)).monospacedDigit().foregroundColor(model.compactStatusColor).lineLimit(1).minimumScaleFactor(0.75).help(model.compactStatusDetail)
                        Image(systemName: "chevron.down").font(.system(size: 8)).foregroundColor(.gray)
                    }.padding(.horizontal, 13).frame(width: model.compactWidth)
                }
            } }.buttonStyle(.plain).focusEffectDisabled().frame(maxWidth: .infinity).frame(height: model.compactHeight)
             .contentShape(Rectangle())
             .accessibilityLabel("Agent Isle 收起态，" + model.compactStatusDetail).accessibilityValue(model.compactStatusText)
            if let alert = model.banner {
                Button {
                    if let target = model.sessions.first(where: { $0.key == alert.key }) { model.jump(target) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: alert.status == "completed" ? "checkmark.circle.fill" : alert.status == "waiting" ? "questionmark.circle.fill" : "exclamationmark.circle.fill").foregroundColor(alert.status == "completed" ? .mint : .orange)
                        Text(alert.status == "completed" ? "任务完成" : alert.status == "waiting" ? "需要输入" : "任务出错").font(.system(size: 11, weight: .semibold))
                        Text(alert.title).font(.system(size: 11)).foregroundColor(.white.opacity(0.75)).lineLimit(1)
                        Spacer(minLength: 5)
                        Text(alert.provider.uppercased()).font(.system(size: 9, design: .monospaced)).foregroundColor(.gray)
                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundColor(.mint)
                    }.padding(.horizontal, 19).frame(height: 58).contentShape(Rectangle())
                }.buttonStyle(.plain).focusEffectDisabled().overlay(Confetti(start: alert.at).id(alert.at))
            }
        }
    }
    var expanded: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchHeight > 0 ? model.notchHeight : 4)
            HStack(spacing: 8) {
                AgentAvatar(preferences: model.preferences, color: model.primarySourceColor, active: model.running > 0).scaleEffect(0.65).frame(width: 25, height: 24)
                Text("Agent Isle").font(.system(size: 11, weight: .semibold)).foregroundColor(.gray)
                Text("\(model.running) 进行中 · \(model.waiting) 需要你").font(.system(size: 10)).foregroundColor(.gray)
                Spacer()
                Menu {
                    Button("全部") { model.filter = "all" }
                    ForEach(SourceAppearance.providers.filter { model.preferences.value.enabledProviders.contains($0.0) }, id: \.0) { provider in
                        Button(provider.1) { model.filter = provider.0 }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease").foregroundColor(.gray) }.menuStyle(.borderlessButton).frame(width: 25).help("筛选会话")
                iconButton(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: "提示音") { model.muted.toggle() }
                iconButton("gearshape.fill", help: "设置…") { model.openSettings?() }
            }.padding(.horizontal, 16).padding(.top, 5).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.visibleSessions.isEmpty { empty }
                        ForEach(model.visibleSessions, id: \.key) { session in sessionRow(session).id(session.key) }
                    }.padding(.horizontal, 8).padding(.bottom, 8)
                }.onChange(of: model.selectedKey) { _, key in if model.keyboardMode, let key = key { model.audit("scroll-request", ["source": "keyboard"]); withAnimation { proxy.scrollTo(key, anchor: .center) } } }
            }
            if !model.connected || !model.message.hasPrefix("本机监听") {
                Text(model.message).font(.system(size: 10)).foregroundColor(.gray).lineLimit(2).padding(8)
            }
        }
    }
    func sessionRow(_ s: AgentSession) -> some View {
        let prefs = model.preferences.value
        let index = model.visibleSessions.firstIndex(where: { $0.key == s.key }) ?? 0
        return Button { model.activate(s) } label: {
            HStack(alignment: .center, spacing: 10) {
                AgentAvatar(preferences: model.preferences, color: model.providerColor(s.provider), statusColor: s.stateColor, active: s.status == "running", celebrate: model.banner?.key == s.key && s.status == "completed").frame(width: 38)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text((prefs.projectName && !s.cwd.isEmpty ? URL(fileURLWithPath: s.cwd).lastPathComponent + " · " : "") + s.title)
                            .font(.system(size: prefs.fontSize + 1, weight: .semibold)).foregroundColor(.white.opacity(0.92)).lineLimit(1)
                        Spacer(minLength: 5)
                        Text(s.providerName).font(.system(size: max(9, prefs.fontSize - 1), weight: .medium)).foregroundColor(model.providerColor(s.provider))
                            .padding(.horizontal, 6).padding(.vertical, 3).background(model.providerColor(s.provider).opacity(0.09)).cornerRadius(5)
                        if !s.originLabel.isEmpty { Text(s.originLabel).font(.system(size: 9)).foregroundColor(.gray).lineLimit(1) }
                        if model.isUnread(s) { Circle().fill(Color.green).frame(width: 7, height: 7).help("任务完成 · 未读").accessibilityLabel("完成未读") }
                        else if s.status == "completed" { Image(systemName: "checkmark").font(.system(size: 9)).foregroundColor(.gray).help("已完成 · 已查看").accessibilityLabel("已完成已查看") }
                        else { Text(s.stateLabel).font(.system(size: 9)).foregroundColor(s.stateColor) }
                    }
                    if !s.user_message.isEmpty { Text("You: " + s.userPreview.prefix(220)).font(.system(size: prefs.fontSize)).foregroundColor(.gray).lineLimit(1) }
                    if prefs.activityDetail {
                        Text(s.status == "running" || s.status == "waiting" || s.summary.isEmpty ? s.detail : s.summary)
                            .font(.system(size: prefs.fontSize, design: s.status == "running" ? .monospaced : .default))
                            .foregroundColor(s.status == "running" ? model.providerColor(s.provider) : .gray).lineLimit(1)
                    }
                }
                if model.showHints && index < 9 { Text("\(index + 1)").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray).padding(5).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5))) }
            }.padding(.horizontal, 10).padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: prefs.cardHeight, alignment: .leading)
                .background(model.selectedKey == s.key ? Color.white.opacity(0.10) : Color.clear).cornerRadius(10)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).focusEffectDisabled()
         .contextMenu {
             Button(s.targetLabel) { model.jump(s) }
             Button("查看最近对话") { model.conversation(s) }
             Divider()
             Button("复制会话 ID") { model.copy(s.id) }
             Button("复制最近回复") { model.copy(s.assistant_message) }.disabled(s.assistant_message.isEmpty)
             if s.provider == "claude" { Button("复制恢复命令") { model.copy("claude --resume " + s.id) } }
             if !s.cwd.isEmpty {
                 Button("在 Finder 中显示项目") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd) }
                 Button("屏蔽此项目目录") { model.preferences.value.filters.append(FilterRule(kind: "directory", pattern: s.cwd)) }
             }
             if !s.userPreview.isEmpty { Button("屏蔽此消息开头") { model.preferences.value.filters.append(FilterRule(kind: "prefix", pattern: String(s.userPreview.prefix(80)))) } }
         }.help(s.cwd + "\n" + s.targetLabel)
         .onHover { inside in if inside && !model.keyboardMode { model.selectedKey = s.key } }
    }
    var empty: some View {
        VStack(spacing: 13) {
            AgentAvatar(preferences: model.preferences, color: .mint.opacity(0.6))
            Text(model.preferences.value.enabledProviders.isEmpty ? "选择你想监听的 AI 工具。" : "给 AI 一个任务，这里就会亮起来。").font(.system(size: 12))
            Text(model.preferences.value.enabledProviders.isEmpty ? "在设置 → 工具接入中勾选至少一个工具。" : "已启用：" + SourceAppearance.providers.filter { model.preferences.value.enabledProviders.contains($0.0) }.map { $0.1 }.joined(separator: "、") + "。\n给已启用的工具一个新任务，或在设置中检查接入。").font(.system(size: 11)).foregroundColor(.gray).multilineTextAlignment(.center)
            Button("设置接入") { model.openSettings?() }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity).padding(.vertical, 35)
    }
    func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 11)).foregroundColor(.gray).frame(width: 22, height: 24) }.buttonStyle(.plain).focusEffectDisabled().help(help)
    }
}

struct ConversationView: View {
    let session: AgentSession
    let model: IsleModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.title).font(.system(size: 19, weight: .semibold))
                Text(session.providerName + " · " + session.stateLabel + " · " + session.id).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
                Text(session.cwd).font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !session.assistant_message.isEmpty { bubble("Agent 最近回复", text: session.assistant_message, color: session.color) }
                    else { Text("尚未捕获回复正文。运行中的会话会在后续事件中补充；此窗口是打开时的快照。").font(.system(size: 12)).foregroundColor(.secondary) }
                    if !session.user_message.isEmpty { DisclosureGroup("你的最近消息（点击展开）") { bubble("用户消息", text: session.user_message, color: .gray) }.font(.system(size: 12)) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            }
            Divider()
            HStack {
                Text("最近消息快照 · 不是完整历史记录").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                if !session.transcript.isEmpty { Button("定位原始记录") { NSWorkspace.shared.selectFile(session.transcript, inFileViewerRootedAtPath: URL(fileURLWithPath: session.transcript).deletingLastPathComponent().path) } }
                Button(session.targetLabel) { model.jump(session) }
            }.padding(16)
        }.frame(minWidth: 500, minHeight: 400).preferredColorScheme(.dark)
    }
    func bubble(_ title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(color)
            Text(text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(15).background(color.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

final class IslePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = IsleModel()
    lazy var guide = GuideController(resources: model.resources)
    var panel: IslePanel!
    var statusItem: NSStatusItem!
    var observers: [NSObjectProtocol] = []
    var hoverTimer: Timer?
    var interaction = InteractionPolicy()
    var shortcuts: ShortcutController?
    var clickMonitor: Any?
    var localClickMonitor: Any?
    var distributedObservers: [NSObjectProtocol] = []
    var previousInside = false
    var fullscreen = false
    var lastSceneCheck = Date.distantPast
    var appliedAvatar = ""
    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!).count > 1 { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        panel = IslePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = RinglessHostingView(rootView: IsleView(model: model))
        model.resize = { [weak self] in self?.shortcuts?.register(); self?.layout(animated: true) }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openGuide = { [weak self] in self?.showGuide() }
        model.dismissPanel = { [weak self] in self?.dismiss() }
        shortcuts = ShortcutController(model: model)
        shortcuts?.makeKey = { [weak self] in self?.panel.makeKeyAndOrderFront(nil); self?.panel.makeFirstResponder(nil); NSApp.activate(ignoringOtherApps: true) }
        installMenu()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.outsideClick() }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in self?.outsideClick(); return event }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.model.screenLocked = locked
                if locked { self?.model.dismissReminder() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.model.screenLocked = true; self?.model.dismissReminder() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.model.screenLocked = false })
        layout(animated: false)
        panel.orderFrontRegardless()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "Agent Isle")
            button.target = self
            button.action = #selector(toggle)
        }
        appliedAvatar = ""
        layout(animated: false)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layout(animated: false) })
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.trackHover() }
        model.startMonitor()
        if !UserDefaults.standard.bool(forKey: "welcomeGuideShown") { showGuide() }
    }
    @objc func showGuide() {
        guide.open { [weak self] success in
            if success { UserDefaults.standard.set(true, forKey: "welcomeGuideShown") }
            else { self?.model.message = "本地指引启动失败 · 可从应用菜单重试" }
            self?.model.audit("guide-open", ["success": success, "localOnly": true])
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "agent-isle" {
            if url.host == "settings" { showSettings() }
            if url.host == "guide" { showGuide() }
        }
    }
    @objc func toggle() {
        if model.expanded { dismiss() } else { interaction.suppressedUntilExit = false; model.keyboardMode = true; model.setExpanded(true); panel.makeKeyAndOrderFront(nil) }
    }
    @objc func showSettings() {
        model.keyboardMode = false
        model.setExpanded(false)
        if model.settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Agent Isle 设置"
            window.isReleasedWhenClosed = false
            window.contentView = RinglessHostingView(rootView: SettingsView(model: model, preferences: model.preferences))
            window.center()
            model.settingsWindow = window
        }
        model.settingsWindow?.makeKeyAndOrderFront(nil)
        model.settingsWindow?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.audit("settings-open", ["independentWindow": true])
    }
    func dismiss() {
        interaction.dismiss()
        model.keyboardMode = false
        model.pinned = false
        model.selectedKey = nil
        model.dismissReminder()
        model.setExpanded(false)
        model.audit("dismiss", ["untilPointerExit": true])
    }
    func outsideClick() {
        if model.preferences.value.outsideDismiss && !panel.frame.contains(NSEvent.mouseLocation) {
            model.dismissReminder()
            if model.keyboardMode { dismiss() }
        }
    }
    func installMenu() {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(title: "Agent Isle"); item.submenu = appMenu
        appMenu.addItem(withTitle: "关于 Agent Isle", action: #selector(showSettings), keyEquivalent: "")
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        let guideItem = appMenu.addItem(withTitle: "打开使用指引…", action: #selector(showGuide), keyEquivalent: ""); guideItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Agent Isle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Agent Isle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
    }
    func layout(animated: Bool) {
        let prefs = model.preferences.value
        let appearanceKey = prefs.avatarStyle + ":" + prefs.customLogo
        if appearanceKey != appliedAvatar {
            appliedAvatar = appearanceKey
            statusItem?.button?.image = AvatarAssets.menuImage(style: prefs.avatarStyle, customLogo: prefs.customLogo)
            statusItem?.button?.image?.isTemplate = false
            model.audit("appearance", ["style": prefs.avatarStyle, "customLoaded": prefs.avatarStyle == "custom" && AvatarAssets.image(prefs.customLogo) != nil])
        }
        let selected = NSScreen.screens.first { String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == prefs.screenID }
        guard let screen = selected ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { return }
        let detected = NotchLayout(screen)
        let metrics = NotchLayout(screen: screen.frame, notchWidth: detected.notchWidth, notchHeight: detected.notchHeight, horizontalAdjustment: prefs.notchWidthAdjustment, verticalAdjustment: prefs.notchHeightAdjustment)
        model.notchWidth = metrics.notchWidth
        model.notchHeight = metrics.hasNotch ? metrics.contentInset : 0
        model.compactWidth = metrics.compactWidth
        model.wingWidth = metrics.wingWidth
        model.compactHeight = metrics.compactHeight
        let contentHeight = min(prefs.panelHeight, max(160, Double(model.visibleSessions.count) * prefs.cardHeight + 45))
        let frame = metrics.frame(expanded: model.expanded, alert: model.banner != nil, width: prefs.panelWidth, height: contentHeight)
        panel.hasShadow = model.expanded || model.banner != nil
        let hidden = (prefs.hideFullscreen && fullscreen && !model.keyboardMode) || (prefs.hideIdle && model.running == 0 && model.waiting == 0 && !model.expanded && model.banner == nil)
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        model.audit("layout", ["expanded": model.expanded, "alert": model.banner != nil,
                              "notchWidth": metrics.notchWidth, "notchHeight": metrics.notchHeight,
                              "width": frame.width, "height": frame.height, "top": frame.maxY,
                              "screenTop": screen.frame.maxY, "screenWidth": screen.frame.width, "hidden": hidden, "widthAdjustment": prefs.notchWidthAdjustment, "heightAdjustment": prefs.notchHeightAdjustment, "wingWidth": metrics.wingWidth])
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
    }
    func trackHover() {
        if Date().timeIntervalSince(lastSceneCheck) > 0.8 {
            lastSceneCheck = Date()
            let next = frontWindowIsFullscreen()
            if next != fullscreen { fullscreen = next; layout(animated: false) }
        }
        let inside = panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
        if inside != previousInside {
            previousInside = inside
            model.audit("pointer", ["inside": inside, "expanded": model.expanded])
            if inside { model.keyboardMode = false }
        }
        if model.hovered != inside { model.hovered = inside }
        let prefs = model.preferences.value
        // A context menu temporarily owns the pointer, but an independent settings
        // window and reminders never prevent mouse-leave collapse.
        let menuTracking = RunLoop.current.currentMode == .eventTracking
        if let next = interaction.update(inside: inside, expanded: model.expanded, locked: model.pinned || model.keyboardMode || menuTracking, hover: prefs.hoverExpand && !(prefs.smartSuppression && !model.focusedKeys.isEmpty), autoCollapse: prefs.autoCollapse, delay: prefs.hoverDelay, now: Date().timeIntervalSince1970) {
            model.audit("pointer-transition", ["expanded": next])
            model.setExpanded(next)
        }
    }
    func frontWindowIsFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            return NSScreen.screens.contains { abs(rect.width - $0.frame.width) <= 1 && abs(rect.height - $0.frame.height) <= 1 }
        }
        return false
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            if let key = response.notification.request.content.userInfo["sessionKey"] as? String,
               let session = self.model.sessions.first(where: { $0.key == key }) { self.model.jump(session) }
        }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .list]) }
    func applicationWillTerminate(_ notification: Notification) { hoverTimer?.invalidate(); model.process?.terminate(); guide.stop()
        for monitor in [clickMonitor, localClickMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) } }
}

@main struct AgentIsle {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
