"""Local session state machine. No network access or agent credentials required."""
import datetime as dt
import json
import os
import re
import time
from dataclasses import asdict, dataclass, fields, field
from pathlib import Path

PROVIDERS = ("codex", "cursor", "claude")
TERMINAL_ENV = ("TERM_PROGRAM", "TERM_SESSION_ID", "ITERM_SESSION_ID", "__CFBundleIdentifier", "TMUX_PANE")


def timestamp(value, fallback=None):
    if isinstance(value, (int, float)):
        return value / 1000 if value > 100000000000 else value
    if isinstance(value, str):
        try:
            return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            pass
    return time.time() if fallback is None else fallback


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return " ".join(str(p.get("text", "")) for p in value if isinstance(p, dict))
    return ""


# Only known transport envelopes are metadata. A task may legitimately start
# with JSON, XML or Markdown; rejecting every '<' / '{"' loses real questions.
def user_task_text(value):
    text = text_content(value).strip()
    for tag in ('external_browser_tabs', 'external_codex_apps_open_page', 'environment_context', 'turn_aborted'):
        text = re.sub(r'<' + tag + r'\b[^>]*>.*?</' + tag + r'\s*>', '', text, flags=re.S).strip()
    if text.startswith(('# AGENTS.md instructions', '# AGENTS instructions')):
        return ''
    query = re.fullmatch(r'<user_query>(.*?)</user_query>', text, re.S)
    if query:
        text = query.group(1).strip()
    if text.startswith(('# Files mentioned by the user:', '# Files pasted by the user:')) and '## My request:' in text:
        text = text.split('## My request:', 1)[1].strip()
        text = re.sub(r'<image\b[^>]*>.*?</image>', '', text, flags=re.S).strip()
    return text


def compact(value, limit=150):
    text = text_content(value)
    query = re.search(r"<user_query>(.*?)</user_query>", text, re.S)
    if query:
        text = query.group(1)
    if "## My request:" in text:
        text = text.split("## My request:", 1)[1]
    return re.sub(r"\s+", " ", text).strip()[:limit]


def reply_summary(value):
    if not isinstance(value, str):
        return ""
    try:
        result = json.loads(value)
        if isinstance(result, dict):
            for key in ("summary", "reply", "answer", "message"):
                if isinstance(result.get(key), str) and result[key].strip():
                    return compact(result[key], 500)
    except ValueError:
        pass
    return compact(value, 500)


@dataclass
class Session:
    id: str
    provider: str
    title: str = "新会话"
    cwd: str = ""
    status: str = "idle"
    detail: str = "等待下一条消息"
    updated: float = 0
    turn: str = ""
    origin: str = ""
    transcript: str = ""
    terminal: dict = None
    unread: bool = False
    completed_at: float = 0
    confidence: str = "observed"
    hook_seen: bool = False
    lifecycle_at: float = 0
    ended: bool = False
    title_source: str = ""
    user_message: str = ""
    user_message_at: float = 0
    assistant_message: str = ""
    summary: str = ""
    source: str = ""
    archived: bool = False
    pending_inputs: dict = field(default_factory=dict)
    input_detail: str = ""

    def wire(self):
        return asdict(self)


class Store:
    def __init__(self, clock=time.time):
        self.sessions = {}
        self.alerts = []
        self.clock = clock
        self.revision = 0
        self.seen_alerts = set()

    def restore(self, rows):
        allowed = {f.name for f in fields(Session)}
        for row in rows:
            if not isinstance(row, dict) or row.get("provider") not in PROVIDERS or not row.get("id"):
                continue
            cached_codex_prompt = row.get("provider") == "codex" and bool(row.get("user_message"))
            if not (row.get("hook_seen") or row.get("pending_inputs") or cached_codex_prompt) or self.clock() - row.get("updated", 0) > 7 * 86400:
                continue
            clean = {k: v for k, v in row.items() if k in allowed}
            if clean["provider"] == "claude" and "/.cursor/projects/" in clean.get("transcript", ""):
                clean["provider"] = "cursor"
            s = Session(**clean)
            s.user_message = user_task_text(s.user_message)[:12000]
            if s.status == 'completed' and not s.completed_at:
                s.completed_at = s.lifecycle_at or s.updated
            if cached_codex_prompt and not (s.hook_seen or s.pending_inputs):
                # Preserve prompt content when the tail contains megabytes of
                # tool output; lifecycle still comes from actual new records.
                s.status, s.detail, s.confidence = "unknown", "正在恢复最近状态", "inferred"
            s.title = compact(s.title, 100)
            key = s.provider + ":" + s.id
            if key not in self.sessions or self.sessions[key].updated < s.updated:
                self.sessions[key] = s

    def apply(self, event, quiet=False):
        provider, sid = event.get("provider"), event.get("id")
        if provider not in PROVIDERS or not sid:
            return None
        key = provider + ":" + str(sid)
        s = self.sessions.get(key)
        at = timestamp(event.get("at"), self.clock())
        order_at = s.lifecycle_at if s and event.get("hook") else s.updated if s else 0
        if s and at < order_at:
            # A late-flushed prompt can still be newer than the last prompt.
            # Enrich content without replaying lifecycle, inputs or notifications.
            if event.get("kind") == "prompt" and at >= s.user_message_at:
                text = user_task_text(event.get("text"))
                if text:
                    s.user_message, s.user_message_at = text[:12000], at
                    self.revision += 1
            return s  # A delayed callback must not revive a completed turn.
        if not s:
            s = Session(str(sid), provider)
            self.sessions[key] = s
        previous = s.status
        new_inputs = set(event.get('input_open', {})) - set(s.pending_inputs)
        if event.get('clear_inputs') or event.get('status') in ('completed', 'cancelled', 'closed', 'error'):
            s.pending_inputs.clear()
        for request_id in event.get('input_close', []):
            s.pending_inputs.pop(request_id, None)
        s.pending_inputs.update(event.get('input_open', {}))
        if event.get('input_open'):
            s.input_detail = compact(event.get('detail') or '需要你回答问题', 300)
        if event.get("hook"):
            s.hook_seen = True
        # Passive Cursor/Claude text has no reliable end-of-turn marker. Once
        # hooks are present, it can enrich labels but must not override lifecycle.
        metadata_only = event.get("passive") and s.hook_seen and provider != "codex"
        for field in ("cwd", "origin", "transcript", "terminal", "turn", "source"):
            if event.get(field):
                setattr(s, field, event[field])
        if "archived" in event:
            s.archived = bool(event["archived"])
        if event.get("title") and (event.get("title_source") == "named" or s.title_source != "named"):
            s.title = compact(event["title"], 100)
            s.title_source = event.get("title_source", "prompt")
        if event.get("kind") == "prompt" and at >= s.user_message_at:
            text = user_task_text(event.get("text"))
            if text:
                s.user_message, s.user_message_at = text[:12000], at
                if s.title_source not in ("named", "summary"):
                    s.title = compact(text, 100) or s.title
                    s.title_source = "prompt"
        if event.get("assistant_message"):
            s.assistant_message = text_content(event["assistant_message"])[:16000]
            s.summary = reply_summary(s.assistant_message)
            if s.title_source != "named":
                try:
                    result = json.loads(s.assistant_message)
                    if isinstance(result, dict) and isinstance(result.get("summary"), str) and result["summary"]:
                        s.title = compact(result["summary"], 100)
                        s.title_source = "summary"
                except ValueError:
                    pass
        if not metadata_only:
            closing_finished = event.get("status") == "closed" and s.status in ("completed", "cancelled", "error")
            if event.get("status") == "closed":
                s.ended = True
            elif event.get("status") == "running":
                s.ended = False
            if not closing_finished:
                s.status = event.get("status", s.status)
            if event.get("detail") and not closing_finished:
                s.detail = compact(event["detail"])
            s.confidence = event.get("confidence", "observed")
            if event.get("hook") or provider == "codex":
                s.lifecycle_at = at
        s.updated = max(s.updated, at)
        if s.pending_inputs:
            s.status = 'waiting'
            s.detail = s.input_detail or '需要你回答问题'
        if s.status == "completed" and (previous != "completed" or not s.completed_at):
            s.completed_at = at
        if s.status == "running":
            s.unread = False
        alert_key = (key, s.turn, s.status, tuple(sorted(s.pending_inputs)))
        is_alert = s.status in ("completed", "waiting", "error") and (previous != s.status or bool(new_inputs))
        if not quiet and not metadata_only and is_alert and alert_key not in self.seen_alerts:
            self.seen_alerts.add(alert_key)
            s.unread = True
            self.alerts.append({"key": key, "status": s.status, "title": s.title,
                                "provider": provider, "detail": s.detail, "at": at})
        # New prompts without a turn identifier can still complete repeatedly.
        if previous != "running" and s.status == "running":
            self.seen_alerts = {k for k in self.seen_alerts if k[0] != key}
        self.revision += 1
        return s

    def apply_read_receipts(self, receipts):
        import math
        for key, at in receipts.items():
            if not isinstance(at, (int, float)) or not math.isfinite(at): continue
            session = self.sessions.get(key)
            if session and session.status == 'completed' and session.unread and at >= (session.completed_at or session.updated):
                session.unread = False
                self.revision += 1

    def snapshot(self):
        now = self.clock()
        # No inactivity-to-success heuristic: silent agents become unknown.
        for s in self.sessions.values():
            if s.status == "running" and now - s.updated > 1800:
                s.status, s.detail, s.confidence = "unknown", "30 分钟无新事件 · 状态待确认", "inferred"
        rows = sorted(self.sessions.values(), key=lambda s: s.updated, reverse=True)
        rows = [s for s in rows if now - s.updated < 7 * 86400][:80]
        alerts, self.alerts = self.alerts, []
        return {"type": "snapshot", "sessions": [s.wire() for s in rows], "alerts": alerts,
                "revision": self.revision, "at": now}


def codex_record(record, context):
    """Translate observed local Codex rollout records, without writing to them."""
    p = record.get("payload", {})
    if not isinstance(p, dict):
        return None
    typ = record.get("type")
    if typ == "session_meta":
        source = p.get("source", "")
        context.update(id=p.get("id", context.get("id")), cwd=p.get("cwd", ""),
                       origin=p.get("originator", ""), source=source, hidden=isinstance(source, dict) or "subagent" in str(source))
    if context.get("hidden") or not context.get("id"):
        return None
    e = {"provider": "codex", "id": context["id"], "at": record.get("timestamp") or (0 if typ == "session_meta" else context.get("mtime", 0)),
         "cwd": context.get("cwd", ""), "origin": context.get("origin", ""),
         "transcript": context.get("transcript", ""), "source": context.get("source", ""),
         "archived": context.get("archived", False)}
    if typ == "session_meta":
        e.update(status="idle", detail="会话已发现")
    elif typ == "event_msg":
        kind = p.get("type")
        if p.get("turn_id"):
            context["turn"] = p["turn_id"]
        e["turn"] = context.get("turn", "")
        if kind in ("task_started", "turn_started", "user_message"):
            e.update(status="running", detail="正在处理任务")
            if kind in ('task_started', 'turn_started'):
                e['clear_inputs'] = True
            if kind == "user_message":
                text = user_task_text(p.get("message", ""))
                if not text: return None
                e.update(kind="prompt", text=text)
        elif kind in ("task_complete", "turn_complete"):
            # A child turn finishing must not mark its parent's task completed.
            if p.get("root_turn_id") and p.get("turn_id") and p["root_turn_id"] != p["turn_id"]:
                return None
            e.update(status="completed", detail=reply_summary(p.get("last_agent_message")) or "本轮任务已完成")
            if p.get("last_agent_message"):
                e["assistant_message"] = p["last_agent_message"]
        elif kind == "turn_aborted":
            e.update(status="cancelled", detail="本轮任务已中止")
        elif kind in ("error", "task_failed"):
            e.update(status="error", detail=p.get("message") or "任务遇到错误")
        elif kind in ("request_user_input", "exec_approval_request", "apply_patch_approval_request"):
            e.update(status="waiting", detail="需要你的确认 · 请返回会话")
        elif kind == "agent_message" and p.get("message"):
            e.update(assistant_message=p["message"])
        else:
            return None
    elif typ == "response_item":
        kind = p.get("type")
        if kind in ("function_call", "custom_tool_call"):
            name = p.get("name", "工具")
            if name.endswith("request_user_input") or name.endswith("request_user_input_async"):
                call = p.get('call_id') or p.get('id') or 'input-request'
                mode = 'async' if name.endswith('_async') else 'blocking'
                context.setdefault('input_calls', {})[call] = mode
                question = ''
                try:
                    args = p.get('arguments') or p.get('input') or {}
                    args = json.loads(args) if isinstance(args, str) else args
                    questions = args.get('questions', []) if isinstance(args, dict) else []
                    if questions:
                        question = questions[0].get('title') or questions[0].get('question') or ''
                except (ValueError, AttributeError, IndexError, TypeError):
                    pass
                e.update(status="waiting", detail=question or "Agent 有问题需要你回答", input_open={call: mode})
            else:
                e.update(status="running", detail="正在调用 " + name)
        elif kind in ('function_call_output', 'custom_tool_call_output') and p.get('call_id') in context.get('input_calls', {}):
            call = p['call_id']
            mode = context['input_calls'][call]
            output = p.get('output', '')
            try:
                output = json.loads(output) if isinstance(output, str) else output
            except ValueError:
                pass
            if mode == 'async' and isinstance(output, dict) and output.get('accepted') is True:
                return None  # Accepted for display is not an answer.
            context['input_calls'].pop(call, None)
            e.update(status='running', detail='已收到输入结果', input_close=[call])
        elif kind == "message" and p.get("role") == "user":
            txt = text_content(p.get("content", []))
            if '<send_user_message_question_reply>' in txt:
                ids = re.findall(r'call_[A-Za-z0-9_-]+', txt)
                if not ids:
                    ids = list(context.get('input_calls', {}))
                for request_id in ids:
                    context.get('input_calls', {}).pop(request_id, None)
                e.update(status='running', detail='已收到你的回答', input_close=ids)
                return e
            task = user_task_text(txt)
            if not task:
                return None
            e.update(status="running", kind="prompt", text=task, detail="正在处理任务")
        elif kind == "message" and p.get("role") == "assistant":
            e.update(assistant_message=text_content(p.get("content", [])))
        else:
            return None
    else:
        return None
    return e


def claude_record(record, context):
    if record.get("isSidechain") or record.get("agentId"):
        return None
    sid = record.get("sessionId") or record.get("session_id") or context.get("id")
    if not sid:
        return None
    e = {"provider": "claude", "id": sid, "cwd": record.get("cwd") or context.get("cwd", ""),
         "at": record.get("timestamp"), "transcript": context.get("transcript", ""), "passive": True,
         "confidence": "inferred"}
    typ, msg = record.get("type"), record.get("message", {})
    if typ == "user" and isinstance(msg, dict):
        content = msg.get("content", [])
        if isinstance(content, list) and any(c.get("type") == "tool_result" for c in content if isinstance(c, dict)):
            return None
        e.update(status="running", kind="prompt", text=text_content(content), detail="收到新消息 · 等待 Hook 确认状态")
    elif typ == "system" and record.get("subtype") == "turn_duration":
        e.update(status="completed", detail="本轮任务已完成")
    elif typ == "assistant":
        e.update(status="unknown", detail="收到 Agent 回复 · 完成状态待 Hook 确认", assistant_message=text_content(msg.get("content", [])))
    else:
        return None
    return e


def cursor_record(record, context):
    e = {"provider": "cursor", "id": context["id"], "cwd": context.get("cwd", ""),
         "transcript": context.get("transcript", ""), "at": context.get("mtime"),
         "passive": True, "confidence": "inferred"}
    if record.get("role") == "user":
        e.update(status="unknown", kind="prompt", text=text_content(record.get("message", {}).get("content", [])),
                 detail="会话已发现 · 等待 Hook 确认状态")
    elif record.get("type") == "error":
        e.update(status="error", detail="会话记录包含错误")
    elif record.get("role") == "assistant":
        e.update(assistant_message=text_content(record.get("message", {}).get("content", [])))
    else:
        return None
    return e


def hook_event(provider, name, data, env=None, now=None):
    env = env or {}
    # Cursor also executes Claude-compatible hooks. A Claude Code process in a
    # Cursor terminal still has a .claude transcript and must remain Claude.
    transcript = str(data.get("transcript_path") or "").replace("\\", "/")
    if provider == "claude" and ("/.cursor/projects/" in transcript or data.get("cursor_version")):
        provider = "cursor"
    sid = data.get("conversation_id") if provider == "cursor" else data.get("session_id")
    sid = sid or data.get("session_id")
    if not sid or data.get("agent_id") or name.lower().startswith("subagent"):
        return None
    roots = data.get("workspace_roots") or []
    e = {"provider": provider, "id": sid, "at": now or time.time(), "hook": True,
         "cwd": data.get("cwd") or (roots[0] if roots else ""),
         "transcript": data.get("transcript_path", ""),
         "turn": data.get("generation_id") or data.get("turn_id") or "",
         "terminal": {k: env[k] for k in TERMINAL_ENV if env.get(k)}}
    if name in ("beforeSubmitPrompt", "UserPromptSubmit"):
        e.update(status="running", kind="prompt", text=data.get("prompt", ""), detail="正在处理任务")
    elif name in ("stop", "Stop"):
        status = data.get("status", "completed")
        status = {"aborted": "cancelled", "error": "error"}.get(status, "completed")
        e.update(status=status, detail=data.get("last_assistant_message") or {"completed": "本轮任务已完成", "cancelled": "任务已中止", "error": "任务遇到错误"}[status])
        if data.get("last_assistant_message"):
            e["assistant_message"] = data["last_assistant_message"]
    elif name == "StopFailure":
        e.update(status="error", detail=data.get("error_details") or data.get("error") or "任务失败")
    elif name in ("sessionStart", "SessionStart"):
        e.update(status="idle", detail="会话已连接")
    elif name in ("sessionEnd", "SessionEnd"):
        e.update(status="closed", detail="会话已关闭")
    elif name in ("PermissionRequest", "Notification"):
        if name == "Notification" and data.get("notification_type") not in ("permission_prompt", "idle_prompt", "elicitation_dialog"):
            return None
        e.update(status="waiting", detail=data.get("message") or "需要你的确认 · 点击返回会话")
    elif name == "afterAgentResponse":
        # A message can be followed by more work. Only `stop` means completion.
        e.update(detail=data.get("text") or "收到 Agent 回复", assistant_message=data.get("text", ""))
    elif name in ("preToolUse", "PreToolUse", "postToolUse", "PostToolUse", "beforeShellExecution", "beforeMCPExecution"):
        tool = data.get("tool_name", "工具")
        question = tool in ('AskUserQuestion', 'AskQuestion', 'request_user_input')
        before = name in ('preToolUse', 'PreToolUse')
        request_id = data.get('tool_use_id') or 'hook-question'
        e.update(status="waiting" if question and before else "running", detail="等待回答" if question and before else "正在调用 " + tool)
        if question:
            e['input_open' if before else 'input_close'] = {request_id: 'blocking'} if before else [request_id]
    else:
        return None
    return e


def latest_codex_prompt(path, context, max_bytes=8 * 1024 * 1024):
    with Path(path).open('rb') as file:
        end = file.seek(0, 2)
        pos, remaining, carry = end, max_bytes, b''
        while pos > 0 and remaining > 0:
            size = min(pos, remaining, 256 * 1024)
            pos -= size; remaining -= size
            file.seek(pos)
            lines = (file.read(size) + carry).split(b'\n')
            carry = lines.pop(0) if pos else b''
            for line in reversed(lines):
                try:
                    record = json.loads(line)
                    payload = record.get('payload', {})
                    if not isinstance(payload, dict): continue
                    candidate = (record.get('type') == 'response_item' and payload.get('type') == 'message' and payload.get('role') == 'user') or (record.get('type') == 'event_msg' and payload.get('type') == 'user_message')
                    if not candidate: continue
                    event = codex_record(record, {**context, 'input_calls': {}})
                    if event and event.get('kind') == 'prompt' and user_task_text(event.get('text')):
                        event.pop('status', None)
                        event.pop('detail', None)
                        return event
                except (ValueError, UnicodeDecodeError, AttributeError, TypeError):
                    continue
    return None


class Tail:
    """Bounded incremental JSONL reader; partial lines and truncation are safe."""
    def __init__(self, path, window=256 * 1024):
        self.path = Path(path)
        self.offset = 0
        self.inode = None
        self.pending = b""
        self.window = window
        self.initialized = False

    def read(self):
        stat = self.path.stat()
        reset = self.inode != stat.st_ino or stat.st_size < self.offset
        first = not self.initialized
        if reset:
            self.offset, self.pending = 0, b""
            self.inode = stat.st_ino
        with self.path.open("rb") as f:
            if first or reset:
                self.offset = max(0, stat.st_size - self.window)
                f.seek(self.offset)
                if self.offset:
                    f.readline()
                    self.offset = f.tell()
            else:
                f.seek(self.offset)
            data = f.read(1024 * 1024)
            self.offset = f.tell()
        self.initialized = True
        lines = (self.pending + data).split(b"\n")
        self.pending = lines.pop()
        # Malformed or enormous records are ignored, never executed.
        if len(self.pending) > 2 * 1024 * 1024:
            self.pending = b""
        out = []
        for line in lines:
            try:
                d = json.loads(line)
                if isinstance(d, dict):
                    out.append(d)
            except (ValueError, UnicodeDecodeError):
                continue
        return first or reset, out
