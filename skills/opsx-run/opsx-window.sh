#!/usr/bin/env bash
# opsx-window.sh — tmux window management for the /opsx-run skill.
#
# One OpenSpec change = one tmux window named after the change, in the caller's
# tmux session, running an interactive agent CLI (Claude Code or Cursor CLI)
# that delegates to the ops-applier subagent. The window is reused for every
# follow-up instruction.
#
# Usage:
#   opsx-window.sh ensure <change> --prompt-file <f> [--cwd <dir>] [--agent-cli <cmd>] [--model <id>]
#   opsx-window.sh send   <change> --prompt-file <f>   # send, or create the window if missing
#   opsx-window.sh close  <change> [--force] [--keep-session]
#   opsx-window.sh close  --all    [--force] [--keep-session]
#   opsx-window.sh status <change> [--lines N]
#   opsx-window.sh detect-cli [--agent-cli <cmd>]
#   opsx-window.sh detect-model [--model <id>]
#   opsx-window.sh list
#
# Agent CLI selection (ensure only):
#   --agent-cli <name>   Launch with this command (claude, agent, cursor, or a path)
#   $OPSX_AGENT_CLI      Same, as a default for every call
#   Auto-detect           Cursor when $CURSOR_AGENT is set, else claude if on PATH,
#                         else agent (Linux Cursor CLI), else error
#   --model <id>         Model for new windows (claude/agent --model)
#   $OPSX_MODEL          Same, as a default for every call
#   Auto-detect           Cursor ~/.cursor/cli-config.json selectedModel,
#                         else $ANTHROPIC_MODEL, else Claude settings.json model
#   When launching `agent`, ensure also links ops-applier into
#   <cwd>/.cursor/agents/ so Cursor Task can use subagent_type ops-applier.
#
# Inside tmux the window goes in the caller's session. Outside tmux, `ensure`
# creates (or reuses) a session named after the project folder and prints an
# "attach with:" hint; `send`/`status`/`list` look that session up and never
# create one.
#
# Output on success (ensure/send): "<created|reused|sent> <window-id> <session>:<change>"
# plus a trailing " session=created" on the field when a new session was made.

set -uo pipefail

die() { printf 'opsx-window: %s\n' "$1" >&2; exit 1; }

require_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux is not installed."
}

inside_tmux() { [ -n "${TMUX:-}" ]; }

# Session name for a project directory: its folder name, with tmux's target
# metacharacters ('.' and ':') and whitespace folded to '-'.
project_session_name() {
  local base
  base=$(basename -- "${1%/}")
  base=$(printf '%s' "$base" | tr ':. \t' '----')
  [ -n "$base" ] || base="opsx"
  printf '%s' "$base"
}

# tmux target matching is prefix-based, so `has-session -t foo` is true when
# only "foobar" exists. Compare names exactly instead.
session_exists() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | awk -v n="$1" '$0==n { found=1; exit } END { exit !found }'
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

# Which session to look in when we are NOT creating anything: the caller's
# session inside tmux, otherwise the project's session (which must exist).
lookup_session() {
  local sess
  if inside_tmux; then
    current_session
    return 0
  fi
  sess=$(project_session_name "$PWD")
  session_exists "$sess" \
    || die "not inside tmux and no session named '$sess' — run '/opsx-run <change> apply' first."
  printf '%s' "$sess"
}

# Window id (@N) for a window named exactly $2 in session $1, empty if absent.
# Everything downstream targets the id: it survives renames and index shifts,
# and sidesteps ':' / '.' being target metacharacters.
find_window() {
  tmux list-windows -t "$1" -F '#{window_id} #{window_name}' 2>/dev/null \
    | awk -v n="$2" '{ id=$1; $1=""; sub(/^ /,""); if ($0==n) { print id; exit } }'
}

# Stamp a window as ours. Bulk close then targets exactly the windows this
# script created, instead of guessing from names that may no longer match an
# active change (e.g. after archiving).
tag_window() {
  tmux set-option -w -t "$1" @opsx_change "$2" >/dev/null 2>&1
  [ -n "${3:-}" ] && tmux set-option -w -t "$1" @opsx_agent_cli "$3" >/dev/null 2>&1
  [ -n "${4:-}" ] && tmux set-option -w -t "$1" @opsx_model "$4" >/dev/null 2>&1
  tmux set-window-option -t "$1" automatic-rename off >/dev/null 2>&1
  tmux set-window-option -t "$1" allow-rename off >/dev/null 2>&1
}

# Window id of the pane we are running in, empty when outside tmux.
current_window() {
  [ -n "${TMUX_PANE:-}" ] || return 0
  tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null
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

# Normalize user-facing CLI names to the binary we exec.
normalize_agent_cli() {
  case "$1" in
    cursor) printf '%s' agent ;;
    *)      printf '%s' "$1" ;;
  esac
}

# True when this shell is running under Cursor CLI/IDE (not just when both CLIs
# happen to be installed). Env markers are checked first; if those were stripped
# (e.g. by a sandbox), walk the parent chain — Cursor CLI on Linux shows up as
# comm=MainThread with .../agent in args, not comm=agent.
running_under_cursor() {
  [ -n "${CURSOR_AGENT:-}" ] && return 0
  [ "${CURSOR_INVOKED_AS:-}" = agent ] && return 0
  [ -n "${CURSOR_RIPGREP_PATH:-}" ] && return 0
  [ -n "${CURSOR_CONVERSATION_ID:-}" ] && return 0

  local pid=$$ i=0 args comm
  while [ "$pid" -gt 1 ] && [ "$i" -lt 25 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$args" in
      *cursor-agent*|*cursor_agent*|*/.cursor/*agent*)
        return 0 ;;
    esac
    case "$args" in
      */agent\ *|*/agent|--use-system-ca*)
        return 0 ;;
    esac
    case "$comm" in
      agent|cursor-agent|Cursor|cursor)
        return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    i=$((i + 1))
  done
  return 1
}

# True when running under Claude Code.
running_under_claude() {
  [ -n "${CLAUDE_CODE_SSE_PORT:-}" ] && return 0
  [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] && return 0

  local pid=$$ i=0 args comm
  while [ "$pid" -gt 1 ] && [ "$i" -lt 25 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$args" in
      *claude-code*|*/claude\ *|*/claude)
        return 0 ;;
    esac
    case "$comm" in
      claude|Claude)
        return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    i=$((i + 1))
  done
  return 1
}

# Pick which agent CLI launches new windows. Precedence: flag > $OPSX_AGENT_CLI >
# host detection (Cursor vs Claude) > claude on PATH > agent on PATH > error.
resolve_agent_cli() {
  local explicit=${1:-}
  local cli=""
  if [ -n "$explicit" ]; then
    cli=$(normalize_agent_cli "$explicit")
  elif [ -n "${OPSX_AGENT_CLI:-}" ]; then
    cli=$(normalize_agent_cli "$OPSX_AGENT_CLI")
  elif running_under_cursor && command -v agent >/dev/null 2>&1; then
    cli=agent
  elif running_under_claude && command -v claude >/dev/null 2>&1; then
    cli=claude
  elif command -v claude >/dev/null 2>&1; then
    cli=claude
  elif command -v agent >/dev/null 2>&1; then
    cli=agent
  else
    die "no agent CLI found — install claude (Claude Code) or agent (Cursor CLI), or pass --agent-cli <cmd>."
  fi
  command -v "$cli" >/dev/null 2>&1 \
    || die "agent CLI '$cli' is not on PATH — install it or pass --agent-cli <cmd>."
  printf '%s' "$cli"
}

# Read a dotted JSON string field (python3, else jq). Empty on miss.
json_str() {
  local file=$1 path=$2 val=""
  [ -f "$file" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    val=$(python3 -c '
import json, sys
obj = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    obj = obj.get(k) if isinstance(obj, dict) else None
    if obj is None:
        print("")
        raise SystemExit(0)
print(obj if isinstance(obj, str) else "")
' "$file" "$path" 2>/dev/null) || val=""
  elif command -v jq >/dev/null 2>&1; then
    val=$(jq -r --arg p "$path" 'getpath($p|split(".")) // empty' "$file" 2>/dev/null) || val=""
  fi
  printf '%s' "$val"
}

# True when this id means "use the CLI default" — omit --model.
model_is_default() {
  case "$1" in
    ""|default|auto|inherit|Auto) return 0 ;;
    *) return 1 ;;
  esac
}

# Precedence: flag > $OPSX_MODEL > host session default.
resolve_model() {
  local explicit=${1:-} model=""
  if [ -n "$explicit" ]; then
    model=$explicit
  elif [ -n "${OPSX_MODEL:-}" ]; then
    model=$OPSX_MODEL
  elif [ -n "${ANTHROPIC_MODEL:-}" ]; then
    model=$ANTHROPIC_MODEL
  elif running_under_cursor; then
    model=$(json_str "$HOME/.cursor/cli-config.json" selectedModel.modelId)
    [ -n "$model" ] || model=$(json_str "$HOME/.cursor/cli-config.json" model.modelId)
  elif running_under_claude; then
    model=$(json_str "$HOME/.claude/settings.json" model)
  fi
  if model_is_default "$model"; then
    printf '%s' ""
    return 0
  fi
  printf '%s' "$model"
}

# Shell command that reads the prompt inside the new window's cwd.
build_launch_cmd() {
  local prompt_file=$1 cli=$2 model=${3:-} model_flag=""
  if [ -n "$model" ]; then
    model_flag=$(printf ' --model %q' "$model")
  fi
  case "$cli" in
    claude)
      printf 'claude --permission-mode bypassPermissions%s "$(cat %q)"' "$model_flag" "$prompt_file"
      ;;
    agent)
      # Linux/macOS Cursor CLI is the `agent` binary; --force skips approval prompts.
      printf 'agent --force%s "$(cat %q)"' "$model_flag" "$prompt_file"
      ;;
    *)
      printf '%s%s "$(cat %q)"' "$cli" "$model_flag" "$prompt_file"
      ;;
  esac
}

# Cursor CLI only loads *project* subagents from <cwd>/.cursor/agents/ — not
# ~/.cursor/agents/. Symlink (or copy) ops-applier into the project so Task can
# take subagent_type: "ops-applier" when the window's agent starts.
ensure_cursor_project_agent() {
  local cwd=$1
  local dir="$cwd/.cursor/agents"
  local dest="$dir/opsx-applier.md"
  local src=""

  if [ -f "$HOME/.cursor/agents/opsx-applier.md" ]; then
    src="$HOME/.cursor/agents/opsx-applier.md"
  elif [ -f "$HOME/.claude/agents/opsx-applier.md" ]; then
    # Last resort: install a Cursor-shaped copy from the Claude agent body.
    mkdir -p "$HOME/.cursor/agents"
    {
      printf '%s\n' '---'
      printf 'name: ops-applier\n'
      printf 'description: Run when asked to implement features, apply changes, or execute OpenSpec apply tasks using a git worktree\n'
      printf '%s\n' '---'
      awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$HOME/.claude/agents/opsx-applier.md"
    } > "$HOME/.cursor/agents/opsx-applier.md"
    src="$HOME/.cursor/agents/opsx-applier.md"
  else
    printf '# warning: no ops-applier agent found under ~/.cursor/agents or ~/.claude/agents — run ./install.sh\n' >&2
    return 1
  fi

  mkdir -p "$dir" || die "cannot create $dir"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    # Project owns a real file — leave it alone (may be a committed override).
    printf '# cursor project agent: %s (existing file)\n' "$dest"
    return 0
  fi
  if ln -sfn "$src" "$dest" 2>/dev/null; then
    printf '# cursor project agent: %s -> %s\n' "$dest" "$src"
  else
    cp "$src" "$dest" || die "cannot install $dest"
    printf '# cursor project agent: %s (copied)\n' "$dest"
  fi
}

cmd_ensure() {
  local change=${1:-} prompt_file="" cwd="$PWD" create_only=0 agent_cli="" model=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-file) prompt_file=${2:-}; shift 2 ;;
      --cwd)         cwd=${2:-}; shift 2 ;;
      --agent-cli)   agent_cli=${2:-}; shift 2 ;;
      --model)       model=${2:-}; shift 2 ;;
      --create-only) create_only=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$change" ] || die "usage: opsx-window.sh ensure <change> --prompt-file <f> [--cwd <dir>] [--agent-cli <cmd>] [--model <id>]"
  [ -n "$prompt_file" ] || die "--prompt-file is required"
  [ -f "$prompt_file" ] || die "prompt file not found: $prompt_file"
  [ -d "$cwd" ] || die "cwd not found: $cwd"

  require_tmux
  local sess win launch cli
  cli=$(resolve_agent_cli "$agent_cli")
  model=$(resolve_model "$model")
  if [ "$cli" = agent ]; then
    ensure_cursor_project_agent "$cwd" || true
  fi
  launch=$(build_launch_cmd "$prompt_file" "$cli" "$model")

  if inside_tmux; then
    sess=$(current_session) || exit 1
  else
    # Called from outside tmux: work in a session named after the project
    # folder, creating it if this is the first change for that project.
    sess=$(project_session_name "$cwd")
    if ! session_exists "$sess"; then
      # Create the session and the change window in one shot, so the session
      # has no stray shell window sitting next to the work.
      win=$(tmux new-session -d -s "$sess" -n "$change" -c "$cwd" -P -F '#{window_id}' \
            "$launch" 2>&1) || die "failed to create session '$sess': $win"
      tag_window "$win" "$change" "$cli" "$model"
      printf 'created %s %s:%s agent=%s model=%s session=created\n' \
        "$win" "$sess" "$change" "$cli" "${model:-default}"
      printf '# attach with: tmux attach -t %s\n' "$sess"
      return 0
    fi
  fi

  win=$(find_window "$sess" "$change")

  if [ -n "$win" ]; then
    [ "$create_only" -eq 1 ] && die "window '$change' already exists ($win)"
    send_prompt "$win" "$prompt_file"
    printf 'reused %s %s:%s\n' "$win" "$sess" "$change"
    inside_tmux || printf '# attach with: tmux attach -t %s\n' "$sess"
    return 0
  fi

  # The prompt is read from the file inside the window's shell, so no prompt
  # text is ever spliced into this command line, and there is no TUI boot race.
  win=$(tmux new-window -d -t "$sess:" -n "$change" -c "$cwd" -P -F '#{window_id}' \
        "$launch" 2>&1) \
    || die "failed to create window: $win"

  # tag_window also disables tmux's automatic rename, which would otherwise
  # relabel the window to the running command ("claude" / "agent") and lose the
  # change name the whole workflow keys off.
  tag_window "$win" "$change" "$cli" "$model"

  printf 'created %s %s:%s agent=%s model=%s\n' \
    "$win" "$sess" "$change" "$cli" "${model:-default}"
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
  if inside_tmux || session_exists "$(project_session_name "$PWD")"; then
    sess=$(lookup_session) || exit 1
    win=$(find_window "$sess" "$change")
  else
    win=""
  fi

  # Window gone (closed after land, killed, never created): open one with this
  # prompt instead of telling the user to apply first.
  if [ -z "$win" ]; then
    cmd_ensure "$change" --prompt-file "$prompt_file"
    return $?
  fi

  send_prompt "$win" "$prompt_file"
  printf 'sent %s %s:%s\n' "$win" "$sess" "$change"
}

cmd_close() {
  local change="" all=0 force=0 keep_session=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)          all=1; shift ;;
      --force|-f)     force=1; shift ;;
      --keep-session) keep_session=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)  [ -z "$change" ] || die "close takes one change name (got '$change' and '$1')"
          change=$1; shift ;;
    esac
  done
  if [ "$all" -eq 1 ]; then
    [ -z "$change" ] || die "pass either a change name or --all, not both"
  else
    [ -n "$change" ] || die "usage: opsx-window.sh close <change> [--force] | close --all [--force]"
  fi

  require_tmux
  local sess here targets closed=0 skipped_self=0 total
  sess=$(lookup_session) || exit 1
  here=$(current_window)

  if [ "$all" -eq 1 ]; then
    # Only windows this script stamped — never the user's own windows that
    # happen to sit in the same session.
    targets=$(tmux list-windows -t "$sess" -F '#{window_id} #{@opsx_change}' 2>/dev/null \
              | awk 'NF>1 && $2!="" { print $1 }')
    if [ -z "$targets" ]; then
      printf 'no opsx windows in session %s\n' "$sess"
      printf '# windows created before tagging was added are not matched by --all; close them by name\n'
      return 0
    fi
  else
    targets=$(find_window "$sess" "$change")
    [ -n "$targets" ] || die "no window named '$change' in session '$sess'."
  fi

  # tmux destroys a session once its last window goes. When asked to keep it,
  # park a plain shell in it first so the session survives the close.
  if [ "$keep_session" -eq 1 ]; then
    total=$(tmux list-windows -t "$sess" -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$total" = "$(printf '%s\n' "$targets" | wc -l | tr -d ' ')" ]; then
      tmux new-window -d -t "$sess:" -c "$PWD" >/dev/null 2>&1 \
        && printf '# parked a shell window to keep session %s alive\n' "$sess"
    fi
  fi

  local win name
  for win in $targets; do
    name=$(tmux display-message -p -t "$win" '#{window_name}' 2>/dev/null)
    if [ -n "$here" ] && [ "$win" = "$here" ] && [ "$force" -eq 0 ]; then
      skipped_self=1
      printf '# skipped %s (%s) — that is the window you are in; pass --force to close it anyway\n' \
             "$win" "$name"
      continue
    fi
    # kill-window ends the agent session in it, along with any work it is
    # still doing. Worktrees and commits it already made survive on disk.
    tmux kill-window -t "$win" 2>/dev/null || die "failed to close $win ($name)"
    printf 'closed %s %s:%s\n' "$win" "$sess" "$name"
    closed=$((closed + 1))
  done

  [ "$all" -eq 1 ] && printf '# closed %s window(s)\n' "$closed"

  # Report a session that went away, rather than letting the next command fail
  # with a confusing "no session named ..." error.
  session_exists "$sess" || printf '# session %s had no windows left and is gone\n' "$sess"

  [ "$closed" -gt 0 ] || [ "$skipped_self" -eq 1 ] || die "nothing was closed."
  return 0
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
  sess=$(lookup_session) || exit 1
  win=$(find_window "$sess" "$change")
  [ -n "$win" ] || die "no window named '$change' in session '$sess'."

  printf '# %s:%s (%s) last %s lines\n' "$sess" "$change" "$win" "$lines"
  tmux capture-pane -p -t "$win" -S "-$lines" 2>/dev/null || die "failed to capture pane for $win"
}

cmd_detect_cli() {
  local agent_cli=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent-cli) agent_cli=${2:-}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  resolve_agent_cli "$agent_cli"
}

cmd_detect_model() {
  local model=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --model) model=${2:-}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  model=$(resolve_model "$model")
  printf '%s\n' "${model:-default}"
}

cmd_list() {
  require_tmux
  local sess
  sess=$(lookup_session) || exit 1
  printf '# session %s\n' "$sess"
  # The opsx column marks windows this script created (see tag_window).
  tmux list-windows -t "$sess" \
    -F '#{window_id}	#{?@opsx_change,opsx,-}	#{window_name}	#{pane_current_command}	#{pane_current_path}'
}

case "${1:-}" in
  ensure)     shift; cmd_ensure "$@" ;;
  send)       shift; cmd_send "$@" ;;
  close)      shift; cmd_close "$@" ;;
  status)     shift; cmd_status "$@" ;;
  detect-cli)   shift; cmd_detect_cli "$@" ;;
  detect-model) shift; cmd_detect_model "$@" ;;
  list)         shift; cmd_list "$@" ;;
  ""|-h|--help)
    awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"
    ;;
  *) die "unknown subcommand: $1 (expected ensure|send|close|status|detect-cli|detect-model|list)" ;;
esac
