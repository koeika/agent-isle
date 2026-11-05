import copy
import datetime
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from agent_isle.core import Store, Tail, codex_record, hook_event
from agent_isle.integrations import update, MARKER
from agent_isle.monitor import Monitor, atomic_json

REPO = Path(__file__).resolve().parent.parent


class StateTests(unittest.TestCase):
    def setUp(self):
        self.store = Store(clock=lambda: 100)

    def test_lifecycle_dedup_and_distinct_providers(self):
        for provider in ("codex", "cursor", "claude"):
            self.store.apply({"provider": provider, "id": "same", "at": 80, "status": "running"})
            self.store.apply({"provider": provider, "id": "same", "at": 81, "status": "completed"})
            self.store.apply({"provider": provider, "id": "same", "at": 82, "status": "completed"})
        snap = self.store.snapshot()
        self.assertEqual(len(snap["sessions"]), 3)
        self.assertEqual(len(snap["alerts"]), 3)
        self.assertTrue(all(s["status"] == "completed" for s in snap["sessions"]))
        self.assertEqual(self.store.snapshot()["alerts"], [])

    def test_delayed_event_cannot_revive_finished_turn(self):
        self.store.apply({"provider": "codex", "id": "s", "at": 90, "status": "completed"}, quiet=True)
        self.store.apply({"provider": "codex", "id": "s", "at": 85, "status": "running"})
        self.assertEqual(self.store.sessions["codex:s"].status, "completed")
        self.assertEqual(self.store.snapshot()["alerts"], [])

    def test_inactivity_is_unknown_never_success(self):
        store = Store(clock=lambda: 5000)
        store.apply({"provider": "codex", "id": "s", "at": 100, "status": "running"})
        snap = store.snapshot()
        self.assertEqual(snap["sessions"][0]["status"], "unknown")
        self.assertEqual(snap["alerts"], [])

    def test_hook_state_restores_without_alert_or_duplicates(self):
        e = hook_event("cursor", "stop", {"conversation_id": "s", "transcript_path": "/Users/test/.cursor/projects/p/s.jsonl"}, now=90)
        self.store.apply(e)
        rows = self.store.snapshot()["sessions"]
        rows.append({**rows[0], "provider": "claude"})
        restored = Store(clock=lambda: 100)
        restored.restore(rows)
        snap = restored.snapshot()
        self.assertEqual(len(snap["sessions"]), 1)
        self.assertEqual(snap["sessions"][0]["status"], "completed")
        self.assertEqual(snap["alerts"], [])

    def test_next_turn_can_alert_again(self):
        for at, status in enumerate(["running", "completed", "running", "completed"], 90):
            self.store.apply({"provider": "claude", "id": "s", "at": at, "status": status})
        self.assertEqual(len(self.store.snapshot()["alerts"]), 2)

    def test_cli_exit_preserves_completion_result(self):
        for at, status in enumerate(["running", "completed", "closed"], 90):
            self.store.apply({"provider": "claude", "id": "s", "at": at, "status": status})
        session = self.store.sessions["claude:s"]
        self.assertEqual(session.status, "completed")
        self.assertTrue(session.ended)
        self.assertEqual(len(self.store.snapshot()["alerts"]), 1)

    def test_passive_record_cannot_override_hook_state(self):
        e = {"provider": "cursor", "id": "s", "at": 90, "status": "completed", "hook": True}
        self.store.apply(e, quiet=True)
        self.store.apply({**e, "at": 91, "status": "running", "hook": False, "passive": True})
        self.assertEqual(self.store.sessions["cursor:s"].status, "completed")

    def test_transcript_flush_cannot_hide_earlier_stop_callback(self):
        self.store.apply({"provider": "cursor", "id": "s", "at": 95, "status": "unknown", "passive": True, "confidence": "inferred"}, quiet=True)
        self.store.apply({"provider": "cursor", "id": "s", "at": 94, "status": "completed", "hook": True})
        self.assertEqual(self.store.sessions["cursor:s"].status, "completed")
        self.assertEqual(len(self.store.snapshot()["alerts"]), 1)

    def test_async_input_stays_waiting_during_other_tools_until_answer(self):
        context = {"id": "input-thread"}
        records = [
            {"timestamp": 90, "type": "response_item", "payload": {"type": "function_call", "name": "request_user_input_async", "call_id": "call_input_1", "arguments": '{"questions":[{"title":"请选择环境"}]}'}},
            {"timestamp": 91, "type": "response_item", "payload": {"type": "function_call_output", "call_id": "call_input_1", "output": '{"accepted":true}'}},
            {"timestamp": 92, "type": "response_item", "payload": {"type": "function_call", "name": "exec", "call_id": "call_other"}}
        ]
        for record in records:
            event = codex_record(record, context)
            if event:
                self.store.apply(event)
        session = self.store.sessions['codex:input-thread']
        self.assertEqual(session.status, 'waiting')
        self.assertIn('请选择环境', session.detail)
        answer = {"timestamp": 93, "type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": '<send_user_message_question_reply>[{"questionItemId":"[\\"request_user_input_async\\",\\"call_input_1\\",0]","answer":"TEST"}]</send_user_message_question_reply>'}]}}
        resolved = codex_record(answer, context)
        self.assertIsNotNone(resolved)
        self.store.apply(resolved)
        self.assertEqual(session.status, 'running')
        self.assertEqual(session.pending_inputs, {})

    def test_second_pending_question_alerts_and_answer_only_closes_matching_one(self):
        for at, cid in [(90, 'call_first'), (91, 'call_second')]:
            self.store.apply({'provider': 'codex', 'id': 's', 'at': at, 'status': 'waiting', 'input_open': {cid: 'async'}})
        self.assertEqual(len(self.store.snapshot()['alerts']), 2)
        self.store.apply({'provider': 'codex', 'id': 's', 'at': 92, 'status': 'running', 'input_close': ['call_first']})
        self.assertEqual(self.store.sessions['codex:s'].status, 'waiting')
        self.store.apply({'provider': 'codex', 'id': 's', 'at': 93, 'status': 'completed'})
        self.assertEqual(self.store.sessions['codex:s'].pending_inputs, {})

    def test_child_completion_is_not_root_completion(self):
        result = codex_record({"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "child", "root_turn_id": "parent"}}, {"id": "s"})
        self.assertIsNone(result)
        child = {}
        codex_record({"type": "session_meta", "payload": {"id": "child", "source": {"subagent": {"thread_spawn": {}}}}}, child)
        self.assertTrue(child["hidden"])
        self.assertIsNone(codex_record({"type": "event_msg", "payload": {"type": "task_complete"}}, child))

    def test_external_triage_displays_latest_reply_and_semantic_title(self):
        context = {"id": "external-triage", "cwd": "/fixture/triage", "origin": "External bridge"}
        raw = json.dumps({"kind": "needs_info", "summary": "help check 缺少具体异常场景", "reply": "请补充需要检查的问题"}, ensure_ascii=False)
        event = codex_record({"timestamp": 95, "type": "event_msg", "payload": {"type": "task_complete", "turn_id": "t", "root_turn_id": "t", "last_agent_message": raw}}, context)
        self.store.apply(event, quiet=True)
        s = self.store.sessions["codex:external-triage"]
        self.assertEqual(s.assistant_message, raw)
        self.assertEqual(s.summary, "help check 缺少具体异常场景")
        self.assertEqual(s.title, "help check 缺少具体异常场景")

    def test_assistant_message_enriches_content_without_false_completion(self):
        context = {"id": "s"}
        self.store.apply({"provider": "codex", "id": "s", "at": 90, "status": "running"})
        e = codex_record({"timestamp": 91, "type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "commentary", "content": [{"type": "output_text", "text": "正在调查"}]}}, context)
        self.assertIsNotNone(e)
        self.store.apply(e)
        self.assertEqual(self.store.sessions["codex:s"].assistant_message, "正在调查")
        self.assertEqual(self.store.sessions["codex:s"].status, "running")

    def test_cursor_message_is_not_completion_and_stop_is(self):
        e = hook_event("cursor", "afterAgentResponse", {"conversation_id": "s", "text": "reply"}, now=90)
        self.assertNotIn("status", e)
        self.assertEqual(hook_event("cursor", "stop", {"conversation_id": "s", "status": "completed"})["status"], "completed")
        self.assertEqual(hook_event("cursor", "stop", {"conversation_id": "s", "status": "aborted"})["status"], "cancelled")
        self.assertEqual(hook_event("cursor", "stop", {"conversation_id": "s", "status": "error"})["status"], "error")
        self.assertIsNone(hook_event("cursor", "stop", {"conversation_id": ""}))

    def test_claude_permission_and_child_events(self):
        self.assertEqual(hook_event("claude", "PermissionRequest", {"session_id": "s"})["status"], "waiting")
        self.assertIsNone(hook_event("claude", "SubagentStop", {"session_id": "s"}))
        self.assertIsNone(hook_event("claude", "Notification", {"session_id": "s", "notification_type": "auth_success"}))

    def test_cursor_claude_compatibility_hook_is_one_session(self):
        payload = {"session_id": "s", "conversation_id": "s", "transcript_path": "/Users/test/.cursor/projects/p/agent-transcripts/s/s.jsonl"}
        native = hook_event("cursor", "stop", payload, now=90)
        compatible = hook_event("claude", "Stop", payload, now=91)
        self.store.apply(native)
        self.store.apply(compatible)
        snap = self.store.snapshot()
        self.assertEqual(len(snap["sessions"]), 1)
        self.assertEqual(len(snap["alerts"]), 1)
        self.assertEqual(snap["sessions"][0]["provider"], "cursor")
        actual_claude = hook_event("claude", "Stop", {"session_id": "other", "transcript_path": "/Users/test/.claude/projects/p/other.jsonl"}, {"__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"})
        self.assertEqual(actual_claude["provider"], "claude")


class DiskTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_tail_partial_truncation_and_rotation(self):
        path = self.root / "log.jsonl"
        path.write_bytes(b'{"a":1}\n{"a":')
        tail = Tail(path)
        self.assertEqual(tail.read(), (True, [{"a": 1}]))
        with path.open("ab") as f:
            f.write(b'2}\n')
        self.assertEqual(tail.read(), (False, [{"a": 2}]))
        path.write_text('{"b":3}\n')
        self.assertEqual(tail.read(), (True, [{"b": 3}]))
        replacement = self.root / "new.jsonl"
        replacement.write_text('{"c":4}\n')
        os.replace(replacement, path)
        self.assertEqual(tail.read(), (True, [{"c": 4}]))

    def test_registration_preserves_existing_and_is_reversible(self):
        for provider in ("cursor", "claude"):
            path = self.root / provider / "settings.json"
            path.parent.mkdir()
            original = {"unrelated": {"keep": 1}, "hooks": {"stop": [{"command": "existing-script"}]}}
            path.write_text(json.dumps(original))
            with patch.dict(os.environ, {"AGENT_ISLE_HOME": str(self.root / "state")}):
                result = update(path, provider, REPO / "agent_isle/monitor.py")
                self.assertTrue(result["changed"])
                installed = json.loads(path.read_text())
                self.assertIn(original["hooks"]["stop"][0], installed["hooks"]["stop"])
                self.assertEqual(installed["unrelated"], original["unrelated"])
                self.assertFalse(update(path, provider, REPO / "agent_isle/monitor.py")["changed"])
                update(path, provider, REPO / "agent_isle/monitor.py", remove=True)
                self.assertEqual(json.loads(path.read_text()), original)
                self.assertTrue(list((self.root / "state/backups").glob(provider + "-*.json")))

    def test_malformed_configuration_is_not_overwritten(self):
        path = self.root / "settings.json"
        path.write_text("{invalid")
        with self.assertRaises(ValueError):
            update(path, "claude", REPO / "agent_isle/monitor.py")
        self.assertEqual(path.read_text(), "{invalid")

    def test_hook_subprocess_to_real_monitor_spool(self):
        state = self.root / "state"
        atomic_json(state / "preferences.json", {"enabledProviders": ["codex", "cursor", "claude"]})
        monitor = Monitor(self.root / "home", state)
        env = {**os.environ, "AGENT_ISLE_HOME": str(state)}
        for provider, start, stop in [("cursor", "beforeSubmitPrompt", "stop"), ("claude", "UserPromptSubmit", "Stop")]:
            sid = provider + "-integration"
            payload = {"conversation_id": sid, "session_id": sid, "cwd": str(self.root), "prompt": "fixture task"}
            for event, expected in [(start, "running"), (stop, "completed")]:
                result = subprocess.run([sys.executable, str(REPO / "agent_isle/monitor.py"), "hook", "--provider", provider, "--event", event], input=json.dumps(payload), text=True, capture_output=True, env=env, check=True)
                self.assertEqual(json.loads(result.stdout), {})
                snap = monitor.step()
                session = next(s for s in snap["sessions"] if s["id"] == sid)
                self.assertEqual(session["status"], expected)
                if expected == "completed":
                    self.assertEqual(len(snap["alerts"]), 1)
        self.assertEqual(list((state / "events").glob("*.json")), [])

    def test_real_file_append_startup_silence_and_completion(self):
        path = self.root / "rollout.jsonl"
        def record(kind, **kwargs):
            return {"timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(), "type": "event_msg", "payload": {"type": kind, **kwargs}}
        meta = {"type": "session_meta", "payload": {"id": "real-file", "cwd": str(self.root), "originator": "Codex Desktop"}}
        path.write_text("\n".join(json.dumps(v) for v in [meta, record("task_started", turn_id="old"), record("task_complete", turn_id="old")]) + "\n")
        monitor = Monitor(self.root / "home", self.root / "state")
        monitor.add(path, "codex")
        snap = monitor.step()
        self.assertEqual(snap["sessions"][0]["status"], "completed")
        self.assertEqual(snap["alerts"], [])
        for event in [record("task_started", turn_id="new"), record("task_complete", turn_id="new")]:
            with path.open("a") as f:
                f.write(json.dumps(event) + "\n")
            snap = monitor.step()
        self.assertEqual(snap["sessions"][0]["status"], "completed")
        self.assertEqual(len(snap["alerts"]), 1)

    def test_unindexed_cli_and_archived_sessions_are_discovered(self):
        home = self.root / "home"
        codex = home / ".codex"
        folder = codex / "sessions" / datetime.date.today().strftime("%Y/%m/%d")
        archives = codex / "archived_sessions"
        for sid, parent in [("external-cli", folder), ("archived-cli", archives)]:
            parent.mkdir(parents=True, exist_ok=True)
            records = [{"type": "session_meta", "payload": {"id": sid, "source": "exec", "cwd": "/fixture/external"}},
                       {"timestamp": time.time(), "type": "event_msg", "payload": {"type": "task_complete", "last_agent_message": "External completed"}}]
            (parent / (sid + ".jsonl")).write_text("\n".join(json.dumps(r) for r in records) + "\n")
        with patch.dict(os.environ, {"CODEX_HOME": str(codex)}):
            snap = Monitor(home, self.root / "state").step()
        rows = {s["id"]: s for s in snap["sessions"]}
        self.assertEqual(set(rows), {"external-cli", "archived-cli"})
        self.assertTrue(rows["archived-cli"]["archived"])
        self.assertEqual(rows["external-cli"]["assistant_message"], "External completed")
        self.assertEqual(snap["alerts"], [])


if __name__ == "__main__":
    unittest.main()
