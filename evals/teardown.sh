#!/usr/bin/env bash
# Eval teardown for tmux-opsx: kill the private tmux server, remove the scratch dir.
# Runs even when checks fail; must never touch anything setup did not create.
set -u
scratch=${EVAL_SCRATCH:-}
case "$scratch" in
  */tmux-opsx-eval.*) ;;
  *) exit 0 ;;   # setup did not run (or failed early): nothing to clean
esac
if [ -n "${EVAL_TMUX_SOCKET:-}" ] && command -v tmux >/dev/null 2>&1; then
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$scratch/tmux" tmux -L "$EVAL_TMUX_SOCKET" kill-server 2>/dev/null || true
fi
rm -rf -- "$scratch"
