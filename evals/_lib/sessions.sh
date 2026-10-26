# Helpers for session-restore checks (sourced, not a check). Private tmux servers
# (one per "label", so a restart can be simulated), scratch HOME and state dir,
# a stub `claude` that logs its argv (NUL separated) and cwd, then execs
# `sleep` under the name claude so tmux reports pane_current_command=claude.
fail() { echo "FAIL: $*"; exit 1; }
command -v tmux >/dev/null || { echo "tmux not on PATH"; exit 77; }
command -v python3 >/dev/null || { echo "python3 not on PATH"; exit 77; }
SESSH="$EVAL_ROOT/skills/opsx-run/opsx-sessions.sh"
WINSH="$EVAL_ROOT/skills/opsx-run/opsx-window.sh"
[ -f "$SESSH" ] || fail "$SESSH missing"
export HOME="$EVAL_TMP/home" XDG_STATE_HOME="$EVAL_TMP/home/.local/state" XDG_CONFIG_HOME="$EVAL_TMP/home/.config"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export OPSX_SESSIONS_DIR="$EVAL_TMP/sessions"
mkdir -p "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$HOME"
export FAKE_LOG="$EVAL_TMP/fakelog" FAKEBIN="$EVAL_TMP/fakebin" RUNS="$EVAL_TMP/runs"
mkdir -p "$FAKE_LOG" "$FAKEBIN" "$RUNS" "$EVAL_TMP/r" "$EVAL_TMP/r2"
R1="$EVAL_TMP/r"; R2="$EVAL_TMP/r2"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
id=$$; [ "${1:-}" = "--resume" ] && id=$2
printf '%s\0' "$@" > "$FAKE_LOG/$id.args"
pwd > "$FAKE_LOG/$id.cwd"
echo "$id" >> "$FAKE_LOG/calls"
exec -a claude sleep 86400
SH
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
unset CLAUDE_CODE_SESSION_ID TMUX_PANE
TSOCK_DIR=$(mktemp -d /tmp/osr.XXXXXX); chmod 700 "$TSOCK_DIR"
export TMUX_TMPDIR="$TSOCK_DIR"
SOCKS=""
trap 'for s in $SOCKS; do env -u TMUX -u TMUX_PANE tmux -L "$s" kill-server >/dev/null 2>&1; done; rm -rf "$TSOCK_DIR"' EXIT
CUR=""
T() { env -u TMUX_PANE tmux -u -L "$CUR" -f /dev/null "$@"; }
# server <label> <session> <cwd> [cmd]: start a private server, make it current.
server() {
  CUR="s-$1-$$"; SOCKS="$SOCKS $CUR"
  env -u TMUX -u TMUX_PANE tmux -u -L "$CUR" -f /dev/null new-session -d -s "$2" -x 200 -y 50 -c "$3" "${4:-exec bash --norc --noprofile -i}" \
    || { echo "cannot start private tmux"; exit 77; }
  export TMUX="$(T display -p -t "$2" '#{socket_path},#{pid},0')"
}
# restart <label> <session> <cwd>: kill the current server, start another.
restart() {
  env -u TMUX -u TMUX_PANE tmux -u -L "$CUR" kill-server >/dev/null 2>&1; sleep 1.1
  server "$@"
}
UUID1=11111111-1111-4111-8111-111111111111
UUID2=22222222-2222-4222-8222-222222222222
UUID3=33333333-3333-4333-8333-333333333333
NRUN=0
hook_json() { # id cwd [mode] [source]
  if [ -n "${3:-}" ]; then
    printf '{"session_id":"%s","cwd":"%s","permission_mode":"%s","hook_event_name":"SessionStart","source":"%s"}' "$1" "$2" "$3" "${4:-startup}"
  else
    printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"%s"}' "$1" "$2" "${4:-startup}"
  fi
}
# claude_win <target session:idx> <name> <cwd> <json> [extra args for the fake claude]:
# new window whose process is named `claude`, runs the hook once with <json> on
# stdin (hook rc in $RUNS/N.rc, stdout in $RUNS/N.out), then stays up as claude.
# Set STRIP_PANE=1 to unset TMUX_PANE first.
claude_win() {
  local tgt=$1 name=$2 cwd=$3 json=$4; shift 4
  NRUN=$((NRUN+1)); local n=$NRUN
  printf '%s' "$json" > "$RUNS/$n.json"
  cat > "$RUNS/hk$n.sh" <<SH
#!/usr/bin/env bash
bash "$SESSH" hook < "$RUNS/$n.json" > "$RUNS/$n.out" 2> "$RUNS/$n.err"
echo \$? > "$RUNS/$n.rc"
exec -a claude sleep 86400
SH
  cat > "$RUNS/run$n.sh" <<SH
#!/usr/bin/env bash
${STRIP_PANE:+unset TMUX_PANE}
exec -a claude bash "$RUNS/hk$n.sh" "\$@"
SH
  chmod +x "$RUNS/run$n.sh"
  T new-window -d -t "$tgt" -n "$name" -c "$cwd" "$RUNS/run$n.sh $*" || fail "new-window $tgt"
  LASTRUN=$n
  wait_file "$RUNS/$n.rc" || fail "hook did not finish for $tgt"
}
wait_file() { local i=0; while [ ! -s "$1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; [ -s "$1" ]; }
# wait for a pane command
wait_cmd() { local i=0; while [ "$(T display -p -t "$1" '#{pane_current_command}' 2>/dev/null)" != "$2" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; [ "$(T display -p -t "$1" '#{pane_current_command}' 2>/dev/null)" = "$2" ]; }
# stub_args <uuid>: fill ARGS from the stub's log (waits)
stub_args() {
  wait_file "$FAKE_LOG/$1.args" || fail "stub claude never ran for $1 (restore output: ${OUT:-})"
  ARGS=(); mapfile -d '' -t ARGS < "$FAKE_LOG/$1.args"
}
# bare_args: ARGS minus --permission-mode <m> / --model <m>; sets BARE (array)
bare_args() {
  BARE=(); local i=0
  while [ $i -lt ${#ARGS[@]} ]; do
    case "${ARGS[$i]}" in --permission-mode|--model) i=$((i+2)); continue;; esac
    BARE+=("${ARGS[$i]}"); i=$((i+1))
  done
}
show_args() { printf 'argv:'; printf ' [%s]' "${ARGS[@]}"; echo; }
# first-server layout: session $1 with a throwaway window 0
sess_run() { OUT=$(bash "$SESSH" "$@" 2>&1); RC=$?; echo "\$ opsx-sessions.sh $* -> exit $RC"; echo "$OUT"; }
# bash_win <target> <name> <cwd>: window sitting at an interactive shell
bash_win() { T new-window -d -t "$1" -n "$2" -c "$3" 'exec bash --norc --noprofile -i' || fail "bash_win $1"; }
# wopt <target> <@opt> [value]: read or set a window option
wopt() { if [ $# -ge 3 ]; then T set-option -w -t "$1" "$2" "$3"; else T show-options -wqv -t "$1" "$2"; fi; }
# pr_stub <ok|merged>: stub pr.sh via OPSX_PR_SH; logs its argv to $FAKE_LOG/pr.log
pr_stub() {
  cat > "$FAKEBIN/pr.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FAKE_LOG/pr.log"
if [ "$1" = ok ]; then echo '/goal keep PR 16 mergeable'; exit 0; fi
echo 'pr: PR o/app#16 is MERGED; only an OPEN PR can be maintained.' >&2; exit 1
SH
  chmod +x "$FAKEBIN/pr.sh"; export OPSX_PR_SH="$FAKEBIN/pr.sh"
}
# restore_setup <pre-save hook>: server a (session work) with claude windows built by
# the caller; then save, restart as server b with the same session. The caller
# adds shell windows in b and runs restore.
