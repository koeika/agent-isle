"""Idempotent hook registration; preserves other integrations and keeps backups."""
import argparse
import copy
import datetime
import fcntl
import hashlib
import json
import os
import shlex
import sys
import subprocess
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from agent_isle.monitor import atomic_json, root_path
from agent_isle.preferences import enabled_sources

MARKER = "agent-isle-owned"
CURSOR_EVENTS = ("sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse", "postToolUse", "afterAgentResponse", "stop")
CLAUDE_EVENTS = ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure")


def owned(row):
    return MARKER in json.dumps(row)


def update(path, provider, script, remove=False):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    lockpath = path.with_name(path.name + ".agent-isle.lock")
    with lockpath.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = path.read_bytes() if path.exists() else None
        data = json.loads(before) if before else {}
        if not isinstance(data, dict) or not isinstance(data.get("hooks", {}), dict):
            raise ValueError("Invalid hooks structure; no changes made: " + str(path))
        result = copy.deepcopy(data)
        receipt_path = root_path() / "integration-receipts" / (hashlib.sha256(str(path).encode()).hexdigest() + ".json")
        receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {"added_version": "version" not in data, "added_hooks": "hooks" not in data}
        hooks = result.setdefault("hooks", {})
        for name, rows in list(hooks.items()):
            if not isinstance(rows, list):
                raise ValueError("Invalid event hook list: " + name)
            hooks[name] = [row for row in rows if not owned(row)]
            if not hooks[name]:
                del hooks[name]
        if not remove:
            if provider == "cursor":
                result.setdefault("version", 1)
            for event in CURSOR_EVENTS if provider == "cursor" else CLAUDE_EVENTS:
                # Marker is an inert CLI argument, not an undocumented config key.
                runtime = Path(sys.prefix)
                prefix = ['/usr/bin/env', 'PYTHONHOME=' + str(runtime), 'PYTHONNOUSERSITE=1', 'PYTHONDONTWRITEBYTECODE=1'] if (runtime / 'runtime-receipt.json').exists() else []
                command = shlex.join(prefix + [sys.executable, str(script), "hook", "--provider", provider, "--event", event]) + " # " + MARKER
                item = {"command": command, "timeout": 3}
                if provider == "claude":
                    item["type"] = "command"
                    item = {"hooks": [item]}
                hooks.setdefault(event, []).append(item)
        elif remove:
            if provider == "cursor" and receipt.get("added_version") and result.get("version") == 1:
                result.pop("version")
            if receipt.get("added_hooks") and not hooks:
                result.pop("hooks", None)
        if result == data:
            return {"provider": provider, "changed": False, "path": str(path)}
        # Preserve bytes exactly in a separate private backup. Atomic write only
        # after checking for an external editor changing the config mid-update.
        if before is not None and path.read_bytes() != before:
            raise RuntimeError("Configuration changed concurrently; try again")
        if before is not None:
            backup = root_path() / "backups" / (provider + "-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".json")
            backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd = os.open(str(backup), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(before)
        atomic_json(path, result)
        if json.loads(path.read_bytes()) != result:
            raise RuntimeError("Hook registration readback mismatch")
        if not remove and not receipt_path.exists():
            atomic_json(receipt_path, receipt)
        elif remove and receipt_path.exists():
            receipt_path.unlink()
        return {"provider": provider, "changed": True, "path": str(path), "installed": not remove}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--providers", nargs="*", choices=["codex", "claude", "cursor"])
    args = parser.parse_args()
    selected = set(args.providers) if args.providers is not None else enabled_sources(root_path())
    script = Path(__file__).resolve().parent / "monitor.py"
    out, errors = [], []
    claude = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(args.home / ".claude")))
    for provider, config in (("cursor", args.home / ".cursor/hooks.json"), ("claude", claude / "settings.json")):
        if args.action == 'install' and provider not in selected: continue
        try:
            out.append(update(config, provider, script, args.action == "uninstall"))
        except (OSError, ValueError, RuntimeError) as exc:
            errors.append({"provider": provider, "error": str(exc)})
    # The app bundle carries the independent local VSIX. Source-only test homes
    # never install extensions into the real user's editor.
    vsix = Path(__file__).resolve().parent.parent / "agent-isle-bridge.vsix"
    cursor_cli = Path('/Applications/Cursor.app/Contents/Resources/app/bin/cursor')
    if args.home == Path.home() and vsix.exists() and cursor_cli.exists() and (args.action == 'uninstall' or 'cursor' in selected):
        command = [str(cursor_cli), '--install-extension', str(vsix)] if args.action == 'install' else [str(cursor_cli), '--uninstall-extension', 'agent-isle.agent-isle-bridge']
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=25)
            out.append({'provider': 'cursor-bridge', 'installed': args.action == 'install', 'ok': result.returncode == 0})
            if result.returncode:
                errors.append({'provider': 'cursor-bridge', 'error': result.stderr[-300:] or result.stdout[-300:]})
        except (OSError, subprocess.SubprocessError) as exc:
            errors.append({'provider': 'cursor-bridge', 'error': type(exc).__name__})
    print(json.dumps({"results": out, "errors": errors}, ensure_ascii=False))
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
