"""Read-only onboarding server. No conversation data or configuration writes."""
import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ASSETS = {"/": ("index.html", "text/html; charset=utf-8"), "/guide.css": ("guide.css", "text/css; charset=utf-8"), "/guide.js": ("guide.js", "text/javascript; charset=utf-8"), "/buddy.svg": ("buddy.svg", "image/svg+xml")}


def create_server(assets, home=None, version="0.5.3"):
    assets, home = Path(assets), Path(home or Path.home())
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            if self.headers.get("Host") != "127.0.0.1:%d" % self.server.server_port:
                self.send_error(403); return
            path = urlsplit(self.path).path
            if path == "/api/status":
                hooks = {}
                for name, file in (("Cursor", home / ".cursor/hooks.json"), ("Claude Code", home / ".claude/settings.json")):
                    try:
                        hooks[name] = "agent-isle-owned" in file.read_text()
                    except (OSError, UnicodeError):
                        hooks[name] = False
                body = json.dumps({"version": version, "tools": {"Codex": (home / ".codex").exists(), "Cursor": (home / ".cursor").exists(), "Claude Code": (home / ".claude").exists()}, "hooks": hooks}).encode()
                mime = "application/json; charset=utf-8"
            elif path in ASSETS:
                filename, mime = ASSETS[path]
                try:
                    body = (assets / filename).read_bytes()
                except OSError:
                    self.send_error(404); return
            else:
                self.send_error(404); return
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    return server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--version", default="0.5.3")
    args = parser.parse_args()
    server = create_server(args.assets, version=args.version)
    print(json.dumps({"url": "http://127.0.0.1:%d/" % server.server_port}), flush=True)
    server.serve_forever(poll_interval=0.25)


if __name__ == "__main__":
    main()
