import http.client
import json
import tempfile
import threading
import unittest
from pathlib import Path
from agent_isle.guide import create_server

ROOT = Path(__file__).resolve().parent.parent

class GuideTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        (self.home / '.codex').mkdir()
        (self.home / '.cursor').mkdir()
        (self.home / '.cursor/hooks.json').write_text('{"marker":"agent-isle-owned"}')
        (self.home / 'private.txt').write_text('DO_NOT_SERVE_THIS')
        self.server = create_server(ROOT / 'web/guide', self.home)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(2)
        self.temp.cleanup()
    def request(self, path, method='GET', headers=None):
        client = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
        client.request(method, path, headers=headers or {})
        response = client.getresponse()
        result = response.status, dict(response.headers), response.read()
        client.close()
        return result
    def test_real_assets_status_and_minimal_readonly_data(self):
        for path, mime in [('/', 'text/html'),('/guide.css','text/css'),('/guide.js','text/javascript'),('/buddy.svg','image/svg+xml')]:
            code, headers, body = self.request(path)
            self.assertEqual(code,200)
            self.assertIn(mime,headers['Content-Type'])
            self.assertEqual(headers['Cache-Control'],'no-store')
            self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])
            self.assertGreater(len(body),100)
        code, headers, body = self.request('/api/status')
        data=json.loads(body)
        self.assertTrue(data['tools']['Codex'])
        self.assertTrue(data['hooks']['Cursor'])
        self.assertFalse(data['hooks']['Claude Code'])
        self.assertEqual(set(data),{'version','tools','hooks'})
        self.assertNotIn(str(self.home).encode(),body)
        self.assertNotIn('Access-Control-Allow-Origin',headers)
        self.assertEqual(self.server.server_address[0],'127.0.0.1')
    def test_host_validation_traversal_and_write_rejection(self):
        self.assertEqual(self.request('/',headers={'Host':'malicious.example'})[0],403)
        self.assertEqual(self.request('/api/status',headers={'Host':'localhost'})[0],403)
        for path in ['/../private.txt','/%2e%2e/private.txt','/private.txt','/api/install','/api/settings']:
            code, _, body=self.request(path)
            self.assertEqual(code,404)
            self.assertNotIn(b'DO_NOT_SERVE_THIS',body)
        self.assertEqual(self.request('/api/status',method='POST')[0],501)
        self.assertEqual((self.home/'.cursor/hooks.json').read_text(),'{"marker":"agent-isle-owned"}')

if __name__=='__main__': unittest.main()
