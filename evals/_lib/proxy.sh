# Real-request helpers for expose-access checks (sourced after _lib/expose.sh,
# not a check). Runs a scratch Caddy — the real binary, never the user's
# running proxy or config — with the installed caddy.json minus TLS: admin on
# the check's own unix socket, the `expose` server on a free 127.0.0.1 port in
# plain HTTP. Requests carry the exposure's hostname in the Host header.
# Exits 77 when no caddy binary with http.matchers.expression is available.
#   OPSX_EVAL_CADDY=<path>  use that binary (else caddy on PATH, else the
#                           tmux-opsx install location under the real home)
_real_home=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)
CADDY_BIN=""
for c in "${OPSX_EVAL_CADDY:-}" "$(command -v caddy 2>/dev/null)" "$_real_home/.local/share/tmux-opsx/bin/caddy"; do
  [ -n "$c" ] && [ -x "$c" ] && { CADDY_BIN=$c; break; }
done
[ -n "$CADDY_BIN" ] || { echo "UNVERIFIABLE: no caddy binary (set OPSX_EVAL_CADDY)"; exit 77; }
"$CADDY_BIN" list-modules 2>/dev/null | grep -qx http.matchers.expression \
  || { echo "UNVERIFIABLE: $CADDY_BIN lacks http.matchers.expression"; exit 77; }
DOMAIN=dev.example.com
free_port() { python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
PROXY_PORT=$(free_port)
CADDY_PID=""
APP_PIDS=""
start_caddy() {  # start_caddy: scratch Caddy built from the installed caddy.json
  local src cfg; src=$(caddy_json); cfg="$EVAL_TMP/scratch-caddy.json"
  [ -f "$src" ] || fail "setup: no installed caddy.json"
  python3 -I - "$src" "$cfg" "$OPSX_EXPOSE_ADMIN" "$PROXY_PORT" <<'PY' || fail "setup: cannot derive scratch caddy config"
import json, sys
src, dst, sock, port = sys.argv[1:]
c = json.load(open(src))
c["admin"] = {"listen": "unix/" + sock}
c.get("apps", {}).pop("tls", None)
s = c["apps"]["http"]["servers"]["expose"]
s["listen"] = ["127.0.0.1:%s" % port]
s.pop("tls_connection_policies", None)
s["automatic_https"] = {"disable": True}
json.dump(c, open(dst, "w"))
PY
  mkdir -p "$EVAL_TMP/caddy-home"
  HOME="$EVAL_TMP/caddy-home" XDG_CONFIG_HOME="$EVAL_TMP/caddy-home/c" XDG_DATA_HOME="$EVAL_TMP/caddy-home/d" \
    "$CADDY_BIN" run --config "$cfg" >"$EVAL_TMP/caddy.log" 2>&1 &
  CADDY_PID=$!
  local i; for i in $(seq 100); do
    [ -S "$OPSX_EXPOSE_ADMIN" ] && (exec 3<>"/dev/tcp/127.0.0.1/$PROXY_PORT") 2>/dev/null && return 0
    kill -0 "$CADDY_PID" 2>/dev/null || break; sleep 0.1
  done
  fail "scratch caddy did not start: $(tail -5 "$EVAL_TMP/caddy.log")"
}
stop_caddy() {
  [ -n "$CADDY_PID" ] && { kill "$CADDY_PID" 2>/dev/null; wait "$CADDY_PID" 2>/dev/null; }
  CADDY_PID=""; rm -f "$OPSX_EXPOSE_ADMIN"
}
# start_app <tag> -> sets APP_PORT; a 127.0.0.1-only app that answers "app:<tag>"
# and logs "<path>\t<Cookie header>" per request to $EVAL_TMP/app-<tag>.log
start_app() {
  local tag=$1 port; port=${2:-$(free_port)}; : > "$EVAL_TMP/app-$tag.log"
  python3 -I -c '
import sys, http.server
port, tag, log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(log, "a") as f: f.write("%s\t%s\n" % (self.path, self.headers.get("Cookie", "<none>")))
        b = ("app:" + tag).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()' "$port" "$tag" "$EVAL_TMP/app-$tag.log" &
  APP_PIDS="$APP_PIDS $!"; APP_PORT=$port
  local i; for i in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0; sleep 0.1; done
  fail "setup: app $tag did not start"
}
app_hits() { awk 'END{print NR}' "$EVAL_TMP/app-$1.log" 2>/dev/null || echo 0; }
# req <host-label> <path> [curl args...] -> sets CODE, HDRS (response headers), BODY
req() {
  local h=$1 p=$2; shift 2
  HDRS=$("$REAL_CURL" -s -m 10 -o "$EVAL_TMP/body" -D - -H "Host: $h.$DOMAIN" "$@" "http://127.0.0.1:$PROXY_PORT$p")
  BODY=$(cat "$EVAL_TMP/body" 2>/dev/null); CODE=$(printf '%s\n' "$HDRS" | awk 'NR==1{print $2}')
}
set_cookies() { printf '%s\n' "$HDRS" | tr -d '\r' | grep -i '^set-cookie:'; }
owner_key() { cat "$CFG_DIR/expose.key" 2>/dev/null; }
_proxy_cleanup() { local p; for p in $APP_PIDS; do kill "$p" 2>/dev/null; done; stop_caddy; _expose_cleanup; }
trap _proxy_cleanup EXIT
# proxy_setup: install expose, start the scratch caddy, cd into project `shop`
proxy_setup() {
  configure_expose; start_caddy; export OPSX_EXPOSE_NO_COPY=1
  mkdir -p "$EVAL_TMP/shop"; cd "$EVAL_TMP/shop" || exit 1
}
