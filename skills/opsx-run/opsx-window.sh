#!/usr/bin/env bash
# opsx-window.sh — tmux window management for the /opsx-run skill.
#
# One OpenSpec change = one tmux window named after the change, in the caller's
# tmux session, running an interactive `claude` that delegates to the
# ops-applier subagent. The window is reused for every follow-up instruction.
#
# Usage:
#   opsx-window.sh ensure <change> --prompt-file <f> [--cwd <dir>]
#   opsx-window.sh send   <change> --prompt-file <f>
#   opsx-window.sh status <change> [--lines N]
#   opsx-window.sh list
#
# Output on success (ensure/send): "<created|reused|sent> <window-id> <session>:<change>"

set -uo pipefail

die() { printf 'opsx-window: %s\n' "$1" >&2; exit 1; }

require_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux is not installed."
  [ -n "${TMUX:-}" ] || die "not running inside tmux — start this from a tmux session."
}

# Resolve the session that owns *this* pane. Bare `display-message -p '#S'`
# reports the session of whichever client tmux considers current, which is the
# wrong answer when several clients are attached.
current_session() {
  local s
  if [ -n "${TMUX_PANE:-}" ]; then
    s=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
  fi
  [ -n "${s:-}" ] || s=$(tmux display-message -p '#S' 2>/dev/null)
  [ -n "${s:-}" ] || die "could not determine the current tmux session."
  printf '%s' "$s"
}

# Window id (@N) for a window named exactly $2 in session $1, empty if absent.
# Everything downstream targets the id: it survives renames and index shifts,
# and sidesteps ':' / '.' being target metacharacters.
find_window() {
  tmux list-windows -t "$1" -F '#{window_id} #{window_name}' 2>/dev/null \
    | awk -v n="$2" '{ id=$1; $1=""; sub(/^ /,""); if ($0==n) { print id; exit } }'
}

send_prompt() {
  local win=$1 file=$2 text
  # Newlines would submit the prompt early in the TUI, so collapse them.
  text=$(tr '\n' ' ' <"$file")
  text=${text%"${text##*[![:space:]]}"}
  [ -n "$text" ] || die "prompt file is empty: $file"
  # -l sends the text literally; without it "Enter", ";" and "C-x" inside the
  # prompt are interpreted as key names.
  tmux send-keys -t "$win" -l -- "$text" || die "failed to send text to $win"
  # Let the TUI ingest the text before submitting; without the gap a fast
  # follow-up send can land in the same input box and concatenate.
  sleep 0.3
  tmux send-keys -t "$win" Enter || die "failed to submit prompt in $win"
}

cmd_ensure() {
  local change=${1:-} prompt_file="" cwd="$PWD" create_only=0
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-file) prompt_file=${2:-}; shift 2 ;;
      --cwd)         cwd=${2:-}; shift 2 ;;
      --create-only) create_only=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$change" ] || die "usage: opsx-window.sh ensure <change> --prompt-file <f> [--cwd <dir>]"
  [ -n "$prompt_file" ] || die "--prompt-file is required"
  [ -f "$prompt_file" ] || die "prompt file not found: $prompt_file"
  [ -d "$cwd" ] || die "cwd not found: $cwd"

  require_tmux
  local sess win
  sess=$(current_session)
  win=$(find_window "$sess" "$change")

  if [ -n "$win" ]; then
    [ "$create_only" -eq 1 ] && die "window '$change' already exists ($win)"
    send_prompt "$win" "$prompt_file"
    printf 'reused %s %s:%s\n' "$win" "$sess" "$change"
    return 0
  fi

  # The prompt is read from the file inside the window's shell, so no prompt
  # text is ever spliced into this command line, and there is no TUI boot race.
  win=$(tmux new-window -d -t "$sess:" -n "$change" -c "$cwd" -P -F '#{window_id}' \
        "claude --permission-mode bypassPermissions \"\$(cat $(printf '%q' "$prompt_file"))\"" 2>&1) \
    || die "failed to create window: $win"

  # Without these tmux renames the window to the running command ("claude"),
  # losing the change name the whole workflow keys off.
  tmux set-window-option -t "$win" automatic-rename off >/dev/null 2>&1
  tmux set-window-option -t "$win" allow-rename off >/dev/null 2>&1

  printf 'created %s %s:%s\n' "$win" "$sess" "$change"
}

cmd_send() {
  local change=${1:-} prompt_file=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-file) prompt_file=${2:-}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$change" ] || die "usage: opsx-window.sh send <change> --prompt-file <f>"
  [ -n "$prompt_file" ] || die "--prompt-file is required"
  [ -f "$prompt_file" ] || die "prompt file not found: $prompt_file"

  require_tmux
  local sess win
  sess=$(current_session)
  win=$(find_window "$sess" "$change")
  [ -n "$win" ] || die "no window named '$change' in session '$sess' — run '/opsx-run $change apply' first."

  send_prompt "$win" "$prompt_file"
  printf 'sent %s %s:%s\n' "$win" "$sess" "$change"
}

cmd_status() {
  local change=${1:-} lines=60
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines) lines=${2:-60}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$change" ] || die "usage: opsx-window.sh status <change> [--lines N]"

  require_tmux
  local sess win
  sess=$(current_session)
  win=$(find_window "$sess" "$change")
  [ -n "$win" ] || die "no window named '$change' in session '$sess'."

  printf '# %s:%s (%s) last %s lines\n' "$sess" "$change" "$win" "$lines"
  tmux capture-pane -p -t "$win" -S "-$lines" 2>/dev/null || die "failed to capture pane for $win"
}

cmd_list() {
  require_tmux
  local sess
  sess=$(current_session)
  printf '# session %s\n' "$sess"
  tmux list-windows -t "$sess" \
    -F '#{window_id}	#{window_name}	#{pane_current_command}	#{pane_current_path}'
}

case "${1:-}" in
  ensure) shift; cmd_ensure "$@" ;;
  send)   shift; cmd_send "$@" ;;
  status) shift; cmd_status "$@" ;;
  list)   shift; cmd_list "$@" ;;
  ""|-h|--help)
    awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"
    ;;
  *) die "unknown subcommand: $1 (expected ensure|send|status|list)" ;;
esac
