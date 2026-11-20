#!/usr/bin/env python3
"""Exercise the production AI transport against two ephemeral loopback origins."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
from threading import Thread


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.server.bodies.append(json.loads(body))
        self.server.requests.append((self.path, self.headers.get("Cookie"), self.headers.get("Authorization")))
        target = None
        if self.path.startswith("/same/"):
            target = "/target"
        elif self.path.startswith("/other-port/"):
            target = f"http://127.0.0.1:{other.server_port}/forbidden"
        elif self.path.startswith("/other-host/"):
            target = f"http://localhost:{origin.server_port}/forbidden"
        if target:
            self.send_response(307)
            self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        data = json.dumps({"choices": [{"message": {"content": "OK"}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Set-Cookie", "fixture=must-not-return; Path=/")
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    origin = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    other = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    for server in (origin, other):
        server.requests = []
        server.bodies = []
        Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(["swift", "run", "PaperDeskChecks", "--network-privacy",
                        f"http://127.0.0.1:{origin.server_port}"],
                       cwd=Path(__file__).resolve().parents[1], check=True, timeout=120)
        assert not other.requests, "Conversation leaked to another port"
        assert not any(path == "/forbidden" for path, _, _ in origin.requests), "Conversation leaked to another host"
        assert len(origin.requests) == 16, "Missing expected redirect or completion requests"
        assert all(cookie is None for _, cookie, _ in origin.requests), "AI transport persisted cookies"
        assert all(auth == "Bearer fixture-only" for _, _, auth in origin.requests), "Same-origin request lost authorization"
        assert all(body["messages"][-1]["content"] == "Connection test. Reply with only OK."
                   for body in origin.bodies), "Same-origin redirect changed the request body"
        print("PASS  Both HTTP servers confirm no cross-origin traffic or cookie reuse")
    finally:
        for server in (origin, other):
            server.shutdown()
            server.server_close()
