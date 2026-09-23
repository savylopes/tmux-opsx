#!/usr/bin/env bash
# fork.sh — tmux plumbing for the /fork skill.
#
# Fork the current agent conversation into a read-only child agent in a tmux
# pane (default) or window. The parent writes a brief; the child answers
# questions and returns a short result; the parent is notified (never typed
# into) and pulls the result with `collect`.
#
# Usage:
#   fork.sh open [--window] [--vertical] [--cli <name>] [--cwd <dir>]  < brief
#   fork.sh return                                                     < result
#   fork.sh collect [<id>]
#   fork.sh list
#   fork.sh close <id> | --all
#   fork.sh detect-cli [--cli <name>]
#   fork.sh help
#
# State: ${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/<tmux-session>/<id>/
#   brief.md    brief (parent text + generated fork protocol), first prompt
#   meta        key=value: parent_pane child_pane window cli cwd created status …
#   result.md   the child's result (written by `return`, or recovered by collect)
#   capture.txt last pane capture (saved by collect/close when no result)
#
# Child CLI selection: --cli > $FORK_CLI > host detection (Cursor, Claude,
# Codex, OpenCode, Gemini) > first of claude/agent/codex/opencode/gemini on PATH.
# Children always launch in the CLI's read-only / plan mode and never with
# bypass or force flags:
#   claude    --permission-mode plan (+ narrow allow rule for `fork.sh return`)
#   agent     --mode ask
#   codex     --sandbox read-only --ask-for-approval on-request
#   opencode  --agent plan
#   gemini    --approval-mode plan
#
# Every subcommand except `return` requires tmux. Nothing here ever sends keys
# to the parent pane.
#
# Exit codes: 0 ok, 1 usage/error, 3 result could not be written (use the
# <<<FORK-RESULT … FORK-RESULT>>> marker fallback).

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

resolve_cli() {
  local explicit=${1:-} cli=""
  if [ -n "$explicit" ]; then
    cli=$(normalize_cli "$explicit")
  elif [ -n "${FORK_CLI:-}" ]; then
    cli=$(normalize_cli "$FORK_CLI")
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
# Launch command (read-only; never bypass/force flags)

# The "$(cat …)" parts are meant to stay literal: they run in the launcher.
# shellcheck disable=SC2016
build_launch_cmd() {
  local cli=$1 brief=$2 id=$3 dir=$4 parent=$5 script envp carve rule
  script=$(this_script)
  envp=$(printf 'FORK_ID=%q FORK_DIR=%q FORK_PARENT=%q FORK_SH=%q' "$id" "$dir" "$parent" "$script")
  case "$cli" in
    claude)
      # Plan mode refuses mutating shell commands; allow exactly `fork.sh
      # return` (literal path — variables are not matched) and tell the model
      # that this one command is the sanctioned exception.
      rule="Bash($script return:*)"
      carve="You are a read-only fork child (fork $id). The only permitted exception to plan mode is running '$script return' when the user asks you to return; it saves your answer to a state directory outside the repository and is not a code change. Do not exit plan mode and do not modify files."
      printf 'exec env %s claude --permission-mode plan --allowedTools %q --append-system-prompt %q "$(cat %q)"' \
        "$envp" "$rule" "$carve" "$brief"
      ;;
    agent)
      printf 'exec env %s agent --mode ask "$(cat %q)"' "$envp" "$brief"
      ;;
    codex)
      printf 'exec env %s codex --sandbox read-only --ask-for-approval on-request "$(cat %q)"' \
        "$envp" "$brief"
      ;;
    opencode)
      printf 'exec env %s opencode --agent plan --prompt "$(cat %q)"' "$envp" "$brief"
      ;;
    gemini)
      printf 'exec env %s gemini --approval-mode plan -i "$(cat %q)"' "$envp" "$brief"
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
  pane next to you. Answer the user's questions about the context above.
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
  local window=0 vertical=0 cli_opt="" cwd=$PWD
  while [ $# -gt 0 ]; do
    case "$1" in
      --window)   window=1; shift ;;
      --vertical) vertical=1; shift ;;
      --cli)      cli_opt=${2:-}; [ -n "$cli_opt" ] || die "--cli needs a value"; shift 2 ;;
      --cwd)      cwd=${2:-}; shift 2 ;;
      -h|--help)  usage; return 0 ;;
      *) die "unknown option for open: $1" ;;
    esac
  done
  require_tmux
  [ -n "${TMUX_PANE:-}" ] || die "cannot determine the parent pane (\$TMUX_PANE is unset)."
  pane_alive "$TMUX_PANE" || die "parent pane $TMUX_PANE not found."
  [ -d "$cwd" ] || die "cwd not found: $cwd"
  [ -t 0 ] && die "pipe the brief on stdin, e.g.  fork.sh open <<'EOF' … EOF"

  local cli brief_text
  cli=$(resolve_cli "$cli_opt") || exit 1
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
  } > "$dir/brief.md" || die "cannot write $dir/brief.md"

  sess=$(current_session)
  meta_set id "$id" "$dir"
  meta_set parent_pane "$parent" "$dir"
  meta_set cli "$cli" "$dir"
  meta_set cwd "$cwd" "$dir"
  meta_set created "$(now)" "$dir"
  meta_set mode "$([ "$window" -eq 1 ] && echo window || echo pane)" "$dir"
  meta_set session "$sess" "$dir"
  meta_set question "$(question_line "$dir/brief.md")" "$dir"
  meta_set status opening "$dir"

  # The launch line lives in a small bash script so it does not depend on the
  # quoting rules of the user's tmux default-shell (zsh, fish, …).
  {
    printf '#!/usr/bin/env bash\n'
    printf '# fork %s child launcher (generated by fork.sh open)\n' "$id"
    printf 'cd %q || exit 1\n' "$cwd"
    build_launch_cmd "$cli" "$dir/brief.md" "$id" "$dir" "$parent" || exit 1
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

  printf 'fork %s pane %s cli %s\n' "$id" "$child" "$cli"
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
  local sdir i dir st child cli q any=0
  require_tmux
  sdir=$(session_dir) || exit 1
  for i in $(fork_ids "$sdir"); do
    dir=$sdir/$i
    if [ "$any" -eq 0 ]; then
      printf '%-4s %-18s %-9s %-6s %s\n' ID STATUS CLI PANE QUESTION
      any=1
    fi
    st=$(meta_get status "$dir")
    child=$(meta_get child_pane "$dir")
    cli=$(meta_get cli "$dir")
    q=$(meta_get question "$dir")
    if [ "$st" != closed ] && ! pane_is_fork "$child" "$dir"; then
      st="$st (pane gone)"
    fi
    printf '%-4s %-18s %-9s %-6s %s\n' "$i" "${st:-?}" "${cli:--}" "${child:--}" "${q:--}"
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
      --cli) cli_opt=${2:-}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  resolve_cli "$cli_opt"
  printf '\n'
}

usage() {
  sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$(this_script)"
}

case "${1:-}" in
  open)       shift; cmd_open "$@" ;;
  return)     shift; cmd_return "$@" ;;
  collect)    shift; cmd_collect "$@" ;;
  list)       shift; cmd_list "$@" ;;
  close)      shift; cmd_close "$@" ;;
  detect-cli) shift; cmd_detect_cli "$@" ;;
  help|-h|--help) usage ;;
  '') usage >&2; exit 1 ;;
  *) die "unknown subcommand: $1 (expected open|return|collect|list|close|detect-cli|help)" ;;
esac
