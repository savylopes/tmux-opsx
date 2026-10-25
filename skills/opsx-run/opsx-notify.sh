#!/usr/bin/env bash
# opsx-notify.sh — push notifications from opsx windows to a (self-hosted) ntfy server.
#
# Usage:
#   opsx-notify.sh send [--window <id>] [--status done|fail] <kind> <window-label> <title> [body|-]
#   opsx-notify.sh <kind> <title> [body|-]       # same, without a window label
#   opsx-notify.sh mark <window-id> <label> <status> [--silence]
#   opsx-notify.sh flush <window-id> <stamp> [--after <secs>]
#   opsx-notify.sh ask-later <window-id> <label>
#   opsx-notify.sh pane-ask [<pane-id>]
#   opsx-notify.sh hook claude-stop|claude-pretool|claude-notification   (hook JSON on stdin)
#   opsx-notify.sh test
#   opsx-notify.sh info [--show-password]
#
# Kinds: decision (priority 4, tag question), finished (done: priority 3,
# white_check_mark; fail: priority 4, x), silence (priority 3, zzz), test.
#
# Settings come only from ${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/notify.env:
# KEY=value lines NTFY_URL, NTFY_TOPIC, NTFY_TOKEN (and NTFY_USER /
# NTFY_PASSWORD for `info`). The file is parsed, never executed. Without it
# (or with an unusable URL or topic) every command but `test`/`info` does
# nothing and exits 0.
#
# Sending never breaks the caller: curl gets --max-time 5, errors are
# swallowed, and send/mark/flush/hook always exit 0. The body goes to curl on
# stdin and the headers through a file descriptor, so neither the text nor the
# token appears in `ps`; the body is plain text cut to 500 characters, the
# title loses its newlines. The token is never printed.
#
# mark (run by opsx-window.sh mark): done|fail store a pending stamp
# @opsx_notify_pending=<status>:<epoch> on the window and start a detached
# flusher that sends the `finished` push after $OPSX_NOTIFY_FLUSH_AFTER
# seconds (default 60) unless the Claude Code Stop hook claimed it first
# (then the hook sends it with the agent's final message). ask starts a
# detached sender that waits $OPSX_NOTIFY_ASK_DELAY seconds (default 5) and
# sends "needs a decision" unless the window had a decision push with text
# (@opsx_notify_last_decision) in the last $OPSX_NOTIFY_DECISION_WINDOW
# seconds (default 30). --silence (the busy-to-idle fallback) sends
# "stopped without marking".
#
# Hooks only act in opsx panes: a pane tagged @fork_dir, a window tagged
# @opsx_change or a session tagged @opsx_task. The pane comes from $TMUX_PANE,
# else from /proc like opsx-window.sh (its recover_tmux_env is sourced). Hooks
# print nothing on stdout.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SELF=$HERE/$(basename -- "${BASH_SOURCE[0]}")
NOTIFY_ENV=${XDG_CONFIG_HOME:-$HOME/.config}/tmux-opsx/notify.env
BODY_MAX=500
TITLE_MAX=200

NTFY_URL="" NTFY_TOPIC="" NTFY_TOKEN="" NTFY_USER="" NTFY_PASSWORD=""

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$SELF"; }

# Read KEY=value lines from notify.env (never sourced). Returns 1 when the file
# is missing or the URL or topic is unusable.
load_config() {
  local line k v
  NTFY_URL="" NTFY_TOPIC="" NTFY_TOKEN="" NTFY_USER="" NTFY_PASSWORD=""
  [ -f "$NOTIFY_ENV" ] && [ -r "$NOTIFY_ENV" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ $line =~ ^(NTFY_URL|NTFY_TOPIC|NTFY_TOKEN|NTFY_USER|NTFY_PASSWORD)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    if [[ $v =~ ^\"(.*)\"$ ]] || [[ $v =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
    printf -v "$k" '%s' "$v"
  done < "$NOTIFY_ENV"
  NTFY_URL=${NTFY_URL%/}
  [[ $NTFY_URL =~ ^https?://[^[:space:]/\"]+(/[^[:space:]\"]*)?$ ]] || return 1
  [[ $NTFY_TOPIC =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 1
  if [ -n "$NTFY_TOKEN" ] && ! [[ $NTFY_TOKEN =~ ^[A-Za-z0-9_.-]+$ ]]; then return 1; fi
  return 0
}

now() { printf '%s' "${EPOCHSECONDS:-$(date +%s)}"; }

# Header lines for curl -H @file. The token stays off the command line.
headers() {
  local title=$1 tags=$2 prio=$3
  printf 'Title: %s\n' "$title"
  printf 'Tags: %s\n' "$tags"
  printf 'Priority: %s\n' "$prio"
  [ -z "$NTFY_TOKEN" ] || printf 'Authorization: Bearer %s\n' "$NTFY_TOKEN"
}

# post <title> <body> <tags> <priority>: one POST, prints the HTTP status.
post() {
  local title=$1 body=$2 tags=$3 prio=$4
  title=$(printf '%s' "$title" | tr -d '\r\n')
  title=${title:0:$TITLE_MAX}
  body=${body:0:$BODY_MAX}
  printf '%s' "$body" | curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' \
    -H @<(headers "$title" "$tags" "$prio") \
    --data-binary @- "$NTFY_URL/$NTFY_TOPIC" 2>/dev/null
}

# kind_meta <kind> <status>: sets PRIO and TAGS.
kind_meta() {
  case "$1" in
    decision) PRIO=4; TAGS=question ;;
    finished) if [ "${2:-done}" = fail ]; then PRIO=4; TAGS=x; else PRIO=3; TAGS=white_check_mark; fi ;;
    silence)  PRIO=3; TAGS=zzz ;;
    *)        PRIO=3; TAGS=bell ;;
  esac
}

# do_send <kind> <status> <title> <body>: needs load_config first; never fails.
do_send() {
  local PRIO TAGS
  kind_meta "$1" "$2"
  post "$3" "$4" "$TAGS" "$PRIO" >/dev/null 2>&1 || true
  return 0
}

# Run a copy of this script detached from the caller (no shared stdout).
detach() {
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$SELF" "$@" </dev/null >/dev/null 2>&1 &
  else
    nohup bash "$SELF" "$@" </dev/null >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true
}

# ---------- tmux scope ----------

# Find this process's pane: $TMUX_PANE, else the /proc walk of opsx-window.sh.
resolve_pane() {
  if [ -n "${TMUX_PANE:-}" ]; then return 0; fi
  [ -f "$HERE/opsx-window.sh" ] || return 1
  # shellcheck source=opsx-window.sh disable=SC1091
  . "$HERE/opsx-window.sh" || return 1
  recover_tmux_env >/dev/null 2>&1 || true
  [ -n "${TMUX_PANE:-}" ]
}

# pane_scope <pane>: sets P_WIN, P_LABEL, P_FORK (1 for a fork pane). Returns 1
# unless the pane is an opsx pane (@fork_dir pane, @opsx_change window,
# @opsx_task session). One tmux query.
pane_scope() {
  local out change task fork
  P_WIN="" P_LABEL="" P_FORK=0
  command -v tmux >/dev/null 2>&1 || return 1
  out=$(tmux display-message -p -t "$1" '#{window_id}|#{@opsx_change}|#{@opsx_task}|#{@fork_dir}' 2>/dev/null) || return 1
  IFS='|' read -r P_WIN change task fork <<<"$out"
  [ -n "$P_WIN" ] || return 1
  if [ -n "$fork" ]; then
    P_FORK=1; P_LABEL="fork-$(basename -- "$fork")"
  elif [ -n "$change" ]; then
    P_LABEL=$change
  elif [ -n "$task" ]; then
    P_LABEL=$task
  else
    return 1
  fi
  return 0
}

# window_ok <window-id>: the window still exists and is tagged.
window_ok() {
  local out
  out=$(tmux display-message -p -t "$1" '#{@opsx_change}|#{@opsx_task}' 2>/dev/null) || return 1
  [ "$out" != "|" ]
}

win_label() { tmux display-message -p -t "$1" '#{?@opsx_change,#{@opsx_change},#{@opsx_task}}' 2>/dev/null; }

lock_root() {
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
    printf '%s/tmux-opsx-notify' "$XDG_RUNTIME_DIR"
  else
    printf '%s/tmux-opsx/notify' "${XDG_STATE_HOME:-$HOME/.local/state}"
  fi
}

# claim <window-id> <stamp|''>: take the pending finished push of the window
# (the given stamp, or any when empty). Prints the claimed stamp. Exactly one
# of the Stop hook and the flusher wins: lock dir, unchanged stamp, unset.
claim() {
  local win=$1 want=$2 root lock cur srv i=0 rc=1
  root=$(lock_root)
  (umask 077; mkdir -p "$root") 2>/dev/null || return 1
  srv=$(tmux display-message -p -t "$win" '#{pid}' 2>/dev/null) || return 1
  lock=$root/$srv-${win#@}.lock
  while ! mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 50 ]; then
      # A claimer that died holding the lock: take it over once.
      if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rmdir "$lock" 2>/dev/null; i=0; continue
      fi
      return 1
    fi
    sleep 0.1
  done
  cur=$(tmux show-options -wqv -t "$win" @opsx_notify_pending 2>/dev/null)
  if [ -n "$cur" ] && { [ -z "$want" ] || [ "$cur" = "$want" ]; }; then
    tmux set-option -wu -t "$win" @opsx_notify_pending >/dev/null 2>&1
    printf '%s' "$cur"; rc=0
  fi
  rmdir "$lock" 2>/dev/null
  return "$rc"
}

record_decision() { tmux set-option -w -t "$1" @opsx_notify_last_decision "$(now)" >/dev/null 2>&1 || true; }

int_or() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

# ---------- JSON (jq, else python3) ----------

# json_get <json> <field>: a top-level string field ('' when absent).
json_get() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // "" | if type=="string" then . else tostring end' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -I -c 'import json,sys
try:
    v=json.load(sys.stdin).get(sys.argv[1],"")
except Exception:
    v=""
print(v if isinstance(v,str) else json.dumps(v))' "$2" 2>/dev/null
  fi
}

# question_text <json>: first AskUserQuestion question plus its option labels.
question_text() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r '(.tool_input.questions // [])[0] // {} |
      (.question // "") + (if ((.options // []) | length) > 0
        then "\nOptions: " + ([.options[] | (.label // tostring)] | join(" / ")) else "" end)' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -I -c 'import json,sys
try:
    q=(json.load(sys.stdin).get("tool_input",{}).get("questions") or [{}])[0]
    t=q.get("question","")
    o=[(x.get("label") if isinstance(x,dict) else str(x)) for x in q.get("options") or []]
    print(t + ("\nOptions: " + " / ".join(o) if o else ""))
except Exception:
    pass' 2>/dev/null
  fi
}

# last_transcript_text <file>: text of the last assistant entry in a JSONL transcript.
last_transcript_text() {
  [ -f "$1" ] && [ -r "$1" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    tail -n 400 "$1" | jq -Rnr '[inputs | fromjson? | select(type=="object" and .type=="assistant")
      | (.message.content // "") | if type=="string" then .
        elif type=="array" then ([.[] | select(type=="object" and .type=="text") | .text] | join("\n"))
        else "" end | select(length > 0)] | last // ""' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    tail -n 400 "$1" | python3 -I -c 'import json,sys
last=""
for line in sys.stdin:
    try:
        e=json.loads(line)
    except Exception:
        continue
    if not isinstance(e,dict) or e.get("type")!="assistant":
        continue
    c=(e.get("message") or {}).get("content") or ""
    if isinstance(c,list):
        c="\n".join(x.get("text","") for x in c if isinstance(x,dict) and x.get("type")=="text")
    if c:
        last=c
print(last)' 2>/dev/null
  fi
}

# ---------- commands ----------

notify_send() {
  local win="" status="done" kind label title body=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --window) win=${2:-}; shift 2 || shift ;;
      --status) status=${2:-done}; shift 2 || shift ;;
      *) break ;;
    esac
  done
  [ $# -ge 3 ] || exit 0
  kind=$1 label=$2 title=$3 body=${4:-}
  [ "$body" != - ] || body=$(head -c 65536)
  load_config || exit 0
  if [ -n "$win" ]; then
    window_ok "$win" || exit 0
    [ "$kind" != decision ] || [ -z "$body" ] || record_decision "$win"
  fi
  [ -n "$title" ] || title="$label"
  do_send "$kind" "$status" "$title" "$body"
  exit 0
}

# mark <win> <label> <status> [--silence]
notify_mark() {
  local win=${1:-} label=${2:-} status=${3:-} silence=0 stamp
  [ "${4:-}" = --silence ] && silence=1
  [ -n "$win" ] && [ -n "$label" ] || exit 0
  load_config || exit 0
  if [ "$silence" -eq 1 ]; then
    detach send --window "$win" silence "$label" "$label: stopped without marking" \
      "$label went quiet while busy and fell back to idle without marking done or fail."
    exit 0
  fi
  case "$status" in
    done|ok|pass|success) status="done" ;;
    fail|failed|error)    status=fail ;;
    ask|asking|question)  detach ask-later "$win" "$label"; exit 0 ;;
    *) exit 0 ;;
  esac
  stamp="$status:$(now)"
  tmux set-option -w -t "$win" @opsx_notify_pending "$stamp" >/dev/null 2>&1 || exit 0
  detach flush "$win" "$stamp" --after "$(int_or "${OPSX_NOTIFY_FLUSH_AFTER:-}" 60)"
  exit 0
}

# flush <win> <stamp> [--after N]: the finished push without the final message.
notify_flush() {
  local win=${1:-} stamp=${2:-} after=60 label status
  [ "${3:-}" = --after ] && after=$(int_or "${4:-}" 60)
  [ -n "$win" ] && [ -n "$stamp" ] || exit 0
  sleep "$after"
  load_config || exit 0
  claim "$win" "$stamp" >/dev/null || exit 0
  status=${stamp%%:*}
  label=$(win_label "$win"); [ -n "$label" ] || label=$win
  do_send finished "$status" "$label: $status" "$label was marked $status."
  exit 0
}

# ask-later <win> <label>: the bare "needs a decision" push, unless a decision
# push with text was sent for the window within the collapse window.
notify_ask_later() {
  local win=${1:-} label=${2:-} last delay span
  [ -n "$win" ] || exit 0
  delay=$(int_or "${OPSX_NOTIFY_ASK_DELAY:-}" 5)
  span=$(int_or "${OPSX_NOTIFY_DECISION_WINDOW:-}" 30)
  sleep "$delay"
  load_config || exit 0
  window_ok "$win" || exit 0
  last=$(tmux show-options -wqv -t "$win" @opsx_notify_last_decision 2>/dev/null)
  last=$(int_or "$last" 0)
  [ $(( $(now) - last )) -ge "$span" ] || exit 0
  [ -n "$label" ] || label=$(win_label "$win")
  do_send decision "" "$label: needs a decision" "$label is waiting for your answer."
  exit 0
}

# pane-ask [pane]: `mark . ask` from a fork pane or a task session.
notify_pane_ask() {
  local pane=${1:-}
  load_config || exit 0
  if [ -z "$pane" ]; then resolve_pane || exit 0; pane=$TMUX_PANE; fi
  pane_scope "$pane" || exit 0
  detach ask-later "$P_WIN" "$P_LABEL"
  exit 0
}

hook_input() { if [ -t 0 ]; then printf ''; else head -c 4194304; fi; }

hook_claude_stop() {
  local input stamp status msg tp
  input=$(hook_input)
  load_config || return 0
  resolve_pane || return 0
  pane_scope "$TMUX_PANE" || return 0
  # A fork pane's turn end is not the change window's turn end.
  [ "$P_FORK" -eq 0 ] || return 0
  stamp=$(claim "$P_WIN" "") || return 0
  status=${stamp%%:*}
  msg=$(json_get "$input" last_assistant_message)
  if [ -z "$msg" ]; then
    tp=$(json_get "$input" transcript_path)
    [ -z "$tp" ] || msg=$(last_transcript_text "$tp")
  fi
  do_send finished "$status" "$P_LABEL: $status" "$msg"
}

hook_claude_pretool() {
  local input q
  input=$(hook_input)
  [ "$(json_get "$input" tool_name)" = AskUserQuestion ] || return 0
  load_config || return 0
  resolve_pane || return 0
  pane_scope "$TMUX_PANE" || return 0
  q=$(question_text "$input")
  record_decision "$P_WIN"
  do_send decision "" "$P_LABEL: needs a decision" "$q"
}

hook_claude_notification() {
  local input type msg
  input=$(hook_input)
  type=$(json_get "$input" notification_type)
  [ -n "$type" ] || type=$(json_get "$input" type)
  msg=$(json_get "$input" message)
  if [ -z "$type" ]; then
    case "$msg" in *permission*) type=permission_prompt ;; esac
  fi
  [ "$type" = permission_prompt ] || return 0
  load_config || return 0
  resolve_pane || return 0
  pane_scope "$TMUX_PANE" || return 0
  record_decision "$P_WIN"
  do_send decision "" "$P_LABEL: waiting for permission" "${msg:-$P_LABEL is waiting for permission.}"
}

notify_hook() {
  case "${1:-}" in
    claude-stop)         hook_claude_stop ;;
    claude-pretool)      hook_claude_pretool ;;
    claude-notification) hook_claude_notification ;;
  esac
  exit 0
}

notify_test() {
  local code
  if ! load_config; then
    printf 'push failed: notify is not configured (%s is missing or has no usable NTFY_URL / NTFY_TOPIC)\n' "$NOTIFY_ENV" >&2
    exit 1
  fi
  code=$(post "tmux-opsx test" "Test push from $(hostname 2>/dev/null || echo this host). Notifications work." bell 3)
  code=${code:-000}
  case "$code" in
    2??) printf 'push sent to %s (topic %s, HTTP %s)\n' "$NTFY_URL" "$NTFY_TOPIC" "$code" ;;
    000) printf 'push failed: %s is not reachable (HTTP 000)\n' "$NTFY_URL" >&2; exit 1 ;;
    *)   printf 'push failed: HTTP %s from %s\n' "$code" "$NTFY_URL" >&2; exit 1 ;;
  esac
}

notify_info() {
  local show=0
  case "${1:-}" in
    --show-password) show=1 ;;
    "") ;;
    *) printf 'usage: opsx notify info [--show-password]\n' >&2; exit 2 ;;
  esac
  if ! load_config; then
    printf 'notify is not configured: %s is missing or has no usable NTFY_URL / NTFY_TOPIC\n' "$NOTIFY_ENV" >&2
    printf 'run ./install.sh --expose-domain <domain>, or write it by hand for any ntfy server\n' >&2
    exit 1
  fi
  printf 'url:      %s\n' "$NTFY_URL"
  printf 'user:     %s\n' "${NTFY_USER:-(none, token only)}"
  printf 'topic:    %s\n' "$NTFY_TOPIC"
  if [ "$show" -eq 1 ]; then
    printf 'password: %s\n' "${NTFY_PASSWORD:-(not stored)}"
  else
    printf 'password: (hidden; opsx notify info --show-password)\n'
  fi
  printf 'Android:  install ntfy, add server %s, log in as %s, subscribe to %s\n' \
    "$NTFY_URL" "${NTFY_USER:-opsx}" "$NTFY_TOPIC"
}

case "${1:-}" in
  send)      shift; notify_send "$@" ;;
  decision|finished|silence)
             k=$1; shift; notify_send "$k" "" "$@" ;;
  mark)      shift; notify_mark "$@" ;;
  flush)     shift; notify_flush "$@" ;;
  ask-later) shift; notify_ask_later "$@" ;;
  pane-ask)  shift; notify_pane_ask "$@" ;;
  hook)      shift; notify_hook "$@" ;;
  test)      shift; notify_test "$@" ;;
  info)      shift; notify_info "$@" ;;
  ""|-h|--help|help) usage ;;
  *) printf 'opsx-notify: unknown command %s\n' "$1" >&2; usage >&2; exit 0 ;;
esac
