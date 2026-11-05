"""Background discovery and streaming, using only Python's standard library."""
import argparse
import collections
import datetime as dt
import fcntl
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from agent_isle.preferences import enabled_sources, read_receipts
from agent_isle.core import Store, Tail, codex_record, claude_record, cursor_record, hook_event, latest_codex_prompt


def root_path():
    return Path(os.environ.get("AGENT_ISLE_HOME", str(Path.home() / "Library/Application Support/Agent Isle")))


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(value, f, ensure_ascii=False)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


class Monitor:
    def __init__(self, home=None, state=None):
        self.home = Path(home or Path.home())
        self.state = Path(state or root_path())
        self.events = self.state / "events"
        self.events.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.enabled = enabled_sources(self.state)
        self.store = Store()
        self.tails = {}
        self.contexts = {}
        self.errors = collections.deque(maxlen=12)
        self.last_discovery = 0
        self.health = {}
        self.last_focus_check = 0
        self.focused_keys = []
        snapshot = self.state / "snapshot.json"
        if snapshot.exists():
            try:
                self.store.restore(json.loads(snapshot.read_text()).get("sessions", []))
            except (OSError, ValueError, TypeError) as exc:
                self.error("state:restore", exc)

    def error(self, source, exc):
        # Do not copy payloads, user messages or credentials to diagnostics.
        item = {"source": source, "error": type(exc).__name__, "at": time.time()}
        if not self.errors or self.errors[-1].get("source") != source or self.errors[-1].get("error") != type(exc).__name__:
            self.errors.append(item)

    def add(self, path, provider, context=None):
        if provider not in self.enabled: return
        path = Path(path)
        if path in self.tails:
            if context:
                self.contexts[path].update(context)
            return
        try:
            stat = path.stat()
            if time.time() - stat.st_mtime > 7 * 86400:
                return
            ctx = dict(context or {})
            ctx.update(provider=provider, transcript=str(path), mtime=stat.st_mtime)
            if provider == "codex":
                # The first record contains session identity even for 200MB logs.
                with path.open("rb") as f:
                    first = json.loads(f.readline(1024 * 1024))
                codex_record(first, ctx)
            else:
                ctx.setdefault("id", path.stem)
            if ctx.get("hidden"):
                return
            if provider == 'codex':
                prompt = latest_codex_prompt(path, ctx)
                if prompt:
                    if ctx.get('named_title'):
                        prompt.update(title=ctx['named_title'], title_source='named')
                    self.store.apply(prompt, quiet=True)
            restored = self.store.sessions.get(provider + ':' + str(ctx.get('id', '')))
            if restored and restored.pending_inputs:
                ctx['input_calls'] = dict(restored.pending_inputs)
            self.contexts[path] = ctx
            self.tails[path] = Tail(path)
        except (OSError, ValueError) as exc:
            self.error(provider + ":discover", exc)

    def discover(self):
        now = time.time()
        self.last_discovery = now
        codex_home = Path(os.environ.get("CODEX_HOME", str(self.home / ".codex")))
        self.health["codex"] = {"available": codex_home.exists(), "mode": "本地会话增量读取"}
        dbs = sorted(codex_home.glob("state_*.sqlite"), key=lambda p: p.stat().st_mtime, reverse=True) if "codex" in self.enabled else []
        found_db = False
        if dbs:
            try:
                with sqlite3.connect(dbs[0].as_uri() + "?mode=ro", uri=True, timeout=0.2) as con:
                    cols = {r[1] for r in con.execute("pragma table_info(threads)")}
                    origin = "originator" if "originator" in cols else "''"
                    name = "name" if "name" in cols else "''"
                    rows = con.execute("SELECT id, rollout_path, title, cwd, source, " + origin + ", " + name + ", archived" +
                                       " FROM threads WHERE source NOT LIKE '%subagent%' AND updated_at>? ORDER BY updated_at DESC LIMIT 200",
                                       (now - 7 * 86400,)).fetchall()
                found_db = True
                for sid, path, title, cwd, source, orig, name, archived in rows:
                    if "subagent" not in source:
                        self.add(path, "codex", {"id": sid, "title": name or title, "named_title": name or "", "cwd": cwd,
                                                 "origin": orig or "", "source": source, "archived": bool(archived)})
            except (sqlite3.Error, OSError) as exc:
                self.error("codex:index", exc)
        # Also scan today's and yesterday's folder: DB indexing can lag a new file.
        for days in range((2 if found_db else 7) if "codex" in self.enabled else 0):
            folder = codex_home / "sessions" / (dt.date.today() - dt.timedelta(days=days)).strftime("%Y/%m/%d")
            if folder.exists():
                for path in folder.glob("*.jsonl"):
                    self.add(path, "codex")
        # CLI / app-server runs can be absent from the desktop sidebar, moved
        # into archives or not indexed yet. Discover their actual files too.
        archives = codex_home / "archived_sessions"
        if "codex" in self.enabled and archives.exists():
            for path in archives.glob("*.jsonl"):
                self.add(path, "codex", {"archived": True})
        claude_home = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(self.home / ".claude")))
        for provider, root, pattern in (("claude", claude_home / "projects", "*/*.jsonl"),
                                        ("cursor", self.home / ".cursor/projects", "*/agent-transcripts/**/*.jsonl")):
            if provider not in self.enabled:
                self.health[provider] = {"enabled": False}
                continue
            self.health[provider] = {"available": root.exists(), "mode": "Hook + 本地记录发现", "enabled": True}
            if root.exists():
                try:
                    files = sorted(root.glob(pattern), key=lambda p: p.stat().st_mtime, reverse=True)[:50]
                    for path in files:
                        self.add(path, provider)
                except OSError as exc:
                    self.error(provider + ":scan", exc)
        self.health["hooks"] = self.hook_health()

    def hook_health(self):
        result = {}
        for provider, path in (("cursor", self.home / ".cursor/hooks.json"),
                                ("claude", Path(os.environ.get("CLAUDE_CONFIG_DIR", str(self.home / ".claude"))) / "settings.json")):
            try:
                data = json.loads(path.read_text())
                result[provider] = "agent-isle-owned" in json.dumps(data)
            except (OSError, ValueError):
                result[provider] = False
        return result

    def consume_files(self):
        adapters = {"codex": codex_record, "claude": claude_record, "cursor": cursor_record}
        for path, tail in list(self.tails.items()):
            ctx = self.contexts[path]
            try:
                quiet, records = tail.read()
                ctx["mtime"] = path.stat().st_mtime
                # Metadata appears before bounded tail data when bootstrapping.
                if quiet and ctx.get("id"):
                    self.store.apply({**ctx, "status": "unknown", "detail": "会话已发现 · 恢复最近状态", "at": 0,
                                      "passive": ctx["provider"] != "codex", "confidence": "inferred"}, quiet=True)
                for record in records:
                    event = adapters[ctx["provider"]](record, ctx)
                    if event:
                        if ctx.get("named_title"):
                            event["title"] = ctx["named_title"]
                            event["title_source"] = "named"
                        self.store.apply(event, quiet=quiet or event.get("passive", False))
            except FileNotFoundError:
                del self.tails[path]
                self.contexts.pop(path, None)
            except (OSError, ValueError) as exc:
                self.error(ctx["provider"] + ":read", exc)

    def consume_hooks(self):
        for path in sorted(self.events.glob("*.json"))[:1000]:
            try:
                if path.stat().st_size > 65536:
                    raise ValueError("oversize event")
                event = json.loads(path.read_text())
                if event.get('provider') in self.enabled:
                    self.store.apply(event, quiet=time.time() - event.get("at", 0) > 60)
                path.unlink()
            except (ValueError, TypeError, OSError) as exc:
                self.error("hook:read", exc)
                try:
                    path.rename(path.with_suffix(".invalid"))
                except OSError:
                    pass

    def step(self):
        enabled = enabled_sources(self.state, self.enabled)
        if enabled != self.enabled:
            self.enabled = enabled
            for path in list(self.tails):
                if self.contexts[path]['provider'] not in enabled:
                    del self.tails[path]; self.contexts.pop(path, None)
            self.last_discovery = 0
            self.last_focus_check = 0
        if time.time() - self.last_discovery >= 6:
            self.discover()
        self.consume_files()
        # Hooks own authoritative Claude/Cursor lifecycle, processed after tails.
        self.consume_hooks()
        self.store.apply_read_receipts(read_receipts(self.state))
        snap = self.store.snapshot()
        snap['sessions'] = [s for s in snap['sessions'] if s['provider'] in self.enabled]
        snap['alerts'] = [a for a in snap['alerts'] if a['provider'] in self.enabled]
        if time.time() - self.last_focus_check >= 2:
            self.last_focus_check = time.time()
            self.focused_keys = self.read_focused_keys(snap["sessions"])
        snap["focused_keys"] = self.focused_keys
        snap["health"] = self.health
        snap["diagnostics"] = list(self.errors)
        return snap

    def read_focused_keys(self, sessions):
        if 'cursor' not in self.enabled: return []
        from agent_isle.navigation import request_bridge
        result = []
        for path in (self.state / "bridges").glob("*.json"):
            try:
                if path.is_symlink() or path.stat().st_uid != os.getuid():
                    continue
                entry = json.loads(path.read_text())
                context = request_bridge(entry, {"action": "focus-context"}, timeout=0.25)
                if context.get("ok") and context.get("focused"):
                    ids = context.get("selectedIds", [])
                    result += [s["provider"] + ":" + s["id"] for s in sessions if s["provider"] == "cursor" and s["id"] in ids]
            except (OSError, ValueError, TypeError, KeyError):
                pass  # Unknown context must never suppress discovery or hover.
        return result


def emit_hook(args):
    # Hooks are observational: they never emit allow/deny or continuation control.
    try:
        raw = sys.stdin.buffer.read(1024 * 1024)
        if args.provider not in enabled_sources(root_path()):
            print("{}"); return
        data = json.loads(raw) if raw.strip() else {}
        if not isinstance(data, dict):
            raise ValueError("Hook input must be an object")
        event = hook_event(args.provider, args.event or data.get("hook_event_name", ""), data, os.environ)
        if event:
            from agent_isle.navigation import process_identity
            event.setdefault("terminal", {}).update(process_identity())
            atomic_json(root_path() / "events" / ("%020d-%s.json" % (time.time_ns(), uuid.uuid4().hex)), event)
    except (OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        print("Agent Isle hook: " + type(exc).__name__, file=sys.stderr)
    print("{}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    hook = sub.add_parser("hook")
    hook.add_argument("--provider", choices=["claude", "cursor"], required=True)
    hook.add_argument("--event")
    watch = sub.add_parser("watch")
    watch.add_argument("--once", action="store_true")
    watch.add_argument("--home", type=Path)
    watch.add_argument("--state", type=Path)
    args = parser.parse_args()
    if args.command == "hook":
        emit_hook(args)
        return
    monitor = Monitor(args.home, args.state)
    lock = (monitor.state / "monitor.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Agent Isle monitor already running", file=sys.stderr)
        sys.exit(2)
    # Exit immediately with the host app. No orphaned watchers after a crash.
    parent = os.getppid()
    last_write = 0
    while os.getppid() == parent:
        snap = monitor.step()
        print(json.dumps(snap, ensure_ascii=False), flush=True)
        if time.time() - last_write > 5 or snap["alerts"]:
            atomic_json(monitor.state / "snapshot.json", snap)
            last_write = time.time()
        if args.once:
            break
        time.sleep(1)


if __name__ == "__main__":
    main()
