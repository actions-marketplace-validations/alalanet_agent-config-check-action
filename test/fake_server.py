"""A fake alalanet and a fake GitHub ID-token endpoint for test.sh (loopback only).

Usage: python3 -I fake_server.py <dir>
  <dir>/responses.json  a list of {"status": int, "headers": {..}, "body": <json or string>}, served in order to
                        POST /v1/repo-config-check (the last one repeats)
  <dir>/port            written once the server listens
  <dir>/req-<n>.json    each request: method, path, headers, body (n from 1 again once test.sh removes them)
  <dir>/served          one line per answer to the check (test.sh removes it with new responses)
"""
import glob
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]
LOCK = threading.Lock()
STATE = {"tokens": 0}


def record(handler, body):
    with LOCK:
        n = len(glob.glob(os.path.join(DIR, "req-*.json"))) + 1
        with open(os.path.join(DIR, "req-%d.json" % n), "w") as f:
            json.dump({"method": handler.command, "path": handler.path,
                       "headers": {k.lower(): v for k, v in handler.headers.items()},
                       "body": body.decode("utf-8", "replace")}, f)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, status, headers, body):
        raw = body if isinstance(body, str) else json.dumps(body)
        raw = raw.encode()
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        record(self, b"")
        if self.path.startswith("/idtoken"):
            with LOCK:
                STATE["tokens"] += 1
                t = STATE["tokens"]
            # a fresh, made-up value for every request (never a real token)
            self.send(200, {}, {"value": "fake" + "-oidc-" + str(t)})
            return
        self.send(404, {}, {"error": "not_found"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        record(self, body)
        if self.path != "/v1/repo-config-check":
            self.send(404, {}, {"error": "not_found"})
            return
        with open(os.path.join(DIR, "responses.json")) as f:
            responses = json.load(f)
        served = os.path.join(DIR, "served")
        with LOCK:
            i = sum(1 for _ in open(served)) if os.path.exists(served) else 0
            with open(served, "a") as f:
                f.write("x\n")
        r = responses[min(i, len(responses) - 1)]
        self.send(r["status"], r.get("headers", {}), r["body"])


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(DIR, "port.tmp"), "w") as f:
    f.write(str(srv.server_address[1]))
os.rename(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
srv.serve_forever()
