import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

private struct SettingsPage: Identifiable {
    let id: String, title: String, icon: String, color: Color
    static let all: [SettingsPage] = [
        .init(id: "general", title: "通用", icon: "gearshape.fill", color: .gray),
        .init(id: "integrations", title: "工具接入", icon: "puzzlepiece.extension.fill", color: .blue),
        .init(id: "notifications", title: "通知", icon: "bell.badge.fill", color: .red),
        .init(id: "display", title: "显示", icon: "display", color: .purple),
        .init(id: "sound", title: "声音", icon: "speaker.wave.2.fill", color: .pink),
        .init(id: "usage", title: "用量统计", icon: "chart.bar.fill", color: .green),
        .init(id: "shortcuts", title: "快捷键", icon: "command", color: .orange),
        .init(id: "ssh", title: "SSH 远程", icon: "network", color: .blue),
        .init(id: "labs", title: "实验功能", icon: "flask.fill", color: .purple),
        .init(id: "free", title: "免费与本地", icon: "checkmark.seal.fill", color: .mint),
        .init(id: "about", title: "关于", icon: "info.circle.fill", color: .gray)
    ]
}
struct SettingsView: View {
    @ObservedObject var model: IsleModel
    @ObservedObject var preferences: AppPreferences
    @State private var page = "general"
    @State private var filterKind = "directory"
    @State private var pattern = ""
    @State private var status = ""
    @State private var colorInputs: [String: String] = [:]
    @State private var confirmRemoval = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var recording = false
    @State private var keyMonitor: Any?
    private var current: SettingsPage { SettingsPage.all.first { $0.id == page }! }
    func binding<T>(_ key: WritableKeyPath<IslePreferences, T>) -> Binding<T> { Binding(get: { preferences.value[keyPath: key] }, set: { preferences.value[keyPath: key] = $0 }) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(SettingsPage.all) { item in
                    if item.id == "shortcuts" { sectionLabel("高级") }
                    if item.id == "free" { sectionLabel("Agent Isle") }
                    Button { page = item.id } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon).font(.system(size: 11, weight: .semibold)).foregroundColor(.white).frame(width: 23, height: 23).background(item.color.gradient).cornerRadius(5)
                            Text(item.title).font(.system(size: 12))
                            Spacer()
                        }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                            .background(page == item.id ? Color.accentColor.opacity(0.15) : .clear).cornerRadius(6)
                    }.buttonStyle(.plain).focusEffectDisabled().accessibilityLabel(item.title)
                }
                Spacer()
                Text("0.5.3 · FREE & LOCAL").font(.system(size: 9)).foregroundColor(.secondary).padding(8)
            }.padding(.horizontal, 10).padding(.top, 12).frame(width: 168).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: current.icon).foregroundColor(current.color).font(.system(size: 25))
                        Text(current.title).font(.system(size: 23, weight: .bold))
                    }.padding(.top, 8).padding(.bottom, 2)
                    content
                    if !preferences.error.isEmpty { Text(preferences.error).foregroundColor(.red) }
                    if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled) }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .controlBackgroundColor))
        }.frame(width: 650, height: 680).focusEffectDisabled()
        .onDisappear { stopRecording() }
        .alert("移除 Agent Isle 接入？", isPresented: $confirmRemoval) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) { model.integrations("uninstall") }
        } message: { Text("仅移除 Agent Isle 的 Hook，保留其他工具配置与备份。已有对话记录不会删除。") }
    }
    func sectionLabel(_ title: String) -> some View { Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary).padding(.top, 14).padding(.leading, 8).padding(.bottom, 3) }
    func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !title.isEmpty { Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary) }
            VStack(alignment: .leading, spacing: 12, content: content).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035)).cornerRadius(10)
        }
    }
    func toggle(_ title: String, _ key: WritableKeyPath<IslePreferences, Bool>, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: binding(key)).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            if let detail = detail { note(detail) }
        }
    }
    func note(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
    func slider(_ title: String, _ key: WritableKeyPath<IslePreferences, Double>, range: ClosedRange<Double>, reset: Double, suffix: String = "pt") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(String(format: suffix == "s" ? "%.2f %@" : "%.0f %@", preferences.value[keyPath: key], suffix)).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                Button { preferences.value[keyPath: key] = reset } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plain).focusEffectDisabled().help("恢复默认")
            }
            Slider(value: binding(key), in: range).controlSize(.small)
        }
    }
    @ViewBuilder var content: some View {
        switch page {
        case "general": general
        case "integrations": integrations
        case "notifications": notifications
        case "display": display
        case "sound": sounds
        case "shortcuts": shortcuts
        case "about": about
        case "free": group("") { Text("永久免费，无账户、充值或订阅。").font(.headline); note("Agent Isle 是独立实现。三个工具的监听、状态提醒和会话跳转全部在本机运行，无遥测。") }
        default: group("当前版本范围") {
            note(["usage": "当前版本聚焦本机 Codex、Cursor、Claude Code 会话，不读取账户配额或账单。", "ssh": "当前版本仅监听此 Mac，没有远程主机、SSH 密钥或远程安装功能。", "labs": "当前版本没有修改 AI 审批、自动放行或测试更新通道的功能。现有三个工具的权限策略保持原样。"][page] ?? "")
        }
        }
    }
    var general: some View {
        VStack(alignment: .leading, spacing: 17) {
            group("系统") {
                Toggle("登录时启动", isOn: Binding(get: { loginEnabled }, set: { enabled in
                    do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginEnabled = SMAppService.mainApp.status == .enabled; status = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 登录项中允许 Agent Isle。" : "" }
                    catch { status = "登录项设置失败：" + error.localizedDescription }
                })).toggleStyle(.switch).controlSize(.small)
            }
            group("展开") {
                toggle("鼠标悬停时展开", \.hoverExpand)
                slider("悬停时长", \.hoverDelay, range: 0.05...1, reset: 0.15, suffix: "s")
                toggle("智能抑制", \.smartSuppression, detail: "Cursor 桥接确认正在查看原会话时，悬停不自动展开；无法确认时正常展开。")
            }
            group("可见性") { toggle("全屏时隐藏", \.hideFullscreen); toggle("没有活跃会话时自动隐藏", \.hideIdle, detail: "等待输入的会话也属于活跃会话。隐藏后仍可通过菜单栏或快捷键展开。") }
            group("收起") {
                toggle("鼠标离开时自动收起", \.autoCollapse)
                HStack { Text("自动提醒停留时长"); Spacer(); Picker("", selection: binding(\.revealSeconds)) { ForEach([2.0,3,5,8,10,15], id: \.self) { Text("\(Int($0)) 秒").tag($0) } }.labelsHidden().frame(width: 95) }
                note("完成和错误提醒到时收起；需要输入的提醒保留至已回答。Esc 可提前关闭当前提醒。")
                toggle("点击外部关闭自动提醒", \.outsideDismiss)
                HStack { Text("清理闲置会话"); Spacer(); Picker("", selection: binding(\.cleanupHours)) { ForEach([0.5,1,2,4,8,24,0], id: \.self) { Text($0 == 0 ? "永不" : $0 == 0.5 ? "30 分钟" : "\(Int($0)) 小时").tag($0) } }.labelsHidden().frame(width: 105) }
                note("只隐藏超时的非活跃会话，原始记录保留。")
            }
            group("交互") { toggle("禁用点击跳转", \.disableJump, detail: "开启后，卡片点击不再跳转；右键菜单仍可显式打开目标会话。") }
        }.font(.system(size: 12))
    }
    var integrations: some View {
        VStack(alignment: .leading, spacing: 17) {
            group("监听工具与来源颜色") {
                note("默认启用 Codex、Claude Code。取消勾选后，对应工具不再监听、显示、计数或提醒，已有接入配置保留。")
                ForEach(SourceAppearance.providers, id: \.0) { item in
                    HStack {
                        Toggle(item.1, isOn: Binding(get: { preferences.value.enabledProviders.contains(item.0) }, set: { enabled in
                            if enabled { if !preferences.value.enabledProviders.contains(item.0) { preferences.value.enabledProviders.append(item.0) } }
                            else { preferences.value.enabledProviders.removeAll { $0 == item.0 } }
                        })).toggleStyle(.checkbox).font(.system(size: 12))
                        Spacer()
                        ColorPicker(item.1 + " 图标颜色", selection: Binding(get: {
                            Color(nsColor: SourceAppearance.color(preferences.value.providerColors[item.0] ?? "", provider: item.0))
                        }, set: { color in preferences.value.providerColors[item.0] = SourceAppearance.hex(NSColor(color)) }), supportsOpacity: false).labelsHidden().frame(width: 30).help(item.1 + " 图标颜色")
                        TextField("#RRGGBB", text: Binding(get: { colorInputs[item.0] ?? "#" + (preferences.value.providerColors[item.0] ?? SourceAppearance.defaults[item.0]!) }, set: { colorInputs[item.0] = $0 })).font(.system(size: 10, design: .monospaced)).frame(width: 76).textFieldStyle(.roundedBorder).accessibilityLabel(item.1 + " 颜色值").onSubmit { applySourceColor(item.0) }
                        Button("应用") { applySourceColor(item.0) }.controlSize(.small).disabled(validSourceColor(item.0) == nil).accessibilityLabel("应用 " + item.1 + " 颜色")
                    }
                }
                Button("恢复默认来源颜色") { preferences.value.providerColors = SourceAppearance.defaults; colorInputs = [:] }
                note("颜色用于像素 Logo 和来源标签。自定义 Logo 保留原色，外圈使用来源色；任务状态颜色单独显示。")
            }
            group("为什么接入方式不同？") {
                note("Codex 有可直接只读的本机会话索引和记录，因此不用安装 Hook。Claude Code、Cursor 也会发现已有记录，但准确的完成、等待输入状态需要 Hook；Cursor 精确选择聊天 / 终端还需要桥接扩展。")
            }
            group("CLI Hooks 与 Cursor 桥接") {
                note("安装前备份并合并已有 Hook；只记录状态，不发送审批响应。安装后请重启 Cursor、新开 Claude Code 会话。")
                HStack { Button(model.integrationsBusy ? "正在处理…" : "安装 / 修复已勾选工具接入") { model.integrations("install") }.disabled(!preferences.value.enabledProviders.contains(where: { $0 == "claude" || $0 == "cursor" })); Button("移除接入…") { confirmRemoval = true } }.disabled(model.integrationsBusy)
                note(model.message)
                Button("重新连接监听器") { model.startMonitor() }
            }
            group("窗口跳转") { note("Codex 按会话 ID；Cursor 通过本地桥接选择聊天；Claude Code 按 TTY / shell 进程选择终端标签。找不到精确目标会说明原因。"); note("Terminal / iTerm2 的定位需要系统自动化许可；Cursor 集成终端使用现有桥接。") }
        }
    }
    func validSourceColor(_ provider: String) -> String? {
        let value = (colorInputs[provider] ?? "#" + (preferences.value.providerColors[provider] ?? SourceAppearance.defaults[provider]!)).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").uppercased()
        return value.count == 6 && UInt32(value, radix: 16) != nil ? value : nil
    }
    func applySourceColor(_ provider: String) {
        guard let value = validSourceColor(provider) else { return }
        preferences.value.providerColors[provider] = value
        colorInputs[provider] = nil
    }
    var notifications: some View {
        VStack(alignment: .leading, spacing: 17) {
            group("任务提醒") {
                toggle("显示灵动岛提醒", \.reveal, detail: "折叠时仅展开当前任务一行，不自动打开整个列表。")
                Button(model.notifications ? "系统通知已开启 · 在系统设置中管理" : "开启 macOS 系统通知") {
                    if model.notifications { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) } else { model.enableNotifications() }
                }
                Button("预览单行完成提醒") { model.dismissPanel?(); model.preview() }
            }
            group("安静场景") {
                toggle("专注模式", \.quiet, detail: "Agent Isle 手动静音：不弹出、不播放声音，列表状态继续更新。")
                toggle("屏幕锁定或睡眠时静默", \.quietWhenLocked)
            }
            group("自定义过滤") {
                note("按项目目录或最近用户消息匹配；命中的会话不显示、不触发声音或通知。也可右键卡片添加。")
                Picker("匹配", selection: $filterKind) { Text("目录包含").tag("directory"); Text("消息开头").tag("prefix"); Text("消息包含").tag("contains") }.font(.system(size: 12))
                HStack { TextField(filterKind == "directory" ? "/path/to/project" : "输入匹配文字", text: $pattern); if filterKind == "directory" { Button { chooseDirectory() } label: { Image(systemName: "folder") } } }
                let count = pattern.isEmpty ? 0 : model.sessions.filter { FilterRule(kind: filterKind, pattern: pattern).matches(cwd: $0.cwd, prompt: $0.userPreview) }.count
                HStack { note(pattern.isEmpty ? "输入后预览匹配数量" : "匹配 \(count) 个会话"); Spacer(); Button("添加规则") { preferences.value.filters.append(FilterRule(kind: filterKind, pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines))); pattern = "" }.disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                ForEach(preferences.value.filters) { rule in
                    HStack {
                        Toggle(isOn: Binding(get: { preferences.value.filters.first { $0.id == rule.id }?.enabled ?? false }, set: { enabled in if let i = preferences.value.filters.firstIndex(where: { $0.id == rule.id }) { preferences.value.filters[i].enabled = enabled } })) { VStack(alignment: .leading) { Text(rule.pattern).lineLimit(2); note(rule.kind == "directory" ? "目录包含" : rule.kind == "prefix" ? "消息开头" : "消息包含") } }.toggleStyle(.switch).controlSize(.mini)
                        Button { preferences.value.filters.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).focusEffectDisabled().help("移除规则")
                    }
                }
            }
        }
    }
    var display: some View {
        VStack(alignment: .leading, spacing: 17) {
            group("灵动岛") {
                HStack { Spacer(); HStack { Image(systemName: "sparkles"); Text(preferences.value.detailed ? "正在调用工具" : "3"); Color.black.frame(width: 100); Text("3 会话") }.font(.system(size: 10, design: .monospaced)).foregroundColor(.white).padding(12).background(.black).clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)); Spacer() }
                Picker("显示方式", selection: binding(\.detailed)) { Text("简洁").tag(false); Text("详细").tag(true) }.pickerStyle(.segmented)
                Picker("显示器", selection: binding(\.screenID)) {
                    Text("自动（优先刘海屏）").tag("auto")
                    ForEach(NSScreen.screens, id: \.localizedName) { screen in Text(screen.localizedName).tag(String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)) }
                }
            }
            avatarSettings
            group("面板") {
                Picker("内容字号", selection: binding(\.fontSize)) { ForEach([10.0,11,12,13], id: \.self) { Text("\(Int($0)) pt").tag($0) } }
                slider("会话卡片高度", \.cardHeight, range: 72...150, reset: 90)
                slider("面板最大高度", \.panelHeight, range: 260...850, reset: 520)
                slider("面板最大宽度", \.panelWidth, range: 480...880, reset: 640)
            }
            group("会话卡片") {
                toggle("显示项目名称", \.projectName)
                toggle("显示 Agent 活动详情", \.activityDetail)
                HStack { AgentAvatar(preferences: preferences, color: .mint); VStack(alignment: .leading) { Text((preferences.value.projectName ? "项目 · " : "") + "完成任务").font(.system(size: preferences.value.fontSize + 1, weight: .semibold)); if preferences.value.activityDetail { Text("正在调用工具").font(.system(size: preferences.value.fontSize)).foregroundColor(.gray) } }; Spacer(); Text("Codex").foregroundColor(.mint) }.padding(8).background(Color.black.opacity(0.9)).foregroundColor(.white).cornerRadius(8)
            }
            group("刘海尺寸微调") {
                note("以系统自动尺寸为基准，0 为不调整。横向调整两侧宽度，高度调整折叠条；摄像头避让区域始终保留。展开列表宽度请调整上方「面板最大宽度」。")
                slider("横向宽度调整", \.notchWidthAdjustment, range: -64...160, reset: 0)
                slider("折叠条高度调整", \.notchHeightAdjustment, range: -8...40, reset: 0)
                Text("实际折叠尺寸 \(Int(model.compactWidth.rounded())) × \(Int(model.compactHeight.rounded())) pt · 摄像头避让 \(Int(model.notchWidth.rounded())) pt").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
        }.font(.system(size: 12))
    }
    var avatarSettings: some View {
        group("图标与 Logo") {
            HStack(spacing: 8) {
                ForEach(AvatarStyle.allCases, id: \.rawValue) { style in
                    Button {
                        preferences.value.avatarStyle = style.rawValue
                    } label: {
                        VStack(spacing: 7) {
                            AvatarPreview(style: style.rawValue)
                            Text(style.title).font(.system(size: 11))
                            Image(systemName: preferences.value.avatarStyle == style.rawValue ? "checkmark.circle.fill" : "circle").foregroundColor(preferences.value.avatarStyle == style.rawValue ? .accentColor : .secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.primary.opacity(preferences.value.avatarStyle == style.rawValue ? 0.09 : 0.025)).cornerRadius(8)
                    }.buttonStyle(.plain).focusEffectDisabled().accessibilityLabel("使用" + style.title + "图标")
                }
            }
            HStack(spacing: 10) {
                if AvatarAssets.image(preferences.value.customLogo) != nil {
                    Button {
                        preferences.value.avatarStyle = "custom"
                    } label: { AvatarPreview(style: "custom", customLogo: preferences.value.customLogo).padding(4).background(Color.black).cornerRadius(7) }.buttonStyle(.plain).focusEffectDisabled().help("使用自定义 Logo")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(preferences.value.avatarStyle == "custom" ? "当前：自定义 Logo" : "当前：" + (AvatarStyle(rawValue: preferences.value.avatarStyle) ?? .robot).title).font(.system(size: 12))
                    note("应用于灵动岛、会话图标及菜单栏；不改写安装包图标。")
                }
                Spacer(minLength: 0)
            }
            HStack {
                Button("导入自定义 Logo…") { importLogo() }
                if !preferences.value.customLogo.isEmpty {
                    Button("移除自定义") {
                        preferences.value.avatarStyle = "robot"
                        preferences.value.customLogo = ""
                    }
                }
            }
            note("PNG / JPEG / HEIC / WebP，最多 10 MB。仅复制到本机，不上传；保留原色与比例，透明 PNG 效果更好。切换预设不会丢失已导入的 Logo。")
        }
    }
    func importLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = false
        panel.prompt = "使用 Logo"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = try AvatarAssets.importLogo(url)
            preferences.value.customLogo = name
            preferences.value.avatarStyle = "custom"
            status = "自定义 Logo 已生效，原图不会被修改。"
            model.audit("logo-import", ["success": true])
        } catch {
            status = error.localizedDescription
            model.audit("logo-import", ["success": false])
        }
    }
    var sounds: some View {
        VStack(alignment: .leading, spacing: 17) {
            group("音效") {
                Toggle("启用提示音", isOn: Binding(get: { !model.muted }, set: { model.muted = !$0 })).toggleStyle(.switch).controlSize(.small)
                HStack { Text("音量"); Slider(value: $model.soundVolume, in: 0...1); Text("\(Int(model.soundVolume * 100))%").monospacedDigit().frame(width: 36) }
            }
            group("事件声音") {
                soundRow("任务完成", "completed", \.completeSound)
                Divider()
                soundRow("任务出错", "error", \.errorSound)
                Divider()
                soundRow("需要输入 / 批准", "waiting", \.inputSound)
                note("仅配置当前监听器已能准确识别的三种事件。Agent Isle 为原创合成音效，也可选择 Apple 系统声音或导入本地音频。")
                Button("添加声音…") { importSound() }
            }
            group("安静时段") {
                toggle("启用安静时段", \.quietHours)
                if preferences.value.quietHours {
                    HStack { Picker("从", selection: binding(\.quietStart)) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) } }; Picker("至", selection: binding(\.quietEnd)) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) } } }
                    note("支持跨午夜；起止相同表示全天静音。顶部文字提醒仍会显示。")
                }
            }
        }.font(.system(size: 12))
    }
    func soundRow(_ title: String, _ event: String, _ key: WritableKeyPath<IslePreferences, String>) -> some View {
        HStack {
            Text(title); Spacer()
            Menu(preferences.value[keyPath: key].replacingOccurrences(of: "custom:", with: "")) {
                Button("Agent Isle") { preferences.value[keyPath: key] = "Agent Isle" }
                Button("关闭") { preferences.value[keyPath: key] = "Off" }
                Menu("Apple 系统声音") { ForEach(["Basso","Blow","Bottle","Frog","Funk","Glass","Hero","Morse","Ping","Pop","Purr","Sosumi","Submarine","Tink"], id: \.self) { name in Button(name) { preferences.value[keyPath: key] = name } } }
                let files = (try? FileManager.default.contentsOfDirectory(atPath: model.stateDir.appendingPathComponent("Sounds").path)) ?? []
                if !files.isEmpty { Menu("我的声音") { ForEach(files.sorted(), id: \.self) { name in Button(name) { preferences.value[keyPath: key] = "custom:" + name } } } }
                Button("导入声音…") { importSound(key) }
            }.frame(width: 140)
            Button { model.play(event, force: true) } label: { Image(systemName: "play.circle.fill").font(.system(size: 18)).foregroundColor(.secondary) }.buttonStyle(.plain).focusEffectDisabled().help("试听" + title)
        }
    }
    var shortcuts: some View {
        VStack(alignment: .leading, spacing: 17) {
            group("全局快捷键") {
                toggle("启用键盘快捷键", \.shortcuts)
                Picker("修饰键", selection: binding(\.shortcutModifier)) { Text("Control ⌃").tag("control"); Text("Option ⌥").tag("option"); Text("Command ⌘").tag("command") }
                HStack { Text("打开切换器"); Spacer(); Button(recording ? "按一个字母或数字…" : preferences.value.shortcutModifier.capitalized + " + " + preferences.value.shortcutKey.uppercased()) { startRecording() }; Button { preferences.value.shortcuts = false } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).focusEffectDisabled().help("停用快捷键") }
                note("轻按打开，用 ↑ ↓ 选择、Enter 跳转。按住修饰键并重复快捷键可循环选择，松开修饰键跳转。")
                toggle("启用反向切换（加 Shift）", \.reverseShortcut)
                toggle("按住修饰键显示数字提示", \.hints)
            }
            group("面板快捷键") {
                shortcutLine("收起 / 关闭当前提醒", "Esc")
                shortcutLine("选择会话", "↑ / ↓")
                shortcutLine("跳转选中会话", "Enter")
                shortcutLine("跳转第 1–9 个会话", "修饰键 + 1–9")
                note("只提供本机监听与跳转；不自动批准、拒绝或绕过 AI 工具权限。")
            }
        }.font(.system(size: 12))
    }
    func shortcutLine(_ text: String, _ keys: String) -> some View { HStack { Text(text); Spacer(); Text(keys).foregroundColor(.secondary).font(.system(size: 11, design: .monospaced)) } }
    var about: some View {
        VStack(alignment: .leading, spacing: 17) {
            group("") { HStack { AgentAvatar(preferences: preferences); VStack(alignment: .leading, spacing: 3) { Text("Agent Isle").font(.system(size: 20, weight: .bold)); note("版本 0.5.3 · 独立免费实现") } }; note("Codex、Cursor、Claude Code 本机任务监听、状态提醒与精确跳转。无需账户，无遥测，无订阅。") }
            group("诊断与维护") {
                Button("打开本地使用指引…") { model.openGuide?() }
                Button("导出匿名诊断报告…") { exportDiagnostics() }
                note("只导出版本、显示参数、状态数量和监听器是否连接，不包含消息、项目路径或会话 ID。")
                Button("打开本地诊断目录") { NSWorkspace.shared.open(model.stateDir) }
                Button("移除所有 Agent Isle 接入…") { confirmRemoval = true }.disabled(model.integrationsBusy)
            }
            group("致谢") { note("Swift / SwiftUI / AppKit · Python 标准库 · Apple SF Symbols。交互参考 Vibe Island，代码、标识与音效独立实现。") }
            Button("退出 Agent Isle") { NSApp.terminate(nil) }
        }
    }
    func chooseDirectory() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { pattern = url.path } }
    func importSound(_ key: WritableKeyPath<IslePreferences, String>? = nil) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 10_000_000, NSSound(contentsOf: url, byReference: false) != nil else { status = "请选择不超过 10 MB、macOS 可播放的音频。"; return }
            let folder = model.stateDir.appendingPathComponent("Sounds")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = UUID().uuidString.prefix(8) + "-" + url.lastPathComponent
            let target = folder.appendingPathComponent(String(name))
            try FileManager.default.copyItem(at: url, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            if let key = key { preferences.value[keyPath: key] = "custom:" + String(name) }
            status = "声音已导入。"
            model.objectWillChange.send()
        } catch { status = "导入失败：" + error.localizedDescription }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Agent-Isle-Diagnostics.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let values: [String: Any] = ["version":"0.5.3", "connected":model.connected, "running":model.running, "waiting":model.waiting, "sessionCount":model.sessions.count, "notchWidth":model.notchWidth, "notchHeight":model.notchHeight, "panelWidth":preferences.value.panelWidth]; try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic); status = "匿名报告已导出。" }
        catch { status = "导出失败：" + error.localizedDescription }
    }
    func startRecording() {
        stopRecording(); recording = true; model.recordingShortcut = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            guard let key = event.charactersIgnoringModifiers?.lowercased(), ShortcutController.codes[key] != nil else { NSSound.beep(); return nil }
            preferences.value.shortcutKey = key
            if event.modifierFlags.contains(.command) { preferences.value.shortcutModifier = "command" }
            else if event.modifierFlags.contains(.option) { preferences.value.shortcutModifier = "option" }
            else { preferences.value.shortcutModifier = "control" }
            preferences.value.shortcuts = true
            stopRecording(); return nil
        }
    }
    func stopRecording() { if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil; recording = false; model.recordingShortcut = false }
}
