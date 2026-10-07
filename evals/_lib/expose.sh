# Shared helpers for expose checks (sourced, not a check). Offline only:
# scratch HOME, PATH shims that log and block every outbound network/privileged
# tool, a fake caddy binary, an unreachable Cloudflare API, and an independent
# fake Caddy admin server on a unix socket. Never a real token, DNS or systemd.
. "$EVAL_ROOT/evals/_lib/install.sh"
mkdir -p "$EVAL_TMP/tmux"; chmod 700 "$EVAL_TMP/tmux"; export TMUX_TMPDIR="$EVAL_TMP/tmux"
unset CLOUDFLARE_API_TOKEN OPSX_CADDY_BIN OPSX_EXPOSE_ADMIN OPSX_EXPOSE_SKIP_VERIFY TMUX TMUX_PANE
export OPSX_CLOUDFLARE_API="http://127.0.0.1:9/client/v4"   # nothing listens there
EXPOSE_SH="$EVAL_ROOT/skills/expose/expose.sh"
CFG_DIR="$XDG_CONFIG_HOME/tmux-opsx"
ENV_FILE="$CFG_DIR/expose.env"
STATE_DIR="$XDG_STATE_HOME/tmux-opsx/expose"
SHIMS="$EVAL_TMP/shims"; SHIM_LOG="$EVAL_TMP/shim.log"; : > "$SHIM_LOG"
export SHIM_LOG REAL_CURL; REAL_CURL=$(command -v curl)
REAL_GETENT=$(command -v getent || echo /usr/bin/getent); export REAL_GETENT
mkdir -p "$SHIMS"
# curl: pass through only unix-socket and 127.0.0.1 calls; log and fail the rest.
cat > "$SHIMS/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$SHIM_LOG"
for a in "$@"; do case $a in --unix-socket|--unix-socket=*|http://127.0.0.1*|http://localhost*) exec "$REAL_CURL" "$@";; esac; done
echo "curl: (7) blocked by eval shim" >&2; exit 7
SH
for t in wget sudo systemctl dig host nslookup launchctl; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$SHIM_LOG"\nexit 1\n' "$t" > "$SHIMS/$t"
done
# getent: name lookups never resolve (offline); passwd etc. go to the real one.
cat > "$SHIMS/getent" <<'SH'
#!/usr/bin/env bash
case ${1:-} in hosts|ahosts|ahostsv4|ahostsv6) printf 'getent %s\n' "$*" >> "$SHIM_LOG"; exit 2;; esac
exec "$REAL_GETENT" "$@"
SH
# fake caddy with the cloudflare DNS module
FAKE_CADDY="$EVAL_TMP/fake-caddy"
cat > "$FAKE_CADDY" <<'SH'
#!/usr/bin/env bash
printf 'caddy %s\n' "$*" >> "$SHIM_LOG"
case ${1:-} in
  list-modules) printf 'http.handlers.reverse_proxy\ntls.issuance.acme\ndns.providers.cloudflare\n';;
  version) echo "v2.8.4 h1:fake";;
esac
exit 0
SH
chmod +x "$SHIMS"/* "$FAKE_CADDY"
export PATH="$SHIMS:$PATH"

# install with expose; extra env can be given as VAR=value before the call.
# install.sh with no terminal (setsid: no controlling tty, stdin /dev/null).
install_nt() {
  ( cd "$EVAL_ROOT" && setsid -w ./install.sh --skip-openspec --skip-graphify --skip-commands \
      --skip-mcp --skip-memory --skip-fork "$@" ) </dev/null 2>&1
}
expose_install() {  # expose_install <domain> [more install args]
  install_nt --expose-domain "$@"
}
SKILL_DIRS="$HOME/.claude/skills $HOME/.cursor/skills $HOME/.agents/skills $HOME/.codex/skills $HOME/.config/opencode/skills $HOME/.gemini/skills"
nothing_installed() {  # fail unless no skill, agent or expose config exists
  local f; f=$(find "$HOME" \( -path '*/skills/*' -o -path '*/agents/*' -o -path '*/tmux-opsx/*' \) 2>/dev/null | head -5)
  [ -z "$f" ] || fail "files were installed: $f"
}
# configure expose for dev.example.com (token t1) the supported way.
configure_expose() {
  local out
  out=$(CLOUDFLARE_API_TOKEN=t1 OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$FAKE_CADDY" \
        expose_install "${1:-dev.example.com}") \
    || { echo "$out" | tail -20; fail "setup: install.sh --expose-domain failed"; }
  [ -f "$ENV_FILE" ] || fail "setup: $ENV_FILE not written"
}
# unix sockets need short paths
SOCK_DIR=$(mktemp -d /tmp/oxe.XXXXXX); chmod 700 "$SOCK_DIR"
export OPSX_EXPOSE_ADMIN="$SOCK_DIR/admin.sock"
ADMIN_PID=""
start_admin() {  # start_admin [initial-config.json]
  python3 -I "$EVAL_ROOT/evals/_lib/fake_caddy_admin.py" "$OPSX_EXPOSE_ADMIN" "${1:-}" >"$EVAL_TMP/admin.log" 2>&1 &
  ADMIN_PID=$!
  local i; for i in $(seq 50); do [ -S "$OPSX_EXPOSE_ADMIN" ] && return 0; sleep 0.1; done
  fail "fake admin server did not start: $(cat "$EVAL_TMP/admin.log")"
}
stop_admin() {
  [ -n "$ADMIN_PID" ] && { kill "$ADMIN_PID" 2>/dev/null; wait "$ADMIN_PID" 2>/dev/null; }
  ADMIN_PID=""; rm -f "$OPSX_EXPOSE_ADMIN"
}
caddy_json() { ls "$CFG_DIR"/*.json 2>/dev/null | head -1; }
_expose_cleanup() { stop_admin; rm -rf "$SOCK_DIR"; }
trap _expose_cleanup EXIT
admin_get() { "$REAL_CURL" -s --unix-socket "$OPSX_EXPOSE_ADMIN" "http://127.0.0.1$1"; }
# routes_to <host> -> prints every upstream dial of routes matching <host>
routes_to() {
  admin_get /config/ | python3 -I -c '
import json,sys
host=sys.argv[1]; cfg=json.load(sys.stdin) or {}
def walk(n,f):
    if isinstance(n,dict):
        f(n); [walk(v,f) for v in n.values()]
    elif isinstance(n,list): [walk(v,f) for v in n]
dials=[]
for s in ((cfg.get("apps") or {}).get("http") or {}).get("servers",{}).values():
    for r in s.get("routes") or []:
        hosts=[h for m in r.get("match") or [] for h in m.get("host") or []]
        if host in hosts:
            walk(r, lambda d: dials.append(d["dial"]) if "dial" in d else None)
            dials.append("ROUTE")
print("\n".join(dials))' "$1"
}
# setsid: no controlling terminal, so OSC 52 can never reach a real /dev/tty
x() { setsid -w "$EXPOSE_SH" "$@"; }
