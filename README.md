# Agent Isle

免费、独立实现的本机 AI 会话浮岛。MIT 许可，无账户、遥测、订阅或云端服务。首次启动通过本机 localhost 提供使用指引。

## 运行

本机安装位置：`~/Applications/Agent Isle.app`。0.3.0 起贴合屏幕顶边；优先选择有刘海的显示器，按 `NSScreen.safeAreaInsets` 与辅助区域测量刘海，收起信息放在摄像头两侧。无刘海时使用顶部紧凑条。点击或悬停可展开，展开宽度 640pt，小屏幕自动缩窄。

- **Codex**：只读 SQLite 会话索引与 JSONL 增量记录，发现最近七天的普通、CLI、外部 app-server 和归档会话。排除子 Agent。支持默认 `~/.codex` 和环境变量 `CODEX_HOME` 指定目录，不扫描任意磁盘上的自定义目录。
- **Cursor / Claude Code**：使用官方 Hook；安装接入后重启 Cursor / 新开 Claude Code 会话。兼容已有配置，保留其他 Hook，备份写入应用支持目录。Cursor 执行 Claude 兼容 Hook 时按 transcript 来源去重。
- **内容**：卡片显示标题、最近用户消息、运行活动与回复摘要；JSON 回复优先使用 `summary`。有命名的会话保留原名称。“最近对话”打开最近消息快照，可选择和复制文字，并定位原始记录；不是完整历史浏览器。最近用户消息最多 12000 字符，Agent 回复最多 16000 字符。
- **提醒**：完成 / 待确认 / 错误使用不同的原创合成音效。折叠时只显示最新完成任务的一行（默认 5 秒，可调），不会打开完整任务列表；点击这一行跳转对应会话。已展开时在原会话行显示状态。像素角色和彩屑保留。默认播放音量 85%，提示音比旧版更长、有效幅度约高 12dB；设置中可调音量、静音及“试听单行完成提醒”。不会更改系统音量。系统通知需要在设置中开启并获 macOS 允许。
- **需要输入**：正式提问工具与 Hook 请求会触发橙色单行提醒和独立提示音。异步提问之后继续执行工具，不会清掉待输入状态；回答、取消或结束轮次后才清除。输入提醒优先于完成事件，未处理前保留；其余完成提醒排队，避免覆盖。已用本聊天真实提问验证，所有者确认“看到了，也听到了”，回答后提醒实际收回。
- **Codex 跳转**：按会话 ID 使用官方 deep link；本机所有者已实际确认落到此聊天。原始 CLI 会话缺少终端身份时，在 Codex 中打开保存的会话。
- **Cursor 跳转**：附带独立的 `agent-isle.agent-isle-bridge` 扩展，通过私有 Unix socket 调用本机 Cursor 的 ID 打开命令，并读回选中的会话 ID；已经从另一聊天切回目标聊天进行实际验证。使用内部命令，随 Cursor 版本可能变化，缺失时显示失败，不创建替代聊天或只打开项目。匹配到多个同项目窗口时明确拒绝猜测。扩展安装/更新后可能需要重新加载当前 Cursor 窗口。
- **Claude Code / 终端跳转**：Hook 捕获实际控制 TTY 和父进程链。Cursor 集成终端按 shell PID / TTY 选择对应终端，并等待选中事件后读回；已用真实 Claude Code 会话和另一标签对照验证。Terminal.app / iTerm2 实现了按 TTY / session ID 选择标签与读回的路由，需要 macOS 自动化权限；当前电脑控制工具禁止控制 Terminal.app，本机未完成原生 Terminal / iTerm2 的实际验证，不声称它们已通过。旧会话没有终端身份时会说明原因，不会假报成功。

不会根据“静默一段时间”假报成功；30 分钟无事件的运行会话标为状态待确认。已有日志的启动恢复不触发历史完成通知。Hook 状态会本地保存，重新打开应用时静默恢复。

## 构建与检查

构建需要 macOS 14+、Swift 工具链、系统构建用 Python 3，以及 Python.org universal2 CPython 3.13 框架（默认 `/Library/Frameworks/Python.framework/Versions/3.13`，可用 `AGENT_ISLE_PYTHON_FRAMEWORK` 指定）。只打包解释器与标准库，排除第三方包、缓存与用户数据。发布包自带运行环境，接收者不需要开发工具；原生应用与解释器均为 arm64 / x86_64 通用二进制，最低部署目标 macOS 14。当前仅本机 Apple Silicon 实机验证，未公证。

```bash
bash scripts/build.sh
/usr/bin/python3 -m unittest discover -s tests -v
node tests/navigation_bridge.test.js
swiftc Sources/NotchLayout.swift Sources/AlertPolicy.swift tests/NotchLayoutTests.swift -o .build/layout-tests
.build/layout-tests
```

产物在 `dist/Agent Isle.app`。应用内附带 Python 源码，使用 ad-hoc 本地签名。

## 配置与退出

应用数据位于 `~/Library/Application Support/Agent Isle/`，包括私有权限的快照、待消费事件、Hook 配置备份和不包含消息正文的 `activity.jsonl` 运行诊断。快照与待消费事件包含会话内容，仅存本机。

设置中的“安装 / 修复接入”安装本应用 Hook 与本地桥接扩展；“移除接入”仅移除本应用注册的 Hook 和扩展。其他 Hook 保留。也可以运行：

```bash
/usr/bin/python3 "$HOME/Applications/Agent Isle.app/Contents/Resources/agent_isle/integrations.py" uninstall
```

退出应用会停止后台监听。登录启动可在设置中由用户主动开启。卸载前先移除接入，再删除应用。原 Vibe Island 不会被修改；如果同时运行，两者都可能播放提示音。

## 参考

独立实现，未使用 Vibe Island 的二进制、声音、图片或专有桥接代码。

- 产品参考：[Vibe Island](https://vibeisland.app/)
- [Cursor Hooks](https://cursor.com/docs/hooks)
- [Claude Code Hooks](https://code.claude.com/docs/en/hooks)
- [Codex 会话跳转](https://learn.chatgpt.com/docs/reference/commands)


### 0.4.0 交互与设置

- 悬停 0.15 秒展开、移出约 0.28 秒收起；点击不再自动固定，Esc 防止原地重开。
- 紧凑会话列表和独立侧栏设置窗口；宽度默认 640pt。
- 鼠标悬停仅高亮；自动滚动限于键盘选择。操作期间行顺序稳定，避免其他任务更新挤走点击目标。
- Ctrl+G 切换器、上下 / Enter / Esc、反向切换、数字跳转和可录制快捷键。
- 过滤规则、原生显示器 / 字号 / 尺寸设置、每事件选音 / 试听 / 导入、安静时段。
- 完成提醒仍只展开一行，待输入仍保留至回答。

完整的原版行为映射与范围说明见 [交互对照](docs/interaction-parity.md)。Cursor 桥接更新到 0.1.2 后，正在运行的旧扩展宿主需要重启才能启用新增的只读聚焦上下文；原有精确聊天 / 终端跳转保持兼容。

### 0.5.0 完整分享包与本地指引

首次启动在默认浏览器自动打开 `http://127.0.0.1:<随机端口>/`。菜单和设置 → 关于也可重新打开；退出应用停止本地服务器。只提供固定静态资源和工具配置存在性，不提供修改配置的网页接口，不读取对话内容。页面的「打开设置」通过 `agent-isle://settings` 返回原生应用。

```bash
bash scripts/build.sh
python3 scripts/package_release.py
```

分享 `dist/Agent-Isle-0.5.0-macOS-universal.zip`。包含完整应用（内置 CPython 标准库、桥接、音效、指引）、备用 VSIX、中文安装说明、许可、源码 ZIP 与逐文件 SHA256。不要直接压缩工作目录或用户数据目录。

### 0.5.1 刘海微调与图标

当前客户端仅支持 macOS 14+（Apple Silicon / Intel 通用二进制）。Windows 和 Linux 无可运行客户端；浏览器指引页不等于跨平台客户端，需要分别适配浮窗、通知、终端与窗口跳转。

设置 → 显示：
- 「刘海尺寸微调」改为相对于系统自动尺寸的增减值：横向 -64…160pt、高度 -8…40pt，0为自动。原绝对尺寸字段保留但不再应用。设置内实时显示折叠窗口实际尺寸；摄像头避让独立保留。展开列表宽度由「面板最大宽度」控制。
- 「图标与 Logo」提供机器人、猫咪、幽灵、星光。选择即时应用于灵动岛、会话图标和菜单栏，不修改已签名安装包的 Finder 图标。
- 可导入 PNG、JPEG、HEIC、WebP（≤10MB、长宽≤16384），下采样至最大512像素，保留比例和透明度，复制为私有PNG。不上传，不依赖原文件持续存在。切换预设保留自定义选择；移除可恢复默认。

检查：
```bash
swiftc Sources/NotchLayout.swift Sources/Preferences.swift Sources/AvatarAssets.swift tests/AppearanceTests.swift -o .build/appearance-tests
.build/appearance-tests
```

### 0.5.2 最近提问预览

修复 Codex 新提问被宽泛的 XML / JSON 前缀过滤误判为系统上下文而漏读。只移除已知环境/浏览器元数据，支持 user_query、文件附件说明和合法 JSON / XML 提问。提问时间独立于工具/状态时间，晚刷出的新提问可更新内容而不回退完成状态。启动时向后有界恢复最近提问（最多8MB），并保存独立的最近提问缓存以跨越长工具输出；历史恢复不弹通知。


### 0.5.3 监听来源、来源颜色与已读

设置 → 工具接入可勾选监听工具，默认启用 Codex、Claude Code，Cursor 默认关闭。取消勾选后停止发现该来源，不在列表、筛选、计数或提醒中展示；保留已有接入配置，重新勾选后恢复发现。安装 / 修复接入只处理已勾选的 Claude Code / Cursor。

Codex 可只读本机会话索引与日志，无需安装 Hook。Claude Code、Cursor 虽可发现已有记录，准确的完成、输入和审批生命周期仍依赖各自 Hook；Cursor 精确跳转还依赖本地桥接扩展。

每个来源有独立默认色：Codex 青绿、Claude Code 杏色、Cursor 紫色。支持颜色选择器与 HEX 输入；无效值不会覆盖配置。颜色用于像素 Logo、来源标签与自定义图片边框，完成 / 输入 / 失败状态仍独立显示。自定义图片保留原色。

完成任务成功打开原会话，或打开“查看最近对话”后，绿色未读点消失，已读状态在重启后保留；同一会话下一轮完成会再次显示未读。定位失败不会清除未读。需要输入的提醒不受完成已读操作影响。

移除自定义窗口和按钮的系统焦点描边，不改变系统键盘与辅助功能偏好。设置与对话窗口退出键盘切换模式，避免关闭后快捷键误触跳转。


### 0.6.0 DS Harness

新增 DS Harness 来源（默认关闭，可在工具接入中勾选），默认蓝色，可自定义。只读 `DSH_HOME` 或 `~/.dsh` 中最近七天的主会话 v4 日志；支持明文 JSONL 与多帧 Zstandard，排除子 Agent。不读取凭据或修改 Harness 配置。压缩记录使用已安装的 DeepSeek Harness 桌面运行环境（或支持 zstd 的 Node）解码，无需额外 Hook。

按实际 `turn/start`、`turn/end`、提问和审批事件显示运行、完成、中止、出错与需要输入状态；启动与重新勾选时静默恢复历史。支持最新提问、回复摘要、声音与单行提醒及已读。压缩日志增量按完整帧读取，正在写入的尾帧等待补齐，不跳过。仅支持已知 v4 格式；读取失败会保留诊断，不凭静默推测完成。

当前本机 DS Harness 只处理 `dsh://open`，因此该来源卡片明确显示“打开 DS Harness（不定位会话）”，打开应用不会清除完成未读；可通过右键“查看最近对话”查看快照并标记已读。没有声称精确跳转到其聊天。

DSH 回归中的压缩日志用例需要安装 Harness 或具备 Zstandard API 的 Node；其余来源仍不依赖 Node。
