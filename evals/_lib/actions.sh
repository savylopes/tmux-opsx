# Shared helpers for notify-actions checks (sourced, not a check). Builds on
# notify.sh: scratch HOME, recording fake curl, private tmux server. Adds a
# multi-user fake ntfy, a fake systemctl that succeeds, a fake `curl` that also
# serves the reply-topic subscription, and pane/window helpers. Offline only.
. "$EVAL_ROOT/evals/_lib/notify.sh"
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 77; }

REPLY_TOPIC_DEFAULT=opsx-0123456789ab-reply
write_notify_env_reply() {   # reply keys included
  write_notify_env
  printf 'NTFY_REPLY_TOPIC=%s\nNTFY_REPLY_TOKEN=tk_replytoken456\n' "$REPLY_TOPIC_DEFAULT" >> "$NOTIFY_ENV"
}


# systemctl that logs and succeeds (notify.sh's shim fails everything)
cat > "$SHIMS/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$SHIM_LOG"; exit 0
SH
chmod +x "$SHIMS/systemctl"
LISTEN_UNIT="$XDG_CONFIG_HOME/systemd/user/tmux-opsx-notify-listen.service"

# ---- curl: POSTs are recorded like notify.sh's shim; a GET of .../json is a
# subscription served from a tiny ntfy model.
#   $EVAL_TMP/stream/history   lines "<id> <epoch> <message>": published before the listener starts
#   $EVAL_TMP/stream/live.<k>  lines "<id> <message>": published while connection k is open
# History is replayed only when the URL has since= (all | <id> | <epoch> | <N>s/m/h).
SUB_DIR="$EVAL_TMP/subs"; STREAM="$EVAL_TMP/stream"; mkdir -p "$SUB_DIR" "$STREAM"; export SUB_DIR STREAM
cat > "$SHIMS/curl" <<'SH'
#!/usr/bin/env bash
sub=0; for x in "$@"; do case $x in */json|*/json\?*) sub=1;; esac; done
if [ "$sub" = 1 ]; then
  k=$(( $(find "$SUB_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) + 1 ))
  d=$SUB_DIR/c$k; mkdir -p "$d"; printf '%s\n' "$*" > "$d/args"
  for x in "$@"; do case $x in @*) cat "${x#@}" >> "$d/headers" 2>/dev/null;; esac; done
  since=$(printf '%s' "$*" | sed -n 's/.*[?&]since=\([^& "]*\).*/\1/p')
  now=$(date +%s)
  printf '{"id":"op%s","time":%s,"event":"open","topic":"t"}\n' "$k" "$now"
  if [ -n "$since" ] && [ -f "$STREAM/history" ]; then
    seen=0
    while read -r id t msg; do
      [ -n "$id" ] || continue
      case $since in
        all) ok=1;;
        *[!0-9]*) case $since in *[smh]) n=${since%[smh]}; case $since in *m) n=$((n*60));; *h) n=$((n*3600));; esac; [ "$t" -gt $((now-n)) ] && ok=1 || ok=0;;
                  *) [ "$seen" = 1 ] && ok=1 || ok=0; [ "$id" = "$since" ] && seen=1;; esac;;
        *) [ "$t" -gt "$since" ] && ok=1 || ok=0;;
      esac
      [ "${ok:-0}" = 1 ] && printf '{"id":"%s","time":%s,"event":"message","topic":"t","message":"%s"}\n' "$id" "$t" "$msg"
    done < "$STREAM/history"
  fi
  if [ -f "$STREAM/live.$k" ]; then
    sleep 0.3
    while read -r id msg; do
      [ -n "$id" ] && printf '{"id":"%s","time":%s,"event":"message","topic":"t","message":"%s"}\n' "$id" "$(date +%s)" "$msg"
    done < "$STREAM/live.$k"
  fi
  sleep 0.5; exit 18
fi
d=$(mktemp -d "$CURL_DIR/call.XXXXXX") || exit 99
printf '%s\n' "$*" > "$d/args"; : > "$d/headers"; : > "$d/body"
while [ $# -gt 0 ]; do
  case $1 in
    -H) case $2 in @*) cat "${2#@}" >> "$d/headers" 2>/dev/null;; *) printf '%s\n' "$2" >> "$d/headers";; esac; shift 2;;
    --data-binary|-d|--data) case $2 in @-) cat > "$d/body";; @*) cat "${2#@}" > "$d/body";; *) printf '%s' "$2" > "$d/body";; esac; shift 2;;
    -o|-w|--max-time|-m) shift 2;;
    *) shift;;
  esac
done
rc=${FAKE_CURL_RC:-0}
[ "$rc" -eq 0 ] && printf '200'
exit "$rc"
SH
chmod +x "$SHIMS/curl"
export SUB_DIR STREAM

# gh for pr.sh note
cat > "$SHIMS/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in "repo view") echo "acme/api";; *) exit 1;; esac
SH
chmod +x "$SHIMS/gh"

need_json() { command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "neither jq nor python3"; exit 77; }; }

# ---- Actions header helpers --------------------------------------------------
# actions_tsv [call-dir...]: one TSV line per action of the Actions header(s):
#   action<TAB>label<TAB>url<TAB>body<TAB>headers-json   (empty output: no actions)
actions_tsv() {
  python3 -I - "$@" <<'PY'
import json,sys,glob,os
files = sys.argv[1:] or sorted(glob.glob(os.environ["CURL_DIR"]+"/call.*/headers"))
for f in files:
    for line in open(f, errors="replace"):
        if line.lower().startswith("actions:"):
            raw=line.split(":",1)[1].strip()
            try: acts=json.loads(raw)
            except Exception as e:
                print("BADJSON\t%s" % raw); continue
            for a in acts:
                print("\t".join([str(a.get("action","")), str(a.get("label","")), str(a.get("url","")),
                                 str(a.get("body","")), json.dumps(a.get("headers",{}))]))
PY
}
has_actions_header() { curl_all_headers | grep -qi '^Actions:'; }
action_count() { actions_tsv | grep -c .; }
last_nonce() { actions_tsv | awk -F'\t' '$1=="http"{print $4; exit}' | cut -d: -f1; }

# ---- panes -------------------------------------------------------------------
# typed_win <name> <kind> : a window whose pane logs what it receives.
#   kind line  -> canonical tty, typed lines land in $EVAL_TMP/typed.<name>
#   kind raw   -> raw tty, bytes land in $EVAL_TMP/typed.<name>; the pane first shows $3
# Tags: change (always). Prints "<window-id> <pane-id>".
typed_win() {
  local name=$1 kind=$2 show=${3:-} f="$EVAL_TMP/typed.$1" w p
  : > "$f"
  if [ "$kind" = raw ]; then
    w=$(TM new-window -d -t s -n "$name" -P -F '#{window_id}' "stty raw -echo; printf '%s\\n' '$show'; exec cat > '$f'" ) || fail "new-window"
  else
    w=$(TM new-window -d -t s -n "$name" -P -F '#{window_id}' "stty -echo; exec cat > '$f'") || fail "new-window"
  fi
  p=$(TM display -p -t "$w" '#{pane_id}')
  TM set-option -w -t "$w" @opsx_change "$name"
  echo "$w $p"
}
typed() { cat "$EVAL_TMP/typed.$1" 2>/dev/null; }
# wait_pane_text <pane> <text> [secs]
wait_pane_text() { local i; for i in $(seq $(( ${3:-5} * 10 ))); do TM capture-pane -p -t "$1" | grep -qF "$2" && return 0; sleep 0.1; done; return 1; }

# fake pr state so `pr.sh note` finds its PR (repo o/r from the gh shim)
pr_state_dir() { echo "$XDG_STATE_HOME/tmux-opsx/pr/acme-api-$1"; }
pr_setup() { local sd; sd=$(pr_state_dir "$1"); mkdir -p "$sd"; printf 'pr=%s\n' "$1" > "$sd/state"; repo="$EVAL_TMP/r"; [ -d "$repo/.git" ] || git init -q "$repo" || fail "git init"; }
pr_note() { # <pane> <args...>
  local p=$1; shift; ( cd "$repo" && TMUX_PANE=$p bash "$PRSH" note "$@" 2>&1 ); }

# ---- listener ----------------------------------------------------------------
# start_listener <secs>: run `listen` for at most <secs>; sets LISTEN_PID.
start_listener() {
  ( exec timeout "$1" bash "$NOTIFY_SH" listen ) >"$EVAL_TMP/listen.out" 2>&1 &
  LISTEN_PID=$!
}
stop_listener() { kill "$LISTEN_PID" 2>/dev/null; wait "$LISTEN_PID" 2>/dev/null; }
listener_alive() { kill -0 "$LISTEN_PID" 2>/dev/null; }
# stream_live <k> <message>...: messages that arrive while connection k is open
stream_live() { local k=$1; shift; local i=0 m; for m in "$@"; do i=$((i+1)); echo "m$k$i $m" >> "$STREAM/live.$k"; done; }
# key bytes of a tmux key name sequence (digits, Enter, Down, Up, Space, Tab, Escape)
key_bytes() { local k; for k in "$@"; do case $k in Enter) printf '\r';; Down) printf '\033[B';; Up) printf '\033[A';; Space) printf ' ';; Tab) printf '\t';; Escape) printf '\033';; [0-9A-Za-z]) printf '%s' "$k";; *) printf '<%s?>' "$k";; esac; done; }
