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
#   opsx-window.sh mark   <change> <busy|done|fail|idle>   # title badge + status color
#   opsx-window.sh list
#   opsx-window.sh preview-start <change> --cwd <dir> --script <file>
#   opsx-window.sh preview-find  <change>
#   opsx-window.sh preview-kill  <change>|--all
#
# Preview windows (used by opsx-preview.sh, never by hand): preview-start opens
# a window titled `ox ><change>` that runs `bash <file>` (no keys are
# typed), keeps it open after the app exits (remain-on-exit), and tags it
# @opsx_preview=<change> and @opsx_preview_project=<main checkout path>. It
# never carries @opsx_change, so ensure/send/close lookups and `close --all`
# never mistake it for the agent window. Previews belong to the project, not
# to a session: preview-find (prints every matching window id, one per line)
# and preview-kill look across all sessions of the tmux server for windows
# with this project's tag, so they work from any session or from outside tmux.
# `close` stops the change's preview first (`close --all` stops every preview
# in the project) through opsx-preview.sh next to this script, ignoring
# failures; a `close` that will refuse to close the caller's own window leaves
# the preview running.
#
# Window status (distinct `ox` title + dark pane + muted bar colors).
# Lookups use @opsx_change, so renaming does not break ensure/send/close.
#   idle  ox ·change   mint on dark teal
#   busy  ox …change   amber on dark olive
#   fail  ox ✗change   rose on dark wine
# `done` is an alias of idle: a finished window is still reusable.
# Busy windows enable monitor-silence; after $OPSX_IDLE_SILENCE seconds with no
# pane output (default 40) they fall back to idle unless already fail.
# Agent CLI selection (ensure only):
#   --agent-cli <name>   Launch with this command (claude, agent, cursor, codex,
#                         opencode, gemini, or a path)
#   $OPSX_AGENT_CLI      Same, as a default for every call
#   Auto-detect           Cursor when $CURSOR_AGENT is set, else Codex when running
#                         under codex, else OpenCode when under opencode, else
#                         Gemini when under gemini, else claude if on PATH, else
#                         agent, else codex, else opencode, else gemini
#   --model <id>         Model for new windows (claude/agent/codex/opencode/gemini)
#   $OPSX_MODEL          Same, as a default for every call
#   Auto-detect           Cursor ~/.cursor/cli-config.json selectedModel,
#                         else $ANTHROPIC_MODEL, else Claude settings.json model,
#                         else Codex ~/.codex/config.toml model,
#                         else OpenCode ~/.config/opencode/opencode.json{,c} model,
#                         else Gemini ~/.gemini/settings.json model / $GEMINI_MODEL
#   When launching `agent`, ensure also links ops-applier and ops-qa into
#   <cwd>/.cursor/agents/ so Cursor Task can use those subagent_types.
#   When launching `opencode`, ensure also links ops-applier and ops-qa into
#   <cwd>/.opencode/agents/ (OpenCode also loads ~/.config/opencode/agents/).
#   Cursor windows use `agent --force --approve-mcps --trust` so ~/.cursor/mcp.json
#   (browser-use) is loaded; Task subagents still often lack MCP — the dispatcher
#   prompt tells the window to run MCP browser tests itself.
#   Codex CLI has no reliable spawn-by-name for custom agents, so a codex window
#   applies the change directly. It launches as
#   `codex --dangerously-bypass-approvals-and-sandbox`.
#   OpenCode windows launch as `opencode --auto --prompt …` and can Task/ @mention
#   the ops-applier subagent.
#   Gemini CLI windows launch as `gemini --approval-mode=yolo --skip-trust -i …`
#   and apply in the window (like Codex). Agents are installed under
#   ~/.gemini/agents/; ensure also links them into <cwd>/.gemini/agents/.
#
# Inside tmux the window goes in the caller's session. Codex (and some
# sandboxes) strip $TMUX from the child environment; opsx-window.sh recovers
# TMUX/TMUX_PANE from /proc so it still uses the same session instead of
# creating a new one named after the project. Outside tmux, `ensure` creates
# (or reuses) a session named after the project folder and prints an
# "attach with:" hint; `send`/`status`/`list` look that session up and never
# create one.
#
# Output on success (ensure/send): "<created|reused|sent> <window-id> <session>:<change>"
# plus a trailing " session=created" on the field when a new session was made.

set -uo pipefail

die() { printf 'opsx-window: %s\n' "$1" >&2; exit 1; }

require_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux is not installed."
  recover_tmux_env || true
}

inside_tmux() { recover_tmux_env; [ -n "${TMUX:-}" ]; }

# Codex (and some sandboxes) strip $TMUX / $TMUX_PANE from the child environment
# even when the process is still inside a tmux pane. Without $TMUX, `ensure`
# thinks it is outside tmux and starts a *new* session named after the project.
# Walk /proc for the real values before deciding.
recover_tmux_env() {
  local pid=$$ i=0 envline pane sock
  if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    return 0
  fi
  while [ "$pid" -gt 1 ] && [ "$i" -lt 30 ]; do
    if [ -r "/proc/$pid/environ" ]; then
      if [ -z "${TMUX:-}" ]; then
        envline=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
                  | awk -F= '/^TMUX=/{print substr($0,6); exit}')
        if [ -n "$envline" ]; then
          sock=${envline%%,*}
          if [ -z "$sock" ] || [ -S "$sock" ]; then
            TMUX=$envline
            export TMUX
          fi
        fi
      fi
      if [ -z "${TMUX_PANE:-}" ]; then
        pane=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
               | awk -F= '/^TMUX_PANE=/{print $2; exit}')
        if [ -n "$pane" ]; then
          TMUX_PANE=$pane
          export TMUX_PANE
        fi
      fi
    fi
    [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    i=$((i + 1))
  done
  [ -n "${TMUX:-}" ] || [ -n "${TMUX_PANE:-}" ]
}

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
  recover_tmux_env || true
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

# Window id (@N) for change $2 in session $1, empty if absent.
# Prefer @opsx_change (survives title badges like "✓add-auth"); fall back to an
# exact window-name match for older windows created before tagging.
find_window() {
  local id
  id=$(tmux list-windows -t "$1" -F '#{window_id} #{@opsx_change}' 2>/dev/null \
       | awk -v n="$2" 'NF>1 && $2==n { print $1; exit }')
  if [ -n "$id" ]; then
    printf '%s' "$id"
    return 0
  fi
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

this_script() {
  printf '%s/%s' "$(cd -- "$(dirname -- "$0")" && pwd)" "$(basename -- "$0")"
}

# Seconds of pane silence before a busy window falls back to idle.
idle_silence_secs() {
  local n=${OPSX_IDLE_SILENCE:-40}
  case "$n" in
    ''|*[!0-9]*) n=40 ;;
  esac
  [ "$n" -ge 10 ] || n=10
  printf '%s' "$n"
}

# Watch pane silence while busy so a finished agent that forgot `mark done`
# does not stay yellow. Does nothing unless @opsx_status is still busy.
arm_busy_silence_watch() {
  local win=$1 change=$2
  local script secs hook
  script=$(this_script)
  secs=$(idle_silence_secs)
  hook=$(printf 'run-shell -b %q mark %q idle --if-busy' "$script" "$change")
  tmux set-option -w -t "$win" silence-action none >/dev/null 2>&1 || true
  tmux set-window-option -t "$win" visual-silence off >/dev/null 2>&1 || true
  tmux set-window-option -t "$win" monitor-silence "$secs" >/dev/null 2>&1 || true
  tmux set-hook -uw -t "$win" alert-silence >/dev/null 2>&1 || true
  tmux set-hook -w -t "$win" alert-silence "$hook" >/dev/null 2>&1 || true
}

disarm_busy_silence_watch() {
  local win=$1
  tmux set-window-option -t "$win" monitor-silence 0 >/dev/null 2>&1 || true
  tmux set-hook -uw -t "$win" alert-silence >/dev/null 2>&1 || true
}

# Apply a distinctive `ox` title, dark pane, and muted status-bar colors.
# Word (fg) color carries status; backgrounds stay dark so they sit next to
# other windows without neon blocks. `done` / ok / pass / success → idle.
apply_window_status() {
  local win=$1 change=$2 status=$3
  local title style pane pane_active
  pane="fg=#b4b4b4,bg=#141414"
  pane_active="fg=#d0d0d0,bg=#171717"
  case "$status" in
    idle|""|done|ok|pass|success)
      title="ox ·${change}"
      style="fg=#8fbfb8,bg=#1a2422,nobold,noitalics"
      status=idle
      ;;
    busy|working|running)
      title="ox …${change}"
      style="fg=#cbb27a,bg=#242018,nobold,noitalics"
      status=busy
      ;;
    fail|failed|error)
      title="ox ✗${change}"
      style="fg=#c98a8a,bg=#241818,nobold,noitalics"
      status=fail
      ;;
    *)
      die "unknown status '$status' (expected busy|done|fail|idle)"
      ;;
  esac
  tmux set-option -w -t "$win" @opsx_status "$status" >/dev/null 2>&1
  tmux rename-window -t "$win" "$title" >/dev/null 2>&1 \
    || die "failed to rename window $win to $title"
  tmux set-window-option -t "$win" window-status-style "$style" >/dev/null 2>&1 || true
  tmux set-window-option -t "$win" window-status-current-style "$style" >/dev/null 2>&1 || true
  tmux set-window-option -t "$win" window-style "$pane" >/dev/null 2>&1 || true
  tmux set-window-option -t "$win" window-active-style "$pane_active" >/dev/null 2>&1 || true
  # Keep rename locked so the agent CLI process cannot overwrite the badge.
  tmux set-window-option -t "$win" automatic-rename off >/dev/null 2>&1
  tmux set-window-option -t "$win" allow-rename off >/dev/null 2>&1
  if [ "$status" = busy ]; then
    arm_busy_silence_watch "$win" "$change"
  else
    disarm_busy_silence_watch "$win"
  fi
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
    cursor)              printf '%s' agent ;;
    codex-cli|oai)       printf '%s' codex ;;
    open-code|oc)        printf '%s' opencode ;;
    gemini-cli|google-gemini) printf '%s' gemini ;;
    *)                   printf '%s' "$1" ;;
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

# True when running under Codex CLI. Codex sets CODEX_SANDBOX* on the shells it
# spawns; otherwise walk the parent chain for the `codex` process.
running_under_codex() {
  [ -n "${CODEX_SANDBOX:-}" ] && return 0
  [ -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" ] && return 0

  local pid=$$ i=0 args comm
  while [ "$pid" -gt 1 ] && [ "$i" -lt 25 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$args" in
      *codex\ *|*/codex|*codex-cli*)
        return 0 ;;
    esac
    case "$comm" in
      codex|Codex)
        return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    i=$((i + 1))
  done
  return 1
}

# True when running under OpenCode CLI.
running_under_opencode() {
  [ -n "${OPENCODE_SERVER_PASSWORD:-}" ] && return 0
  [ -n "${OPENCODE_SERVER_USERNAME:-}" ] && return 0
  [ -n "${OPENCODE_CONFIG:-}" ] && return 0
  [ -d "${OPENCODE_CONFIG_DIR:-}" ] && return 0

  local pid=$$ i=0 args comm
  while [ "$pid" -gt 1 ] && [ "$i" -lt 25 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$args" in
      *opencode\ *|*/opencode|*open-code*)
        return 0 ;;
    esac
    case "$comm" in
      opencode|OpenCode)
        return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    i=$((i + 1))
  done
  return 1
}

# True when running under Gemini CLI.
running_under_gemini() {
  [ -n "${GEMINI_CLI:-}" ] && return 0

  local pid=$$ i=0 args comm
  while [ "$pid" -gt 1 ] && [ "$i" -lt 25 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$args" in
      */gemini\ *|*/gemini|*gemini-cli*)
        return 0 ;;
    esac
    case "$comm" in
      gemini|Gemini)
        return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    i=$((i + 1))
  done
  return 1
}

# Pick which agent CLI launches new windows. Precedence: flag > $OPSX_AGENT_CLI >
# host detection > first of claude/agent/codex/opencode/gemini on PATH > error.
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
  elif running_under_codex && command -v codex >/dev/null 2>&1; then
    cli=codex
  elif running_under_opencode && command -v opencode >/dev/null 2>&1; then
    cli=opencode
  elif running_under_gemini && command -v gemini >/dev/null 2>&1; then
    cli=gemini
  elif command -v claude >/dev/null 2>&1; then
    cli=claude
  elif command -v agent >/dev/null 2>&1; then
    cli=agent
  elif command -v codex >/dev/null 2>&1; then
    cli=codex
  elif command -v opencode >/dev/null 2>&1; then
    cli=opencode
  elif command -v gemini >/dev/null 2>&1; then
    cli=gemini
  else
    die "no agent CLI found — install claude, agent, codex, opencode, or gemini, or pass --agent-cli <cmd>."
  fi
  command -v "$cli" >/dev/null 2>&1 \
    || die "agent CLI '$cli' is not on PATH — install it or pass --agent-cli <cmd>."
  printf '%s' "$cli"
}

# Read a dotted JSON string field (python3, else jq). Empty on miss.
# Also accepts JSONC (strips // and /* */ comments) for OpenCode configs.
json_str() {
  local file=$1 path=$2 val=""
  [ -f "$file" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    val=$(python3 -c '
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
# Strip // line comments and /* */ block comments (JSONC / opencode.jsonc).
raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
raw = re.sub(r"(?m)//.*?$", "", raw)
obj = json.loads(raw)
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

# Read a top-level string key from a TOML file (e.g. Codex config.toml). Handles
# `key = "value"` and `key = 'value'`, ignoring commented lines. Empty on miss.
toml_str() {
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ { insec=1 }             # stop at the first [section]
    !insec {
      line=$0
      sub(/[[:space:]]*#.*$/, "", line)       # strip trailing comments
      if (match(line, "^[[:space:]]*" k "[[:space:]]*=")) {
        sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", line)
        gsub(/^["'\'']|["'\'']$/, "", line)
        gsub(/[[:space:]]*$/, "", line)
        print line
        exit
      }
    }
  ' "$file" 2>/dev/null
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
  local explicit=${1:-} model="" oc_cfg=""
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
  elif running_under_codex; then
    model=$(toml_str "${CODEX_HOME:-$HOME/.codex}/config.toml" model)
  elif running_under_opencode; then
    oc_cfg="${OPENCODE_CONFIG:-}"
    [ -n "$oc_cfg" ] || oc_cfg="$HOME/.config/opencode/opencode.jsonc"
    [ -f "$oc_cfg" ] || oc_cfg="$HOME/.config/opencode/opencode.json"
    model=$(json_str "$oc_cfg" model)
  elif running_under_gemini; then
    [ -n "${GEMINI_MODEL:-}" ] && model=$GEMINI_MODEL
    [ -n "$model" ] || model=$(json_str "${GEMINI_DIR:-$HOME/.gemini}/settings.json" model)
  fi
  if model_is_default "$model"; then
    printf '%s' ""
    return 0
  fi
  printf '%s' "$model"
}

# Shell command that reads the prompt inside the new window's cwd.
# The $(cat …) is expanded later by the window's shell, not here.
# shellcheck disable=SC2016
build_launch_cmd() {
  local prompt_file=$1 cli=$2 model=${3:-} model_flag="" codex_model_flag="" oc_model_flag="" gemini_model_flag=""
  if [ -n "$model" ]; then
    model_flag=$(printf ' --model %q' "$model")
  fi
  case "$cli" in
    claude)
      printf 'claude --permission-mode bypassPermissions%s "$(cat %q)"' "$model_flag" "$prompt_file"
      ;;
    agent)
      # --force: skip command approval. --approve-mcps: load ~/.cursor/mcp.json
      # (browser-use, …) in this unattended window — without it Task/ops-applier
      # inherit no MCP and fall back to CLI/CDP. --trust: skip workspace prompt.
      printf 'agent --force --approve-mcps --trust%s "$(cat %q)"' "$model_flag" "$prompt_file"
      ;;
    codex)
      # No reliable spawn-by-name for custom agents — the window applies the
      # change itself. Bypass all approval/sandbox prompts so it runs unattended.
      # Codex takes the model with -m, not --model.
      [ -n "$model" ] && codex_model_flag=$(printf ' -m %q' "$model")
      printf 'codex --dangerously-bypass-approvals-and-sandbox%s "$(cat %q)"' \
        "$codex_model_flag" "$prompt_file"
      ;;
    opencode)
      # --auto: approve permissions that are not denied. --prompt: seed the TUI
      # with the dispatcher text. Model is provider/model via -m.
      [ -n "$model" ] && oc_model_flag=$(printf ' -m %q' "$model")
      printf 'opencode --auto%s --prompt "$(cat %q)"' "$oc_model_flag" "$prompt_file"
      ;;
    gemini)
      # Keep an interactive TUI (-i) like the other CLIs. YOLO + skip-trust so
      # the unattended window does not stall on tool or folder prompts.
      [ -n "$model" ] && gemini_model_flag=$(printf ' -m %q' "$model")
      printf 'gemini --approval-mode=yolo --skip-trust%s -i "$(cat %q)"' \
        "$gemini_model_flag" "$prompt_file"
      ;;
    *)
      printf '%s%s "$(cat %q)"' "$cli" "$model_flag" "$prompt_file"
      ;;
  esac
}

# Cursor CLI only loads *project* subagents from <cwd>/.cursor/agents/ — not
# ~/.cursor/agents/. Symlink (or copy) ops-applier and ops-qa into the project
# so Task can take subagent_type: "ops-applier" / "ops-qa".
ensure_cursor_project_agent() {
  local cwd=$1
  local file=${2:-opsx-applier.md}
  local name=${3:-ops-applier}
  local desc=${4:-Run when asked to implement features, apply changes, or execute OpenSpec apply tasks using a git worktree}
  local dir="$cwd/.cursor/agents"
  local dest="$dir/$file"
  local src="" claude="$HOME/.claude/agents/$file"

  if [ -f "$HOME/.cursor/agents/$file" ]; then
    src="$HOME/.cursor/agents/$file"
  elif [ -f "$claude" ]; then
    mkdir -p "$HOME/.cursor/agents"
    {
      printf '%s\n' '---'
      printf 'name: %s\n' "$name"
      printf 'description: %s\n' "$desc"
      printf '%s\n' '---'
      awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$claude"
    } > "$HOME/.cursor/agents/$file"
    src="$HOME/.cursor/agents/$file"
  else
    printf '# warning: no %s agent found under ~/.cursor/agents or ~/.claude/agents — run ./install.sh\n' "$name" >&2
    return 1
  fi

  mkdir -p "$dir" || die "cannot create $dir"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
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

ensure_cursor_project_agents() {
  local cwd=$1
  ensure_cursor_project_agent "$cwd" opsx-applier.md ops-applier \
    "Run when asked to implement features, apply changes, or execute OpenSpec apply tasks using a git worktree" || true
  ensure_cursor_project_agent "$cwd" opsx-qa.md ops-qa \
    "Run after ops-applier to validate UI/UX and catch visual regressions. Do not implement fixes." || true
  ensure_cursor_project_agent "$cwd" opsx-eval.md ops-eval \
    "Run after ops-applier to verify spec fidelity by execution: write and run one evals/ check per OpenSpec scenario. Never edits product code." || true
  ensure_cursor_project_agent "$cwd" opsx-reviewer.md ops-reviewer \
    "Run after ops-applier to review implementation: spec fidelity, logic, tests, and maintainability. Do not implement fixes." || true
  ensure_cursor_project_agent "$cwd" opsx-security.md ops-security \
    "Run after ops-applier to review security: auth, injection, secrets, unsafe defaults. Do not implement fixes." || true
}

# OpenCode loads agents from ~/.config/opencode/agents/ and <cwd>/.opencode/agents/.
ensure_opencode_project_agent() {
  local cwd=$1
  local oc_file=${2:-ops-applier.md}
  local claude_file=${3:-opsx-applier.md}
  local desc=${4:-Run when asked to implement features, apply changes, or execute OpenSpec apply tasks using a git worktree}
  local dir="$cwd/.opencode/agents"
  local dest="$dir/$oc_file"
  local src="" oc="$HOME/.config/opencode/agents/$oc_file" claude="$HOME/.claude/agents/$claude_file"

  if [ -f "$oc" ]; then
    src="$oc"
  elif [ -f "$claude" ]; then
    mkdir -p "$HOME/.config/opencode/agents"
    {
      printf '%s\n' '---'
      printf 'description: %s\n' "$desc"
      printf 'mode: subagent\n'
      printf 'permission:\n'
      printf '  edit: allow\n'
      printf '  bash: allow\n'
      printf '  read: allow\n'
      printf '  glob: allow\n'
      printf '  grep: allow\n'
      printf '  task: allow\n'
      printf '  skill: allow\n'
      printf '  webfetch: allow\n'
      printf '  websearch: allow\n'
      printf '  todowrite: allow\n'
      printf '  external_directory: allow\n'
      printf '%s\n' '---'
      awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$claude"
    } > "$oc"
    src="$oc"
  else
    printf '# warning: no %s agent found under ~/.config/opencode/agents — run ./install.sh\n' "$oc_file" >&2
    return 1
  fi

  mkdir -p "$dir" || die "cannot create $dir"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    printf '# opencode project agent: %s (existing file)\n' "$dest"
    return 0
  fi
  if ln -sfn "$src" "$dest" 2>/dev/null; then
    printf '# opencode project agent: %s -> %s\n' "$dest" "$src"
  else
    cp "$src" "$dest" || die "cannot install $dest"
    printf '# opencode project agent: %s (copied)\n' "$dest"
  fi
}

ensure_opencode_project_agents() {
  local cwd=$1
  ensure_opencode_project_agent "$cwd" ops-applier.md opsx-applier.md \
    "Run when asked to implement features, apply changes, or execute OpenSpec apply tasks using a git worktree" || true
  ensure_opencode_project_agent "$cwd" ops-qa.md opsx-qa.md \
    "Run after ops-applier to validate UI/UX and catch visual regressions. Do not implement fixes." || true
  ensure_opencode_project_agent "$cwd" ops-eval.md opsx-eval.md \
    "Run after ops-applier to verify spec fidelity by execution: write and run one evals/ check per OpenSpec scenario. Never edits product code." || true
  ensure_opencode_project_agent "$cwd" ops-reviewer.md opsx-reviewer.md \
    "Run after ops-applier to review implementation: spec fidelity, logic, tests, and maintainability. Do not implement fixes." || true
  ensure_opencode_project_agent "$cwd" ops-security.md opsx-security.md \
    "Run after ops-applier to review security: auth, injection, secrets, unsafe defaults. Do not implement fixes." || true
}

# Gemini CLI loads agents from ~/.gemini/agents/ and project .gemini/agents/.
ensure_gemini_project_agent() {
  local cwd=$1
  local file=${2:-opsx-applier.md}
  local dir="$cwd/.gemini/agents"
  local dest="$dir/$file"
  local src="$HOME/.gemini/agents/$file"
  local claude="$HOME/.claude/agents/$file"

  if [ ! -f "$src" ] && [ -f "$claude" ]; then
    mkdir -p "$HOME/.gemini/agents"
    cp "$claude" "$src" || true
  fi
  if [ ! -f "$src" ]; then
    printf '# warning: no %s agent found under ~/.gemini/agents — run ./install.sh\n' "$file" >&2
    return 1
  fi

  mkdir -p "$dir" || die "cannot create $dir"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    printf '# gemini project agent: %s (existing file)\n' "$dest"
    return 0
  fi
  if ln -sfn "$src" "$dest" 2>/dev/null; then
    printf '# gemini project agent: %s -> %s\n' "$dest" "$src"
  else
    cp "$src" "$dest" || die "cannot install $dest"
    printf '# gemini project agent: %s (copied)\n' "$dest"
  fi
}

ensure_gemini_project_agents() {
  local cwd=$1
  ensure_gemini_project_agent "$cwd" opsx-applier.md || true
  ensure_gemini_project_agent "$cwd" opsx-qa.md || true
  ensure_gemini_project_agent "$cwd" opsx-eval.md || true
  ensure_gemini_project_agent "$cwd" opsx-reviewer.md || true
  ensure_gemini_project_agent "$cwd" opsx-security.md || true
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
    ensure_cursor_project_agents "$cwd"
  fi
  if [ "$cli" = opencode ]; then
    ensure_opencode_project_agents "$cwd"
  fi
  if [ "$cli" = gemini ]; then
    ensure_gemini_project_agents "$cwd"
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
      apply_window_status "$win" "$change" busy
      printf 'created %s %s:%s agent=%s model=%s session=created\n' \
        "$win" "$sess" "$change" "$cli" "${model:-default}"
      printf '# attach with: tmux attach -t %s\n' "$sess"
      return 0
    fi
  fi

  win=$(find_window "$sess" "$change")

  if [ -n "$win" ]; then
    [ "$create_only" -eq 1 ] && die "window '$change' already exists ($win)"
    apply_window_status "$win" "$change" busy
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
  apply_window_status "$win" "$change" busy

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

  apply_window_status "$win" "$change" busy
  send_prompt "$win" "$prompt_file"
  printf 'sent %s %s:%s\n' "$win" "$sess" "$change"
}

# Project directories to stop previews from: $PWD inside a git repository;
# otherwise the main checkout of each agent window being closed ($1 = change,
# or --all for every opsx window in the lookup session), found from its pane.
preview_project_dirs() {
  local target=$1 sess wins w path common
  if git rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s\n' "$PWD"; return 0
  fi
  sess=$(lookup_session 2>/dev/null) || return 0
  if [ "$target" = "--all" ]; then
    wins=$(tmux list-windows -t "$sess" -F '#{window_id} #{@opsx_change}' 2>/dev/null \
           | awk 'NF>1 && $2!="" { print $1 }')
  else
    wins=$(find_window "$sess" "$target" 2>/dev/null)
  fi
  for w in $wins; do
    path=$(tmux display-message -p -t "$w" '#{pane_current_path}' 2>/dev/null)
    [ -n "$path" ] && [ -d "$path" ] || continue
    common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
    dirname -- "$common"
  done | sort -u
}

# Run `opsx-preview.sh stop <change>|--all` from next to this script, from
# the project (see preview_project_dirs); output is relayed, failures are
# ignored. When no project can be found, say that previews were not stopped.
stop_previews() {
  local script out dirs dir
  script="$(cd -- "$(dirname -- "$0")" && pwd)/opsx-preview.sh"
  [ -x "$script" ] || return 0
  dirs=$(preview_project_dirs "$1")
  if [ -z "$dirs" ]; then
    printf '# warning: previews were NOT stopped — not inside a git repository and no project found from the windows; run from the project root: %s stop %s\n' "$script" "$1"
    return 0
  fi
  while IFS= read -r dir; do
    out=$(cd -- "$dir" && "$script" stop "$1" 2>&1) || true
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/# /'
  done <<< "$dirs"
  return 0
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
  here=$(current_window)

  # Stop the preview first (route, app process group, window). Never fatal:
  # a missing or failing opsx-preview.sh must not block closing the window.
  # Skipped when this close is about to refuse closing the caller's own
  # window, so a refused close changes nothing.
  if [ "$all" -eq 1 ]; then
    stop_previews --all
  elif [ "$force" -eq 1 ] || [ -z "$here" ] \
       || [ "$(find_window "$(lookup_session 2>/dev/null)" "$change" 2>/dev/null)" != "$here" ]; then
    stop_previews "$change"
  fi

  sess=$(lookup_session) || exit 1

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

cmd_mark() {
  local change="" status="" if_busy=0 current=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --if-busy) if_busy=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)
        if [ -z "$change" ]; then change=$1
        elif [ -z "$status" ]; then status=$1
        else die "usage: opsx-window.sh mark <change> <busy|done|fail|idle> [--if-busy]"
        fi
        shift ;;
    esac
  done
  [ -n "$change" ] || die "usage: opsx-window.sh mark <change> <busy|done|fail|idle> [--if-busy]"
  [ -n "$status" ] || die "usage: opsx-window.sh mark <change> <busy|done|fail|idle> [--if-busy]"

  require_tmux
  local sess win
  sess=$(lookup_session) || exit 1
  win=$(find_window "$sess" "$change")
  [ -n "$win" ] || die "no window for change '$change' in session '$sess'."
  # Ensure the tag exists even on older windows found by name only.
  tmux set-option -w -t "$win" @opsx_change "$change" >/dev/null 2>&1
  if [ "$if_busy" -eq 1 ]; then
    current=$(tmux show-options -wv -t "$win" @opsx_status 2>/dev/null || true)
    if [ "$current" != busy ]; then
      printf 'skipped %s %s:%s status=%s (not busy)\n' "$win" "$sess" "$change" "${current:-unset}"
      return 0
    fi
  fi
  apply_window_status "$win" "$change" "$status"
  printf 'marked %s %s:%s status=%s\n' "$win" "$sess" "$change" \
    "$(tmux show-options -wv -t "$win" @opsx_status 2>/dev/null || echo "$status")"
}

cmd_list() {
  require_tmux
  local sess
  sess=$(lookup_session) || exit 1
  printf '# session %s\n' "$sess"
  # The opsx column marks windows this script created (see tag_window).
  # status comes from @opsx_status (busy|fail|idle; done is stored as idle).
  tmux list-windows -t "$sess" \
    -F '#{window_id}	#{?@opsx_change,opsx,#{?@opsx_preview,preview,-}}	#{@opsx_status}	#{window_name}	#{pane_current_command}	#{pane_current_path}'
}

# ---------- preview windows (driven by opsx-preview.sh) ----------

# Project key of a preview window: the main checkout's absolute path (the
# parent of the git common dir), $PWD outside a repository. opsx-preview.sh
# runs us from the main checkout, so this matches its idea of the project.
preview_project_key() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  if [ -z "$common" ]; then
    common=$(git rev-parse --git-common-dir 2>/dev/null) && common=$(cd -- "$common" 2>/dev/null && pwd) || common=""
  fi
  if [ -n "$common" ]; then dirname -- "$common"; else pwd; fi
}

# Window id(s) on the whole tmux server tagged @opsx_preview=$1 for this
# project ($1 = "--all": every preview of this project). Fails, with tmux's
# error on stderr, when the server cannot be asked; no server at all simply
# means no windows.
find_preview_windows() {
  local key out
  key=$(preview_project_key)
  if ! out=$(tmux list-windows -a -F '#{window_id}	#{@opsx_preview}	#{@opsx_preview_project}' 2>&1); then
    case "$out" in
      *"no server running"*|*"No such file or directory"*) return 0 ;;
    esac
    printf 'cannot reach the tmux server: %s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out" \
    | awk -F '\t' -v n="$1" -v k="$key" '$2!="" && $3==k && (n=="--all" || $2==n) { print $1 }'
}

# Same rule as valid_name in opsx-preview.sh; this script checks its own input.
valid_preview_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

cmd_preview_start() {
  local change=${1:-} cwd="$PWD" script=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd)    cwd=${2:-}; shift 2 ;;
      --script) script=${2:-}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$change" ] || die "usage: opsx-window.sh preview-start <change> --cwd <dir> --script <file>"
  valid_preview_name "$change" || die "invalid preview name '$change'"
  [ -n "$script" ] || die "--script is required"
  [ -f "$script" ] || die "script not found: $script"
  [ -d "$cwd" ] || die "cwd not found: $cwd"

  require_tmux
  local sess win title run created=""
  # ASCII marker: a non-UTF-8 client would show ▶ as `_`, like the agent badges.
  title="ox >$change"
  run=$(printf 'bash %q' "$script")
  if inside_tmux; then
    sess=$(current_session) || exit 1
  else
    sess=$(project_session_name "$PWD")
    if ! session_exists "$sess"; then
      win=$(tmux new-session -d -s "$sess" -n "$title" -c "$cwd" -P -F '#{window_id}' \
            "$run" 2>&1) || die "failed to create session '$sess': $win"
      created=" session=created"
    fi
  fi
  if [ -z "$created" ]; then
    # Started with a command, never send-keys: nothing is typed into any pane.
    win=$(tmux new-window -d -t "$sess:" -n "$title" -c "$cwd" -P -F '#{window_id}' \
          "$run" 2>&1) || die "failed to create window: $win"
  fi
  tmux set-option -w -t "$win" remain-on-exit on >/dev/null 2>&1 || true
  tmux set-option -w -t "$win" @opsx_preview "$change" >/dev/null 2>&1
  tmux set-option -w -t "$win" @opsx_preview_project "$(preview_project_key)" >/dev/null 2>&1
  tmux set-window-option -t "$win" automatic-rename off >/dev/null 2>&1 || true
  tmux set-window-option -t "$win" allow-rename off >/dev/null 2>&1 || true
  printf 'created %s %s:%s%s\n' "$win" "$sess" "$title" "$created"
  [ -n "$created" ] && printf '# attach with: tmux attach -t %s\n' "$sess"
  return 0
}

cmd_preview_find() {
  local change=${1:-} ids
  [ -n "$change" ] || die "usage: opsx-window.sh preview-find <change>"
  require_tmux
  ids=$(find_preview_windows "$change") || exit 1
  [ -n "$ids" ] || exit 1
  printf '%s\n' "$ids"
}

cmd_preview_kill() {
  local change=${1:-} ids win n=0
  [ -n "$change" ] || die "usage: opsx-window.sh preview-kill <change>|--all"
  require_tmux
  local out failed=0
  ids=$(find_preview_windows "$change") || exit 1
  for win in $ids; do
    if out=$(tmux kill-window -t "$win" 2>&1); then
      n=$((n + 1))
      printf 'closed %s (preview %s)\n' "$win" "$change"
    else
      printf 'could not close %s (preview %s): %s\n' "$win" "$change" "$out" >&2
      failed=1
    fi
  done
  [ "$n" -gt 0 ] || [ "$failed" -eq 1 ] || printf 'no preview window for %s\n' "$change"
  [ "$failed" -eq 0 ]
}

case "${1:-}" in
  ensure)     shift; cmd_ensure "$@" ;;
  send)       shift; cmd_send "$@" ;;
  close)      shift; cmd_close "$@" ;;
  status)     shift; cmd_status "$@" ;;
  mark)         shift; cmd_mark "$@" ;;
  detect-cli)   shift; cmd_detect_cli "$@" ;;
  detect-model) shift; cmd_detect_model "$@" ;;
  list)         shift; cmd_list "$@" ;;
  preview-start) shift; cmd_preview_start "$@" ;;
  preview-find)  shift; cmd_preview_find "$@" ;;
  preview-kill)  shift; cmd_preview_kill "$@" ;;
  ""|-h|--help)
    awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"
    ;;
  *) die "unknown subcommand: $1 (expected ensure|send|close|status|mark|detect-cli|detect-model|list|preview-start|preview-find|preview-kill)" ;;
esac
