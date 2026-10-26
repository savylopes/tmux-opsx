#!/usr/bin/env bash
# opsx-notify.sh — push notifications from opsx windows to a (self-hosted) ntfy server.
#
# Usage:
#   opsx-notify.sh send [--window <id>] [--status done|fail] [--pr <n> --repo <owner/name> --option <label>...]
#                       <kind> <window-label> <title> [body|-]
#   opsx-notify.sh <kind> <title> [body|-]       # same, without a window label
#   opsx-notify.sh mark <window-id> <label> <status> [--silence]
#   opsx-notify.sh flush <window-id> <stamp> [--after <secs>]
#   opsx-notify.sh ask-later <window-id> <label> [--pane <pane-id>]
#   opsx-notify.sh pane-ask [<pane-id>]
#   opsx-notify.sh hook claude-stop|claude-pretool|claude-notification   (hook JSON on stdin)
#   opsx-notify.sh listen
#   opsx-notify.sh menu-keys <n>
#   opsx-notify.sh test
#   opsx-notify.sh info [--show-password]
#
# Kinds: decision (priority 4, tag question), finished (done: priority 3,
# white_check_mark; fail: priority 4, x), silence (priority 3, zzz), test.
#
# Settings come only from ${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/notify.env:
# KEY=value lines NTFY_URL, NTFY_TOPIC, NTFY_TOKEN (and NTFY_USER /
# NTFY_PASSWORD for `info`, NTFY_REPLY_TOPIC / NTFY_REPLY_TOKEN for answer
# buttons). The file is parsed, never executed. Without it
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
# Action buttons (ntfy `Actions` header, a JSON array built with jq or
# python3, in the header file; at most 3; none -> no header):
# - answer buttons (`http` actions) on a decision push that offers 1-3 fixed
#   options: a Claude Code AskUserQuestion with exactly one single-select
#   question (when menu-keys knows the key sequence), or `pr.sh note --option`
#   (send --pr/--repo/--option). Each POSTs `<nonce>:<n>` to
#   <NTFY_URL>/<NTFY_REPLY_TOPIC> with the reply token (never NTFY_TOKEN). The
#   nonce (32 hex) is recorded on the window: @opsx_notify_reply = "<nonce>
#   <epoch> <claude|pr> <pane>", @opsx_notify_reply_opts = the labels, one per
#   line, @opsx_notify_reply_q = the question (claude: its first 60
#   characters; pr: PR number, repo and the ask= value, one per line). A newer
#   answer push replaces it; any AskUserQuestion or permission prompt from the
#   pane (and its turn end) forgets a claude record first. An empty label
#   means no answer buttons. Without both reply keys: no answer buttons.
# - link buttons (`view` actions) after them on decision and finished pushes:
#   Open PR (window @opsx_change pr-<n> with @opsx_pr_repo), Open preview
#   (opsx-preview.sh url <change> within 2 s), Open page (a /fork page pane
#   whose page .meta has url=).
#
# listen (the tmux-opsx-notify-listen user unit): subscribes to the reply
# topic with the main token, and for a reply `<nonce>:<n>` whose nonce is
# live (recorded, at most 1 hour old, the window still shows the question:
# claude = on the pane's visible screen, pr = the ask= line in the PR state)
# forgets the nonce and delivers option n: pr -> the label typed as one line
# through opsx-window.sh type; claude -> the keys of `menu-keys <n>` through
# opsx-window.sh keys. Anything else is dropped; a well-formed reply with a
# dead nonce sends one "already answered or expired" push (once per nonce per
# hour, at most OPSX_NOTIFY_STALE_MAX=10 per hour in all). Reconnects with a
# 1..60 s backoff, `since=<last id>`. Exits 0 when notify.env has no reply
# keys (the unit restarts only on failure).
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
NTFY_REPLY_TOPIC="" NTFY_REPLY_TOKEN=""
# The ntfy Actions header (JSON array) of the next post; empty = none.
ACTIONS=""
REPLY_TTL=3600
LABEL_MAX=40

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$SELF"; }

# Read KEY=value lines from notify.env (never sourced). Returns 1 when the file
# is missing or the URL or topic is unusable.
load_config() {
  local line k v
  NTFY_URL="" NTFY_TOPIC="" NTFY_TOKEN="" NTFY_USER="" NTFY_PASSWORD=""
  NTFY_REPLY_TOPIC="" NTFY_REPLY_TOKEN=""
  [ -f "$NOTIFY_ENV" ] && [ -r "$NOTIFY_ENV" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ $line =~ ^(NTFY_URL|NTFY_TOPIC|NTFY_TOKEN|NTFY_USER|NTFY_PASSWORD|NTFY_REPLY_TOPIC|NTFY_REPLY_TOKEN)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    if [[ $v =~ ^\"(.*)\"$ ]] || [[ $v =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
    printf -v "$k" '%s' "$v"
  done < "$NOTIFY_ENV"
  NTFY_URL=${NTFY_URL%/}
  [[ $NTFY_URL =~ ^https?://[^[:space:]/\"]+(/[^[:space:]\"]*)?$ ]] || return 1
  [[ $NTFY_TOPIC =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 1
  if [ -n "$NTFY_TOKEN" ] && ! [[ $NTFY_TOKEN =~ ^[A-Za-z0-9_.-]+$ ]]; then return 1; fi
  # Unusable reply keys only turn the answer buttons off.
  [[ $NTFY_REPLY_TOPIC =~ ^[A-Za-z0-9_-]{1,64}$ ]] || NTFY_REPLY_TOPIC=""
  [[ $NTFY_REPLY_TOKEN =~ ^[A-Za-z0-9_.-]+$ ]] || NTFY_REPLY_TOKEN=""
  return 0
}

# Answer buttons need both reply keys.
reply_ready() { [ -n "$NTFY_REPLY_TOPIC" ] && [ -n "$NTFY_REPLY_TOKEN" ]; }

now() { printf '%s' "${EPOCHSECONDS:-$(date +%s)}"; }

# Header lines for curl -H @file. The token stays off the command line.
headers() {
  local title=$1 tags=$2 prio=$3
  printf 'Title: %s\n' "$title"
  printf 'Tags: %s\n' "$tags"
  printf 'Priority: %s\n' "$prio"
  [ -z "$ACTIONS" ] || printf 'Actions: %s\n' "$ACTIONS"
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
    info)     PRIO=3; TAGS=information_source ;;
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

# question_options <json>: the option labels, one per line, only when the
# AskUserQuestion has exactly one question, not multi-select, with 1-3
# options; nothing otherwise.
question_options() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r '(.tool_input.questions // []) as $q
      | if ($q | type) == "array" and ($q | length) == 1 and (($q[0].multiSelect // false) != true)
           and (($q[0].options // []) | length) >= 1 and (($q[0].options // []) | length) <= 3
        then $q[0].options[] | (if type == "object" then (.label // "") else tostring end) | gsub("[\r\n\t]"; " ")
        else empty end' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -I -c 'import json,sys
try:
    q=json.load(sys.stdin).get("tool_input",{}).get("questions") or []
    o=q[0].get("options") or [] if isinstance(q,list) and len(q)==1 else []
    if len(q)==1 and q[0].get("multiSelect") is not True and 1<=len(o)<=3:
        for x in o:
            l=x.get("label","") if isinstance(x,dict) else str(x)
            print(" ".join(str(l).replace("\t"," ").splitlines()))
except Exception:
    pass' 2>/dev/null
  fi
}

# question_first <json>: the first question's text, one line, 60 characters.
question_first() {
  local t
  t=$(json_get "$(printf '%s' "$1" | { if command -v jq >/dev/null 2>&1; then jq -c '{q: ((.tool_input.questions // [])[0].question // "")}'; else python3 -I -c 'import json,sys
try:
    print(json.dumps({"q":(json.load(sys.stdin).get("tool_input",{}).get("questions") or [{}])[0].get("question","")}))
except Exception:
    print("{}")'; fi; } 2>/dev/null)" q)
  t=$(printf '%s' "$t" | head -n1 | tr -d '\r')
  printf '%s' "${t:0:60}"
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

# ---------- action buttons ----------

# clean_label <text>: one line, no tabs, trimmed.
clean_label() {
  local l
  l=$(printf '%s' "$1" | tr '\r\n\t' '   ')
  l=${l#"${l%%[![:space:]]*}"}; l=${l%"${l##*[![:space:]]}"}
  printf '%s' "$l"
}

# actions_json <nonce> <spec>...: the Actions JSON array (one line) for specs
# "a<TAB><label>" (answer n = its position) and "v<TAB><label><TAB><url>",
# at most 3, labels cut to $LABEL_MAX characters. Prints nothing without
# jq/python3 or without specs.
actions_json() {
  local nonce=$1 url="" auth=""
  shift
  [ $# -gt 0 ] || return 0
  if reply_ready; then url=$NTFY_URL/$NTFY_REPLY_TOPIC; auth="Bearer $NTFY_REPLY_TOKEN"; fi
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg url "$url" --arg auth "$auth" --arg nonce "$nonce" --argjson max "$LABEL_MAX" '
      [$ARGS.positional | to_entries[] | (.value | split("\t")) as $f
        | if $f[0] == "a" then
            {action: "http", label: ($f[1][0:$max]), url: $url, method: "POST",
             headers: {Authorization: $auth}, body: ($nonce + ":" + ((.key + 1) | tostring)), clear: true}
          else {action: "view", label: ($f[1][0:$max]), url: $f[2], clear: false} end][0:3]' \
      --args "$@" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import json,sys
url,auth,nonce,mx=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4])
out=[]
for i,s in enumerate(sys.argv[5:]):
    f=s.split("\t")
    if f[0]=="a":
        out.append({"action":"http","label":f[1][:mx],"url":url,"method":"POST",
                    "headers":{"Authorization":auth},"body":"%s:%d"%(nonce,i+1),"clear":True})
    else:
        out.append({"action":"view","label":f[1][:mx],"url":f[2],"clear":False})
print(json.dumps(out[:3],separators=(",",":"),ensure_ascii=False))' "$url" "$auth" "$nonce" "$LABEL_MAX" "$@" 2>/dev/null
  fi
}

new_nonce() { od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; }

# menu_keys <n>: tmux key names that pick option n in Claude Code's
# AskUserQuestion menu. Checked against Claude Code 2.1.310 (tmux 3.4): the
# digit alone selects and submits option n (digit + Enter leaks the Enter
# into whatever comes next; Down x (n-1) + Enter depends on the highlight).
# Print nothing here if a Claude Code release breaks it: Claude questions
# then get no answer buttons.
menu_keys() {
  case "${1:-}" in
    1|2|3) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

# agent_pane <window>: the first pane of the window that is not a /fork pane.
agent_pane() {
  tmux list-panes -t "$1" -F '#{pane_index}	#{pane_id}	#{@fork_dir}' 2>/dev/null \
    | sort -n | awk -F '\t' '$3 == "" { print $2; exit }'
}

# record_reply <window> <kind> <pane> <question-record> <label>...: mint a
# nonce and record it on the window (replacing an older one). Prints the nonce.
record_reply() {
  local win=$1 kind=$2 pane=$3 q=$4 nonce opts
  shift 4
  nonce=$(new_nonce)
  [[ $nonce =~ ^[0-9a-f]{32}$ ]] || return 1
  # Button n types line n: an empty label would shift the lines, so no buttons.
  for opts in "$@"; do [ -n "$opts" ] || return 1; done
  opts=$(printf '%s\n' "$@")
  tmux set-option -w -t "$win" @opsx_notify_reply_opts "$opts" >/dev/null 2>&1 || return 1
  tmux set-option -w -t "$win" @opsx_notify_reply_q "$q" >/dev/null 2>&1 || return 1
  tmux set-option -w -t "$win" @opsx_notify_reply "$nonce $(now) $kind $pane" >/dev/null 2>&1 || return 1
  printf '%s' "$nonce"
}

forget_reply() {
  tmux set-option -wu -t "$1" @opsx_notify_reply >/dev/null 2>&1
  tmux set-option -wu -t "$1" @opsx_notify_reply_opts >/dev/null 2>&1
  tmux set-option -wu -t "$1" @opsx_notify_reply_q >/dev/null 2>&1
  return 0
}

# forget_pane_reply <window> <pane>: drop a claude record asked from <pane>.
forget_pane_reply() {
  local rec
  rec=$(tmux show-options -wqv -t "$1" @opsx_notify_reply 2>/dev/null)
  [ -n "$rec" ] || return 0
  local kind pane
  read -r _ _ kind pane <<<"$rec"
  [ "${kind:-}" = claude ] && [ "${pane:-}" = "$2" ] && forget_reply "$1"
  return 0
}

# push_links <window> [<pane>]: "v<TAB>label<TAB>url" lines for the links that
# exist: Open PR, Open preview, Open page.
push_links() {
  local win=$1 pane=${2:-} out change repo cwd url p d fd pd
  [ -n "$win" ] || return 0
  out=$(tmux display-message -p -t "$win" '#{@opsx_change}	#{@opsx_pr_repo}	#{pane_current_path}' 2>/dev/null) || return 0
  IFS=$'\t' read -r change repo cwd <<<"$out"
  if [[ $change =~ ^pr-[0-9]+$ ]] && [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf 'v\tOpen PR\thttps://github.com/%s/pull/%s\n' "$repo" "${change#pr-}"
  elif [[ $change =~ ^[A-Za-z0-9._-]+$ ]] && [ -f "$HERE/opsx-preview.sh" ] && [ -d "$cwd" ]; then
    url=$(cd -- "$cwd" 2>/dev/null && OPSX_EXPOSE_NO_COPY=1 timeout 2 bash "$HERE/opsx-preview.sh" url "$change" </dev/null 2>/dev/null \
          | awk 'NF { l = $0 } END { print l }')
    [[ $url =~ ^https?://[^[:space:]]+$ ]] && printf 'v\tOpen preview\t%s\n' "$url"
  fi
  # A /fork page pane: the pushing pane first, then the window's panes.
  for p in $pane $(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null); do
    fd=$(tmux show-options -pqv -t "$p" @fork_dir 2>/dev/null)
    { [ -n "$fd" ] && [ -f "$fd/meta" ]; } || continue
    pd=$(awk 'index($0, "page_dir=") == 1 { v = substr($0, 10) } END { printf "%s", v }' "$fd/meta")
    { [ -n "$pd" ] && [ -f "$pd/.meta" ]; } || continue
    d=$(awk 'index($0, "url=") == 1 { v = substr($0, 5) } END { printf "%s", v }' "$pd/.meta")
    if [[ $d =~ ^https?://[^[:space:]]+$ ]]; then printf 'v\tOpen page\t%s\n' "$d"; break; fi
  done
  return 0
}

# set_actions <nonce> <answer-label>... -- <window> [<pane>]: ACTIONS for the
# next push: the answer buttons, then links, at most 3.
set_actions() {
  local nonce=$1 specs=() l win pane line
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do specs+=("a	$(clean_label "$1")"); shift; done
  [ "${1:-}" != -- ] || shift
  win=${1:-} pane=${2:-}
  if [ "${#specs[@]}" -lt 3 ] && [ -n "$win" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && specs+=("$line")
    done < <(push_links "$win" "$pane")
  fi
  ACTIONS=""
  [ "${#specs[@]}" -gt 0 ] || return 0
  l=$(actions_json "$nonce" "${specs[@]}")
  [[ $l == \[*\] ]] && [ "$l" != "[]" ] && ACTIONS=$l
  return 0
}

# ---------- commands ----------

notify_send() {
  local win="" status="done" kind label title body="" pr="" repo="" opts=() pane="" nonce="" q
  while [ $# -gt 0 ]; do
    case "$1" in
      --window) win=${2:-}; shift 2 || shift ;;
      --status) status=${2:-done}; shift 2 || shift ;;
      --pr)     pr=${2:-}; shift 2 || shift ;;
      --repo)   repo=${2:-}; shift 2 || shift ;;
      --option) opts+=("${2:-}"); shift 2 || shift ;;
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
    if [ "$kind" = decision ] && [ "${#opts[@]}" -ge 1 ] && [ "${#opts[@]}" -le 3 ] && reply_ready \
       && [[ $pr =~ ^[0-9]+$ ]] && [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [ -n "$body" ]; then
      pane=$(agent_pane "$win")
      local i labels=()
      for i in "${opts[@]}"; do labels+=("$(clean_label "$i")"); done
      # The ask= line as pr.sh writes it: newlines folded to spaces.
      q=$(printf '%s\n%s\n%s' "$pr" "$repo" "$(printf '%s' "$body" | tr '\n' ' ')")
      [ -z "$pane" ] || nonce=$(record_reply "$win" pr "$pane" "$q" "${labels[@]}") || nonce=""
      [ -n "$nonce" ] || labels=()
    fi
    if [ "$kind" = decision ] || [ "$kind" = finished ]; then
      set_actions "$nonce" "${labels[@]+"${labels[@]}"}" -- "$win"
    fi
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
  set_actions "" -- "$win"
  do_send finished "$status" "$label: $status" "$label was marked $status."
  exit 0
}

# ask-later <win> <label> [--pane <pane>]: the bare "needs a decision" push,
# unless a decision push with text was sent for the window within the collapse
# window. With --pane (a /fork pane or a task session, whose window may carry
# no tag) the pane must still be an opsx pane instead of the window being tagged.
notify_ask_later() {
  local win=${1:-} label=${2:-} pane="" last delay span
  [ "${3:-}" = --pane ] && pane=${4:-}
  [ -n "$win" ] || exit 0
  delay=$(int_or "${OPSX_NOTIFY_ASK_DELAY:-}" 5)
  span=$(int_or "${OPSX_NOTIFY_DECISION_WINDOW:-}" 30)
  sleep "$delay"
  load_config || exit 0
  if [ -n "$pane" ]; then
    pane_scope "$pane" || exit 0
    win=$P_WIN
  else
    window_ok "$win" || exit 0
  fi
  last=$(tmux show-options -wqv -t "$win" @opsx_notify_last_decision 2>/dev/null)
  last=$(int_or "$last" 0)
  [ $(( $(now) - last )) -ge "$span" ] || exit 0
  [ -n "$label" ] || label=$(win_label "$win")
  set_actions "" -- "$win" "$pane"
  do_send decision "" "$label: needs a decision" "$label is waiting for your answer."
  exit 0
}

# pane-ask [pane]: `mark . ask` from a fork pane or a task session.
notify_pane_ask() {
  local pane=${1:-}
  load_config || exit 0
  if [ -z "$pane" ]; then resolve_pane || exit 0; pane=$TMUX_PANE; fi
  pane_scope "$pane" || exit 0
  detach ask-later "$P_WIN" "$P_LABEL" --pane "$pane"
  exit 0
}

hook_input() { if [ -t 0 ]; then printf ''; else head -c 4194304; fi; }

hook_claude_stop() {
  local input stamp status msg tp
  input=$(hook_input)
  load_config || return 0
  resolve_pane || return 0
  pane_scope "$TMUX_PANE" || return 0
  # The turn ended, so a question this pane asked is no longer open.
  forget_pane_reply "$P_WIN" "$TMUX_PANE"
  # A fork pane's turn end is not the change window's turn end.
  [ "$P_FORK" -eq 0 ] || return 0
  stamp=$(claim "$P_WIN" "") || return 0
  status=${stamp%%:*}
  msg=$(json_get "$input" last_assistant_message)
  if [ -z "$msg" ]; then
    tp=$(json_get "$input" transcript_path)
    [ -z "$tp" ] || msg=$(last_transcript_text "$tp")
  fi
  set_actions "" -- "$P_WIN" "$TMUX_PANE"
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
  # A new question replaces whatever menu this pane showed: an older answer
  # nonce must not reach it, even when this question gets no buttons.
  forget_pane_reply "$P_WIN" "$TMUX_PANE"
  local labels=() l nonce="" first
  if reply_ready && [ -n "$(menu_keys 1)" ]; then
    while IFS= read -r l; do labels+=("$(clean_label "$l")"); done < <(question_options "$input")
    first=$(question_first "$input")
    if [ "${#labels[@]}" -ge 1 ] && [ "${#labels[@]}" -le 3 ] && [ -n "$first" ]; then
      nonce=$(record_reply "$P_WIN" claude "$TMUX_PANE" "$first" "${labels[@]}") || nonce=""
    fi
    [ -n "$nonce" ] || labels=()
  fi
  set_actions "$nonce" "${labels[@]+"${labels[@]}"}" -- "$P_WIN" "$TMUX_PANE"
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
  # The pane now shows a permission prompt, not the question a nonce answers.
  forget_pane_reply "$P_WIN" "$TMUX_PANE"
  record_decision "$P_WIN"
  set_actions "" -- "$P_WIN" "$TMUX_PANE"
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

# ---------- listen (reply topic -> asking pane) ----------

# win_lock <window>: the per-window lock dir of claim(); sets WIN_LOCK.
win_lock() {
  local win=$1 root srv i=0
  WIN_LOCK=""
  root=$(lock_root)
  (umask 077; mkdir -p "$root") 2>/dev/null || return 1
  srv=$(tmux display-message -p -t "$win" '#{pid}' 2>/dev/null) || return 1
  WIN_LOCK=$root/$srv-${win#@}.lock
  while ! mkdir "$WIN_LOCK" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 50 ]; then
      if [ -n "$(find "$WIN_LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rmdir "$WIN_LOCK" 2>/dev/null; i=0; continue
      fi
      WIN_LOCK=""; return 1
    fi
    sleep 0.1
  done
}
win_unlock() { [ -z "${WIN_LOCK:-}" ] || rmdir "$WIN_LOCK" 2>/dev/null; WIN_LOCK=""; }

# pr_state_file <n> <owner/name>: pr.sh's state file of that PR.
pr_state_file() {
  printf '%s/tmux-opsx/pr/%s-%s/state' "${XDG_STATE_HOME:-$HOME/.local/state}" "$(printf '%s' "$2" | tr '/' '-')" "$1"
}

# still_asking <kind> <pane> <question-record>: the window still shows it.
still_asking() {
  local kind=$1 pane=$2 q=$3 pr repo ask f
  case "$kind" in
    claude)
      [ -n "$q" ] || return 1
      # The visible screen only: an open menu is on screen, while scrollback
      # still holds questions that were answered.
      tmux capture-pane -p -J -t "$pane" 2>/dev/null | grep -qF -- "$q" ;;
    pr)
      pr=$(printf '%s\n' "$q" | sed -n 1p); repo=$(printf '%s\n' "$q" | sed -n 2p)
      ask=$(printf '%s\n' "$q" | sed -n '3,$p')
      [[ $pr =~ ^[0-9]+$ ]] && [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
      f=$(pr_state_file "$pr" "$repo")
      [ -f "$f" ] && grep -qxF -- "ask=$ask" "$f" ;;
    *) return 1 ;;
  esac
}

declare -A STALE_SENT=()

# stale_push <nonce>: one "already answered or expired" push per nonce per
# hour, and at most $OPSX_NOTIFY_STALE_MAX (default 10) of them per hour in
# total: a forger with the reply token picks a fresh nonce for every reply.
# Entries older than an hour are pruned, so the table holds at most the cap.
stale_push() {
  local t k max
  t=$(now)
  max=$(int_or "${OPSX_NOTIFY_STALE_MAX:-}" 10)
  for k in "${!STALE_SENT[@]}"; do
    [ $(( t - STALE_SENT[$k] )) -lt "$REPLY_TTL" ] || unset 'STALE_SENT[$k]'
  done
  [ -z "${STALE_SENT[$1]:-}" ] || return 0
  [ "${#STALE_SENT[@]}" -lt "$max" ] || return 0
  STALE_SENT[$1]=$t
  ACTIONS=""
  do_send info "" "already answered or expired" \
    "That answer button belongs to a question that was already answered, replaced or has expired. Nothing was typed."
}

# handle_reply <body>: deliver a live reply, drop anything else.
handle_reply() {
  local body=$1 nonce n win rec rn epoch kind pane opts count label tmp q
  [[ $body =~ ^([0-9a-f]{32}):([1-3])$ ]] || return 0
  nonce=${BASH_REMATCH[1]} n=${BASH_REMATCH[2]}
  win=$(tmux list-windows -a -F '#{window_id} #{@opsx_notify_reply}' 2>/dev/null \
        | awk -v k="$nonce" '$2 == k { print $1; exit }')
  if [ -z "$win" ]; then stale_push "$nonce"; return 0; fi
  win_lock "$win" || return 0
  rec=$(tmux show-options -wqv -t "$win" @opsx_notify_reply 2>/dev/null)
  read -r rn epoch kind pane <<<"$rec"
  if [ "${rn:-}" != "$nonce" ]; then win_unlock; stale_push "$nonce"; return 0; fi
  opts=$(tmux show-options -wqv -t "$win" @opsx_notify_reply_opts 2>/dev/null)
  count=$(printf '%s\n' "$opts" | awk 'END { print NR }')
  # An option that was never offered: drop it, the question stays open.
  if [ "$n" -gt "$count" ]; then win_unlock; return 0; fi
  q=$(tmux show-options -wqv -t "$win" @opsx_notify_reply_q 2>/dev/null)
  epoch=$(int_or "${epoch:-}" 0)
  if [ $(( $(now) - epoch )) -gt "$REPLY_TTL" ] || ! still_asking "${kind:-}" "${pane:-}" "$q"; then
    forget_reply "$win"; win_unlock; stale_push "$nonce"; return 0
  fi
  forget_reply "$win"
  win_unlock
  case "$kind" in
    pr)
      label=$(printf '%s\n' "$opts" | sed -n "${n}p")
      [ -n "$label" ] || return 0
      tmp=$( umask 077; mktemp "${TMPDIR:-/tmp}/opsx-reply.XXXXXX" ) || return 0
      printf '%s\n' "$label" > "$tmp"
      bash "$HERE/opsx-window.sh" type "$pane" --text-file "$tmp" </dev/null >/dev/null 2>&1
      rm -f "$tmp" ;;
    claude)
      local keys=()
      read -r -a keys <<<"$(menu_keys "$n" | tr '\n' ' ')"
      [ "${#keys[@]}" -gt 0 ] || return 0
      bash "$HERE/opsx-window.sh" keys "$pane" "${keys[@]}" </dev/null >/dev/null 2>&1 ;;
  esac
  return 0
}

# stream_fields: one ntfy JSON event per line in, "<event>\t<id>\t<time>\t<message>" out.
stream_fields() {
  if command -v jq >/dev/null 2>&1; then
    jq --unbuffered -Rr 'fromjson? | select(type == "object")
      | [(.event // ""), (.id // ""), ((.time // 0) | tostring), ((.message // "") | gsub("[\t\r\n]"; " "))] | join("\t")' 2>/dev/null
  else
    python3 -I -u -c 'import json,sys
for line in sys.stdin:
    try:
        e=json.loads(line)
    except Exception:
        continue
    if not isinstance(e,dict):
        continue
    m=str(e.get("message","")).replace("\t"," ").replace("\r"," ").replace("\n"," ")
    print("\t".join([str(e.get("event","")),str(e.get("id","")),str(e.get("time",0)),m]),flush=True)' 2>/dev/null
  fi
}

notify_listen() {
  local hdr since="" url delay base maxd ev id t msg got
  if ! load_config; then
    printf 'opsx-notify listen: notify is not configured (%s); nothing to listen to\n' "$NOTIFY_ENV" >&2
    exit 0
  fi
  if ! reply_ready; then
    printf 'opsx-notify listen: %s has no NTFY_REPLY_TOPIC / NTFY_REPLY_TOKEN; answer buttons are off\n' "$NOTIFY_ENV" >&2
    exit 0
  fi
  if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    printf 'opsx-notify listen: jq or python3 is needed\n' >&2; exit 0
  fi
  base=$(int_or "${OPSX_NOTIFY_LISTEN_BACKOFF:-}" 1); [ "$base" -ge 1 ] || base=1
  maxd=$(int_or "${OPSX_NOTIFY_LISTEN_BACKOFF_MAX:-}" 60); [ "$maxd" -ge "$base" ] || maxd=$base
  hdr=$( umask 077; mktemp "${TMPDIR:-/tmp}/opsx-listen.XXXXXX" ) || exit 1
  trap 'rm -f "$hdr"' EXIT
  trap 'exit 0' INT TERM
  [ -z "$NTFY_TOKEN" ] || printf 'Authorization: Bearer %s\n' "$NTFY_TOKEN" > "$hdr"
  delay=$base
  while :; do
    url="$NTFY_URL/$NTFY_REPLY_TOPIC/json"
    [ -z "$since" ] || url="$url?since=$since"
    got=0
    while IFS=$'\t' read -r ev id t msg; do
      # Before any message: resume from the time the first connection opened,
      # so a reconnect never replays replies from before the listener started.
      if [ "$ev" = open ] && [ -z "$since" ] && [[ $t =~ ^[0-9]+$ ]] && [ "$t" -gt 0 ]; then since=$t; fi
      [ "$ev" = message ] || continue
      [[ $id =~ ^[A-Za-z0-9]+$ ]] && since=$id
      got=1; delay=$base
      handle_reply "$msg"
    done < <(curl -sN --max-time 0 -H @"$hdr" "$url" 2>/dev/null | stream_fields)
    [ "$got" -eq 0 ] || delay=$base
    sleep "$delay"
    delay=$(( delay * 2 )); [ "$delay" -le "$maxd" ] || delay=$maxd
  done
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
  if [ -n "$NTFY_REPLY_TOPIC" ]; then
    printf 'replies:  %s (answer buttons%s)\n' "$NTFY_REPLY_TOPIC" "$([ -n "$NTFY_REPLY_TOKEN" ] || printf ', off: no reply token')"
  fi
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
  listen)    shift; notify_listen "$@" ;;
  menu-keys) shift
             if [[ ${1:-} =~ ^[1-3]$ ]]; then menu_keys "$1"; exit 0; fi
             printf 'usage: opsx-notify.sh menu-keys <1-3>\n' >&2; exit 2 ;;
  test)      shift; notify_test "$@" ;;
  info)      shift; notify_info "$@" ;;
  ""|-h|--help|help) usage ;;
  *) printf 'opsx-notify: unknown command %s\n' "$1" >&2; usage >&2; exit 0 ;;
esac
