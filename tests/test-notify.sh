#!/usr/bin/env bash
# Scripted tests for skills/opsx-run/opsx-notify.sh, the notify wiring of
# opsx-window.sh mark, and `opsx notify`.
#
# Offline: a fake `curl` on PATH logs argv, headers and stdin per call into a
# scratch dir (nothing is ever sent), notify.env lives in a scratch
# XDG_CONFIG_HOME, and every tmux call goes to a private server
# (tmux -L notify-test-$$). Your real config, tmux session and phone are never
# touched.
# Usage: bash tests/test-notify.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016
set -u
command -v tmux >/dev/null 2>&1 || { echo "tmux is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
N=$REPO/skills/opsx-run/opsx-notify.sh
W=$REPO/skills/opsx-run/opsx-window.sh
OPSX=$REPO/bin/opsx
SP=$(mktemp -d "${TMPDIR:-/tmp}/notify-test.XXXXXX")
SOCK=notify-test-$$
L="tmux -L $SOCK"
cleanup() {
  # Detached senders started by mark: stop them before the scratch dir goes.
  pkill -f "$N" 2>/dev/null
  [ -n "${APID:-}" ] && kill "$APID" 2>/dev/null
  $L kill-server 2>/dev/null
  [ -n "${KEEP_SP:-}" ] || rm -rf "$SP"
}
trap cleanup EXIT
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

export HOME=$SP/home XDG_CONFIG_HOME=$SP/home/.config XDG_STATE_HOME=$SP/home/.local/state
unset XDG_RUNTIME_DIR OPSX_NOTIFY_FLUSH_AFTER OPSX_NOTIFY_ASK_DELAY OPSX_NOTIFY_DECISION_WINDOW
mkdir -p "$HOME" "$XDG_CONFIG_HOME/tmux-opsx"
ENVF=$XDG_CONFIG_HOME/tmux-opsx/notify.env
CALLS=$SP/calls; mkdir -p "$CALLS"
export FAKE_CURL_DIR=$CALLS

# ---------------------------------------------------------------- fake curl
mkdir -p "$SP/bin"
cat > "$SP/bin/curl" <<'SH'
#!/usr/bin/env bash
# One file per call: ARGV line, HDR lines (from -H values and -H @files), BODY.
f=$FAKE_CURL_DIR/call-$(date +%s%N)-$$
{
  printf 'ARGV:'; printf ' %s' "$@"; printf '\n'
  prev=""; wfmt=0
  for a in "$@"; do
    if [ "$prev" = -H ]; then
      case $a in @*) sed 's/^/HDR: /' "${a#@}" ;; *) printf 'HDR: %s\n' "$a" ;; esac
    fi
    [ "$a" = -w ] && wfmt=1
    prev=$a
  done
  printf 'BODY:\n'; cat
} > "$f.tmp"
mv "$f.tmp" "$f.call"
rc=${FAKE_CURL_EXIT:-0}
if [ "$wfmt" = 1 ] 2>/dev/null || printf ' %s ' "$@" | grep -q ' -w '; then
  if [ "$rc" -eq 0 ]; then printf '%s' "${FAKE_CURL_CODE:-200}"; else printf '000'; fi
fi
[ "$rc" -eq 0 ] || echo "curl: ($rc) Failed to connect" >&2
exit "$rc"
SH
chmod +x "$SP/bin/curl"
export PATH="$SP/bin:$PATH"

ncalls() { find "$CALLS" -name '*.call' 2>/dev/null | wc -l | tr -d ' '; }
reset_calls() { rm -f "$CALLS"/*; }
last_call() { cat "$(find "$CALLS" -name '*.call' | sort | tail -n1)" 2>/dev/null; }
body_of() { last_call | sed -n '/^BODY:$/,$p' | sed '1d'; }
hdr() { last_call | sed -n "s/^HDR: $1: //p"; }
# wait_calls <n> <secs>: until at least n calls or the timeout.
wait_calls() { local i; for i in $(seq 1 $(( $2 * 10 ))); do [ "$(ncalls)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }

write_env() {
  ( umask 077
    printf '# test\nNTFY_URL=https://ntfy.dev.example.com\nNTFY_TOPIC=opsx-0123456789ab\nNTFY_TOKEN=tk_secrettoken123\nNTFY_USER=opsx\nNTFY_PASSWORD=pw-secret-456\n' > "$ENVF" )
}

# ---------------------------------------------------------------- 1.1 send
rm -f "$ENVF"; reset_calls
out=$(bash "$N" finished "t" "b" 2>&1); rc=$?
ok "not configured: exit 0, no curl call" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 0 ] && [ -z "$out" ]'
out=$(bash "$N" send decision lbl "title" "body" 2>&1); rc=$?
ok "not configured: send exits 0 silently" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 0 ] && [ -z "$out" ]'
printf 'NTFY_URL=https://ntfy.dev.example.com\nNTFY_TOKEN=tk_x\n' > "$ENVF"
bash "$N" finished "t" "b"; rc=$?
ok "incomplete (no topic): exit 0, no curl call" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 0 ]'
printf 'NTFY_URL=$(touch %s/pwned)\nNTFY_TOPIC=x\n' "$SP" > "$ENVF"
bash "$N" finished "t" "b"
ok "notify.env is parsed, never executed" '[ ! -e "$SP/pwned" ] && [ "$(ncalls)" -eq 0 ]'

write_env; reset_calls
out=$(bash "$N" send decision pr-7 "pr-7: needs a decision" "keep theirs?" 2>&1); rc=$?
ok "send: exit 0, one call" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 1 ]'
ok "send: POST to url/topic with -fsS --max-time 5 and the body on stdin" 'last_call | grep -q "^ARGV:.* -fsS --max-time 5 .*--data-binary @- https://ntfy.dev.example.com/opsx-0123456789ab$"'
ok "send: Bearer token, title, decision tags/priority headers" '[ "$(hdr Authorization)" = "Bearer tk_secrettoken123" ] && [ "$(hdr Title)" = "pr-7: needs a decision" ] && [ "$(hdr Tags)" = question ] && [ "$(hdr Priority)" = 4 ]'
ok "send: body as given" '[ "$(body_of)" = "keep theirs?" ]'
ok "send: token not on curl argv" '! last_call | grep "^ARGV:" | grep -q tk_secrettoken123'
ok "send: token absent from stdout and stderr" '! printf "%s" "$out" | grep -q tk_secrettoken123'

reset_calls
long=$(head -c 2000 /dev/zero | tr '\0' 'a')
bash "$N" finished "t" "$long"
ok "2000-character body: at most 500 characters, no Markdown header" '[ "$(ncalls)" -eq 1 ] && [ "$(body_of | tr -d "\n" | wc -c)" -le 500 ] && ! last_call | grep -qi "^HDR: Markdown" && ! last_call | grep -qi "^HDR: X-Markdown"'
reset_calls
bash "$N" send finished x $'line one\nline two\r' "b"
ok "title loses its newlines" '[ "$(hdr Title)" = "line oneline two" ]'
reset_calls
bash "$N" send --status fail finished x "x: fail" "b"
ok "finished fail: priority 4, tag x" '[ "$(hdr Tags)" = x ] && [ "$(hdr Priority)" = 4 ]'
reset_calls
bash "$N" send finished x "x: done" "b"
ok "finished done: priority 3, tag white_check_mark" '[ "$(hdr Tags)" = white_check_mark ] && [ "$(hdr Priority)" = 3 ]'

reset_calls
out=$(FAKE_CURL_EXIT=7 bash "$N" finished "t" "b" 2>&1); rc=$?
ok "server down (curl exit 7): exit 0, quiet" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 1 ] && [ -z "$out" ]'
reset_calls
out=$(FAKE_CURL_EXIT=22 bash "$N" send decision l "t" "b" 2>&1); rc=$?
ok "server rejects (curl exit 22): exit 0" '[ $rc -eq 0 ] && ! printf "%s" "$out" | grep -q tk_'

# ---------------------------------------------------------------- 1.3 opsx notify
export OPSX_SKILLS_DIR=$REPO/skills
reset_calls
out=$(bash "$OPSX" notify test 2>&1); rc=$?
ok "opsx notify test: ok exits 0, says sent" '[ $rc -eq 0 ] && [[ "$out" == *"push sent"* ]] && [ "$(ncalls)" -eq 1 ]'
out=$(FAKE_CURL_EXIT=7 bash "$OPSX" notify test 2>&1); rc=$?
ok "opsx notify test: curl fails -> non-zero, push failed" '[ $rc -ne 0 ] && [[ "$out" == *"push failed"* ]]'
out=$(FAKE_CURL_CODE=403 bash "$OPSX" notify test 2>&1); rc=$?
ok "opsx notify test: HTTP 403 -> non-zero with the status" '[ $rc -ne 0 ] && [[ "$out" == *"push failed"* ]] && [[ "$out" == *403* ]]'
ok "opsx notify test: token never printed" '! printf "%s" "$out" | grep -q tk_secrettoken123'
out=$(bash "$OPSX" notify info 2>&1); rc=$?
ok "opsx notify info: url, user, topic" '[ $rc -eq 0 ] && [[ "$out" == *"https://ntfy.dev.example.com"* ]] && [[ "$out" == *opsx* ]] && [[ "$out" == *opsx-0123456789ab* ]]'
ok "opsx notify info: no password, no token" '[[ "$out" != *pw-secret-456* ]] && [[ "$out" != *tk_secrettoken123* ]]'
out=$(bash "$OPSX" notify info --show-password 2>&1)
ok "opsx notify info --show-password: password, still no token" '[[ "$out" == *pw-secret-456* ]] && [[ "$out" != *tk_secrettoken123* ]]'
h=$(bash "$OPSX" notify --help)
ok "opsx notify --help lists test and info --show-password" '[[ "$h" == *test* ]] && [[ "$h" == *"info [--show-password]"* ]]'
ok "opsx help lists notify" 'bash "$OPSX" help | grep -q "notify"'
mv "$ENVF" "$ENVF.off"
out=$(bash "$OPSX" notify test 2>&1); rc=$?
ok "opsx notify test: not configured -> non-zero" '[ $rc -ne 0 ] && [[ "$out" == *"push failed"* ]]'
mv "$ENVF.off" "$ENVF"
unset OPSX_SKILLS_DIR

# ---------------------------------------------------------------- private tmux
# Env is exported before the server starts, so panes inherit the fake curl
# and the scratch config.
$L -f /dev/null new-session -d -s nt -x 160 -y 40 -n plain 'exec sleep 3000'
TMUX="$($L display -p '#{socket_path}'),$($L display -p '#{pid}'),0"
export TMUX
P_PLAIN=$($L display -p -t nt:plain '#{pane_id}')
$L new-window -d -t nt -n chg 'exec sleep 3000'
W_CHG=$($L display -p -t nt:chg '#{window_id}'); P_CHG=$($L display -p -t nt:chg '#{pane_id}')
$L set-option -w -t "$W_CHG" @opsx_change fix-x
P_FORK=$($L split-window -d -P -F '#{pane_id}' -t "$W_CHG" 'exec sleep 3000')
$L set-option -p -t "$P_FORK" @fork_dir "$SP/forks/7"
$L new-window -d -t nt -n pr 'exec sleep 3000'
W_PR=$($L display -p -t nt:pr '#{window_id}'); P_PR=$($L display -p -t nt:pr '#{pane_id}')
$L set-option -w -t "$W_PR" @opsx_change pr-42
$L new-session -d -s MED-43 'exec sleep 3000'
$L set-option -t MED-43 @opsx_task MED-43
P_TASK=$($L display -p -t MED-43 '#{pane_id}')
export TMUX_PANE=$P_PLAIN

ASK='{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Keep theirs or ours in api.ts?","header":"Merge","options":[{"label":"theirs","description":"a"},{"label":"ours","description":"b"}],"multiSelect":false}]}}'
hook() { printf '%s' "$2" | TMUX_PANE=$1 bash "$N" hook "$3"; }

# ---------------------------------------------------------------- 1.2 / 4.1 scope + question hooks
reset_calls
out=$(hook "$P_PLAIN" "$ASK" claude-pretool); rc=$?
ok "untagged window: question hook sends nothing, exit 0" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 0 ] && [ -z "$out" ]'
out=$(printf '{"stop_hook_active":false,"last_assistant_message":"x"}' | TMUX_PANE=$P_PLAIN bash "$N" hook claude-stop); rc=$?
ok "untagged window: Stop hook sends nothing, exit 0" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 0 ]'
# Outside tmux: only checkable when no ancestor of this test runs in tmux (the
# /proc recovery would find that pane, as it is meant to).
under_tmux=0; pid=$$
while [ "${pid:-1}" -gt 1 ]; do
  tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q '^TMUX_PANE=' && { under_tmux=1; break; }
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done
if [ "$under_tmux" -eq 0 ]; then
  out=$(printf '%s' "$ASK" | env -u TMUX -u TMUX_PANE bash "$N" hook claude-pretool); rc=$?
  ok "outside tmux: nothing, exit 0" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 0 ]'
else
  echo "SKIP outside tmux: this test itself runs under tmux"
fi
for t in CHG:fix-x TASK:MED-43 FORK:fork-7; do
  reset_calls
  v=P_${t%%:*}; out=$(hook "${!v}" "$ASK" claude-pretool)
  ok "${t%%:*} pane: question hook sends one decision push naming ${t#*:}" '[ "$(ncalls)" -eq 1 ] && [ -z "$out" ] && [ "$(hdr Tags)" = question ] && [[ "$(hdr Title)" == *"${t#*:}"* ]]'
done
ok "question push body: the question and its option labels" 'body_of | grep -q "Keep theirs or ours in api.ts?" && body_of | grep -q "theirs / ours"'
ok "question hook records @opsx_notify_last_decision" '[ -n "$($L show-options -wqv -t "$W_CHG" @opsx_notify_last_decision)" ]'
reset_calls
hook "$P_FORK" '{"tool_name":"Bash","tool_input":{"command":"ls"}}' claude-pretool
ok "other tool names: no push" '[ "$(ncalls)" -eq 0 ]'
hook "$P_FORK" '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}' claude-notification
ok "idle_prompt: no push" '[ "$(ncalls)" -eq 0 ]'
hook "$P_FORK" '{"hook_event_name":"Notification","notification_type":"auth_success","message":"ok"}' claude-notification
ok "other notification types: no push" '[ "$(ncalls)" -eq 0 ]'
out=$(hook "$P_FORK" '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}' claude-notification)
ok "permission_prompt: one decision push, waiting for permission" '[ "$(ncalls)" -eq 1 ] && [ -z "$out" ] && [[ "$(hdr Title)" == *"waiting for permission"* ]] && [ "$(hdr Tags)" = question ]'

# $TMUX_PANE stripped: the pane is recovered from /proc like opsx-window.sh does.
reset_calls
printf '%s' "$ASK" > "$SP/ask.json"
$L respawn-pane -k -t "$P_CHG" "bash -c 'env -u TMUX_PANE bash \"$N\" hook claude-pretool < \"$SP/ask.json\" > \"$SP/stripped.out\" 2>&1; exec sleep 3000'"
wait_calls 1 10
ok "TMUX_PANE unset in an opsx pane: still one push" '[ "$(ncalls)" -eq 1 ] && [[ "$(hdr Title)" == *fix-x* ]] && [ ! -s "$SP/stripped.out" ]'

# ---------------------------------------------------------------- 2.1 mark ask
reset_calls
$L set-option -wu -t "$W_PR" @opsx_notify_last_decision
o=$(TMUX_PANE=$P_PLAIN bash "$W" mark pr-42 ask); rc=$?
ok "mark pr-42 ask: mark exits at once and still prints its line" '[ $rc -eq 0 ] && [[ "$o" == marked* ]] && [ "$(ncalls)" -eq 0 ]'
wait_calls 1 9
sleep 1
ok "mark pr-42 ask: one decision push whose title contains pr-42" '[ "$(ncalls)" -eq 1 ] && [[ "$(hdr Title)" == *pr-42* ]] && [ "$(hdr Tags)" = question ]'

reset_calls
$L set-option -wu -t "$W_PR" @opsx_notify_last_decision
TMUX_PANE=$P_PLAIN bash "$W" mark pr-42 ask >/dev/null
sleep 2
bash "$N" send --window "$W_PR" decision pr-42 "pr-42: needs a decision" "rebase onto main or develop?"
sleep 5
ok "mark ask then a texted push 2 s later: exactly one push, with the text" '[ "$(ncalls)" -eq 1 ] && body_of | grep -q "rebase onto main or develop?"'

reset_calls
bash "$N" send --window "$W_PR" decision pr-42 "pr-42: needs a decision" "squash or merge?"
TMUX_PANE=$P_PLAIN bash "$W" mark pr-42 ask >/dev/null
sleep 6.5
ok "texted push then mark ask: exactly one push, with the text" '[ "$(ncalls)" -eq 1 ] && body_of | grep -q "squash or merge?"'

# `mark . ask` in a fork pane: decision push, no title change.
reset_calls
$L set-option -wu -t "$W_CHG" @opsx_notify_last_decision
name_before=$($L display -p -t "$W_CHG" '#{window_name}')
o=$(TMUX_PANE=$P_FORK OPSX_NOTIFY_ASK_DELAY=1 bash "$W" mark . ask); rc=$?
wait_calls 1 5
ok "mark . ask in a fork pane: one decision push, window title unchanged" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 1 ] && [[ "$(hdr Title)" == *fork-7* ]] && [ "$($L display -p -t "$W_CHG" "#{window_name}")" = "$name_before" ]'

# `mark . ask` in a fork pane of an untagged window (fork.sh's default split or
# its fork-<id> window): the window carries no @opsx_change / @opsx_task.
$L new-window -d -t nt -n forkwin 'exec sleep 3000'
W_FW=$($L display -p -t nt:forkwin '#{window_id}')
P_FW=$($L split-window -d -P -F '#{pane_id}' -t "$W_FW" 'exec sleep 3000')
$L set-option -p -t "$P_FW" @fork_dir "$SP/forks/9"
reset_calls
o=$(TMUX_PANE=$P_FW OPSX_NOTIFY_ASK_DELAY=1 bash "$W" mark . ask); rc=$?
wait_calls 1 5; sleep 1
ok "F1: mark . ask in a fork pane of an untagged window: one decision push" '[ $rc -eq 0 ] && [ -z "$($L show-options -wqv -t "$W_FW" @opsx_change)$($L show-options -qv -t nt @opsx_task)" ] && [ "$(ncalls)" -eq 1 ] && [[ "$(hdr Title)" == *fork-9* ]] && [ "$(hdr Tags)" = question ]'
# the fork pane closes before the delay ends: no push
reset_calls
P_FW2=$($L split-window -d -P -F '#{pane_id}' -t "$W_FW" 'exec sleep 3000')
$L set-option -p -t "$P_FW2" @fork_dir "$SP/forks/10"
TMUX_PANE=$P_FW2 OPSX_NOTIFY_ASK_DELAY=2 bash "$W" mark . ask >/dev/null; rc=$?
$L kill-pane -t "$P_FW2"
sleep 3.5
ok "F1: fork pane closed before the ask delay: no push" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 0 ]'
# a question hook in the same pane right after: the bare ask collapses
reset_calls
$L set-option -wu -t "$W_FW" @opsx_notify_last_decision
TMUX_PANE=$P_FW OPSX_NOTIFY_ASK_DELAY=2 bash "$W" mark . ask >/dev/null
hook "$P_FW" "$ASK" claude-pretool >/dev/null
sleep 3.5
ok "F1: mark . ask then a question hook in an untagged-window fork pane: one push, with the text" '[ "$(ncalls)" -eq 1 ] && body_of | grep -q "Keep theirs or ours"'
$L kill-window -t "$W_FW"

# ---------------------------------------------------------------- 3.1 / 3.2 finished
reset_calls
OPSX_NOTIFY_FLUSH_AFTER=2 TMUX_PANE=$P_PLAIN bash "$W" mark fix-x fail >/dev/null
ok "mark fail: pending stamp set" '[[ "$($L show-options -wqv -t "$W_CHG" @opsx_notify_pending)" == fail:* ]]'
wait_calls 1 6; sleep 1
ok "mark fix-x fail, no hook: exactly one push with fix-x and fail in the title" '[ "$(ncalls)" -eq 1 ] && [[ "$(hdr Title)" == *fix-x* ]] && [[ "$(hdr Title)" == *fail* ]] && [ "$(hdr Tags)" = x ]'
ok "flusher cleared the stamp" '[ -z "$($L show-options -wqv -t "$W_CHG" @opsx_notify_pending)" ]'

reset_calls
OPSX_NOTIFY_FLUSH_AFTER=3 TMUX_PANE=$P_PLAIN bash "$W" mark fix-x "done" >/dev/null
out=$(printf '{"stop_hook_active":false,"last_assistant_message":"all gates passed"}' | TMUX_PANE=$P_CHG bash "$N" hook claude-stop); rc=$?
ok "done then Stop hook: one push with the final message" '[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(ncalls)" -eq 1 ] && [[ "$(hdr Title)" == *fix-x* ]] && [[ "$(hdr Title)" == *done* ]] && body_of | grep -q "all gates passed"'
sleep 4.5
ok "done then Stop hook: the flusher sends nothing later" '[ "$(ncalls)" -eq 1 ]'

reset_calls
printf '{"last_assistant_message":"just a turn"}' | TMUX_PANE=$P_CHG bash "$N" hook claude-stop
ok "Stop hook without a pending done/fail: no push" '[ "$(ncalls)" -eq 0 ]'

reset_calls
OPSX_NOTIFY_FLUSH_AFTER=30 TMUX_PANE=$P_PLAIN bash "$W" mark fix-x "done" >/dev/null
printf '{"last_assistant_message":"fork says hi"}' | TMUX_PANE=$P_FORK bash "$N" hook claude-stop
ok "Stop hook in a fork pane does not take the change window's push" '[ "$(ncalls)" -eq 0 ] && [ -n "$($L show-options -wqv -t "$W_CHG" @opsx_notify_pending)" ]'
TR=$SP/transcript.jsonl
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"older text"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"final: tests green"}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}'
} > "$TR"
printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$TR" | TMUX_PANE=$P_CHG bash "$N" hook claude-stop
ok "Stop hook with only transcript_path: body from the transcript" '[ "$(ncalls)" -eq 1 ] && [ "$(body_of)" = "final: tests green" ]'

# python3 fallback for the hook JSON (no jq on PATH).
if command -v python3 >/dev/null 2>&1; then
  mkdir -p "$SP/nojq"
  for t in bash tmux sed head tail tr basename dirname cat date python3 find mkdir rmdir sleep setsid env curl mv grep; do
    p=$(PATH="$SP/bin:$PATH" command -v "$t") && ln -sf "$p" "$SP/nojq/$t"
  done
  reset_calls
  OPSX_NOTIFY_FLUSH_AFTER=30 TMUX_PANE=$P_PLAIN bash "$W" mark fix-x "done" >/dev/null
  printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$TR" | PATH=$SP/nojq TMUX_PANE=$P_CHG bash "$N" hook claude-stop
  ok "no jq: python3 reads the transcript" '[ "$(ncalls)" -eq 1 ] && [ "$(body_of)" = "final: tests green" ]'
  reset_calls
  printf '%s' "$ASK" | PATH=$SP/nojq TMUX_PANE=$P_TASK bash "$N" hook claude-pretool
  ok "no jq: python3 reads the question" '[ "$(ncalls)" -eq 1 ] && body_of | grep -q "theirs / ours"'
fi

# ---------------------------------------------------------------- 3.3 silence fallback
reset_calls
TMUX_PANE=$P_PLAIN bash "$W" mark fix-x busy >/dev/null
o=$(TMUX_PANE=$P_PLAIN bash "$W" mark fix-x idle --if-busy)
wait_calls 1 5; sleep 0.5
ok "silence fallback: busy -> idle sends one push saying it stopped without marking" '[[ "$o" == marked* ]] && [ "$(ncalls)" -eq 1 ] && [[ "$(hdr Title)" == *"stopped without marking"* ]] && [ "$(hdr Tags)" = zzz ]'
reset_calls
o=$(TMUX_PANE=$P_PLAIN bash "$W" mark fix-x idle --if-busy)
sleep 1
ok "silence fallback skipped (not busy): no push" '[[ "$o" == skipped* ]] && [ "$(ncalls)" -eq 0 ]'
reset_calls
TMUX_PANE=$P_PLAIN bash "$W" mark fix-x busy >/dev/null
TMUX_PANE=$P_PLAIN bash "$W" mark fix-x idle >/dev/null
sleep 1
ok "plain mark busy / idle: no push" '[ "$(ncalls)" -eq 0 ]'

# not configured: mark still works and sends nothing
mv "$ENVF" "$ENVF.off"; reset_calls; $L set-option -wu -t "$W_CHG" @opsx_notify_pending
o=$(TMUX_PANE=$P_PLAIN bash "$W" mark fix-x "done"); rc=$?
ok "not configured: mark done works, no pending stamp, no push" '[ $rc -eq 0 ] && [[ "$o" == marked* ]] && [ "$(ncalls)" -eq 0 ] && [ -z "$($L show-options -wqv -t "$W_CHG" @opsx_notify_pending)" ]'
mv "$ENVF.off" "$ENVF"

# ---------------------------------------------------------------- 5.x install.sh
# Fresh scratch HOMEs, offline: fake caddy ($OPSX_CADDY_BIN), fake ntfy
# ($OPSX_NTFY_BIN, tests/fake-ntfy.sh), PATH shims that log any sudo/systemctl
# call, a curl shim that only lets unix-socket / 127.0.0.1 / file:// through,
# a scratch systemd dir. Never the real HOME, systemd or network.
SH=$SP/ishims; mkdir -p "$SH"
REAL_CURL=$(PATH=${PATH#"$SP/bin:"} command -v curl)
for c in sudo systemctl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/privileged.log"\nexit 0\n' "$c" "$SP" > "$SH/$c"
done
cat > "$SH/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SP/icurl.log"
for a in "\$@"; do case \$a in --unix-socket|file://*|http://127.0.0.1*) exec "$REAL_CURL" "\$@" ;; esac; done
echo "curl: (7) blocked by test shim" >&2; exit 7
EOF
for c in claude node npm; do printf '#!/bin/sh\necho 0.0.0\n' > "$SH/$c"; done
mkdir -p "$SP/fcaddy"
printf '#!/bin/sh\n[ "$1" = list-modules ] && { echo http.handlers.reverse_proxy; echo dns.providers.cloudflare; exit 0; }\nexit 0\n' > "$SP/fcaddy/caddy"
chmod +x "$SH"/* "$SP/fcaddy/caddy"
FNTFY=$REPO/tests/fake-ntfy.sh
SYSD=$SP/systemd-scratch; mkdir -p "$SYSD"
INSTALL_FLAGS=(--skip-openspec --skip-graphify --skip-commands --skip-mcp --skip-memory)
H_N=0
new_home() { H_N=$((H_N+1)); IH=$SP/ih$H_N; mkdir -p "$IH"; rm -f "$SP/privileged.log" "$SP/icurl.log"; }
# run_install <env assignments...> -- <install args...>
run_install() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_RUNTIME_DIR -u TMUX -u TMUX_PANE \
      -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_HOME -u OPENCODE_CONFIG_DIR -u CLOUDFLARE_API_TOKEN -u SUDO_USER \
      -u OPSX_NTFY_BIN -u OPSX_NTFY_RELEASE_BASE \
      HOME="$IH" PATH="$SH:${PATH#"$SP/bin:"}" NO_COLOR=1 OPSX_SYSTEMD_DIR="$SYSD" FAKE_NTFY_DIR="$IH.ntfy" "${envs[@]}" \
    bash "$REPO/install.sh" "${INSTALL_FLAGS[@]}" "$@" </dev/null > "$IH.out" 2>&1
}
DOM=(CLOUDFLARE_API_TOKEN=t1 OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/fcaddy/caddy")
CFG() { printf '%s/.config/tmux-opsx' "$IH"; }
route_ids() { jq -r '[.apps.http.servers[].routes[]?."@id"] | join(",")' "$(CFG)/caddy.json"; }
SKILL_DIRS=(.claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills)
notify_hook_count() { jq '[.hooks[]?[]?.hooks[]? | select((.command // "") | test("opsx-notify"))] | length' "$IH/.claude/settings.json" 2>/dev/null || echo 0; }

ok "install --help lists --skip-notify" 'bash "$REPO/install.sh" --help | grep -q -- "--skip-notify"'

# 5.1 / 5.2 / 5.3 / 5.4 fresh install with a domain
new_home; run_install "${DOM[@]}" OPSX_NTFY_BIN="$FNTFY" -- --expose-domain dev.example.com; rc=$?
H1=$IH
ok "install with domain + fake ntfy exits 0" '[ $rc -eq 0 ]'
ok "5.1: the install step reports the ntfy binary from \$OPSX_NTFY_BIN" 'grep -q "ntfy .*fake-ntfy.sh (from \$OPSX_NTFY_BIN)" "$IH.out"'
Y=$(CFG)/ntfy-server.yml
ok "5.2: server.yml: base-url, loopback listen, behind-proxy, deny-all, state under ~/.local/state/tmux-opsx/ntfy" 'grep -qx "base-url: https://ntfy.dev.example.com" "$Y" && grep -qx "listen-http: 127.0.0.1:2586" "$Y" && grep -qx "behind-proxy: true" "$Y" && grep -qx "auth-default-access: deny-all" "$Y" && grep -qx "auth-file: \"$IH/.local/state/tmux-opsx/ntfy/auth.db\"" "$Y" && grep -qx "cache-file: \"$IH/.local/state/tmux-opsx/ntfy/cache.db\"" "$Y"'
U=$(CFG)/tmux-opsx-ntfy.service
ok "5.2: unit ExecStart is the installed ntfy with the config" 'grep -qx "ExecStart=\"$FNTFY\" serve --config \"$Y\"" "$U" && grep -q "^User=$(id -un)$" "$U" && grep -q "^WantedBy=multi-user.target" "$U"'
ok "5.2: non-root: no sudo/systemctl run, prints the enable command" '[ ! -e "$SP/privileged.log" ] && grep -q "sudo install -m 644 .*tmux-opsx-ntfy.service.* $SYSD/ && sudo systemctl daemon-reload && sudo systemctl enable --now tmux-opsx-ntfy" "$IH.out"'
ok "5.3: caddy.json has route opsx-ntfy for ntfy.dev.example.com -> 127.0.0.1:2586, streaming" 'J=$(CFG)/caddy.json; [ "$(jq -r ".apps.http.servers.expose.routes[0][\"@id\"]" "$J")" = opsx-ntfy ] && [ "$(jq -r ".apps.http.servers.expose.routes[0].match[0].host[0]" "$J")" = ntfy.dev.example.com ] && [ "$(jq -r ".apps.http.servers.expose.routes[0].handle[0].upstreams[0].dial" "$J")" = 127.0.0.1:2586 ] && [ "$(jq -r ".apps.http.servers.expose.routes[0].handle[0].flush_interval" "$J")" = -1 ]'
NE=$(CFG)/notify.env
ok "5.4: notify.env mode 600 with url, opsx-<12 hex> topic and a token" '[ "$(stat -c %a "$NE")" = 600 ] && grep -qx "NTFY_URL=https://ntfy.dev.example.com" "$NE" && grep -qE "^NTFY_TOPIC=opsx-[0-9a-f]{12}$" "$NE" && grep -qE "^NTFY_TOKEN=tk_[0-9a-f]+$" "$NE" && grep -qx "NTFY_USER=opsx" "$NE"'
ok "5.4: user opsx created once, granted rw on the topic, one token" '[ "$(grep -c "^user .*add opsx$" "$IH.ntfy/calls.log")" -eq 1 ] && grep -q "^access .*opsx $(sed -n "s/^NTFY_TOPIC=//p" "$NE") rw$" "$IH.ntfy/calls.log" && [ "$(grep -c "^token .*add opsx$" "$IH.ntfy/calls.log")" -eq 1 ]'
ok "5.4: the token matches the one ntfy created" 'grep -q " $(sed -n "s/^NTFY_TOKEN=//p" "$NE")$" "$IH.ntfy/tokens"'
PW=$(sed -n 's/^NTFY_PASSWORD=//p' "$NE"); TK=$(sed -n 's/^NTFY_TOKEN=//p' "$NE"); TP=$(sed -n 's/^NTFY_TOPIC=//p' "$NE")
ok "5.4: the password is 24 characters and set in ntfy" '[ "${#PW}" -eq 24 ] && [ "$(cat "$IH.ntfy/pw-opsx")" = "$PW" ]'
ok "F3: the password reaches ntfy on stdin, never in argv or the environment" 'grep -qx "pw-from stdin" "$IH.ntfy/calls.log" && ! grep -q "pw-from env" "$IH.ntfy/calls.log" && ! grep -qF "$PW" "$IH.ntfy/calls.log"'
ok "5.4: install output has the Android setup lines but neither password nor token" 'grep -q "Android: install ntfy, add server https://ntfy.dev.example.com, log in as opsx, subscribe to $TP" "$IH.out" && grep -q "opsx notify info --show-password" "$IH.out" && ! grep -qF "$PW" "$IH.out" && ! grep -qF "$TK" "$IH.out"'
ok "5.6: opsx-notify.sh executable in all six opsx-run dirs; verify parses it" 'for d in "${SKILL_DIRS[@]}"; do [ -x "$IH/$d/opsx-run/opsx-notify.sh" ] || exit 1; done; grep -q "opsx-notify.sh parses" "$IH.out"'
ok "5.5: settings.json has the three notify hooks" '[ "$(notify_hook_count)" -eq 3 ] && [ "$(jq -r ".hooks.PreToolUse[-1].matcher" "$IH/.claude/settings.json")" = AskUserQuestion ] && [ "$(jq -r ".hooks.Notification[-1].matcher" "$IH/.claude/settings.json")" = permission_prompt ] && [ "$(jq -r ".hooks.Stop[-1].hooks[0].command" "$IH/.claude/settings.json")" = "$IH/.claude/skills/opsx-run/opsx-notify.sh hook claude-stop" ]'
out=$(env -u XDG_CONFIG_HOME HOME="$IH" PATH="$SH:$PATH" bash "$IH/.local/bin/opsx" notify info 2>&1); rc=$?
ok "7.1: installed opsx notify info: url, user, topic; no password or token" '[ $rc -eq 0 ] && [[ "$out" == *"https://ntfy.dev.example.com"* ]] && [[ "$out" == *"opsx"* ]] && [[ "$out" == *"$TP"* ]] && [[ "$out" != *"$PW"* ]] && [[ "$out" != *"$TK"* ]]'

# 5.4 rerun keeps the credentials and makes no second user
sum_before=$(cd "$IH" && find . -path ./.local/state -prune -o -type f -print | sort | xargs md5sum)
run_install "${DOM[@]}" OPSX_NTFY_BIN="$FNTFY" -- --expose-domain dev.example.com; rc=$?
sum_after=$(cd "$IH" && find . -path ./.local/state -prune -o -type f -print | sort | xargs md5sum)
ok "5.4: rerun: exit 0, no second user add, same token and topic" '[ $rc -eq 0 ] && [ "$(grep -c "^user .*add opsx$" "$IH.ntfy/calls.log")" -eq 1 ] && [ "$(grep -c "^token .*add" "$IH.ntfy/calls.log")" -eq 1 ] && grep -qx "NTFY_TOKEN=$TK" "$NE" && grep -qx "NTFY_TOPIC=$TP" "$NE" && grep -qx "NTFY_PASSWORD=$PW" "$NE"'
ok "5.4: rerun leaves identical files (no .bak, hooks not duplicated)" '[ "$sum_before" = "$sum_after" ] && [ "$(notify_hook_count)" -eq 3 ]'
# a token that no longer exists in ntfy is replaced, the topic kept
: > "$IH.ntfy/tokens"
run_install "${DOM[@]}" OPSX_NTFY_BIN="$FNTFY" -- --expose-domain dev.example.com
ok "5.4: a lost token is re-created, the topic kept, no second user" '! grep -qx "NTFY_TOKEN=$TK" "$NE" && grep -qE "^NTFY_TOKEN=tk_" "$NE" && grep -qx "NTFY_TOPIC=$TP" "$NE" && [ "$(grep -c "^user .*add opsx$" "$IH.ntfy/calls.log")" -eq 1 ]'

# 5.3 expose.sh up/down against a fake admin API keeps the static route
if command -v python3 >/dev/null 2>&1; then
  ASOCK=$(mktemp -d /tmp/ntfy-adm.XXXXXX)/a.sock
  python3 "$REPO/tests/fake-caddy-admin.py" "$ASOCK" "$(CFG)/caddy.json" & APID=$!
  for _ in $(seq 1 50); do [ -S "$ASOCK" ] && break; sleep 0.1; done
  IE() { env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u TMUX -u TMUX_PANE HOME="$IH" OPSX_EXPOSE_ADMIN="$ASOCK" OPSX_EXPOSE_NO_COPY=1 PATH="$SH:$PATH" "$IH/.claude/skills/expose/expose.sh" "$@"; }
  IE up 3000 --name web --project shop >/dev/null 2>&1
  r1=$("$REAL_CURL" -s --unix-socket "$ASOCK" http://127.0.0.1/config/apps/http/servers/expose/routes | jq -r '[.[]."@id"] | join(",")')
  IE down web --project shop >/dev/null 2>&1
  code=$("$REAL_CURL" -s -o /dev/null -w '%{http_code}' --unix-socket "$ASOCK" http://127.0.0.1/id/opsx-ntfy)
  r2=$("$REAL_CURL" -s --unix-socket "$ASOCK" http://127.0.0.1/config/apps/http/servers/expose/routes | jq -r '[.[]."@id"] | join(",")')
  ok "5.3: expose up adds its route beside opsx-ntfy; down removes only its own" '[ "$r1" = "opsx-ntfy,expose-web--shop" ] && [ "$r2" = opsx-ntfy ] && [ "$code" = 200 ]'
  kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null; rm -rf "$(dirname "$ASOCK")"
fi

# 5.6 uninstall: no unit, no route, no hook; the state dir stays
cp "$U" "$SYSD/"
rm -f "$SP/privileged.log"
run_install -- --uninstall; rc=$?
ok "5.6: uninstall exits 0" '[ $rc -eq 0 ]'
ok "5.6: uninstall removes the unit file and the opsx-ntfy route" '[ ! -e "$U" ] && ! grep -q opsx-ntfy "$(CFG)/caddy.json"'
ok "5.6: uninstall leaves no opsx-notify hook command in settings.json" '! grep -q "opsx-notify" "$IH/.claude/settings.json"'
ok "5.6: uninstall: no sudo run, prints the systemctl disable command for the installed unit" '[ ! -e "$SP/privileged.log" ] && grep -q "sudo systemctl disable --now tmux-opsx-ntfy" "$IH.out"'
ok "5.6: uninstall keeps the ntfy state dir and removes opsx-notify.sh" '[ -d "$IH/.local/state/tmux-opsx/ntfy" ] && [ ! -e "$IH/.claude/skills/opsx-run/opsx-notify.sh" ]'
rm -f "$SYSD/tmux-opsx-ntfy.service"

# --skip-notify in a fresh HOME
new_home; run_install "${DOM[@]}" OPSX_NTFY_BIN="$FNTFY" -- --expose-domain dev.example.com --skip-notify; rc=$?
ok "5.3: --skip-notify: no opsx-ntfy route, no unit, no notify.env, no hooks, no ntfy call" '[ $rc -eq 0 ] && [ "$(route_ids)" = "" ] && [ ! -e "$(CFG)/tmux-opsx-ntfy.service" ] && [ ! -e "$(CFG)/notify.env" ] && ! grep -qs opsx-notify "$IH/.claude/settings.json" && [ ! -e "$IH.ntfy/calls.log" ] && [ ! -e "$IH/.claude/skills/opsx-run/opsx-notify.sh" ]'
# rerun without --skip-notify adds it, a --skip-notify rerun takes it out again (state kept)
run_install "${DOM[@]}" OPSX_NTFY_BIN="$FNTFY" -- --expose-domain dev.example.com
ok "rerun without --skip-notify adds route, unit, notify.env, hooks" '[ "$(route_ids)" = opsx-ntfy ] && [ -f "$(CFG)/tmux-opsx-ntfy.service" ] && [ -f "$(CFG)/notify.env" ] && [ "$(notify_hook_count)" -eq 3 ]'
run_install "${DOM[@]}" OPSX_NTFY_BIN="$FNTFY" -- --expose-domain dev.example.com --skip-notify
ok "--skip-notify rerun removes route, unit and hooks, keeps the state dir" '[ "$(route_ids)" = "" ] && [ ! -e "$(CFG)/tmux-opsx-ntfy.service" ] && [ "$(notify_hook_count)" -eq 0 ] && [ -d "$IH/.local/state/tmux-opsx/ntfy" ]'
# F2: --skip-notify without --expose-domain also takes out the unit and the route
run_install "${DOM[@]}" OPSX_NTFY_BIN="$FNTFY" -- --expose-domain dev.example.com
ok "F2: reinstall with the domain adds route and unit again" '[ "$(route_ids)" = opsx-ntfy ] && [ -f "$(CFG)/tmux-opsx-ntfy.service" ] && [ "$(notify_hook_count)" -eq 3 ]'
cp "$(CFG)/tmux-opsx-ntfy.service" "$SYSD/"
rm -f "$SP/privileged.log"
run_install -- --skip-notify; rc=$?
ok "F2: --skip-notify without --expose-domain removes route, unit and hooks, keeps the state dir" '[ $rc -eq 0 ] && [ "$(route_ids)" = "" ] && [ ! -e "$(CFG)/tmux-opsx-ntfy.service" ] && [ "$(notify_hook_count)" -eq 0 ] && [ -d "$IH/.local/state/tmux-opsx/ntfy" ]'
ok "F2: no sudo run; prints the systemctl disable command for the installed unit once" '[ ! -e "$SP/privileged.log" ] && [ "$(grep -c "sudo systemctl disable --now tmux-opsx-ntfy" "$IH.out")" -eq 1 ]'
rm -f "$SYSD/tmux-opsx-ntfy.service"

# 5.5 existing settings.json hooks are kept; two runs, one Stop hook
new_home; mkdir -p "$IH/.claude"
cat > "$IH/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/my-guard.sh"}]}
    ]
  }
}
JSON
mine=$(jq -c '.hooks.PreToolUse[0]' "$IH/.claude/settings.json")
run_install -- ; rc1=$?
run_install -- ; rc2=$?
S=$IH/.claude/settings.json
ok "5.5: two runs without a domain exit 0" '[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]'
ok "5.5: the existing PreToolUse hook is unchanged and other settings kept" '[ "$(jq -c ".hooks.PreToolUse[0]" "$S")" = "$mine" ] && [ "$(jq -r .model "$S")" = opus ]'
ok "5.5: the tmux-opsx Stop hook appears exactly once" '[ "$(jq "[.hooks.Stop[]?.hooks[]? | select(.command | test(\"opsx-notify.sh hook claude-stop\"))] | length" "$S")" -eq 1 ] && [ "$(notify_hook_count)" -eq 3 ]'
ok "5.5: a .bak was kept of the original settings.json, only one" '[ "$(ls "$S".bak.* 2>/dev/null | wc -l)" -eq 1 ] && [ "$(jq -c ".hooks.PreToolUse" "$(ls "$S".bak.* | head -n1)")" = "[$mine]" ]'
ok "5.5: no domain: no ntfy server, no ~/.config/tmux-opsx" '[ ! -e "$IH/.config/tmux-opsx" ] && ! grep -q "Setting up the push server" "$IH.out"'
ok "5.5: no domain: says how to configure and names the CLIs without hooks" 'grep -q "notify.env" "$IH.out" && grep -q "Cursor, Codex, OpenCode and Gemini" "$IH.out"'
cp "$S" "$SP/settings.before"; rm -f "$S".bak.*
run_install -- --no-backup
ok "5.5: --no-backup rerun writes no .bak" '[ -z "$(ls "$S".bak.* 2>/dev/null)" ]'
run_install -- --skip-notify
ok "5.5: --skip-notify removes only the tmux-opsx hooks" '[ "$(notify_hook_count)" -eq 0 ] && [ "$(jq -c ".hooks.PreToolUse" "$S")" = "[$mine]" ] && [ "$(jq -r ".hooks.Stop // \"none\"" "$S")" = none ] && [ "$(jq -r .model "$S")" = opus ]'
printf '{ not json' > "$S"
run_install -- ; rc=$?
ok "5.5: invalid settings.json is left alone with a warning" '[ $rc -eq 0 ] && [ "$(cat "$S")" = "{ not json" ] && grep -q "not valid JSON" "$IH.out"'
# python3 fallback (no jq on PATH)
if command -v python3 >/dev/null 2>&1; then
  mkdir -p "$SP/nojq-i"
  for p in /usr/bin/* /bin/*; do
    t=${p##*/}
    [ "$t" = jq ] || [ -e "$SP/nojq-i/$t" ] || ln -s "$p" "$SP/nojq-i/$t" 2>/dev/null
  done
  cp "$SP/settings.before" "$S"
  printf '%s\n' "$(jq 'del(.hooks.Stop, .hooks.Notification) | .hooks.PreToolUse = [.hooks.PreToolUse[0]]' "$S")" > "$S"
  env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u TMUX -u TMUX_PANE -u CLAUDE_CONFIG_DIR HOME="$IH" PATH="$SH:$SP/nojq-i" NO_COLOR=1 \
    bash "$REPO/install.sh" "${INSTALL_FLAGS[@]}" --no-backup </dev/null > "$IH.out" 2>&1; rc=$?
  ok "5.5: python3 fallback merges the hooks (no jq)" '[ $rc -eq 0 ] && [ "$(notify_hook_count)" -eq 3 ] && [ "$(jq -c ".hooks.PreToolUse[0]" "$S")" = "$mine" ]'
fi

# 5.1 pinned sha256 / match / failed download (release tarball from file://).
# The fake tarball can never match the real pinned hash, so the test-only
# OPSX_NTFY_SHA256 (honoured only with OPSX_NTFY_RELEASE_BASE) stands in for it.
case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; armv7*) ARCH=armv7 ;; *) ARCH=armv6 ;; esac
REL=$SP/rel; TB=ntfy_2.34.0_linux_$ARCH; mkdir -p "$REL/$TB"
cp "$FNTFY" "$REL/$TB/ntfy"; chmod +x "$REL/$TB/ntfy"
tar -czf "$REL/$TB.tar.gz" -C "$REL" "$TB"
TBSUM=$(sha256sum "$REL/$TB.tar.gz" | awk '{print $1}')
# a checksums.txt beside the tarball that vouches for it must not matter
printf '%s  %s\n' "$TBSUM" "$TB.tar.gz" > "$REL/checksums.txt"
ok "F1: install.sh pins the sha256 of all four linux tarballs of ntfy 2.34.0" 'for h in f78e2645c6457363f37d5d1c4f7cddb7e9658abd197824a7387a1a38d92bb895 d585fe48d1b2e80b1b1719977bb651cc7d9259bacb817aa8a8d5b4c8f0c9e946 c8c3a58301db93a9f5de32c0b028ce09485e9dcb0fa1433b9171e073c23e8342 4eaad91bf08f6c959449203de009cfb065b564bd37ba32a2e1f95d75bcb9adb9; do grep -q "want=$h ;;" "$REPO/install.sh" || exit 1; done'
new_home; run_install "${DOM[@]}" OPSX_NTFY_RELEASE_BASE="file://$REL" -- --expose-domain dev.example.com; rc=$?
ok "F1: another origin must still match the pinned hash (its checksums.txt is ignored): abort, no binary, no temp dir" '[ $rc -ne 0 ] && grep -q "does not match its pinned sha256 (expected f78e2645\|does not match its pinned sha256 (expected d585fe48\|does not match its pinned sha256 (expected c8c3a583\|does not match its pinned sha256 (expected 4eaad91b" "$IH.out" && [ ! -e "$IH/.local/share/tmux-opsx/bin/ntfy" ] && [ -z "$(ls -A "$IH/.local/share/tmux-opsx/bin" 2>/dev/null | grep ntfy)" ] && ! grep -q "checksums.txt" "$SP/icurl.log"'
new_home; run_install "${DOM[@]}" OPSX_NTFY_SHA256="$TBSUM" -- --expose-domain dev.example.com; rc=$?
ok "F1: OPSX_NTFY_SHA256 is ignored for the default GitHub download (pinned hash kept)" '[ $rc -eq 0 ] && grep -q "could not download ntfy from https://github.com/binwiederhier/ntfy/releases/download/v2.34.0" "$IH.out" && grep -q "releases/download/v2.34.0/$TB.tar.gz" "$SP/icurl.log" && [ ! -e "$IH/.local/share/tmux-opsx/bin/ntfy" ]'
new_home; run_install "${DOM[@]}" OPSX_NTFY_RELEASE_BASE="file://$REL" OPSX_NTFY_SHA256=0000000000000000000000000000000000000000000000000000000000000000 -- --expose-domain dev.example.com; rc=$?
ok "5.1: checksum mismatch aborts, leaves no binary and no temp dir" '[ $rc -ne 0 ] && grep -q "does not match its pinned sha256" "$IH.out" && [ ! -e "$IH/.local/share/tmux-opsx/bin/ntfy" ] && [ -z "$(ls -A "$IH/.local/share/tmux-opsx/bin" 2>/dev/null | grep ntfy)" ]'
new_home; run_install "${DOM[@]}" OPSX_NTFY_RELEASE_BASE="file://$REL" OPSX_NTFY_SHA256="$TBSUM" -- --expose-domain dev.example.com; rc=$?
ok "5.1: matching checksum installs the binary in the Caddy bin dir" '[ $rc -eq 0 ] && [ -x "$IH/.local/share/tmux-opsx/bin/ntfy" ] && grep -q "sha256 verified against the pinned hash" "$IH.out" && grep -q "ExecStart=\"$IH/.local/share/tmux-opsx/bin/ntfy\" serve" "$(CFG)/tmux-opsx-ntfy.service"'
run_install "${DOM[@]}" OPSX_NTFY_RELEASE_BASE="file:///nonexistent" -- --expose-domain dev.example.com; rc=$?
ok "5.1: an installed pinned binary is reused (no download)" '[ $rc -eq 0 ] && grep -q "already installed" "$IH.out"'
new_home; run_install "${DOM[@]}" OPSX_NTFY_RELEASE_BASE="file:///nonexistent" -- --expose-domain dev.example.com; rc=$?
ok "5.1: failed download: install still ok, server skipped (no route, no notify.env)" '[ $rc -eq 0 ] && grep -q "could not download ntfy" "$IH.out" && [ "$(route_ids)" = "" ] && [ ! -e "$(CFG)/notify.env" ]'
# a CPU with no pinned hash: clear warning, no download, server skipped
UN=$SP/uname-riscv; mkdir -p "$UN"
REAL_UNAME=$(command -v uname)
cat > "$UN/uname" <<EOF
#!/bin/sh
[ "\$1" = -m ] && { echo riscv64; exit 0; }
exec "$REAL_UNAME" "\$@"
EOF
chmod +x "$UN/uname"
new_home; run_install "${DOM[@]}" PATH="$UN:$SH:${PATH#"$SP/bin:"}" OPSX_NTFY_RELEASE_BASE="file://$REL" OPSX_NTFY_SHA256="$TBSUM" -- --expose-domain dev.example.com; rc=$?
ok "F1: a CPU without a pinned hash: warning, no download, no binary, server skipped" '[ $rc -eq 0 ] && grep -q "no pinned ntfy 2.34.0 build for CPU riscv64" "$IH.out" && ! grep -q "$TB" "$SP/icurl.log" 2>/dev/null && [ ! -e "$IH/.local/share/tmux-opsx/bin/ntfy" ] && [ ! -e "$(CFG)/notify.env" ]'

# F3 sudo ./install.sh: root with SUDO_USER. Shims: id -u says 0; getent maps
# the fake user to the scratch HOME (never a real home); chown and sudo log to
# one ordered file; sudo -u runs the command with env_reset semantics (only
# HOME, PATH, USER, LOGNAME and FAKE_NTFY_DIR, the test's stand-in for the
# fake ntfy's state, survive; NTFY_PASSWORD would not).
RS=$SP/rootshims; mkdir -p "$RS"
REAL_ID=$(command -v id); REAL_GETENT=$(command -v getent || echo false)
cat > "$RS/id" <<EOF
#!/bin/sh
[ "\$*" = -u ] && { echo 0; exit 0; }
exec "$REAL_ID" "\$@"
EOF
cat > "$RS/chown" <<EOF
#!/bin/sh
echo "chown \$*" >> "$SP/seq.log"
exit 0
EOF
cat > "$RS/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >> "$SP/seq.log"
[ "\$1" = -u ] || { echo "privileged \$*" >> "$SP/privileged.log"; exit 0; }
u=\$2; shift 2; [ "\${1:-}" = -H ] && shift
exec env -i HOME="\$HOME" PATH="\$PATH" USER="\$u" LOGNAME="\$u" FAKE_NTFY_DIR="\$FAKE_NTFY_DIR" "\$@"
EOF
new_home; rm -f "$SP/seq.log"
cat > "$RS/getent" <<EOF
#!/bin/sh
[ "\$1 \$2" = "passwd opsxtest" ] && { echo "opsxtest:x:1234:1234::$IH:/bin/sh"; exit 0; }
exec "$REAL_GETENT" "\$@"
EOF
chmod +x "$RS"/*
run_install "${DOM[@]}" PATH="$RS:$SH:${PATH#"$SP/bin:"}" SUDO_USER=opsxtest OPSX_NTFY_BIN="$FNTFY" NTFY_PASSWORD=leaked-from-env -- --expose-domain dev.example.com; rc=$?
NE=$(CFG)/notify.env; PW=$(sed -n 's/^NTFY_PASSWORD=//p' "$NE" 2>/dev/null)
ST=$IH/.local/state/tmux-opsx/ntfy
ok "F3: sudo: install exits 0 into the scratch HOME, ntfy runs as SUDO_USER" '[ $rc -eq 0 ] && grep -q "installing into opsxtest.s home ($IH)" "$IH.out" && grep -q "^sudo -u opsxtest -H $FNTFY user --config $(CFG)/ntfy-server.yml add opsx$" "$SP/seq.log"'
ok "F3: sudo: user opsx created with the stored password (stdin survives env_reset)" '[ "${#PW}" -eq 24 ] && [ "$(cat "$IH.ntfy/pw-opsx")" = "$PW" ] && grep -qx "pw-from stdin" "$IH.ntfy/calls.log" && ! grep -q "pw-from env" "$IH.ntfy/calls.log" && grep -qE "^NTFY_TOKEN=tk_" "$NE"'
ok "F3: sudo: the password is in no sudo/ntfy argv" '[ -n "$PW" ] && ! grep -qF "$PW" "$SP/seq.log" && ! grep -qF "$PW" "$IH.ntfy/calls.log"'
ok "F3: sudo: the state dir and config dir are chowned to SUDO_USER before the first ntfy call" 'first_ntfy=$(grep -n "^sudo -u opsxtest .*$FNTFY " "$SP/seq.log" | head -n1 | cut -d: -f1); c_st=$(grep -n "^chown -R opsxtest $ST$" "$SP/seq.log" | head -n1 | cut -d: -f1); c_cfg=$(grep -n "^chown -R opsxtest $(CFG) " "$SP/seq.log" | head -n1 | cut -d: -f1); [ -n "$first_ntfy" ] && [ -n "$c_st" ] && [ -n "$c_cfg" ] && [ "$c_st" -lt "$first_ntfy" ] && [ "$c_cfg" -lt "$first_ntfy" ] && [ -e "$ST/auth.db" ] && [ -e "$(CFG)/ntfy-server.yml" ]'

# ---------------------------------------------------------------- 2.3 prompts
SK=$REPO/skills/opsx-run/SKILL.md
ok "validate dispatcher prompt tells the agent to mark <change> ask before asking" 'sed -n "/^\*\*validate\*\*/,/^\*\*apply\*\*/p" "$SK" | grep -q "^> Before you ask the user a question, run \`opsx-window.sh mark <change> ask\`"'
ok "every dispatcher prompt has the mark ask line" 'a=$(grep -c "^> You are the dispatcher for OpenSpec change" "$SK"); b=$(grep -c "^> Before you ask the user a question, run .opsx-window.sh mark <change> ask." "$SK"); [ "$a" -gt 0 ] && [ "$b" -ge "$a" ]'
ok "opsx-task prompt writer has the mark . ask line" 'grep -q "mark \. ask" "$REPO/skills/opsx-task/opsx-task.sh"'
ok "fork protocol has the mark . ask line" 'grep -q "opsx-window.sh mark \. ask" "$REPO/skills/fork/fork.sh"'

# ---------------------------------------------------------------- 6.1 docs
RD=$REPO/README.md
ok "README: Notifications section, overview row for opsx-notify.sh and the push server" 'grep -q "^## Notifications" "$RD" && grep -q "^| \`opsx-notify.sh\`" "$RD" && grep -q "^| Push server" "$RD" && grep -q "notify       opsx-notify.sh" "$RD"'
ok "README: the /opsx-pr line about no notifications is gone" '! grep -q "There are no notifications" "$RD"'
ok "README: documented opsx notify commands are in opsx notify --help" 'h=$(bash "$OPSX" notify --help); for c in $(grep -oE "opsx notify [a-z-]+" "$RD" | awk "{print \$3}" | sort -u); do [[ "$h" == *"$c"* ]] || { echo "missing: $c"; exit 1; }; done; grep -q "opsx notify info --show-password" "$RD" && grep -q "opsx notify test" "$RD"'
ok "README: --skip-notify, password rotation, CLIs without hooks" 'bash "$REPO/install.sh" --help | grep -q -- "--skip-notify" && grep -q -- "--skip-notify" "$RD" && grep -q "change-pass" "$RD" && grep -q "Cursor CLI, Codex CLI, OpenCode and Gemini CLI" "$RD"'
ok "config.yaml names the notify helper" 'grep -q "opsx-notify.sh" "$REPO/openspec/config.yaml"'

# ---------------------------------------------------------------- shellcheck
if command -v shellcheck >/dev/null 2>&1; then
  ok "opsx-notify.sh is shellcheck clean" 'shellcheck "$N"'
  ok "this test and the fake ntfy are shellcheck clean (warnings)" 'shellcheck -S warning "$REPO/tests/test-notify.sh" "$REPO/tests/fake-ntfy.sh"'
fi

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
