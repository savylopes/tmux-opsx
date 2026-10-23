# Helpers for task-session checks (sourced, not a check). Scratch git repo, private
# tmux server (-L), stub agent CLIs that log argv and stdin; no real agent is launched.
fail() { echo "FAIL: $*"; exit 1; }
TASK="$EVAL_ROOT/skills/opsx-task/opsx-task.sh"
[ -x "$TASK" ] || fail "$TASK missing or not executable"
export HOME="$EVAL_TMP/home" XDG_STATE_HOME="$EVAL_TMP/home/.local/state" XDG_CONFIG_HOME="$EVAL_TMP/home/.config"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
export FAKE_LOG="$EVAL_TMP/fakelog"; mkdir -p "$FAKE_LOG" "$EVAL_TMP/fakebin"
R="$EVAL_TMP/repo"; mkdir -p "$R"
git -C "$R" init -q . 2>/dev/null; git -C "$R" config user.email e@e; git -C "$R" config user.name e
echo x > "$R/f"; git -C "$R" add f; git -C "$R" commit -qm init
R=$(cd "$R" && pwd -P)
mkstub() {  # mkstub <name> : logs argv (not for --help/--version), then logs stdin
  cat > "$EVAL_TMP/fakebin/$1" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --help|--version|-h) exit 0;; esac
printf '%s\n' "\$@" > "\$FAKE_LOG/$1.args"
pwd > "\$FAKE_LOG/$1.cwd"
echo "fake-$1 started"
exec cat >> "\$FAKE_LOG/stdin.log"
SH
  chmod +x "$EVAL_TMP/fakebin/$1"
}
for n in claude codex agent gemini; do mkstub "$n"; done
export PATH="$EVAL_TMP/fakebin:$PATH"
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID OPENCODE_CONFIG_DIR OPENCODE_SERVER_PASSWORD
command -v tmux >/dev/null || { echo "tmux not on PATH"; exit 77; }
TSOCK_DIR=$(mktemp -d /tmp/otk.XXXXXX); chmod 700 "$TSOCK_DIR"
export TMUX_TMPDIR="$TSOCK_DIR"
TSOCK="tk$$"
T() { env -u TMUX -u TMUX_PANE tmux -L "$TSOCK" -f /dev/null "$@"; }
trap 'T kill-server >/dev/null 2>&1; rm -rf "$TSOCK_DIR"' EXIT
T new-session -d -s base -x 200 -y 50 -c "$R" 'exec sleep 86400' || { echo "cannot start private tmux"; exit 77; }
export TMUX="$(T display -p -t base '#{socket_path},#{pid},0')"
export TMUX_PANE="$(T display -p -t base '#{pane_id}')"
cd "$R"
export OPSX_TASK_ID_TIMEOUT=2
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
mkbrief() {  # mkbrief <name> <source>
  printf 'body of the task\n' > "$EVAL_TMP/d.md"
  "$TASK" brief "$1" --source "$2" --body-file "$EVAL_TMP/d.md" --repo "$R" >/dev/null 2>&1 || fail "brief setup failed"
}
brief() { echo "$R/.opsx/tasks/$1.md"; }
hdr() { sed -n "s/^$2: *//p" "$(brief "$1")" | head -1; }
wait_args() {  # wait_args <cli>
  local i=0
  while [ ! -s "$FAKE_LOG/$1.args" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  [ -s "$FAKE_LOG/$1.args" ] || fail "stub $1 never launched"
  tr '\n' ' ' < "$FAKE_LOG/$1.args"
}
