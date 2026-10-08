#!/usr/bin/env python3
# internal-hybrid-builds — static server + save relay + pad-input relay.
# Serves the repo: /games/<name>.html, / (dashboard), /pad (phone controller).
# API:  GET  /api/saves                 -> all save data
#       POST /api/save?game=<id>        -> merge save json
#       GET  /api/input?sid=X&since=N   -> {n, ev:[...]} pad events since N
#       POST /api/input?sid=X           -> queue a pad event {type,...}
import json, os, threading
from urllib.parse import urlparse, parse_qs
from http.server import HTTPServer, SimpleHTTPRequestHandler

ROOT = os.path.dirname(os.path.abspath(__file__))
SAVES = os.path.join(ROOT, "saves.json")
if not os.path.exists(SAVES):
    open(SAVES, "w").write("{}")

inputs = {}            # sid -> list of events
lock = threading.Lock()

class H(SimpleHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/saves":
            return self._json(200, json.load(open(SAVES)))
        if path == "/api/input":
            q = parse_qs(urlparse(self.path).query)
            sid = q.get("sid", ["main"])[0]
            since = int(q.get("since", ["0"])[0])
            with lock:
                ev = inputs.setdefault(sid, [])
                return self._json(200, {"n": len(ev), "ev": ev[since:]})
        return super().do_GET()

    def do_POST(self):
        path = urlparse(self.path).path
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if path == "/api/save":
            game = parse_qs(urlparse(self.path).query).get("game", ["?"])[0]
            try:
                data = json.loads(body)
                s = json.load(open(SAVES))
                s.setdefault(game, {}).update(data)
                open(SAVES, "w").write(json.dumps(s))
                return self._json(200, {"ok": True})
            except Exception as e:
                return self._json(400, {"err": str(e)})
        if path == "/api/input":
            sid = parse_qs(urlparse(self.path).query).get("sid", ["main"])[0]
            try:
                with lock:
                    inputs.setdefault(sid, []).append(json.loads(body))
                return self._json(200, {"ok": True})
            except Exception as e:
                return self._json(400, {"err": str(e)})
        return self._json(404, {"err": "no route"})

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

os.chdir(ROOT)
srv = HTTPServer(("0.0.0.0", 8732), H)
print("internal-hybrid-builds serving on :8732")
srv.serve_forever()
