import json
import os
import socket
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from agent_isle.navigation import editor_jump, request_bridge, process_identity


class NavigationTests(unittest.TestCase):
    def test_real_process_identity_has_own_process(self):
        info = process_identity()
        self.assertIn(str(os.getpid()), info['PROCESS_IDS'].split(','))

    def test_process_lookup_timeout_keeps_local_identity(self):
        import subprocess
        with patch('subprocess.run', side_effect=subprocess.TimeoutExpired('ps', 1)):
            info = process_identity()
        self.assertEqual(info['PROCESS_IDS'].split(',')[0], str(os.getpid()))

    def test_exact_id_roundtrip_and_ambiguous_window_rejection(self):
        # The transport is real Unix IPC, not an invocation-count assertion.
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='isle-nav-') as temp:
            root = Path(temp); bridges = root / 'bridges'; bridges.mkdir(mode=0o700)
            path = bridges / 'c1.sock'
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(path)); server.listen(1)
            seen = []
            def receive():
                conn, _ = server.accept()
                with conn:
                    data = b''
                    while b'\n' not in data:
                        data += conn.recv(4096)
                    request = json.loads(data)
                    seen.append(request)
                    conn.sendall(json.dumps({'ok': True, 'code': 'chat_selected', 'selectedIds': [request['id']]}).encode() + b'\n')
            thread = threading.Thread(target=receive); thread.start()
            entry = {'socket': str(path), 'workspaces': ['/fixture/project']}
            (bridges / 'c1.json').write_text(json.dumps(entry))
            with patch.dict(os.environ, {'AGENT_ISLE_HOME': str(root)}):
                result = editor_jump({'id': 'desired-session', 'cwd': '/fixture/project'})
                self.assertTrue(result['ok'])
                self.assertEqual(result['selectedIds'], ['desired-session'])
                thread.join(2)
                self.assertEqual(seen[0], {'action': 'open-chat', 'id': 'desired-session', 'cwd': '/fixture/project'})
                (bridges / 'c2.json').write_text(json.dumps(entry))
                self.assertEqual(editor_jump({'id': 'desired-session', 'cwd': '/fixture/project'})['code'], 'ambiguous_editor_windows')
                self.assertFalse(editor_jump({'id': 'desired-session', 'cwd': '/fixture/other'})['ok'])
                with self.assertRaises(ValueError):
                    request_bridge({'socket': '/tmp/not-an-agent-isle.sock'}, {'action': 'ping'})
            server.close()


if __name__ == '__main__':
    unittest.main()
