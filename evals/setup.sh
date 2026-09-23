#!/usr/bin/env bash
# Eval setup for tmux-opsx: scratch HOME + private tmux server.
# Writes KEY=VALUE lines to $EVAL_ENV_FILE; opsx-eval.sh passes them to every check
# and to teardown.
set -eu
: "${EVAL_ENV_FILE:?run via opsx-eval.sh}"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tmux-opsx-eval.XXXXXX")
home="$scratch/home"
mkdir -p "$home/.config" "$home/.local/state" "$scratch/tmux"
chmod 700 "$scratch/tmux"
sock="eval-$$"
session="eval"
tmux_env="" pane=""
if command -v tmux >/dev/null 2>&1; then
  # Never inherit the caller's $TMUX: the private server lives under our TMUX_TMPDIR.
  T() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$scratch/tmux" HOME="$home" tmux -L "$sock" -f /dev/null "$@"; }
  T new-session -d -s "$session" -x 200 -y 50 'exec sleep 86400'
  tmux_env="$(T display -p -t "$session" '#{socket_path},#{pid},0')"
  pane="$(T display -p -t "$session" '#{pane_id}')"
fi
{
  printf 'EVAL_SCRATCH=%s\n' "$scratch"
  printf 'HOME=%s\n' "$home"
  printf 'XDG_CONFIG_HOME=%s\n' "$home/.config"
  printf 'XDG_STATE_HOME=%s\n' "$home/.local/state"
  printf 'CLAUDE_CONFIG_DIR=%s\n' "$home/.claude"
  printf 'CODEX_HOME=%s\n' "$home/.codex"
  printf 'TMUX_TMPDIR=%s\n' "$scratch/tmux"
  printf 'EVAL_TMUX_SOCKET=%s\n' "$sock"
  printf 'EVAL_TMUX_SESSION=%s\n' "$session"
  printf 'TMUX=%s\n' "$tmux_env"
  printf 'TMUX_PANE=%s\n' "$pane"
} >> "$EVAL_ENV_FILE"
