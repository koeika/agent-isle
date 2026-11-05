"""Create an allowlisted, self-contained share bundle; never archive the workspace."""
import hashlib
import json
import plistlib
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'dist/Agent Isle.app'


def main():
    info = plistlib.loads((APP/'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    name = 'Agent-Isle-' + version + '-macOS-universal'
    folder = ROOT/'dist'/name
    if folder.exists(): shutil.rmtree(folder)
    folder.mkdir()
    subprocess.run(['codesign','--verify','--deep','--strict',str(APP)],check=True)
    subprocess.run(['ditto',str(APP),str(folder/'Agent Isle.app')],check=True)
    shutil.copy2(ROOT/'dist/agent-isle-bridge.vsix',folder/'agent-isle-bridge.vsix')
    shutil.copy2(ROOT/'LICENSE',folder/'LICENSE.txt')
    (folder/'安装与使用.txt').write_text('''Agent Isle VERSION · 完整分享版

适用：macOS 14 或更新版本。内含 Apple Silicon / Intel 双架构二进制。
本次实际运行验证为 Apple Silicon；Intel 和旧版 macOS 未在实体设备上复测。

1. 将 Agent Isle.app 拖入「应用程序」或个人 ~/Applications 目录，再打开。
2. 首次启动会自动在默认浏览器打开本地指引页（127.0.0.1 随机端口）。
   以后可用应用菜单「打开使用指引…」，或设置 → 关于重新打开。
3. 设置 → 工具接入勾选监听工具。默认 Codex、Claude Code，Cursor 默认关闭。
   取消勾选后，该工具不再监听、展示、计数或提醒；已有接入配置保留。
   Codex 自动发现本机会话，无需 Hook。每个来源可设置独立 Logo / 标签颜色。
4. Claude Code / Cursor：设置 → 工具接入 → 安装 / 修复已勾选工具接入。
   接入后重启 Cursor / 新开 Claude Code 会话。
5. 悬停展开，移出收起；Ctrl+G 打开键盘切换器；Esc 收起。
   成功打开完成会话或查看最近对话后，绿色未读点消失；下轮完成再次提醒。
6. 设置 → 显示可调整折叠尺寸、选择四种图标或导入本地 Logo。
   微调以系统自动尺寸为基准，0不调整；摄像头避让独立保留。
   当前仅macOS客户端，Windows/Linux不能直接运行此包。

应用自带 Python 标准库运行环境、原创音效、指引页面与 Cursor 桥接扩展，
不需要额外安装 Python、Homebrew、Xcode。外置 VSIX 供必要时手动安装备用；
正常使用通过应用设置安装即可。Source.zip 为独立实现的完整源码。

当前为 ad-hoc 签名分享版，没有 Apple Developer ID 公证。
macOS 可能提示无法验证开发者。确认分享者可信后，在系统设置 → 隐私与安全性
查看系统提供的打开选项；无需关闭 Gatekeeper / SIP，不提供绕过安全保护的脚本。

网页仅监听 127.0.0.1，不对局域网开放。退出应用后网页服务器同时停止。
下载 ZIP 本身不会执行程序：自动指引在第一次打开应用时出现。

免费，无账户、充值、订阅或遥测。只监听当前用户的本机 Codex、Cursor、Claude Code。
压缩包不包含制作者的聊天、Hook 配置、令牌、Cookie 或个人诊断记录。
首次安装不自动修改 AI 工具配置；请在设置中主动接入。
不要在接入后移动或改名应用；如移动，请从新位置执行「安装 / 修复接入」。

卸载：先在应用设置移除接入，再退出并移除应用。不会删除 AI 工具的原始会话。
Terminal / iTerm2 精确定位需要 macOS 自动化许可，原生终端适配仍待更多设备验证。

第三方许可：应用 Resources/Runtime/python/LICENSE.txt 与运行环境说明。
项目许可：MIT，见 LICENSE.txt。完整性校验：见 SHA256SUMS.txt。
'''.replace('VERSION',version),encoding='utf-8')
    with zipfile.ZipFile(folder/'Source.zip','w',compression=zipfile.ZIP_DEFLATED) as archive:
        for dirname in ['Sources','agent_isle','cursor-bridge','scripts','tests','web','docs','licenses']:
            for p in sorted((ROOT/dirname).rglob('*')):
                if p.is_file() and not {'__pycache__','node_modules','.DS_Store'}.intersection(p.parts) and p.suffix != '.pyc':
                    archive.write(p,p.relative_to(ROOT))
        for p in ['README.md','LICENSE','.gitignore']: archive.write(ROOT/p,p)
    files = sorted(p for p in folder.rglob('*') if p.is_file())
    manifest = '\n'.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(folder)) for p in files)+'\n'
    (folder/'SHA256SUMS.txt').write_text(manifest)
    output = ROOT/'dist'/(name+'.zip')
    if output.exists(): output.unlink()
    subprocess.run(['ditto','-c','-k','--norsrc','--keepParent',str(folder),str(output)],check=True)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix('.zip.sha256').write_text(digest+'  '+output.name+'\n')
    print(json.dumps({'archive':str(output),'bytes':output.stat().st_size,'sha256':digest,'payload_files':len(files)},ensure_ascii=False))

if __name__=='__main__': main()
