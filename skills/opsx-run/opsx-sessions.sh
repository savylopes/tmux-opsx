#!/usr/bin/env bash
# opsx-sessions.sh — bring Claude Code conversations back after tmux restarts.
#
# Usage:
#   opsx-sessions.sh hook                  # Claude Code SessionStart hook (JSON on stdin)
#   opsx-sessions.sh save                  # write the snapshot (tmux-resurrect post-save hook)
#   opsx-sessions.sh restore [--no-nudge]  # resume conversations (resurrect post-restore hook)
#   opsx-sessions.sh list [--live]         # show the snapshot (or the running server's records)
#
# hook     Installed by install.sh as a Claude Code SessionStart hook (startup,
#          resume, clear). Records which conversation runs in which tmux pane:
#          server, pane id, session, window index and name, pane index, cwd,
#          session id and permission mode, in live/<server-key>/<pane-id>. A
#          new record for the same pane replaces the old one. Writes nothing
#          outside tmux, for print-mode (-p/--print) sessions, or for an input
#          without a valid session id. Always exits 0 and prints nothing.
# save     Keeps the running server's records whose pane still runs `claude`,
#          with the pane's position and window name now and the window's
#          @opsx_* options now, and writes snapshot.tsv. Entries of earlier
#          servers that were not restored yet are kept. Live records of dead
#          servers are removed once nothing of theirs is pending.
# restore  For each pending entry of an earlier server, in session / window /
#          pane order: finds session:window.pane (creating a missing session or
#          window with the recorded name and cwd; a missing pane is skipped),
#          and when that pane sits at a shell types
#            cd -- <cwd> && claude --resume <id> [--permission-mode <m>] [--model <m>] [<prompt>]
#          through `opsx-window.sh type`. --permission-mode is left out for
#          `default`, --model comes from the window's @opsx_model. A pane that
#          runs anything else is skipped and stays pending. The window's
#          @opsx_* options are put back either way. Restored entries are marked
#          and never typed again.
#          Prompt (left out with --no-nudge):
#            - change window (@opsx_change, no @opsx_pr_repo) that was busy at
#              save: a resume message, prefixed by `/goal <@opsx_goal>` when
#              the window has one (dropped if it would pass 4000 characters);
#              the window is then marked busy.
#            - PR window (@opsx_pr_repo, @opsx_change=pr-<n>) not marked done:
#              the output of `pr.sh restart-input <n> --repo <cwd>`; when that
#              fails the pane is resumed with no prompt and the reason printed.
#            - anything else: no prompt.
#          Change windows get their status colours back through
#          `opsx-window.sh mark` (a busy window that is not continued is
#          marked idle).
# list     One line per snapshot entry: session:window.pane, window name, cwd,
#          session id, pending|restored. --live: the running server's records.
#
# State: $OPSX_SESSIONS_DIR, else ${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/sessions/
#   live/<server-key>/<pane-id>   hook records (key=value lines)
#   snapshot.tsv                  save output, marked by restore
#   restore.log                   output of every restore run
# <server-key> is <cksum of the socket path>-<server start time>, so pane ids
# reused by a new server never overwrite records still waiting for a restore.
# Overrides (tests): OPSX_WINDOW (opsx-window.sh), OPSX_PR_SH (pr.sh).

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR=${OPSX_SESSIONS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-opsx/sessions}
SNAP=$STATE_DIR/snapshot.tsv
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
SHELLS=" bash zsh sh fish dash ksh mksh "
GOAL_MAX=4000

die() { printf 'opsx-sessions: %s\n' "$1" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; }

# ---------------------------------------------------------------- helpers

# Escape a value for one TSV field / key=value line: \ tab newline CR.
esc() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# unesc <var> <escaped>: undo esc into variable <var>.
unesc() { printf -v "$1" '%b' "$2"; }

# Split a TSV line into the array F (empty fields kept).
split_tsv() {
  local line=$1
  F=()
  while :; do
    case $line in
      *$'\t'*) F+=("${line%%$'\t'*}"); line=${line#*$'\t'} ;;
      *) F+=("$line"); break ;;
    esac
  done
}

# Copied from skills/fork/fork.sh: read a variable from the nearest ancestor
# whose environment has it (agent CLIs and sandboxes may strip TMUX/TMUX_PANE).
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

parent_pid() {
  local p=""
  if [ -r "/proc/$1/stat" ]; then
    # Field 4 of stat, after the parenthesised command name.
    p=$(sed 's/.*) [A-Za-z] \([0-9]*\) .*/\1/' "/proc/$1/stat" 2>/dev/null)
  fi
  [ -n "$p" ] || p=$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')
  printf '%s' "$p"
}

# Arguments of process $1, one per line.
proc_args() {
  if [ -r "/proc/$1/cmdline" ]; then
    tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null
  else
    ps -o args= -p "$1" 2>/dev/null | tr ' ' '\n'
  fi
}

# Server identity of the tmux server $TMUX/-L points at: "<key>\t<socket>\t<start>".
server_info() {
  local out sock start sum
  out=$(tmux display-message -p '#{socket_path}	#{start_time}' 2>/dev/null) || return 1
  sock=${out%%$'\t'*}; start=${out#*$'\t'}
  [ -n "$sock" ] && [ -n "$start" ] || return 1
  sum=$(printf '%s' "$sock" | cksum | awk '{print $1}')
  printf '%s-%s\t%s\t%s' "$sum" "$start" "$sock" "$start"
}

current_key() {
  local i
  i=$(server_info) || return 1
  printf '%s' "${i%%$'\t'*}"
}

# Is the server recorded in live/<key>/.server still running?
server_alive() {
  local f=$STATE_DIR/live/$1/.server sock start now
  [ -f "$f" ] || return 1
  sock=$(sed -n 's/^socket=//p' "$f" | head -1)
  start=$(sed -n 's/^start_time=//p' "$f" | head -1)
  [ -n "$sock" ] && [ -S "$sock" ] || return 1
  now=$(tmux -S "$sock" display-message -p '#{start_time}' 2>/dev/null) || return 1
  [ "$now" = "$start" ]
}

with_lock() {
  mkdir -p "$STATE_DIR" || return 1
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w 30 9 || exit 1
      "$@"
    ) 9>"$STATE_DIR/.lock"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------- hook

# Prints session_id, cwd, permission_mode, source (escaped), one per line.
parse_hook_json() {
  local json=$1
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
def e(v):
    v = v if isinstance(v, str) else ""
    return v.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")
for k in ("session_id", "cwd", "permission_mode", "source"):
    print(e(d.get(k)))
' 2>/dev/null && return 0
  fi
  # Tolerant fallback: plain string values only (no escaped quotes).
  local k
  for k in session_id cwd permission_mode source; do
    printf '%s' "$json" | tr '\n' ' ' \
      | sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\\([^\"\\\\]*\\)\".*/\\1/p" | head -1
    printf '\n'
  done
}

# Walk ancestors of the hook: sets HOOK_PANE (pane whose pane_pid is an
# ancestor; only looked up when $1 is 1) and HOOK_PRINT=1 when the nearest
# claude ancestor runs in print mode.
walk_ancestors() {
  local want_pane=$1 pid=$$ i=0 panes="" args a base found_claude=0 j
  HOOK_PANE="" HOOK_PRINT=0
  [ "$want_pane" -eq 1 ] && panes=$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null)
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$i" -lt 40 ]; do
    if [ "$found_claude" -eq 0 ]; then
      mapfile -t args < <(proc_args "$pid")
      for j in 0 1; do
        a=${args[$j]:-}
        base=${a##*/}
        if [ "$base" = claude ] || [[ "$a" == *claude-code/cli.js ]]; then
          found_claude=1
          for a in "${args[@]:$((j + 1))}"; do
            case "$a" in
              -p|--print|--print=*) HOOK_PRINT=1 ;;
            esac
          done
          break
        fi
      done
    fi
    if [ "$want_pane" -eq 1 ] && [ -z "$HOOK_PANE" ]; then
      HOOK_PANE=$(printf '%s\n' "$panes" | awk -v p="$pid" '$1 == p { print $2; exit }')
    fi
    [ "$found_claude" -eq 1 ] && { [ "$want_pane" -eq 0 ] || [ -n "$HOOK_PANE" ]; } && return 0
    pid=$(parent_pid "$pid")
    i=$((i + 1))
  done
  return 0
}

hook_main() {
  local json lines id cwd mode source v pane info key sock start sess widx wname pidx dir tmp
  [ -t 0 ] && return 0
  json=$(head -c 65536)
  mapfile -t lines < <(parse_hook_json "$json")
  unesc id "${lines[0]:-}"; unesc cwd "${lines[1]:-}"
  unesc mode "${lines[2]:-}"; unesc source "${lines[3]:-}"
  [[ $id =~ $UUID_RE ]] || return 0
  [[ $mode =~ ^[A-Za-z]{1,40}$ ]] || mode=""
  [[ $source =~ ^[a-z]{1,20}$ ]] || source=""

  command -v tmux >/dev/null 2>&1 || return 0
  if [ -z "${TMUX:-}" ] && v=$(recover_env_var TMUX); then
    TMUX=$v; export TMUX
  fi
  [ -n "${TMUX:-}" ] || return 0
  info=$(server_info) || return 0
  key=${info%%$'\t'*}; info=${info#*$'\t'}
  sock=${info%%$'\t'*}; start=${info#*$'\t'}

  pane=${TMUX_PANE:-}
  if [ -z "$pane" ] && v=$(recover_env_var TMUX_PANE); then pane=$v; fi
  if [ -n "$pane" ]; then
    walk_ancestors 0
  else
    walk_ancestors 1
    pane=$HOOK_PANE
  fi
  [ "$HOOK_PRINT" -eq 1 ] && return 0
  [[ $pane =~ ^%[0-9]+$ ]] || return 0
  v=$(tmux display-message -p -t "$pane" '#{pane_id}	#{session_name}	#{window_index}	#{pane_index}	#{window_name}' 2>/dev/null) || return 0
  [ "${v%%$'\t'*}" = "$pane" ] || return 0
  split_tsv "$v"
  sess=${F[1]:-}; widx=${F[2]:-}; pidx=${F[3]:-}; wname=${F[4]:-}
  [ -n "$cwd" ] || cwd=$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)

  dir=$STATE_DIR/live/$key
  mkdir -p "$dir" || return 0
  if [ ! -f "$dir/.server" ]; then
    printf 'socket=%s\nstart_time=%s\n' "$sock" "$start" > "$dir/.server.$$" && mv -f "$dir/.server.$$" "$dir/.server"
  fi
  tmp=$dir/.${pane}.$$
  {
    printf 'pane=%s\n' "$pane"
    printf 'session=%s\n' "$(esc "$sess")"
    printf 'window_index=%s\n' "$widx"
    printf 'window_name=%s\n' "$(esc "$wname")"
    printf 'pane_index=%s\n' "$pidx"
    printf 'cwd=%s\n' "$(esc "$cwd")"
    printf 'session_id=%s\n' "$id"
    printf 'mode=%s\n' "$mode"
    printf 'source=%s\n' "$source"
    printf 'time=%s\n' "$(date +%s)"
  } > "$tmp" && mv -f "$tmp" "$dir/$pane"
  rm -f "$tmp" 2>/dev/null
  return 0
}

cmd_hook() {
  local log
  mkdir -p "$STATE_DIR" 2>/dev/null
  log=$STATE_DIR/hook.log
  [ -w "$STATE_DIR" ] || log=/dev/null
  # Claude Code adds hook stdout to the conversation: never print anything.
  hook_main >/dev/null 2>>"$log" || true
  exit 0
}

# rec_get <file> <key>: escaped value of key in a live record.
rec_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# ---------------------------------------------------------------- save

# Window @opsx_* options as escaped "@name=value" fields, tab separated.
window_opts() {
  local win=$1 name val out=""
  while read -r name _; do
    case "$name" in @opsx_*) ;; *) continue ;; esac
    val=$(tmux show-options -wqv -t "$win" "$name" 2>/dev/null)
    out+=$'\t'"$(esc "$name=$val")"
  done < <(tmux show-options -w -t "$win" 2>/dev/null)
  printf '%s' "$out"
}

save_locked() {
  local info key panes line f pane sess widx wname pidx cmd win id cwd mode now tmp n=0 kept=0
  local -A cur_ids=()
  now=$(date +%s)
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  tmp=$SNAP.tmp.$$
  printf '# opsx-sessions snapshot v1: state server pane session window_index window_name pane_index cwd session_id mode saved_at @opsx_*=value...\n' > "$tmp" \
    || die "cannot write $tmp"
  key=""
  if info=$(server_info); then
    key=${info%%$'\t'*}
    panes=$(tmux list-panes -a -F '#{pane_id}	#{session_name}	#{window_index}	#{pane_index}	#{pane_current_command}	#{window_id}	#{window_name}' 2>/dev/null)
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      split_tsv "$line"
      pane=${F[0]}; sess=${F[1]}; widx=${F[2]}; pidx=${F[3]}; cmd=${F[4]}; win=${F[5]}; wname=${F[6]:-}
      f=$STATE_DIR/live/$key/$pane
      [ -f "$f" ] || continue
      [ "${cmd##*/}" = claude ] || continue
      id=$(rec_get "$f" session_id); [[ $id =~ $UUID_RE ]] || continue
      cwd=$(rec_get "$f" cwd); mode=$(rec_get "$f" mode)
      cur_ids[$id]=1
      printf 'pending\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' \
        "$key" "$pane" "$(esc "$sess")" "$widx" "$(esc "$wname")" "$pidx" \
        "$cwd" "$id" "$mode" "$now" "$(window_opts "$win")" >> "$tmp"
      n=$((n + 1))
    done <<<"$panes"
  fi
  # Earlier servers' entries still waiting for a restore stay, unless the same
  # conversation is already running again on this server.
  if [ -f "$SNAP" ]; then
    while IFS= read -r line; do
      case "$line" in '#'*|'') continue ;; esac
      split_tsv "$line"
      [ "${F[0]}" = pending ] || continue
      [ "${F[1]}" != "$key" ] || continue
      [ -z "${cur_ids[${F[8]:-x}]:-}" ] || continue
      printf '%s\n' "$line" >> "$tmp"
      kept=$((kept + 1))
    done < "$SNAP"
  fi
  mv -f "$tmp" "$SNAP" || die "cannot write $SNAP"
  prune_live "$key"
  # Quiet unless run by hand: resurrect hooks run without a terminal.
  [ -t 1 ] && printf 'saved %s session(s) of this server, kept %s pending from earlier servers -> %s\n' "$n" "$kept" "$SNAP"
  return 0
}

# Remove live dirs of servers that are gone and have nothing pending.
prune_live() {
  local key=$1 d k pending
  [ -d "$STATE_DIR/live" ] || return 0
  pending=$(awk -F '\t' '$1 == "pending" { print $2 }' "$SNAP" 2>/dev/null | sort -u)
  for d in "$STATE_DIR"/live/*/; do
    [ -d "$d" ] || continue
    k=$(basename "$d")
    [ "$k" = "$key" ] && continue
    printf '%s\n' "$pending" | grep -qxF "$k" && continue
    server_alive "$k" && continue
    rm -rf "${d%/}"
  done
}

cmd_save() {
  [ $# -eq 0 ] || die "save takes no arguments"
  with_lock save_locked || exit 1
  return 0
}

# ---------------------------------------------------------------- list

cmd_list() {
  local live=0 line key f pane cur sess widx pidx wname cwd id mode n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --live) live=1; shift ;;
      *) die "unknown option: $1 (list [--live])" ;;
    esac
  done
  if [ "$live" -eq 1 ]; then
    key=$(current_key) || { printf 'no tmux server running\n'; return 0; }
    for f in "$STATE_DIR/live/$key"/%*; do
      [ -f "$f" ] || continue
      pane=$(rec_get "$f" pane)
      unesc sess "$(rec_get "$f" session)"; unesc wname "$(rec_get "$f" window_name)"
      widx=$(rec_get "$f" window_index); pidx=$(rec_get "$f" pane_index)
      cur=$(tmux display-message -p -t "$pane" '#{pane_id}	#{session_name}	#{window_index}	#{pane_index}	#{window_name}' 2>/dev/null) || cur=""
      if [ "${cur%%$'\t'*}" = "$pane" ]; then
        split_tsv "$cur"; sess=${F[1]}; widx=${F[2]}; pidx=${F[3]}; wname=${F[4]:-}
      fi
      unesc cwd "$(rec_get "$f" cwd)"
      id=$(rec_get "$f" session_id); mode=$(rec_get "$f" mode)
      printf '%s:%s.%s\t%s\t%s\t%s\t%s\t%s\n' "$sess" "$widx" "$pidx" "$pane" "$wname" "$cwd" "$id" "${mode:-default}"
      n=$((n + 1))
    done
    [ "$n" -gt 0 ] || printf 'no recorded sessions on this tmux server\n'
    return 0
  fi
  if [ -f "$SNAP" ]; then
    while IFS= read -r line; do
      case "$line" in '#'*|'') continue ;; esac
      split_tsv "$line"
      unesc sess "${F[3]}"; unesc wname "${F[5]}"; unesc cwd "${F[7]}"
      printf '%s:%s.%s\t%s\t%s\t%s\t%s\n' "$sess" "${F[4]}" "${F[6]}" "$wname" "$cwd" "${F[8]}" "${F[0]}"
      n=$((n + 1))
    done < "$SNAP"
  fi
  [ "$n" -gt 0 ] || printf 'no recorded sessions (the snapshot is empty; see opsx-sessions.sh save)\n'
  return 0
}

# ---------------------------------------------------------------- restore

window_script() {
  local w=${OPSX_WINDOW:-$HERE/opsx-window.sh}
  [ -f "$w" ] || die "opsx-window.sh not found at $w"
  printf '%s' "$w"
}

pr_script() {
  local p=${OPSX_PR_SH:-$HERE/../opsx-pr/pr.sh}
  [ -f "$p" ] || return 1
  printf '%s' "$p"
}

# POSIX single-quoting (works in bash, zsh, sh, dash, ksh and fish).
squote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# One line, no control characters (newlines would submit early).
one_line() { printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037'; }

safe_name() {
  [ -n "$1" ] || return 1
  case "$1" in *[:.]*) return 1 ;; esac
  ! printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

say() { printf '%s\n' "$1"; printf '%s %s\n' "$(date '+%F %T')" "$1" >> "$STATE_DIR/restore.log" 2>/dev/null; }

nudge_message() {
  local change=$1
  printf 'tmux restarted (tmux server restart or reboot) and this window'\''s last task (%s) was not finished. Check where you stopped first (git status and log in the worktree, tasks.md, the last messages above), then continue the same steps from there and mark the window as before (opsx-window.sh mark %s busy|done|fail).' "$change" "$change"
}

# Run opsx-window.sh for the server/pane being restored.
win_cmd() {
  local pane=$1; shift
  TMUX=$RESTORE_TMUX TMUX_PANE=$pane bash "$WINDOW_SH" "$@"
}

# opt_get <name>: value of @name recorded in the current entry (OPTS).
opt_get() {
  local o
  for o in "${OPTS[@]}"; do
    [ "${o%%=*}" = "$1" ] && { printf '%s' "${o#*=}"; return 0; }
  done
  return 1
}

restore_one() {
  local line=$1 key pane sess widx wname pidx cwd id mode o cur cmd
  local win newpane created="" change status pr_repo goal model prompt="" msg out rc n cli tf typed
  split_tsv "$line"
  key=${F[1]}; pane=${F[2]}
  unesc sess "${F[3]}"; widx=${F[4]}; unesc wname "${F[5]}"; pidx=${F[6]}
  unesc cwd "${F[7]}"; id=${F[8]}; mode=${F[9]}
  OPTS=()
  for o in "${F[@]:11}"; do
    [ -n "$o" ] || continue
    unesc o "$o"
    case "$o" in @opsx_*=*) OPTS+=("$o") ;; esac
  done
  local label="$sess:$widx.$pidx"

  if ! safe_name "$sess" || ! [[ $widx =~ ^[0-9]+$ ]] || ! [[ $pidx =~ ^[0-9]+$ ]] \
     || ! [[ $id =~ $UUID_RE ]] || [ -z "$cwd" ] || [ "${cwd#/}" = "$cwd" ]; then
    say "invalid $label: bad session name, index, id or cwd in the snapshot; skipped"
    return 1
  fi
  printf '%s' "$wname" | LC_ALL=C grep -q '[[:cntrl:]]' && wname=""
  [[ $mode =~ ^[A-Za-z]{1,40}$ ]] || mode=""
  local wcwd=$cwd
  [ -d "$wcwd" ] || wcwd=$HOME

  # Session and window, created when missing.
  if ! tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qxF -- "$sess"; then
    out=$(tmux new-session -d -s "$sess" ${wname:+-n "$wname"} -c "$wcwd" -P -F '#{window_index}' 2>&1) \
      || { say "failed $label: cannot create session: $out"; return 1; }
    if [ "$out" != "$widx" ]; then
      tmux move-window -s "=$sess:$out" -t "=$sess:$widx" >/dev/null 2>&1 \
        || { say "failed $label: cannot move the new window to index $widx"; return 1; }
    fi
    created=" (session created)"
  elif ! tmux list-windows -a -F '#{session_name}	#{window_index}' 2>/dev/null \
         | awk -F '\t' -v s="$sess" -v w="$widx" '$1 == s && $2 == w { f = 1 } END { exit !f }'; then
    out=$(tmux new-window -d -t "=$sess:$widx" ${wname:+-n "$wname"} -c "$wcwd" -P -F '#{window_id}' 2>&1) \
      || { say "failed $label: cannot create window: $out"; return 1; }
    created=" (window created)"
  fi
  # Exact lookup: display-message -t falls back to another pane when missing.
  cur=$(tmux list-panes -a -F '#{session_name}	#{window_index}	#{pane_index}	#{pane_id}	#{window_id}	#{pane_current_command}' 2>/dev/null \
        | awk -F '\t' -v s="$sess" -v w="$widx" -v i="$pidx" \
            '$1 == s && $2 == w && $3 == i { print $4 "\t" $5 "\t" $6; exit }')
  split_tsv "$cur"
  newpane=${F[0]:-}; win=${F[1]:-}; cmd=${F[2]:-}
  if ! [[ $newpane =~ ^%[0-9]+$ ]]; then
    say "skipped $label: no pane $pidx in window $sess:$widx (layout is tmux-resurrect's job)"
    return 1
  fi

  # Tags go back whether or not the pane is free.
  for o in "${OPTS[@]}"; do
    tmux set-option -w -t "$win" "${o%%=*}" "${o#*=}" >/dev/null 2>&1
  done
  change=$(opt_get @opsx_change) || change=""
  status=$(opt_get @opsx_status) || status=""
  pr_repo=$(opt_get @opsx_pr_repo) || pr_repo=""
  if [ -n "$change" ]; then
    tmux set-window-option -t "$win" automatic-rename off >/dev/null 2>&1
    tmux set-window-option -t "$win" allow-rename off >/dev/null 2>&1
    [ -z "$wname" ] || tmux rename-window -t "$win" "$wname" >/dev/null 2>&1
  fi

  cmd=${cmd##*/}; cmd=${cmd#-}
  case "$SHELLS" in
    *" $cmd "*) ;;
    *) say "skipped $label: pane $newpane is busy ($cmd); tags put back, still pending"
       return 2 ;;
  esac

  # First prompt for unfinished work.
  if [ "$NUDGE" -eq 1 ] && [ -n "$change" ]; then
    if [ -n "$pr_repo" ] && [[ $change =~ ^pr-([0-9]+)$ ]]; then
      n=${BASH_REMATCH[1]}
      if [ "$status" = "done" ]; then
        :
      elif ! out=$(pr_script); then
        say "note $label: $change not continued: pr.sh not found"
      else
        out=$(cd "$wcwd" && timeout 120 bash "$out" restart-input "$n" --repo "$cwd" 2>&1); rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
          prompt=$(one_line "$out")
        else
          say "note $label: $change not continued: $(one_line "$out") (pr.sh restart-input exit $rc)"
        fi
      fi
    elif [ -z "$pr_repo" ] && [ "$status" = busy ]; then
      msg=$(nudge_message "$change")
      goal=$(opt_get @opsx_goal) || goal=""
      goal=$(one_line "$goal")
      if [ -n "$goal" ] && [ $(( ${#goal} + 1 + ${#msg} )) -le "$GOAL_MAX" ]; then
        prompt="/goal $goal $msg"
      else
        prompt=$msg
      fi
    fi
  fi

  cli="claude --resume $id"
  [ -z "$mode" ] || [ "$mode" = default ] || cli+=" --permission-mode $mode"
  model=$(opt_get @opsx_model) || model=""
  if [ -n "$model" ] && [ "$model" != default ]; then
    if [[ $model =~ ^[A-Za-z0-9._:/@][A-Za-z0-9._:/@-]*$ ]]; then
      cli+=" --model $model"
    else
      say "note $label: @opsx_model '$(one_line "$model")' has unsafe characters; resumed without --model"
    fi
  fi
  [ -z "$prompt" ] || cli+=" $(squote "$prompt")"
  typed="cd -- $(squote "$cwd") && $cli"

  tf=$(mktemp "$STATE_DIR/.type.XXXXXX") || { say "failed $label: cannot create a temp file"; return 1; }
  printf '%s\n' "$typed" > "$tf"
  out=$(win_cmd "$newpane" type "$newpane" --text-file "$tf" 2>&1); rc=$?
  rm -f "$tf"
  if [ "$rc" -ne 0 ]; then
    say "failed $label: $out"
    return 1
  fi
  RESTORED+=("$key"$'\t'"$pane")

  # Status colours and badge back for change windows.
  if [ -n "$change" ] && [ -n "$status" ]; then
    if [ -n "$prompt" ]; then status=busy
    elif [ "$status" = busy ]; then status=idle
    fi
    win_cmd "$newpane" mark "$change" "$status" >/dev/null 2>&1 \
      || say "note $label: could not mark $change $status"
  fi
  if [ -n "$prompt" ]; then
    say "resumed $label $id$created -> $newpane, continued ($change)"
  else
    say "resumed $label $id$created -> $newpane"
  fi
  return 0
}

mark_restored_locked() {
  local tmp line k
  local -A done_keys=()
  [ -f "$SNAP" ] || return 0
  for k in "${RESTORED[@]}"; do done_keys[$k]=1; done
  tmp=$SNAP.tmp.$$
  while IFS= read -r line; do
    case "$line" in
      '#'*|'') printf '%s\n' "$line" ;;
      *)
        split_tsv "$line"
        if [ "${F[0]}" = pending ] && [ -n "${done_keys[${F[1]}$'\t'${F[2]}]:-}" ]; then
          printf 'restored%s\n' "${line#pending}"
        else
          printf '%s\n' "$line"
        fi ;;
    esac
  done < "$SNAP" > "$tmp" && mv -f "$tmp" "$SNAP"
}

cmd_restore() {
  NUDGE=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-nudge) NUDGE=0; shift ;;
      *) die "unknown option: $1 (restore [--no-nudge])" ;;
    esac
  done
  command -v tmux >/dev/null 2>&1 || die "tmux is not installed."
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  [ -f "$SNAP" ] || { say "no recorded sessions to restore"; return 0; }
  WINDOW_SH=$(window_script) || exit 1
  local key="" entries line k total=0 ok=0 skipped=0
  key=$(current_key) || key=""
  RESTORED=() RESTORE_TMUX=
  # Pending entries of servers that are gone, in session / window / pane order.
  entries=$(grep -v '^#' "$SNAP" | awk -F '\t' '$1 == "pending"' | sort -t "$(printf '\t')" -k4,4 -k5,5n -k7,7n)
  local -A alive=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    split_tsv "$line"; k=${F[1]}
    [ "$k" != "$key" ] || continue
    if [ -z "${alive[$k]:-}" ]; then
      if server_alive "$k"; then alive[$k]=yes; else alive[$k]=no; fi
    fi
    [ "${alive[$k]}" = no ] || continue
    if [ -z "$RESTORE_TMUX" ]; then
      RESTORE_TMUX=$(tmux display-message -p '#{socket_path},#{pid},0' 2>/dev/null) || RESTORE_TMUX=""
    fi
    total=$((total + 1))
    restore_one "$line"
    case $? in
      0) ok=$((ok + 1)) ;;
      *) skipped=$((skipped + 1)) ;;
    esac
    [ -n "$RESTORE_TMUX" ] || RESTORE_TMUX=$(tmux display-message -p '#{socket_path},#{pid},0' 2>/dev/null) || RESTORE_TMUX=""
  done <<<"$entries"
  if [ "${#RESTORED[@]}" -gt 0 ]; then
    with_lock mark_restored_locked || say "warning: could not mark restored entries in $SNAP"
  fi
  if [ "$total" -eq 0 ]; then
    say "nothing to restore (no pending entries from an earlier tmux server)"
  else
    say "restore: $ok resumed, $skipped skipped of $total"
  fi
  return 0
}

# ---------------------------------------------------------------- main

case "${1:-}" in
  hook)    shift; cmd_hook "$@" ;;
  save)    shift; cmd_save "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  list)    shift; cmd_list "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown subcommand: $1 (expected hook|save|restore|list)" ;;
esac
