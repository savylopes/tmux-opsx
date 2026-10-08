#!/usr/bin/env python3
"""Independent fake of Caddy's admin API on a unix socket (written by ops-eval,
not shared with the product tests). Models the documented Caddy admin API:

  GET    /config/<path>          value at path (null for a missing leaf)
  POST   /config/<path>          append to an array (path/... expands), or set a key
  PUT    /config/<path>          insert into an array at index / create a new key
  PATCH  /config/<path>          replace an existing value
  DELETE /config/<path>          delete
  *      /id/<id>[/<path>]       same, on the object whose "@id" is <id>

Like real Caddy: request bodies must have a JSON Content-Type, and a config with
a duplicate "@id" is rejected. Initial config: argv[2] (JSON file) minus "admin",
else an empty expose server. No autosave: a restart drops every added route.

Usage: fake_caddy_admin.py <socket> [initial-config.json]
"""
import json, os, socketserver, sys
from http.server import BaseHTTPRequestHandler

sock = sys.argv[1]
if len(sys.argv) > 2 and os.path.exists(sys.argv[2]):
    CONFIG = json.load(open(sys.argv[2]))
    CONFIG.pop("admin", None)
else:
    CONFIG = {"apps": {"http": {"servers": {"expose": {"listen": [":443"], "routes": []}}}}}


class Err(Exception):
    def __init__(self, code, msg):
        self.code, self.msg = code, msg


def find_id(node, ident, path):
    if isinstance(node, dict):
        if node.get("@id") == ident:
            return path
        items = node.items()
    elif isinstance(node, list):
        items = ((str(i), v) for i, v in enumerate(node))
    else:
        return None
    for k, v in items:
        r = find_id(v, ident, path + [k])
        if r is not None:
            return r
    return None


def ids(node, acc):
    if isinstance(node, dict):
        if "@id" in node:
            acc.append(node["@id"])
        for v in node.values():
            ids(v, acc)
    elif isinstance(node, list):
        for v in node:
            ids(v, acc)
    return acc


def step(cur, p):
    if isinstance(cur, dict):
        if p not in cur:
            raise Err(400, "invalid traversal path at: " + p)
        return cur[p]
    if isinstance(cur, list):
        if not p.isdigit() or int(p) >= len(cur):
            raise Err(400, "invalid traversal path at: " + p)
        return cur[int(p)]
    raise Err(400, "invalid traversal path at: " + p)


def mutate(method, parts, body):
    global CONFIG
    root = {"config": CONFIG}
    parts = ["config"] + parts
    expand = parts[-1] == "..."
    if expand:
        parts = parts[:-1]
    cur = root
    for p in parts[:-1]:
        cur = step(cur, p)
    key = parts[-1]
    if method == "GET":
        if isinstance(cur, dict):
            return cur.get(key)
        return step(cur, key)
    if isinstance(cur, dict):
        exists = key in cur
        if method == "POST":
            if exists and isinstance(cur[key], list):
                if expand:
                    cur[key].extend(body)
                else:
                    cur[key].append(body)
            else:
                cur[key] = body
        elif method == "PUT":
            if exists:
                raise Err(409, "key already exists: " + key)
            cur[key] = body
        elif method == "PATCH":
            if not exists:
                raise Err(404, "key does not exist: " + key)
            cur[key] = body
        elif method == "DELETE":
            if not exists:
                raise Err(404, "key does not exist: " + key)
            del cur[key]
    elif isinstance(cur, list):
        if not key.isdigit():
            raise Err(400, "invalid array index: " + key)
        i = int(key)
        if method == "POST":
            target = step(cur, key)
            if isinstance(target, list):
                target.extend(body) if expand else target.append(body)
            else:
                raise Err(400, "cannot POST to non-array element")
        elif method == "PUT":
            if i > len(cur):
                raise Err(400, "index out of bounds")
            cur.insert(i, body)
        elif method == "PATCH":
            step(cur, key)
            cur[i] = body
        elif method == "DELETE":
            step(cur, key)
            del cur[i]
    else:
        raise Err(400, "invalid traversal path")
    CONFIG = root.get("config")
    return None


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        data = (json.dumps(obj) + "\n").encode() if obj is not ... else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        global CONFIG
        try:
            path = self.path.split("?")[0]
            body = None
            if method in ("POST", "PUT", "PATCH"):
                ct = self.headers.get("Content-Type", "")
                if "/json" not in ct:
                    raise Err(400, "unacceptable content-type: %s; 'application/json' required" % ct)
                n = int(self.headers.get("Content-Length") or 0)
                try:
                    body = json.loads(self.rfile.read(n) or b"null")
                except ValueError as e:
                    raise Err(400, "decoding request body: %s" % e)
            parts = [p for p in path.split("/") if p]
            if parts[:1] == ["config"]:
                parts = parts[1:]
            elif parts[:1] == ["id"] and len(parts) >= 2:
                p = find_id(CONFIG, parts[1], [])
                if p is None:
                    raise Err(404, "unknown object ID '%s'" % parts[1])
                parts = p + parts[2:]
            else:
                raise Err(404, "not found")
            backup = json.dumps(CONFIG)
            if not parts:
                if method == "GET":
                    return self.reply(200, CONFIG)
                if method in ("POST", "PATCH", "PUT"):
                    CONFIG = body
                elif method == "DELETE":
                    CONFIG = None
                return self.reply(200, ...)
            out = mutate(method, parts, body)
            if method != "GET":
                all_ids = ids(CONFIG, [])
                dup = {i for i in all_ids if all_ids.count(i) > 1}
                if dup:
                    CONFIG = json.loads(backup)
                    raise Err(400, "duplicate ID '%s' found" % sorted(dup)[0])
                return self.reply(200, ...)
            return self.reply(200, out)
        except Err as e:
            self.reply(e.code, {"error": e.msg})

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_PUT(self): self.handle_any("PUT")
    def do_PATCH(self): self.handle_any("PATCH")
    def do_DELETE(self): self.handle_any("DELETE")


class S(socketserver.UnixStreamServer):
    allow_reuse_address = True

    def get_request(self):
        req, _ = super().get_request()
        return req, ("local", 0)


if os.path.exists(sock):
    os.unlink(sock)
srv = S(sock, H)
try:
    srv.serve_forever()
finally:
    try:
        os.unlink(sock)
    except OSError:
        pass
