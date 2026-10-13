#!/usr/bin/env bash
# fork.sh — tmux plumbing for the /fork skill.
#
# Fork the current agent conversation into a read-only child agent in a tmux
# pane (default) or window. The parent writes a brief; the child answers
# questions and returns a short result; the parent is notified (never typed
# into) and pulls the result with `collect`.
#
# Usage:
#   fork.sh open [--window] [--vertical] [--cli <name>] [--cwd <dir>]
#                [--model <m>] [--parent-model <m>] [--brief-only]
#                [--page-dir <abs dir>]                             < brief
#   fork.sh native [--cli <name>] [--cwd <dir>] [--brief-only]
#   fork.sh return                                                     < result
#   fork.sh page [--manifest]                                          < html|tsv
#   fork.sh collect [<id>]
#   fork.sh list
#   fork.sh close <id> | --all
#   fork.sh detect-cli [--cli <name>]
#   fork.sh help
#
# State: ${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/<tmux-session>/<id>/
#   brief.md    brief (parent text + generated fork protocol), first prompt
#   meta        key=value: parent_pane child_pane window cli model cwd created status
#               context (full|brief) context_source page_dir (empty = no page) …
#   result.md   the child's result (written by `return`, or recovered by collect)
#   capture.txt last pane capture (saved by collect/close when no result)
#
# Child CLI selection: --cli > $FORK_CLI > host CLI (Cursor, Claude, Codex,
# OpenCode, Gemini) > first of claude/agent/codex/opencode/gemini on PATH.
# The host CLI is $FORK_HOST_CLI when set (a CLI name, or `none` = undetected),
# otherwise detected from env vars and the process chain.
#
# Child model selection: --model > $FORK_MODEL > --parent-model (only when the
# child CLI is the host CLI; for opencode only in provider/model form) > none
# (no model flag, the CLI's default). The parent agent passes its own model id
# as --parent-model. Values that are empty, contain whitespace or start with
# `-` are rejected. Flag per CLI: claude/agent --model, codex/opencode/gemini -m.
# Children always launch in the CLI's read-only / plan mode and never with
# bypass or force flags:
#   claude    --permission-mode plan (+ narrow allow rule for `fork.sh return`,
#             and one for `fork.sh page` in a page fork)
#   agent     --mode ask
#   codex     --sandbox read-only --ask-for-approval on-request
#   opencode  --agent plan
#   gemini    --approval-mode plan
#
# Context mode: a fork is "full" (native) when the child CLI is the host CLI,
# that CLI can fork a session natively, and native mode is not disabled; the
# child then starts as a fork of the parent's whole conversation and the parent
# writes only a short brief (question + role). Otherwise it is "brief": the
# child knows only the brief the parent wrote. Native launches:
#   claude    --resume <$CLAUDE_CODE_SESSION_ID> --fork-session (the id is taken
#             from the environment, else recovered from the process chain below
#             the claude process; an id only the claude process or tmux server
#             holds may be stale and falls back to brief)
#   opencode  --continue --fork (only when --cwd is the OpenCode session's
#             directory, the cwd of the opencode process: OpenCode continues
#             the last session of that directory)
# Codex, Gemini and Cursor (agent) always use brief mode, as do cross-CLI forks.
# Opt out with `open --brief-only` or FORK_NATIVE=0. `fork.sh native` prints the
# decision `open` would make (`full <cli> <source>` or `brief <reason>`) without
# writing anything, so the parent knows which brief to write.
#
# Page forks (used by /explain): `open --page-dir <dir>` records page_dir in
# meta, passes FORK_PAGE_DIR to the child, appends a page protocol section to
# the brief (labels, stable ids, SVG-first diagrams; the page's languages
# come from the brief's `Languages:` line, written by /explain) and (Claude)
# allows `fork.sh page` beside `fork.sh return`. The
# child runs `fork.sh page < html` to replace <dir>/index.html atomically, or
# `fork.sh page --manifest < tsv` for <dir>/manifest.tsv; nothing else is ever
# written (mode 600). After an index.html write, <dir>/../.reindex is run
# (its exit status is ignored) only when <dir>/.. sits directly under
# <state root>/explain/ and the hook is an executable regular file owned by
# the user: /explain installs it there to regenerate the library index. The page dir comes from $FORK_PAGE_DIR, the
# process chain, or the fork's meta.
#
# Every subcommand except `return` and `page` requires tmux. Nothing here ever sends keys
# to the parent pane.
#
# Exit codes: 0 ok, 1 usage/error (`page`/`return`: not a fork), 2 `page`:
# empty input, 3 result or page could not be written (`return`: use the
# <<<FORK-RESULT … FORK-RESULT>>> marker fallback; `page` has no fallback),
# 4 `page`: the fork has no page directory (not opened with --page-dir).

set -uo pipefail

die() { printf 'fork: %s\n' "$1" >&2; exit "${2:-1}"; }

MARK_BEGIN='<<<FORK-RESULT'
MARK_END='FORK-RESULT>>>'

this_script() {
  printf '%s/%s' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" \
    "$(basename -- "${BASH_SOURCE[0]}")"
}

state_root() {
  printf '%s/agent-forks' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# ---------------------------------------------------------------------------
# tmux environment

# Some CLIs (Codex, sandboxes) strip $TMUX / $TMUX_PANE from the shells they
# spawn. Recover them from the parent process chain via /proc.
recover_env_var() {
  local name=$1 pid=$$ i=0 val
  while [ "$pid" -gt 1 ] && [ "$i" -lt 30 ]; do
    if [ -r "/proc/$pid/environ" ]; then
      val=$({ tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null \
            | awk -v n="$name" 'index($0, n "=") == 1 { print substr($0, length(n) + 2); exit }')
      if [ -n "$val" ]; then
        printf '%s' "$val"
        return 0
      fi
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    i=$((i + 1))
  done
  return 1
}

recover_tmux_env() {
  local v sock
  if [ -z "${TMUX:-}" ] && v=$(recover_env_var TMUX); then
    sock=${v%%,*}
    if [ -z "$sock" ] || [ -S "$sock" ]; then
      TMUX=$v
      export TMUX
    fi
  fi
  if [ -n "${TMUX:-}" ] && [ -z "${TMUX_PANE:-}" ] && v=$(recover_env_var TMUX_PANE); then
    TMUX_PANE=$v
    export TMUX_PANE
  fi
}

require_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux is not installed."
  recover_tmux_env
  [ -n "${TMUX:-}" ] || die "tmux is required — run your agent inside a tmux session to use /fork."
  tmux display-message -p '#{session_name}' >/dev/null 2>&1 \
    || die "cannot reach the tmux server (\$TMUX=$TMUX)."
}

tmux_ok() {
  [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1 \
    && tmux display-message -p '#{pid}' >/dev/null 2>&1
}

# Session name of the caller's pane (not whichever client is "current").
current_session() {
  local s=""
  if [ -n "${TMUX_PANE:-}" ]; then
    s=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
  fi
  [ -n "$s" ] || s=$(tmux display-message -p '#S' 2>/dev/null)
  [ -n "$s" ] || die "could not determine the current tmux session."
  printf '%s' "$s"
}

# Directory-safe form of a session name.
session_key() {
  local k
  k=$(printf '%s' "$1" | tr '/\t\n' '___')
  case "$k" in ''|.|..) k="_$k" ;; esac
  printf '%s' "$k"
}

session_dir() {
  printf '%s/%s' "$(state_root)" "$(session_key "$(current_session)")"
}

# `display-message -t <dead pane>` can exit 0 with empty output, so compare
# the id it reports instead of trusting the exit status.
pane_alive() {
  [ -n "${1:-}" ] || return 1
  [ "$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null)" = "$1" ]
}

# True when pane $1 is the child of fork dir $2 (guards against a pane id that
# was reused after a tmux server restart).
pane_is_fork() {
  local dir
  pane_alive "$1" || return 1
  dir=$(tmux show-options -p -v -t "$1" @fork_dir 2>/dev/null)
  [ "$dir" = "$2" ]
}

# ---------------------------------------------------------------------------
# meta file: one key=value per line

meta_get() {
  local key=$1 file=$2/meta
  [ -f "$file" ] || return 0
  awk -v k="$key" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$file"
}

meta_set() {
  local key=$1 val=$2 dir=$3 file tmp
  file=$dir/meta
  val=$(printf '%s' "$val" | tr '\n\r' '  ')
  tmp=$(mktemp "$dir/.meta.XXXXXX") || return 1
  if [ -f "$file" ]; then
    awk -v k="$key" 'index($0, k "=") != 1' "$file" > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv -f "$tmp" "$file"
}

# Numeric ids under $1, ascending.
fork_ids() {
  local d
  [ -d "$1" ] || return 0
  for d in "$1"/*/; do
    d=${d%/}
    d=${d##*/}
    case "$d" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$d"
  done | sort -n
}

# Allocate the next id under $1 atomically. Each id is claimed by creating
# .ids/<n> with bash noclobber (O_CREAT|O_EXCL). `mkdir` is not used as the
# lock because some coreutils builds (e.g. uutils) do not fail reliably when
# two processes create the same directory at once.
alloc_id() {
  local sdir=$1 n max f
  mkdir -p "$sdir/.ids" || die "cannot create state dir $sdir"
  max=$( { fork_ids "$sdir"
           for f in "$sdir"/.ids/*; do f=${f##*/}; case "$f" in ''|*[!0-9]*) ;; *) printf '%s\n' "$f" ;; esac; done
         } | sort -n | tail -n 1)
  n=$(( ${max:-0} + 1 ))
  while ! ( set -C; : > "$sdir/.ids/$n" ) 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -gt 100000 ] && die "could not allocate a fork id under $sdir"
  done
  mkdir -p "$sdir/$n" || die "cannot create $sdir/$n"
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# CLI detection (pattern copied from opsx-run/opsx-window.sh, not shared)

normalize_cli() {
  case "$1" in
    cursor|cursor-agent)      printf '%s' agent ;;
    codex-cli|oai)            printf '%s' codex ;;
    open-code|oc)             printf '%s' opencode ;;
    gemini-cli|google-gemini) printf '%s' gemini ;;
    claude-code)              printf '%s' claude ;;
    *)                        printf '%s' "$1" ;;
  esac
}

# Walk the parent chain; succeed when any ancestor matches the args/comm globs.
ancestor_matches() {
  local args_re=$1 comm_re=$2 pid=$$ i=0 args comm
  while [ "$pid" -gt 1 ] && [ "$i" -lt 25 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    if printf '%s' "$args" | grep -Eq -- "$args_re"; then return 0; fi
    if printf '%s' "$comm" | grep -Eqx -- "$comm_re"; then return 0; fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    i=$((i + 1))
  done
  return 1
}

running_under_cursor() {
  [ -n "${CURSOR_AGENT:-}" ] && return 0
  [ "${CURSOR_INVOKED_AS:-}" = agent ] && return 0
  [ -n "${CURSOR_RIPGREP_PATH:-}" ] && return 0
  [ -n "${CURSOR_CONVERSATION_ID:-}" ] && return 0
  ancestor_matches 'cursor-agent|cursor_agent|/\.cursor/.*agent|/agent( |$)' \
    'agent|cursor-agent|Cursor|cursor'
}

running_under_claude() {
  [ -n "${CLAUDE_CODE_SSE_PORT:-}" ] && return 0
  [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] && return 0
  ancestor_matches 'claude-code|/claude( |$)' 'claude|Claude'
}

running_under_codex() {
  [ -n "${CODEX_SANDBOX:-}" ] && return 0
  [ -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" ] && return 0
  ancestor_matches '(^|/)codex( |$)|codex-cli' 'codex|Codex'
}

running_under_opencode() {
  [ -n "${OPENCODE_SERVER_PASSWORD:-}" ] && return 0
  [ -n "${OPENCODE_SERVER_USERNAME:-}" ] && return 0
  [ -n "${OPENCODE_CONFIG:-}" ] && return 0
  ancestor_matches '(^|/)opencode( |$)|open-code' 'opencode|OpenCode'
}

running_under_gemini() {
  [ -n "${GEMINI_CLI:-}" ] && return 0
  ancestor_matches '/gemini( |$)|gemini-cli' 'gemini|Gemini'
}

# The CLI this script runs under: $FORK_HOST_CLI when set (`none` = not
# detected), else the running_under_* checks. Empty when nothing matches; there
# is deliberately no PATH fallback.
host_cli() {
  if [ -n "${FORK_HOST_CLI:-}" ]; then
    [ "$FORK_HOST_CLI" = none ] || normalize_cli "$FORK_HOST_CLI"
    return 0
  fi
  if running_under_cursor; then printf '%s' agent
  elif running_under_claude; then printf '%s' claude
  elif running_under_codex; then printf '%s' codex
  elif running_under_opencode; then printf '%s' opencode
  elif running_under_gemini; then printf '%s' gemini
  fi
  return 0
}

resolve_cli() {
  local explicit=${1:-} cli="" host
  host=""
  [ -z "$explicit" ] && [ -z "${FORK_CLI:-}" ] && host=$(host_cli)
  if [ -n "$explicit" ]; then
    cli=$(normalize_cli "$explicit")
  elif [ -n "${FORK_CLI:-}" ]; then
    cli=$(normalize_cli "$FORK_CLI")
  elif [ -n "$host" ] && command -v "$host" >/dev/null 2>&1; then
    cli=$host
  else
    for cli in claude agent codex opencode gemini ""; do
      [ -n "$cli" ] && command -v "$cli" >/dev/null 2>&1 && break
    done
    [ -n "$cli" ] || die "no agent CLI found — install claude, agent, codex, opencode or gemini, or pass --cli."
  fi
  case "$cli" in
    claude|agent|codex|opencode|gemini) ;;
    *) die "unsupported CLI '$cli' — use one of: claude, agent (Cursor), codex, opencode, gemini." ;;
  esac
  command -v "$cli" >/dev/null 2>&1 || die "agent CLI '$cli' is not on PATH."
  printf '%s' "$cli"
}

# ---------------------------------------------------------------------------
# Model selection

# A model value must be non-empty, contain no whitespace and not start with
# `-` (the child CLI could read it as a flag, e.g. a bypass flag).
valid_model() {
  case "$1" in
    ''|-*|*[[:space:]]*) return 1 ;;
  esac
  return 0
}

check_model() {
  valid_model "$2" \
    || die "invalid $1 value '$2' — a model must be non-empty, contain no whitespace and not start with '-'."
}

# Print the child's model for CLI $1 (empty = CLI default):
# --model ($2) > $FORK_MODEL > --parent-model ($3, same CLI as the host only;
# opencode only in provider/model form) > none.
resolve_model() {
  local cli=$1 explicit=$2 parent=$3 host
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
  elif [ -n "${FORK_MODEL:-}" ]; then
    printf '%s' "$FORK_MODEL"
  elif [ -n "$parent" ]; then
    host=$(host_cli)
    [ -n "$host" ] && [ "$host" = "$cli" ] || return 0
    if [ "$cli" = opencode ]; then
      case "$parent" in ?*/?*) ;; *) return 0 ;; esac
    fi
    printf '%s' "$parent"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Native (full-context) forks

valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# Read variable $2 from /proc/$1/environ (empty when unset or unreadable).
proc_env_var() {
  [ -r "/proc/$1/environ" ] || return 0
  { tr '\0' '\n' < "/proc/$1/environ"; } 2>/dev/null \
    | awk -v n="$2" 'index($0, n "=") == 1 { print substr($0, length(n) + 2); exit }'
}

# Is pid $1 a Claude Code process (native binary or node running claude-code)?
is_claude_proc() {
  local comm args
  comm=$(ps -o comm= -p "$1" 2>/dev/null | tr -d ' ')
  case "$comm" in claude|Claude) return 0 ;; esac
  args=$(ps -o args= -p "$1" 2>/dev/null) || return 1
  printf '%s' "$args" | grep -Eq -- '(^|/)claude( |$)|claude-code'
}

# Is pid $1 a tmux server/client process?
is_tmux_proc() {
  case "$(ps -o comm= -p "$1" 2>/dev/null)" in tmux*) return 0 ;; esac
  return 1
}

# Recover CLAUDE_CODE_SESSION_ID from the parent chain. The claude process and
# the tmux server keep the id they were *launched* with, which can belong to an
# earlier conversation (a tmux server started from a Claude shell, a claude
# started from such a pane), so they are never read: the walk takes the nearest
# ancestor below them, and an id equal to one of those launch-time values is
# rejected as stale (pane shells inherit the server's). Prints the id; returns
# 1 when none was found, 2 when only a stale id was found.
recover_session_id() {
  local pid=$$ i=0 v cand="" stale="" tpid
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$i" -lt 30 ]; do
    if is_claude_proc "$pid" || is_tmux_proc "$pid"; then
      v=$(proc_env_var "$pid" CLAUDE_CODE_SESSION_ID)
      [ -n "$v" ] && stale="$stale $v"
      break
    fi
    if [ -z "$cand" ]; then
      cand=$(proc_env_var "$pid" CLAUDE_CODE_SESSION_ID)
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    i=$((i + 1))
  done
  [ -n "$cand" ] || return 1
  # The tmux server of this session, also when it is not on the chain.
  if [ -n "${TMUX:-}" ]; then
    tpid=${TMUX#*,}; tpid=${tpid%%,*}
    case "$tpid" in
      ''|*[!0-9]*) ;;
      *) v=$(proc_env_var "$tpid" CLAUDE_CODE_SESSION_ID); [ -n "$v" ] && stale="$stale $v" ;;
    esac
  fi
  case " $stale " in *" $cand "*) return 2 ;; esac
  printf '%s' "$cand"
}

# The parent's Claude Code session id: $CLAUDE_CODE_SESSION_ID, else recovered
# by recover_session_id (some shells strip it). Only a well-formed UUID is
# printed. Returns 1 when no id was found, 2 when only a stale one was.
parent_session_id() {
  local v=${CLAUDE_CODE_SESSION_ID:-} rc
  if [ -n "$v" ]; then
    valid_uuid "$v" || return 1
    printf '%s' "$v"; return 0
  fi
  v=$(recover_session_id); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  valid_uuid "$v" || return 1
  printf '%s' "$v"
}

# The directory the OpenCode session runs in: the cwd of the nearest opencode
# ancestor process (the agent's shell may have cd'd elsewhere), else this
# shell's directory.
opencode_session_dir() {
  local pid=$$ i=0 comm args d
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$i" -lt 30 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if [ "$comm" = opencode ] || printf '%s' "$args" | grep -Eq -- '(^|/)opencode( |$)'; then
      if d=$(readlink "/proc/$pid/cwd" 2>/dev/null) && [ -d "$d" ]; then
        (cd -- "$d" && pwd -P); return 0
      fi
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    i=$((i + 1))
  done
  pwd -P
}

# Print `full <cli> <source>` or `brief <reason>` for child CLI $1 in cwd $2
# ($3 = 1 for --brief-only). Order: same CLI as the host, CLI with a true fork,
# opencode only in the parent's cwd, not disabled, claude session id found.
native_mode() {
  local cli=$1 cwd=$2 brief_only=${3:-0} host here there sid rc
  host=$(host_cli)
  if [ -z "$host" ]; then
    printf 'brief host CLI not detected (child %s)' "$cli"; return 0
  fi
  if [ "$host" != "$cli" ]; then
    printf 'brief cross-CLI (%s -> %s)' "$host" "$cli"; return 0
  fi
  case "$cli" in
    claude|opencode) ;;
    *) printf 'brief %s has no true fork' "$cli"; return 0 ;;
  esac
  if [ "$cli" = opencode ]; then
    here=$(opencode_session_dir)
    there=$(cd -- "$cwd" 2>/dev/null && pwd -P) || there=$cwd
    if [ "$here" != "$there" ]; then
      printf 'brief cwd differs from the opencode session directory (%s); opencode sessions are per directory' "$here"; return 0
    fi
  fi
  if [ "$brief_only" = 1 ]; then
    printf 'brief disabled (--brief-only)'; return 0
  fi
  if [ "${FORK_NATIVE:-1}" = 0 ]; then
    printf 'brief disabled (FORK_NATIVE=0)'; return 0
  fi
  case "$cli" in
    claude)
      sid=$(parent_session_id); rc=$?
      if [ "$rc" -eq 0 ]; then
        printf 'full claude session %s' "$sid"
      elif [ "$rc" -eq 2 ]; then
        printf 'brief stale CLAUDE_CODE_SESSION_ID (the only id found is the one the claude process or tmux server was launched with; parent session id not verified)'
      else
        printf 'brief no CLAUDE_CODE_SESSION_ID (parent session id not found)'
      fi
      ;;
    opencode) printf 'full opencode continue' ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Launch command (read-only; never bypass/force flags)

# The "$(cat …)" parts are meant to stay literal: they run in the launcher.
# shellcheck disable=SC2016
build_launch_cmd() {
  local cli=$1 brief=$2 id=$3 dir=$4 parent=$5 model=${6:-} native=${7:-} page_dir=${8:-}
  local script envp carve rule rules mf="" nf=""
  script=$(this_script)
  envp=$(printf 'FORK_ID=%q FORK_DIR=%q FORK_PARENT=%q FORK_SH=%q' "$id" "$dir" "$parent" "$script")
  [ -n "$page_dir" ] && envp="$envp $(printf 'FORK_PAGE_DIR=%q' "$page_dir")"
  if [ -n "$model" ]; then
    case "$cli" in
      claude|agent) mf=$(printf ' --model %q' "$model") ;;
      *)            mf=$(printf ' -m %q' "$model") ;;
    esac
  fi
  # $native is the native_mode line; only `full <cli> …` adds fork flags.
  case "$native" in
    "full claude session "*)
      nf=${native#full claude session }
      valid_uuid "$nf" || die "invalid parent session id '$nf'"
      nf=$(printf ' --resume %q --fork-session' "$nf") ;;
    "full opencode "*) nf=' --continue --fork' ;;
  esac
  case "$cli" in
    claude)
      # Plan mode refuses mutating shell commands; allow exactly `fork.sh
      # return` (and `fork.sh page` in a page fork; literal path — variables
      # are not matched) and tell the model these are the sanctioned exceptions.
      rule="Bash($script return:*)"
      rules=$(printf '%q' "$rule")
      if [ -n "$page_dir" ]; then
        rules="$rules $(printf '%q' "Bash($script page:*)")"
        carve="You are a read-only fork child (fork $id) that writes one explain page. The only permitted exceptions to plan mode are running '$script page' (and '$script page --manifest') to write your page and its manifest into the fork's page directory, and '$script return' when the user asks you to return; both write only outside the repository and are not code changes. Do not exit plan mode and do not modify any other file."
      else
        carve="You are a read-only fork child (fork $id). The only permitted exception to plan mode is running '$script return' when the user asks you to return; it saves your answer to a state directory outside the repository and is not a code change. Do not exit plan mode and do not modify files."
      fi
      printf 'exec env %s claude%s --permission-mode plan --allowedTools %s --append-system-prompt %q%s "$(cat %q)"' \
        "$envp" "$nf" "$rules" "$carve" "$mf" "$brief"
      ;;
    agent)
      printf 'exec env %s agent --mode ask%s "$(cat %q)"' "$envp" "$mf" "$brief"
      ;;
    codex)
      printf 'exec env %s codex --sandbox read-only --ask-for-approval on-request%s "$(cat %q)"' \
        "$envp" "$mf" "$brief"
      ;;
    opencode)
      printf 'exec env %s opencode%s --agent plan%s --prompt "$(cat %q)"' "$envp" "$nf" "$mf" "$brief"
      ;;
    gemini)
      printf 'exec env %s gemini --approval-mode plan%s -i "$(cat %q)"' "$envp" "$mf" "$brief"
      ;;
    *) die "unsupported CLI '$cli'" ;;
  esac
}

# Protocol appended to every brief so the child knows how to return, whatever
# the parent wrote.
protocol_footer() {
  local id=$1 script=$2
  cat <<EOF

---
## Fork protocol (fork $id)

- You are a **read-only fork** of another agent session running in the tmux
  pane next to you. Answer the user's questions about the context above
  (in a full-context fork: the conversation you inherited).
  Do **not** modify, create or delete files in the project, and do not run
  commands that change state. Reading files and running read-only commands
  is fine.
- For your first reply, briefly confirm what you understood and answer the
  question if one was given. Then wait for the user.
- When the user says \`/fork return\` (or asks you to report back), write a
  concise result — **Answer**, **Evidence** (\`file:line\`, commands run),
  **Unresolved** — at most ~40 lines, and save it by running exactly:

      $script return <<'FORK_EOF'
      <your result>
      FORK_EOF

  This single command is allowed even in plan / read-only mode: it writes only
  to the fork's state directory, outside the repository.
- If that command is refused, blocked by a sandbox, or fails, print the same
  result in your reply instead, wrapped in marker lines: first a line that
  contains only \`$MARK_BEGIN\`, then the result, then a line that contains
  only \`$MARK_END\`. The parent recovers it from this pane.
EOF
}

# Page protocol appended after the fork protocol when the fork writes a page
# (open --page-dir). The HTML skeleton itself comes from the parent's brief
# (/explain); this section only fixes the commands and the rules.
page_protocol() {
  local id=$1 script=$2 page_dir=$3
  cat <<EOF

---
## Page protocol (fork $id)

- Your job is to write **one web page** that explains the topic above. It is
  served from this machine behind the expose login (the page URL is in the
  brief) and is the only thing you may write besides your return result.
- Write the **whole page** every time, as one self-contained HTML document,
  by running exactly:

      $script page <<'PAGE_EOF'
      <!doctype html>
      …the complete page, every language it carries…
      PAGE_EOF

  and write the label manifest **every time you write the page**, one line per
  current label (labels are shared by all languages, so one line each),
  \`<label><TAB><one-line summary>\`:

      $script page --manifest <<'PAGE_EOF'
      S1	What the section covers
      P1	What the paragraph says
      PAGE_EOF

  Both commands are allowed even in plan / read-only mode: they write only
  \`index.html\` and \`manifest.tsv\` in the fork's page directory
  (\`$page_dir\`), outside the repository. Never edit project files, never
  write the page anywhere else.
- **Languages, one write**: the brief's \`Languages:\` line (in the Page
  section) is authoritative. With one language the page has one
  \`<article lang="xx">\` and no language switch. With two, the page carries
  the whole explanation in English and in Portuguese as two sibling
  articles \`<article lang="en">\` and \`<article lang="pt">\` (the template
  from the brief then has both and the EN / PT switch; keep them), holding
  the **same labelled blocks in the same order** with the same
  \`data-label\` and \`id\` (the repeat is intended; the page script keeps the
  ids only on the shown language), each its own \`<h1>\`; \`<title>\` is
  \`English title · Título em português\`. Diagrams are duplicated per
  language (translated text, same structure, same \`D<n>\` in both). Always
  write every article in the same \`page\` command; never write one language
  alone. Every edit the user asks for applies to every language the page
  carries unless they name one. If the user asks to add a language, add the
  second article and the switch from the template and keep both from then on.
- Labels: every block carries a visible label and an HTML id equal to it:
  \`S<n>\` sections (nested \`S1.2\`), \`P<n>\` paragraphs, \`D<n>\` diagrams,
  \`T<n>\` tabular blocks (tables, key cards, terms lists), \`C<n>\` code
  blocks, \`N<n>\` callouts (prefixes S P D T C N), e.g.
  \`<p id="P7" data-label="P7">\`. Use the HTML template from the brief for
  the design, the margin labels, click-to-copy and reload-on-change.
- Labels are **stable**: before rewriting, read \`$page_dir/manifest.tsv\`.
  An edited block keeps its label; a new block takes the next number never
  used in the manifest; a removed label is never reused; never renumber.
- Diagrams: **inline SVG first** (a framed \`<figure>\` from the template:
  \`viewBox\`, \`role="img"\`, \`aria-label\`, token colours), drawn by hand for
  the one or two pictures that carry the explanation; Mermaid
  (\`<pre class="mermaid">\` inside the frame) only when a diagram has too
  many nodes to draw, adding the pinned Mermaid tag exactly as the brief
  gives it; an ASCII \`<pre>\` as the last resort. Every diagram still
  carries its \`D<n>\` label.
- First reply: write the page and the manifest, then confirm the page URL
  (from the brief) and list the top-level labels (\`S1 …\`, \`D1 …\`).
- The user asks for edits by label ("expand P7", "the arrow in D2 is wrong"):
  change those blocks in both languages, keep every other label, rewrite the
  whole page and the manifest with the commands above, then say which labels
  changed.
- **Never put secrets in the page**: no API keys, tokens, passwords,
  cookies, private keys, connection strings, environment values or other
  credentials you saw in the conversation or in tool output, not even
  partially or "redacted by hand". Name the setting instead (\`\$STRIPE_KEY\`,
  "the owner key"). The page may be shared beyond the user.
- The page is served with a strict Content-Security-Policy: no external
  scripts except the pinned Mermaid tag from the template, no external
  images, fonts, styles, frames or fetches, no forms. Keep everything inline
  (\`data:\` URIs for images) and do not add other external resources.
- If \`$script page\` is refused, blocked by a sandbox, needs an approval
  the user declines, or exits non-zero, tell the user the page cannot be
  written from this fork and stop. Do not print the HTML into this pane
  instead.
EOF
}

# First meaningful line of the question in a brief.
question_line() {
  awk '
    /^[[:space:]]*$/ { next }
    tolower($0) ~ /^#+[[:space:]]*question/ { inq = 1; next }
    inq && /^#/ { exit }
    inq { sub(/^[[:space:]]*[-*][[:space:]]*/, ""); print; found = 1; exit }
    !first && !/^#/ { first = $0 }
    END { if (!found && first != "") print first }
  ' "$1" 2>/dev/null | cut -c1-80
}

# ---------------------------------------------------------------------------
# Badge on the parent pane (title + @fork_badge option). Never send-keys.

badge_update() {
  local parent=$1 id=$2 action=$3 ids new title orig
  pane_alive "$parent" || return 0
  ids=$(tmux show-options -p -v -t "$parent" @fork_badge_ids 2>/dev/null)
  # shellcheck disable=SC2086  # $ids is a space-separated list of numbers
  new=$(printf '%s\n' $ids | awk -v id="$id" -v a="$action" '
      NF && $0 != id { print }
      END { if (a == "add") print id }' | sort -n | tr '\n' ' ')
  new=${new% }
  if [ -z "$ids" ] && [ -n "$new" ]; then
    # First badge: remember the title and the allow-set-title setting so the
    # agent CLI does not immediately overwrite the badge.
    orig=$(tmux display-message -p -t "$parent" '#{pane_title}' 2>/dev/null)
    tmux set-option -p -t "$parent" @fork_orig_title "$orig" >/dev/null 2>&1
    orig=$(tmux show-options -p -v -t "$parent" allow-set-title 2>/dev/null)
    tmux set-option -p -t "$parent" @fork_orig_allow_title "${orig:-default}" >/dev/null 2>&1
    tmux set-option -p -t "$parent" allow-set-title off >/dev/null 2>&1
  fi
  if [ -n "$new" ]; then
    title="fork ${new// /,} ✓"
    tmux set-option -p -t "$parent" @fork_badge_ids "$new" >/dev/null 2>&1
    tmux set-option -p -t "$parent" @fork_badge "$title" >/dev/null 2>&1
    tmux select-pane -t "$parent" -T "$title" >/dev/null 2>&1
  elif [ -n "$ids" ]; then
    tmux set-option -p -u -t "$parent" @fork_badge_ids >/dev/null 2>&1
    tmux set-option -p -u -t "$parent" @fork_badge >/dev/null 2>&1
    orig=$(tmux show-options -p -v -t "$parent" @fork_orig_title 2>/dev/null)
    tmux select-pane -t "$parent" -T "$orig" >/dev/null 2>&1
    orig=$(tmux show-options -p -v -t "$parent" @fork_orig_allow_title 2>/dev/null)
    if [ "$orig" = default ] || [ -z "$orig" ]; then
      tmux set-option -p -u -t "$parent" allow-set-title >/dev/null 2>&1
    else
      tmux set-option -p -t "$parent" allow-set-title "$orig" >/dev/null 2>&1
    fi
    tmux set-option -p -u -t "$parent" @fork_orig_title >/dev/null 2>&1
    tmux set-option -p -u -t "$parent" @fork_orig_allow_title >/dev/null 2>&1
  fi
}

notify_parent() {
  local parent=$1 msg=$2 sess c
  pane_alive "$parent" || return 0
  sess=$(tmux display-message -p -t "$parent" '#{session_id}' 2>/dev/null) || return 0
  tmux list-clients -t "$sess" -F '#{client_name}' 2>/dev/null | while IFS= read -r c; do
    [ -n "$c" ] && tmux display-message -c "$c" -d 8000 "$msg" >/dev/null 2>&1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Capture / marker extraction

capture_pane() {
  tmux capture-pane -p -J -S - -t "$1" 2>/dev/null
}

# Print the body of the LAST complete marker block in stdin, with common
# leading indentation removed. A marker line must contain nothing but the
# marker, apart from whitespace and TUI decorations (bullets, box borders,
# backticks), so the instructions in the echoed brief never match. Exit 1 when
# there is no block.
extract_marker_block() {
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    function rtrim(s) { sub(/[[:space:]]+$/, "", s); return s }
    function bare(s) {
      gsub(/[[:space:]`*]/, "", s)
      gsub(/^(●|⏺|•|│|┃|║|>|-)+/, "", s)
      gsub(/(│|┃|║)+$/, "", s)
      return s
    }
    { k = bare($0) }
    k == b { inb = 1; n = 0; next }
    inb && k == e { inb = 0; last_n = n; for (i = 1; i <= n; i++) last[i] = cur[i]; got = 1; next }
    inb { cur[++n] = rtrim($0) }
    END {
      if (!got) exit 1
      min = -1
      for (i = 1; i <= last_n; i++) {
        if (last[i] == "") continue
        match(last[i], /^[ \t]*/)
        if (min < 0 || RLENGTH < min) min = RLENGTH
      }
      if (min < 0) min = 0
      for (i = 1; i <= last_n; i++) print substr(last[i], min + 1)
    }'
}

# ---------------------------------------------------------------------------
# Subcommands

cmd_open() {
  local window=0 vertical=0 cli_opt="" cwd=$PWD model_opt="" parent_model="" brief_only=0 page_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --window)   window=1; shift ;;
      --vertical) vertical=1; shift ;;
      --cli)      [ -n "${2:-}" ] || die "--cli needs a value"
                  cli_opt=$2; shift 2 ;;
      --model)    [ $# -ge 2 ] || die "--model needs a value"
                  model_opt=$2; check_model --model "$model_opt"; shift 2 ;;
      --model=*)  model_opt=${1#--model=}; check_model --model "$model_opt"; shift ;;
      --parent-model)
                  [ $# -ge 2 ] || die "--parent-model needs a value"
                  parent_model=$2; check_model --parent-model "$parent_model"; shift 2 ;;
      --parent-model=*)
                  parent_model=${1#--parent-model=}; check_model --parent-model "$parent_model"; shift ;;
      --cwd)      [ -n "${2:-}" ] || die "--cwd needs a value"
                  cwd=$2; shift 2 ;;
      --brief-only) brief_only=1; shift ;;
      --page-dir) [ -n "${2:-}" ] || die "--page-dir needs a value"
                  page_dir=$2; shift 2 ;;
      -h|--help)  usage; return 0 ;;
      *) die "unknown option for open: $1" ;;
    esac
  done
  [ -z "${FORK_MODEL:-}" ] || check_model "\$FORK_MODEL" "$FORK_MODEL"
  if [ -n "$page_dir" ]; then
    case "$page_dir" in
      /*) ;;
      *) die "--page-dir must be an absolute path: $page_dir" ;;
    esac
    case "$page_dir" in
      *[[:cntrl:]]*) die "--page-dir must not contain control characters" ;;
    esac
    page_dir=${page_dir%/}; [ -n "$page_dir" ] || die "--page-dir must not be /"
  fi
  require_tmux
  [ -n "${TMUX_PANE:-}" ] || die "cannot determine the parent pane (\$TMUX_PANE is unset)."
  pane_alive "$TMUX_PANE" || die "parent pane $TMUX_PANE not found."
  [ -d "$cwd" ] || die "cwd not found: $cwd"
  [ -t 0 ] && die "pipe the brief on stdin, e.g.  fork.sh open <<'EOF' … EOF"

  local cli brief_text model native
  cli=$(resolve_cli "$cli_opt") || exit 1
  model=$(resolve_model "$cli" "$model_opt" "$parent_model")
  native=$(native_mode "$cli" "$cwd" "$brief_only")
  brief_text=$(cat)
  [ -n "${brief_text//[[:space:]]/}" ] || die "the brief on stdin is empty."

  local sdir id dir parent script launch sess out child win
  parent=$TMUX_PANE
  sdir=$(session_dir) || exit 1
  id=$(alloc_id "$sdir") || exit 1
  dir=$sdir/$id
  script=$(this_script)
  {
    printf '%s\n' "$brief_text"
    protocol_footer "$id" "$script"
    [ -z "$page_dir" ] || page_protocol "$id" "$script" "$page_dir"
  } > "$dir/brief.md" || die "cannot write $dir/brief.md"

  sess=$(current_session)
  meta_set id "$id" "$dir"
  meta_set parent_pane "$parent" "$dir"
  meta_set cli "$cli" "$dir"
  meta_set model "$model" "$dir"
  meta_set cwd "$cwd" "$dir"
  meta_set created "$(now)" "$dir"
  meta_set mode "$([ "$window" -eq 1 ] && echo window || echo pane)" "$dir"
  meta_set session "$sess" "$dir"
  meta_set question "$(question_line "$dir/brief.md")" "$dir"
  meta_set context "${native%% *}" "$dir"
  meta_set context_source "${native#* }" "$dir"
  meta_set page_dir "$page_dir" "$dir"
  meta_set status opening "$dir"

  # The launch line lives in a small bash script so it does not depend on the
  # quoting rules of the user's tmux default-shell (zsh, fish, …).
  {
    printf '#!/usr/bin/env bash\n'
    printf '# fork %s child launcher (generated by fork.sh open)\n' "$id"
    printf 'cd %q || exit 1\n' "$cwd"
    build_launch_cmd "$cli" "$dir/brief.md" "$id" "$dir" "$parent" "$model" "$native" "$page_dir" || exit 1
    printf '\n'
  } > "$dir/launch.sh" || die "cannot write $dir/launch.sh"
  launch=$(printf 'bash %q' "$dir/launch.sh")

  if [ "$window" -eq 1 ]; then
    out=$(tmux new-window -t "$sess:" -n "fork-$id" -c "$cwd" -P \
          -F '#{pane_id} #{window_id}' "$launch" 2>&1) \
      || { meta_set status failed "$dir"; die "failed to open window: $out"; }
    tmux set-window-option -t "${out#* }" automatic-rename off >/dev/null 2>&1
    tmux set-window-option -t "${out#* }" allow-rename off >/dev/null 2>&1
  else
    local dirflag=-h
    [ "$vertical" -eq 1 ] && dirflag=-v
    out=$(tmux split-window "$dirflag" -l 40% -t "$parent" -c "$cwd" -P \
          -F '#{pane_id} #{window_id}' "$launch" 2>&1) \
      || { meta_set status failed "$dir"; die "failed to split pane: $out"; }
  fi
  child=${out%% *}
  win=${out#* }

  tmux set-option -p -t "$child" @fork_id "$id" >/dev/null 2>&1
  tmux set-option -p -t "$child" @fork_dir "$dir" >/dev/null 2>&1
  tmux set-option -p -t "$child" @fork_parent "$parent" >/dev/null 2>&1
  tmux select-pane -t "$child" -T "fork $id" >/dev/null 2>&1

  meta_set child_pane "$child" "$dir"
  meta_set window "$win" "$dir"
  meta_set status open "$dir"

  [ "$window" -eq 0 ] && arrange_layout "$parent" "$vertical"

  printf 'fork %s pane %s cli %s model %s\n' "$id" "$child" "$cli" "${model:-default}"
  case "$native" in
    "full claude session "*) printf '# context: full (claude --resume %s --fork-session)\n' "${native#full claude session }" ;;
    "full opencode "*)       printf '# context: full (opencode --continue --fork)\n' ;;
    *)                       printf '# context: brief (%s)\n' "${native#brief }" ;;
  esac
  printf '# state: %s\n' "$dir"
  printf '# collect later with: %s collect %s\n' "$script" "$id"
}

# With more than one fork child beside the parent, keep the parent as the big
# pane. Only rearrange when the window holds nothing but the parent and its
# fork children, so unrelated user layouts are left alone.
arrange_layout() {
  local parent=$1 vertical=$2 win panes p fp children=0 other=0 first
  win=$(tmux display-message -p -t "$parent" '#{window_id}' 2>/dev/null) || return 0
  panes=$(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null) || return 0
  for p in $panes; do
    [ "$p" = "$parent" ] && continue
    fp=$(tmux show-options -p -v -t "$p" @fork_parent 2>/dev/null)
    if [ "$fp" = "$parent" ]; then children=$((children + 1)); else other=$((other + 1)); fi
  done
  [ "$children" -gt 1 ] && [ "$other" -eq 0 ] || return 0
  first=$(printf '%s\n' "$panes" | head -n 1)
  [ "$first" != "$parent" ] && tmux swap-pane -d -s "$parent" -t "$first" >/dev/null 2>&1
  if [ "$vertical" -eq 1 ]; then
    tmux set-window-option -t "$win" main-pane-height 60% >/dev/null 2>&1
    tmux select-layout -t "$win" main-horizontal >/dev/null 2>&1
  else
    tmux set-window-option -t "$win" main-pane-width 60% >/dev/null 2>&1
    tmux select-layout -t "$win" main-vertical >/dev/null 2>&1
  fi
  return 0
}

# Find this child's fork dir: $FORK_DIR, then the process chain, then the
# @fork_dir option on this pane.
resolve_own_fork_dir() {
  local d=${FORK_DIR:-}
  if [ -z "$d" ]; then
    d=$(recover_env_var FORK_DIR) || d=""
  fi
  if [ -z "$d" ] && command -v tmux >/dev/null 2>&1; then
    recover_tmux_env
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
      d=$(tmux show-options -p -v -t "$TMUX_PANE" @fork_dir 2>/dev/null) || d=""
    fi
  fi
  printf '%s' "$d"
}

cmd_return() {
  local dir id parent result tmp
  dir=$(resolve_own_fork_dir)
  [ -n "$dir" ] || die "this session is not a fork (FORK_DIR is unset) — /fork return only works inside a fork child."
  [ -d "$dir" ] || die "fork state dir not found: $dir" 3
  [ -t 0 ] && die "pipe the result on stdin, e.g.  fork.sh return <<'FORK_EOF' … FORK_EOF"
  result=$(cat)
  [ -n "${result//[[:space:]]/}" ] || die "the result on stdin is empty."
  id=$(meta_get id "$dir"); [ -n "$id" ] || id=${FORK_ID:-${dir##*/}}

  tmp=""
  if ! { tmp=$(mktemp "$dir/.result.XXXXXX" 2>/dev/null) \
         && printf '%s\n' "$result" > "$tmp" 2>/dev/null \
         && mv -f "$tmp" "$dir/result.md" 2>/dev/null; }; then
    [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null
    die "could not write $dir/result.md (sandbox?). Print the result between '$MARK_BEGIN' and '$MARK_END' lines instead." 3
  fi
  meta_set status returned "$dir" 2>/dev/null
  meta_set returned "$(now)" "$dir" 2>/dev/null

  parent=$(meta_get parent_pane "$dir")
  [ -n "$parent" ] || parent=${FORK_PARENT:-}
  recover_tmux_env
  if [ -n "$parent" ] && tmux_ok && pane_alive "$parent"; then
    badge_update "$parent" "$id" add
    notify_parent "$parent" "fork $id returned — run /fork collect $id in the parent"
    printf 'fork %s: result saved; parent %s notified.\n' "$id" "$parent"
  else
    printf 'fork %s: result saved (%s); parent pane not reachable, no notification.\n' \
      "$id" "$dir/result.md"
  fi
}

# F6: `fork.sh page` is auto-approved in page forks, so the library hook it
# runs must be the one explain.sh wrote: <pd>/../.reindex only when <pd>'s
# parent is a project root directly under <state root>/explain, and the hook
# is a regular file (not a symlink) owned by the current user.
reindex_allowed() {
  local pd=$1 parent xroot hook
  hook=$pd/../.reindex
  [ -f "$hook" ] && [ ! -L "$hook" ] && [ -x "$hook" ] && [ -O "$hook" ] || return 1
  parent=$(cd -- "$pd/.." 2>/dev/null && pwd -P) || return 1
  xroot=$(cd -- "$(state_root)/explain" 2>/dev/null && pwd -P) || return 1
  [ "$(dirname -- "$parent")" = "$xroot" ]
}

# Write the calling fork's page (index.html) or, with --manifest, its
# manifest.tsv. Never writes anywhere but the fork's page directory.
cmd_page() {
  local manifest=0 pd dir target content tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --manifest) manifest=1; shift ;;
      -h|--help)  usage; return 0 ;;
      *) die "unknown option for page: $1" ;;
    esac
  done
  pd=${FORK_PAGE_DIR:-}
  [ -n "$pd" ] || pd=$(recover_env_var FORK_PAGE_DIR) || pd=""
  if [ -z "$pd" ]; then
    dir=$(resolve_own_fork_dir)
    [ -n "$dir" ] || die "this session is not a fork (FORK_DIR is unset) — fork.sh page only works inside a fork child." 1
    [ -d "$dir" ] || die "fork state dir not found: $dir" 1
    pd=$(meta_get page_dir "$dir")
    [ -n "$pd" ] || die "this fork has no page directory — it was not opened with --page-dir (use /explain to open a page fork)." 4
  fi
  case "$pd" in
    /*) ;;
    *) die "the page directory is not an absolute path: $pd" 4 ;;
  esac
  pd=${pd%/}
  [ -t 0 ] && die "pipe the page on stdin, e.g.  fork.sh page <<'PAGE_EOF' … PAGE_EOF" 2
  content=$(cat)
  [ -n "${content//[[:space:]]/}" ] || die "the page on stdin is empty; nothing was written." 2
  if [ "$manifest" -eq 1 ]; then target=$pd/manifest.tsv; else target=$pd/index.html; fi

  tmp=""
  if ! { mkdir -p -- "$pd" 2>/dev/null \
         && tmp=$(mktemp "$pd/.page.XXXXXX" 2>/dev/null) \
         && printf '%s\n' "$content" > "$tmp" 2>/dev/null \
         && chmod 600 "$tmp" 2>/dev/null \
         && mv -f -- "$tmp" "$target" 2>/dev/null; }; then
    [ -n "$tmp" ] && rm -f -- "$tmp" 2>/dev/null
    die "could not write $target (sandbox or permissions?). The page was not changed — tell the user and stop." 3
  fi
  if [ "$manifest" -eq 0 ] && reindex_allowed "$pd"; then
    "$pd/../.reindex" </dev/null >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$target"
}

# Id of the most recently returned fork in session dir $1.
latest_returned() {
  local sdir=$1 i best="" best_t="" t
  for i in $(fork_ids "$sdir"); do
    [ -f "$sdir/$i/result.md" ] || continue
    t=$(meta_get returned "$sdir/$i")
    [ -n "$t" ] || t=$(date -r "$sdir/$i/result.md" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)
    # ISO timestamps from the same machine sort lexically; ties go to the higher id.
    if [ -z "$best" ] || [[ ! "$t" < "$best_t" ]]; then
      best=$i; best_t=$t
    fi
  done
  printf '%s' "$best"
}

cmd_collect() {
  local id=${1:-} sdir dir child parent cap block
  require_tmux
  sdir=$(session_dir) || exit 1
  if [ -z "$id" ]; then
    id=$(latest_returned "$sdir")
    [ -n "$id" ] || die "no fork in this session has returned yet — use /fork collect <id> (see /fork list)."
  fi
  case "$id" in ''|*[!0-9]*) die "fork id must be a number: $id" ;; esac
  dir=$sdir/$id
  [ -d "$dir" ] || die "no fork $id in this tmux session."
  child=$(meta_get child_pane "$dir")
  parent=$(meta_get parent_pane "$dir")

  if [ -f "$dir/result.md" ]; then
    printf '# fork %s result\n\n' "$id"
    cat "$dir/result.md"
  else
    cap=""
    if pane_is_fork "$child" "$dir"; then
      cap=$(capture_pane "$child")
      printf '%s\n' "$cap" > "$dir/capture.txt" 2>/dev/null
    elif [ -f "$dir/capture.txt" ]; then
      cap=$(cat "$dir/capture.txt")
    fi
    if block=$(printf '%s\n' "$cap" | extract_marker_block) && [ -n "${block//[[:space:]]/}" ]; then
      printf '%s\n' "$block" > "$dir/result.md"
      meta_set status returned "$dir"
      meta_set returned "$(now)" "$dir"
      printf '# fork %s result (recovered from the marker block in the child pane)\n\n' "$id"
      printf '%s\n' "$block"
    elif [ -n "${cap//[[:space:]]/}" ]; then
      printf '# fork %s: RAW CAPTURE — no result was returned; last 60 lines of the child pane\n\n' "$id"
      printf '%s\n' "$cap" | awk 'NF { last = NR } { l[NR] = $0 } END { s = last - 59; if (s < 1) s = 1; for (i = s; i <= last; i++) print l[i] }'
    else
      printf '# fork %s: no result and no capture available (pane gone before anything was saved)\n' "$id"
    fi
  fi
  [ -n "$parent" ] && badge_update "$parent" "$id" remove
  return 0
}

cmd_list() {
  local sdir i dir st child cli model ctx q any=0
  require_tmux
  sdir=$(session_dir) || exit 1
  for i in $(fork_ids "$sdir"); do
    dir=$sdir/$i
    if [ "$any" -eq 0 ]; then
      printf '%-4s %-18s %-9s %-20s %-7s %-6s %s\n' ID STATUS CLI MODEL CONTEXT PANE QUESTION
      any=1
    fi
    st=$(meta_get status "$dir")
    child=$(meta_get child_pane "$dir")
    cli=$(meta_get cli "$dir")
    model=$(meta_get model "$dir")
    ctx=$(meta_get context "$dir")
    q=$(meta_get question "$dir")
    if [ "$st" != closed ] && ! pane_is_fork "$child" "$dir"; then
      st="$st (pane gone)"
    fi
    # Forks opened before context modes existed were brief forks.
    printf '%-4s %-18s %-9s %-20s %-7s %-6s %s\n' "$i" "${st:-?}" "${cli:--}" "${model:-default}" "${ctx:-brief}" "${child:--}" "${q:--}"
  done
  [ "$any" -eq 1 ] || printf 'no forks in tmux session %s\n' "$(current_session)"
}

close_one() {
  local sdir=$1 id=$2 dir child win mode parent n
  dir=$sdir/$id
  [ -d "$dir" ] || { printf 'fork: no fork %s in this tmux session.\n' "$id" >&2; return 1; }
  child=$(meta_get child_pane "$dir")
  win=$(meta_get window "$dir")
  mode=$(meta_get mode "$dir")
  parent=$(meta_get parent_pane "$dir")
  if pane_is_fork "$child" "$dir"; then
    if [ ! -f "$dir/result.md" ]; then
      capture_pane "$child" > "$dir/capture.txt" 2>/dev/null
    fi
    if [ "$mode" = window ] && [ -n "$win" ]; then
      n=$(tmux list-panes -t "$win" -F x 2>/dev/null | wc -l)
      if [ "${n:-0}" -le 1 ]; then
        tmux kill-window -t "$win" >/dev/null 2>&1
      else
        tmux kill-pane -t "$child" >/dev/null 2>&1
      fi
    else
      tmux kill-pane -t "$child" >/dev/null 2>&1
    fi
  fi
  meta_set status closed "$dir"
  meta_set closed "$(now)" "$dir"
  [ -n "$parent" ] && badge_update "$parent" "$id" remove
  local note=""
  if [ -f "$dir/result.md" ]; then
    note=' (result kept)'
  elif [ -f "$dir/capture.txt" ]; then
    note=' (capture saved)'
  fi
  printf 'fork %s closed%s\n' "$id" "$note"
}

cmd_close() {
  local arg=${1:-} sdir i st rc=0 any=0
  require_tmux
  [ -n "$arg" ] || die "usage: fork.sh close <id> | --all"
  sdir=$(session_dir) || exit 1
  if [ "$arg" = --all ]; then
    for i in $(fork_ids "$sdir"); do
      st=$(meta_get status "$sdir/$i")
      [ "$st" = closed ] && continue
      any=1
      close_one "$sdir" "$i" || rc=1
    done
    [ "$any" -eq 1 ] || printf 'no open forks in this tmux session.\n'
    return "$rc"
  fi
  case "$arg" in *[!0-9]*) die "fork id must be a number: $arg" ;; esac
  close_one "$sdir" "$arg" || exit 1
}

cmd_detect_cli() {
  local cli_opt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cli) [ -n "${2:-}" ] || die "--cli needs a value"
             cli_opt=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  resolve_cli "$cli_opt"
  printf '\n'
}

# Print the context mode `open` would use; reads no stdin, writes nothing,
# needs no tmux. Exit 0 for both `full` and `brief`.
cmd_native() {
  local cli_opt="" cwd=$PWD brief_only=0 cli
  while [ $# -gt 0 ]; do
    case "$1" in
      --cli) [ -n "${2:-}" ] || die "--cli needs a value"
             cli_opt=$2; shift 2 ;;
      --cwd) [ -n "${2:-}" ] || die "--cwd needs a value"
             cwd=$2; shift 2 ;;
      --brief-only) brief_only=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown option for native: $1" ;;
    esac
  done
  [ -d "$cwd" ] || die "cwd not found: $cwd"
  cli=$(resolve_cli "$cli_opt") || exit 1
  native_mode "$cli" "$cwd" "$brief_only"
  printf '\n'
}

usage() {
  sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$(this_script)"
}

case "${1:-}" in
  open)       shift; cmd_open "$@" ;;
  return)     shift; cmd_return "$@" ;;
  page)       shift; cmd_page "$@" ;;
  collect)    shift; cmd_collect "$@" ;;
  list)       shift; cmd_list "$@" ;;
  close)      shift; cmd_close "$@" ;;
  detect-cli) shift; cmd_detect_cli "$@" ;;
  native)     shift; cmd_native "$@" ;;
  help|-h|--help) usage ;;
  '') usage >&2; exit 1 ;;
  *) die "unknown subcommand: $1 (expected open|return|page|collect|list|close|native|detect-cli|help)" ;;
esac
