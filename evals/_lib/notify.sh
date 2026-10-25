# Shared helpers for mobile-notify checks (sourced, not a check). Offline only:
# scratch HOME, a recording fake curl (never a real push), a stateful fake ntfy
# binary, a private tmux server (-L), and PATH shims for sudo/systemctl.
. "$EVAL_ROOT/evals/_lib/expose.sh"     # scratch HOME, fake caddy, install_nt, shims
NOTIFY_SH="$EVAL_ROOT/skills/opsx-run/opsx-notify.sh"
WINSH="$EVAL_ROOT/skills/opsx-run/opsx-window.sh"
PRSH="$EVAL_ROOT/skills/opsx-pr/pr.sh"
NOTIFY_ENV="$XDG_CONFIG_HOME/tmux-opsx/notify.env"
CURL_DIR="$EVAL_TMP/curl-calls"; mkdir -p "$CURL_DIR"; export CURL_DIR
FAKE_NTFY_STATE="$EVAL_TMP/ntfy-state"; mkdir -p "$FAKE_NTFY_STATE"
FAKE_NTFY_LOG="$EVAL_TMP/ntfy.log"; : > "$FAKE_NTFY_LOG"; export FAKE_NTFY_STATE FAKE_NTFY_LOG
unset OPSX_NOTIFY XDG_RUNTIME_DIR

# Recording curl: one dir per call with args, headers (-H and -H @file) and body (stdin).
# Exit code from $FAKE_CURL_RC (default 0). Replaces expose.sh's blocking curl shim.
cat > "$SHIMS/curl" <<'SH'
#!/usr/bin/env bash
d=$(mktemp -d "$CURL_DIR/call.XXXXXX") || exit 99
printf '%s\n' "$*" > "$d/args"; : > "$d/headers"; : > "$d/body"
while [ $# -gt 0 ]; do
  case $1 in
    -H) case $2 in @*) cat "${2#@}" >> "$d/headers" 2>/dev/null;; *) printf '%s\n' "$2" >> "$d/headers";; esac; shift 2;;
    --data-binary|-d|--data) case $2 in @-) cat > "$d/body";; @*) cat "${2#@}" > "$d/body";; *) printf '%s' "$2" > "$d/body";; esac; shift 2;;
    -o|-w|--max-time|-m) shift 2;;
    *) shift;;
  esac
done
rc=${FAKE_CURL_RC:-0}
[ "$rc" -eq 0 ] && printf '200'
exit "$rc"
SH
chmod +x "$SHIMS/curl"
curl_calls() { find "$CURL_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l; }
curl_all_headers() { cat "$CURL_DIR"/call.*/headers 2>/dev/null; }
curl_all_bodies() { cat "$CURL_DIR"/call.*/body 2>/dev/null; }
reset_curl() { rm -rf "$CURL_DIR"; mkdir -p "$CURL_DIR"; }
# wait_calls <n> [timeout-s]: poll until at least n calls were recorded
wait_calls() { local i; for i in $(seq $(( ${2:-10} * 10 ))); do [ "$(curl_calls)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }

write_notify_env() {
  mkdir -p "$(dirname "$NOTIFY_ENV")"
  printf 'NTFY_URL=https://ntfy.test.example\nNTFY_TOPIC=opsx-0123456789ab\nNTFY_TOKEN=tk_secrettoken123\nNTFY_USER=opsx\nNTFY_PASSWORD=pw-SECRET-abcdefghij\n' > "$NOTIFY_ENV"
  chmod 600 "$NOTIFY_ENV"
}

# Stateful fake ntfy binary (user/access/token subcommands only).
FAKE_NTFY="$EVAL_TMP/fake-ntfy"
cat > "$FAKE_NTFY" <<'SH'
#!/usr/bin/env bash
S=$FAKE_NTFY_STATE
printf 'ntfy %s\n' "$*" >> "$FAKE_NTFY_LOG"
sub=${1:-}; shift || true
a=(); while [ $# -gt 0 ]; do case $1 in --config) shift 2;; *) a+=("$1"); shift;; esac; done
set -- "${a[@]}"
case $sub in
  user) case ${1:-} in
          list) if [ -f "$S/user" ]; then echo "user opsx (role: user, tier: none)"
                  [ -f "$S/topic" ] && echo "- read-write access to topic $(cat "$S/topic")"; fi; exit 0;;
          add) : > "$S/user"; echo "user opsx added with role user";;
          change-pass) :;;
        esac;;
  access) printf '%s' "$3" > "$S/topic";;
  token) case ${1:-} in
           list) [ -f "$S/token" ] && printf 'user opsx\n- %s (never expires)\n' "$(cat "$S/token")"; exit 0;;
           add) t=tk_$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 29); printf '%s' "$t" > "$S/token"
                echo "token $t created for user opsx, never expires";;
         esac;;
  version|--version) echo "ntfy 2.34.0";;
  serve) exit 0;;
esac
exit 0
SH
chmod +x "$FAKE_NTFY"

# install.sh --expose-domain with the fakes. notify_install <domain> [args...]
notify_install() {
  local d=$1; shift
  CLOUDFLARE_API_TOKEN=t1 OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$FAKE_CADDY" OPSX_NTFY_BIN="$FAKE_NTFY" \
    install_nt --expose-domain "$d" "$@"
}
notify_install_ok() {
  local out; out=$(notify_install "$@") || { echo "$out" | tail -25; fail "setup: install.sh failed"; }
  printf '%s\n' "$out" > "$EVAL_TMP/install.out"
}
no_real_privilege() { ! grep -E '^(sudo|systemctl) ' "$SHIM_LOG" >/dev/null; }

# ---- private tmux server ----
need_tmux() { command -v tmux >/dev/null 2>&1 || { echo "tmux missing"; exit 77; }; }
NSOCK="nt-$$"
TM() { env -u TMUX -u TMUX_PANE tmux -L "$NSOCK" -f /dev/null "$@"; }
# start_tmux: server with one session "s"; exports TMUX/TMUX_PANE for commands run later.
start_tmux() {
  need_tmux
  TM new-session -d -s s -n main -x 200 -y 50 'exec sleep 3600' || fail "cannot start private tmux"
  trap 'TM kill-server 2>/dev/null; rm -rf "$SOCK_DIR"; stop_admin' EXIT
  export TMUX="$(TM display -p '#{socket_path},#{pid},0')"
}
# new_win <name> [tag-option value]: new window named <name>, prints "<window-id> <pane-id>"
new_win() {
  local w p
  w=$(TM new-window -d -t s -n "$1" -P -F '#{window_id}' 'exec sleep 3600') || fail "new-window failed"
  p=$(TM display -p -t "$w" '#{pane_id}')
  case ${2:-} in
    change) TM set-option -w -t "$w" @opsx_change "$1";;
    fork) TM set-option -p -t "$p" @fork_dir "$EVAL_TMP/forkdir";;
  esac
  echo "$w $p"
}
