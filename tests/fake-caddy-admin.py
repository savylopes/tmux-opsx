#!/usr/bin/env python3
"""Fake Caddy admin API on a unix socket, for tests of skills/expose/expose.sh.

Usage: python3 tests/fake-caddy-admin.py <socket-path> [config.json]

Keeps the config in memory (no autosave, so a restart loses every route, like
Caddy without --resume). Supports the subset of the admin API expose.sh uses:
  GET    /config/<path>   read a value (null when the leaf key is missing)
  POST   /config/<path>   append to an array, or set a missing/object key
  DELETE /config/<path>   remove a key or array item
  GET    /id/<id>         read the object whose "@id" is <id>
  DELETE /id/<id>         remove the object whose "@id" is <id>
  POST   /load            replace the whole config (like `caddy reload`)
Like Caddy, a change that would leave two objects with the same "@id" is
refused with HTTP 400 and the config is left as it was. Requests are handled
one at a time, as Caddy serialises config changes.
Like Caddy on a unix socket, only Host 127.0.0.1, ::1 or "" is accepted.

Note: evals/_lib/fake_caddy_admin.py is a separate fake owned by ops-eval (the
eval suite must not depend on test code, and tests must not depend on evals/).
The two overlap on purpose and are kept independent; change this one for
tests/test-expose.sh only, and never edit the evals copy from here.
"""
import copy
import json
import os
import socketserver
import sys
import threading
from http.server import BaseHTTPRequestHandler

DEFAULT = {"apps": {"http": {"servers": {"expose": {"listen": [":443"], "routes": []}}}}}


class NotFound(Exception):
    pass


def split(path):
    return [p for p in path.split("/") if p]


def traverse(root, parts):
    """Return (parent, key) for the last part; raise NotFound on a bad path."""
    cur = root
    for p in parts[:-1]:
        if isinstance(cur, dict) and p in cur:
            cur = cur[p]
        elif isinstance(cur, list) and p.isdigit() and int(p) < len(cur):
            cur = cur[int(p)]
        else:
            raise NotFound(p)
    return cur, parts[-1]


def ids(node, out=None):
    out = [] if out is None else out
    if isinstance(node, dict):
        if "@id" in node:
            out.append(node["@id"])
        for v in node.values():
            ids(v, out)
    elif isinstance(node, list):
        for v in node:
            ids(v, out)
    return out


def duplicate_id(cfg):
    seen = set()
    for i in ids(cfg):
        if i in seen:
            return i
        seen.add(i)
    return None


LOCK = threading.Lock()


def find_id(node, ident, parent=None, key=None):
    if isinstance(node, dict):
        if node.get("@id") == ident:
            return parent, key
        for k, v in node.items():
            r = find_id(v, ident, node, k)
            if r:
                return r
    elif isinstance(node, list):
        for i, v in enumerate(node):
            r = find_id(v, ident, node, i)
            if r:
                return r
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def address_string(self):
        return "unix"

    def reply(self, code, obj=None):
        body = b"" if obj is None and code != 200 else (json.dumps(obj) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        return json.loads(raw) if raw.strip() else None

    def check_host(self):
        host = (self.headers.get("Host") or "").split(":")[0].strip("[]")
        if host not in ("", "127.0.0.1", "::1"):
            self.reply(403, {"error": "host not allowed: " + host})
            return False
        return True

    def handle_any(self, method):
        if not self.check_host():
            return
        with LOCK:
            before = copy.deepcopy(self.server.config)
            code = self.handle_locked(method)
            dup = duplicate_id(self.server.config) if method == "POST" else None
            if dup is not None:
                self.server.config = before
                return self.reply(400, {"error": "duplicate ID '%s' found" % dup})
            self.reply(*code)

    def handle_locked(self, method):
        """Apply the request; return (code, body) for handle_any to send."""
        cfg = self.server.config
        if method == "POST" and self.path.split("?")[0].rstrip("/") == "/load":
            try:
                self.server.config = self.body()
            except ValueError as e:
                return 400, {"error": str(e)}
            return 200, None
        parts = split(self.path.split("?")[0])
        try:
            if parts and parts[0] == "id" and len(parts) >= 2:
                found = find_id(cfg, parts[1])
                if not found:
                    return 404, {"error": "unknown object ID '%s'" % parts[1]}
                parent, key = found
                if method == "GET":
                    return 200, parent[key]
                if method == "DELETE":
                    del parent[key]
                    return 200, None
                return 405, {"error": "method not allowed"}
            if not parts or parts[0] != "config":
                return 404, {"error": "not found"}
            parts = parts[1:]
            if method == "GET":
                if not parts:
                    return 200, cfg
                parent, key = traverse(cfg, parts)
                if isinstance(parent, dict):
                    return 200, parent.get(key)
                return 200, parent[int(key)]
            if method == "POST":
                val = self.body()
                if not parts:
                    self.server.config = val
                    return 200, None
                extend = parts[-1] == "..."
                if extend:
                    parts = parts[:-1]
                parent, key = traverse(cfg, parts)
                target = parent.get(key) if isinstance(parent, dict) else parent[int(key)]
                if isinstance(target, list):
                    if extend:
                        target.extend(val)
                    else:
                        target.append(val)
                elif isinstance(parent, dict):
                    parent[key] = val
                else:
                    parent[int(key)] = val
                return 200, None
            if method == "DELETE":
                parent, key = traverse(cfg, parts)
                if isinstance(parent, dict):
                    if key not in parent:
                        raise NotFound(key)
                    del parent[key]
                else:
                    del parent[int(key)]
                return 200, None
            return 405, {"error": "method not allowed"}
        except NotFound as e:
            return 404, {"error": "invalid traversal path at: %s" % e}
        except (ValueError, IndexError, KeyError) as e:
            return 400, {"error": str(e)}

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sock = sys.argv[1]
    if os.path.exists(sock):
        os.unlink(sock)
    srv = Server(sock, Handler)
    if len(sys.argv) > 2:
        with open(sys.argv[2]) as f:
            srv.config = json.load(f)
    else:
        srv.config = json.loads(json.dumps(DEFAULT))
    try:
        srv.serve_forever()
    finally:
        try:
            os.unlink(sock)
        except OSError:
            pass


if __name__ == "__main__":
    main()
