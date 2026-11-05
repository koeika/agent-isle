import AppKit

struct NavigationResult {
    let exact: Bool
    let code: String
    let message: String
    var evidence: [String: Any] = [:]
}

final class Navigator {
    private let work = DispatchQueue(label: "local.agentisle.navigation", qos: .userInitiated)
    let resources: URL
    init(resources: URL) { self.resources = resources }

    func jump(_ session: AgentSession, completion: @escaping (NavigationResult) -> Void) {
        let terminal = session.terminal ?? [:]
        let host = terminal["__CFBundleIdentifier"] ?? ""
        let isTerminal = terminal["TTY"] != nil || terminal["ITERM_SESSION_ID"] != nil
        if isTerminal {
            work.async {
                let result: NavigationResult
                if host == "com.todesktop.230313mzl4w4u92" || host == "com.microsoft.VSCode" || terminal["TERM_PROGRAM"] == "vscode" {
                    result = self.editor(session, terminal: true)
                } else if terminal["ITERM_SESSION_ID"] != nil || terminal["TERM_PROGRAM"] == "iTerm.app" {
                    result = self.iterm(terminal)
                } else if terminal["TERM_PROGRAM"] == "Apple_Terminal" || host == "com.apple.Terminal" {
                    result = self.appleTerminal(terminal)
                } else {
                    result = NavigationResult(exact: false, code: "unsupported_terminal", message: "此终端尚无精确定位适配 · 未切到其他窗口")
                }
                DispatchQueue.main.async {
                    if result.exact && (host == "com.todesktop.230313mzl4w4u92" || host == "com.microsoft.VSCode") {
                        NSRunningApplication.runningApplications(withBundleIdentifier: host).first?.activate()
                    }
                    completion(result)
                }
            }
            return
        }
        if session.provider == "codex" {
            guard let url = URL(string: "codex://threads/" + session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) else {
                completion(NavigationResult(exact: false, code: "invalid_id", message: "会话 ID 无效")); return
            }
            let accepted = NSWorkspace.shared.open(url)
            completion(NavigationResult(exact: false, code: accepted ? "codex_deeplink_sent" : "codex_handler_missing",
                message: accepted ? "已按 ID 打开 Codex 对话" : "未找到 Codex 跳转处理程序",
                evidence: ["accepted": accepted, "sessionId": session.id, "verification": "target-ui-owner-confirmation"]))
        } else if session.provider == "cursor" {
            work.async {
                let result = self.editor(session, terminal: false)
                DispatchQueue.main.async {
                    if result.exact { NSRunningApplication.runningApplications(withBundleIdentifier: "com.todesktop.230313mzl4w4u92").first?.activate() }
                    completion(result)
                }
            }
        } else {
            completion(NavigationResult(exact: false, code: "terminal_identity_missing", message: "此旧会话没有终端身份 · 新会话会自动捕获，右键可复制恢复命令"))
        }
    }

    private func editor(_ session: AgentSession, terminal: Bool) -> NavigationResult {
        let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        PythonRuntime.configure(child, resources: resources)
        child.arguments = [resources.appendingPathComponent("agent_isle/navigation.py").path] + (terminal ? ["--terminal"] : [])
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        do {
            let request: [String: Any] = ["id": session.id, "cwd": session.cwd, "terminal": session.terminal ?? [:]]
            try child.run()
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0, let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return NavigationResult(exact: false, code: "bridge_process_error", message: "本地跳转桥接失败 · 未改变项目窗口")
            }
            let ok = response["ok"] as? Bool == true, code = response["code"] as? String ?? "unknown"
            return NavigationResult(exact: ok, code: code,
                message: ok ? (terminal ? "已选中原终端标签" : "已按 ID 选中 Cursor 对话") : self.explanation(code), evidence: response)
        } catch { return NavigationResult(exact: false, code: "bridge_launch_error", message: "无法运行本地跳转桥接") }
    }

    private func explanation(_ code: String) -> String {
        switch code {
        case "editor_bridge_not_active": return "Cursor 桥接未加载 · 请安装接入或在 Cursor 重新加载窗口"
        case "ambiguous_editor_windows": return "同一项目有多个窗口，无法唯一定位 · 未猜测跳转"
        default: return "未找到对应对话或终端 · 不会打开其他会话"
        }
    }

    private func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\"" }

    private func execute(_ source: String, target: String, expected: String) -> NavigationResult {
        var error: NSDictionary?
        let answer = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            return NavigationResult(exact: false, code: number == -1743 ? "automation_permission_required" : "terminal_script_error",
                message: number == -1743 ? "需要允许 Agent Isle 控制\(target)以选择标签；不会执行终端命令" : "未能定位原终端标签",
                evidence: ["errorNumber": number])
        }
        let actual = answer?.stringValue ?? ""
        let matched = actual == expected
        return NavigationResult(exact: matched, code: matched ? "terminal_selected_and_readback" : "terminal_not_found",
            message: matched ? "已选中并核对\(target)原标签" : "原标签已关闭或未找到 · 未跳到其他标签",
            evidence: ["expected": expected, "selected": actual, "terminal": target])
    }

    private func appleTerminal(_ identity: [String: String]) -> NavigationResult {
        guard let tty = identity["TTY"], tty.hasPrefix("/dev/tty") else {
            return NavigationResult(exact: false, code: "missing_tty", message: "没有捕获到 Terminal TTY")
        }
        let script = """
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) is \(quote(tty)) then
                        set selected tab of w to t
                        set miniaturized of w to false
                        set index of w to 1
                        activate
                        return (tty of selected tab of front window) as text
                    end if
                end repeat
            end repeat
            return "not-found"
        end tell
        """
        return execute(script, target: "Terminal", expected: tty)
    }

    private func iterm(_ identity: [String: String]) -> NavigationResult {
        let token = identity["ITERM_SESSION_ID"]?.components(separatedBy: ":").last ?? ""
        let tty = identity["TTY"] ?? ""
        guard !token.isEmpty || !tty.isEmpty else { return NavigationResult(exact: false, code: "missing_session", message: "没有捕获到 iTerm 标签身份") }
        let condition = !token.isEmpty ? "(unique id of s) is \(quote(token))" : "(tty of s) is \(quote(tty))"
        let readback = !token.isEmpty ? "unique id" : "tty"
        let script = """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if \(condition) then
                            select w
                            select t
                            select s
                            activate
                            return (\(readback) of current session of current window) as text
                        end if
                    end repeat
                end repeat
            end repeat
            return "not-found"
        end tell
        """
        return execute(script, target: "iTerm2", expected: token.isEmpty ? tty : token)
    }
}
