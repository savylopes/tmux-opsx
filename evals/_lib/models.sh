# Shared helpers for agent-models checks (sourced, not a check). Everything is
# local to $EVAL_TMP: scratch HOME/XDG dirs, a per-check private tmux server
# (tmux -L), and fake agent CLIs (claude, agent, codex, opencode, gemini) on PATH
# that log their argv to $LAUNCH_LOG and then idle. Never the user's tmux
# session, real agent CLIs or real config.
fail() { echo "FAIL: $*"; exit 1; }
command -v tmux >/dev/null || { echo "tmux not on PATH"; exit 77; }
WINDOW="$EVAL_ROOT/skills/opsx-run/opsx-window.sh"
export HOME="$EVAL_TMP/home"
export CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_HOME="$HOME/.codex"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
unset OPSX_MODELS_CONF OPSX_MODEL CURSOR_AGENT ANTHROPIC_MODEL GEMINI_MODEL
# "runs on Claude Code": the default CLI for calls without --agent-cli.
export OPSX_AGENT_CLI=claude OPSX_MODELS_LIST_TIMEOUT=3
USER_CONF="$XDG_CONFIG_HOME/tmux-opsx/models.conf"
user_conf() { mkdir -p "$(dirname "$USER_CONF")"; printf '%s\n' "$@" > "$USER_CONF"; }

# ---- fake agent CLIs -----------------------------------------------------
FAKEBIN="$EVAL_TMP/bin"; LAUNCH_LOG="$EVAL_TMP/launch.log"; export LAUNCH_LOG
mkdir -p "$FAKEBIN"
for c in claude agent codex opencode gemini; do
  cat > "$FAKEBIN/$c" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = models ]; then
  case $c in opencode) echo openai/gpt-5; echo anthropic/claude-sonnet-4;; agent) echo gpt-5; echo sonnet-4;; esac
  exit 0
fi
printf '%s' "$c" >> "\$LAUNCH_LOG"; printf ' %q' "\$@" >> "\$LAUNCH_LOG"; echo >> "\$LAUNCH_LOG"
exec sleep 86400
SH
  chmod +x "$FAKEBIN/$c"
done
export PATH="$FAKEBIN:$PATH"

# ---- private tmux server (per check), started after PATH has the fakes ----
TSOCK_DIR=$(mktemp -d /tmp/oxm.XXXXXX); chmod 700 "$TSOCK_DIR"
export TMUX_TMPDIR="$TSOCK_DIR"
TSOCK="am$$"
T() { env -u TMUX -u TMUX_PANE tmux -L "$TSOCK" -f /dev/null "$@"; }
T new-session -d -s proj -n caller -x 200 -y 50 'exec sleep 86400' || { echo "cannot start private tmux server"; exit 77; }
export TMUX="$(T display -p -t proj '#{socket_path},#{pid},0')"
export TMUX_PANE="$(T display -p -t proj:caller '#{pane_id}')"
trap 'T kill-server >/dev/null 2>&1; rm -rf "$TSOCK_DIR"' EXIT

cd "$EVAL_TMP" || exit 1
printf 'Implement the change.\n' > p

# run_w <args...>: run opsx-window.sh; sets RC, OUT, ERR and prints them.
run_w() {
  OUT=$("$WINDOW" "$@" 2>"$EVAL_TMP/stderr" </dev/null); RC=$?
  ERR=$(cat "$EVAL_TMP/stderr")
  echo "\$ opsx-window.sh $*"; echo "exit $RC"
  echo "-- stdout:"; printf '%s\n' "$OUT"; echo "-- stderr:"; printf '%s\n' "$ERR"
}
# windows whose @opsx_change == $1
win_of() { T list-windows -a -F '#{window_id} #{@opsx_change}' 2>/dev/null | awk -v c="$1" '$2==c {print $1}'; }
# win_has_opt <win> <option>: 0 when the window-level option is set on that window
win_has_opt() { T show-options -w -t "$1" 2>/dev/null | awk '{print $1}' | grep -qx -- "$2"; }
win_opt() { T show-options -wqv -t "$1" "$2" 2>/dev/null; }
model_opts() { T show-options -w -t "$1" 2>/dev/null | grep '^@opsx_model_' || true; }
# line_of <agent>: the "<agent> <model> <source>" line from $OUT
line_of() { printf '%s\n' "$OUT" | awk -v a="$1" '$1==a' | head -1 | tr -s ' \t' ' ' | sed 's/ $//'; }
expect_line() {  # expect_line "<agent> <model> <source>"
  local got; got=$(line_of "${1%% *}")
  [ "$got" = "$1" ] || fail "expected line '$1', got '${got:-<none>}'"
  echo "ok: $1"
}
# frontmatter <file>: lines between the first two --- markers
frontmatter() { awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm' "$1"; }
