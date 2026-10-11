# Helpers for tmux-fork checks (sourced, not a check). Private tmux server per
# check, scratch HOME/XDG, fake claude/codex/opencode/gemini on PATH that log
# their argv (one arg per line) to $FAKE_LOG/<name>.args and then sleep.
fail() { echo "FAIL: $*"; exit 1; }
command -v tmux >/dev/null || { echo "tmux not on PATH"; exit 77; }
FORK="$EVAL_ROOT/skills/fork/fork.sh"
export HOME="$EVAL_TMP/home" XDG_STATE_HOME="$EVAL_TMP/home/.local/state" XDG_CONFIG_HOME="$EVAL_TMP/home/.config"
mkdir -p "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
export FAKE_LOG="$EVAL_TMP/fakelog"; mkdir -p "$FAKE_LOG" "$EVAL_TMP/fakebin" "$EVAL_TMP/work" "$EVAL_TMP/other"
for n in claude codex opencode gemini agent; do
  cat > "$EVAL_TMP/fakebin/$n" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$FAKE_LOG/$n.args"
echo "fake-$n started"
exec sleep 600
SH
  chmod +x "$EVAL_TMP/fakebin/$n"
done
export PATH="$EVAL_TMP/fakebin:$PATH"
unset CLAUDE_CODE_SESSION_ID FORK_HOST_CLI FORK_CLI FORK_MODEL FORK_NATIVE CODEX_THREAD_ID
TSOCK_DIR=$(mktemp -d /tmp/ofk.XXXXXX); chmod 700 "$TSOCK_DIR"
export TMUX_TMPDIR="$TSOCK_DIR"
TSOCK="fk$$"
T() { env -u TMUX -u TMUX_PANE tmux -L "$TSOCK" -f /dev/null "$@"; }
trap 'T kill-server >/dev/null 2>&1; rm -rf "$TSOCK_DIR"' EXIT
T new-session -d -s fk -x 200 -y 50 -c "$EVAL_TMP/work" 'exec sleep 86400' || { echo "cannot start private tmux"; exit 77; }
export TMUX="$(T display -p -t fk '#{socket_path},#{pid},0')"
export TMUX_PANE="$(T display -p -t fk '#{pane_id}')"
cd "$EVAL_TMP/work"
SESS=fk
SID=11111111-2222-4333-8444-555555555555
BRIEF="Question: what does foo do?"
# open_fork <args...>: runs fork.sh open with a brief on stdin; output in $OUT
open_fork() { OUT=$(printf '%s\n' "$BRIEF" | "$FORK" open "$@" 2>&1); RC=$?; }
fdir() { echo "$XDG_STATE_HOME/agent-forks/$SESS/$1"; }
# wait_args <name>: wait until the fake CLI logged its args; echo them joined by space
wait_args() {
  local i=0
  while [ ! -s "$FAKE_LOG/$1.args" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  [ -s "$FAKE_LOG/$1.args" ] || fail "fake $1 was never launched; open output: $OUT"
  tr '\n' ' ' < "$FAKE_LOG/$1.args"
}
has_arg() { grep -qxF -- "$2" "$FAKE_LOG/$1.args"; }

# detached <bash script>: run with no inherited ancestor (setsid -f, reparented
# to init) so a real CLAUDE_CODE_SESSION_ID on the eval caller's process chain
# cannot leak in. Output (stdout+stderr) in $DOUT.
detached() {
  DOUT="$EVAL_TMP/det.out"; rm -f "$DOUT" "$DOUT.done"
  export FORK
  setsid -f bash -c "{ $1 ; } > '$DOUT' 2>&1; touch '$DOUT.done'" </dev/null >/dev/null 2>&1
  local i=0; while [ ! -e "$DOUT.done" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done
  [ -e "$DOUT.done" ] || fail "detached command timed out"
  DOUT_TXT=$(cat "$DOUT")
}
