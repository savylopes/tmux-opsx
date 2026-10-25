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
  $L kill-server 2>/dev/null
  rm -rf "$SP"
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

# ---------------------------------------------------------------- 3.1 / 3.2 finished
reset_calls
OPSX_NOTIFY_FLUSH_AFTER=2 TMUX_PANE=$P_PLAIN bash "$W" mark fix-x fail >/dev/null
ok "mark fail: pending stamp set" '[[ "$($L show-options -wqv -t "$W_CHG" @opsx_notify_pending)" == fail:* ]]'
wait_calls 1 6; sleep 1
ok "mark fix-x fail, no hook: exactly one push with fix-x and fail in the title" '[ "$(ncalls)" -eq 1 ] && [[ "$(hdr Title)" == *fix-x* ]] && [[ "$(hdr Title)" == *fail* ]] && [ "$(hdr Tags)" = x ]'
ok "flusher cleared the stamp" '[ -z "$($L show-options -wqv -t "$W_CHG" @opsx_notify_pending)" ]'

reset_calls
OPSX_NOTIFY_FLUSH_AFTER=3 TMUX_PANE=$P_PLAIN bash "$W" mark fix-x done >/dev/null
out=$(printf '{"stop_hook_active":false,"last_assistant_message":"all gates passed"}' | TMUX_PANE=$P_CHG bash "$N" hook claude-stop); rc=$?
ok "done then Stop hook: one push with the final message" '[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(ncalls)" -eq 1 ] && [[ "$(hdr Title)" == *fix-x* ]] && [[ "$(hdr Title)" == *done* ]] && body_of | grep -q "all gates passed"'
sleep 4.5
ok "done then Stop hook: the flusher sends nothing later" '[ "$(ncalls)" -eq 1 ]'

reset_calls
printf '{"last_assistant_message":"just a turn"}' | TMUX_PANE=$P_CHG bash "$N" hook claude-stop
ok "Stop hook without a pending done/fail: no push" '[ "$(ncalls)" -eq 0 ]'

reset_calls
OPSX_NOTIFY_FLUSH_AFTER=30 TMUX_PANE=$P_PLAIN bash "$W" mark fix-x done >/dev/null
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
  OPSX_NOTIFY_FLUSH_AFTER=30 TMUX_PANE=$P_PLAIN bash "$W" mark fix-x done >/dev/null
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
o=$(TMUX_PANE=$P_PLAIN bash "$W" mark fix-x done); rc=$?
ok "not configured: mark done works, no pending stamp, no push" '[ $rc -eq 0 ] && [[ "$o" == marked* ]] && [ "$(ncalls)" -eq 0 ] && [ -z "$($L show-options -wqv -t "$W_CHG" @opsx_notify_pending)" ]'
mv "$ENVF.off" "$ENVF"

# ---------------------------------------------------------------- 2.3 prompts
SK=$REPO/skills/opsx-run/SKILL.md
ok "validate dispatcher prompt tells the agent to mark <change> ask before asking" 'sed -n "/^\*\*validate\*\*/,/^\*\*apply\*\*/p" "$SK" | grep -q "^> Before you ask the user a question, run \`opsx-window.sh mark <change> ask\`"'
ok "every dispatcher prompt has the mark ask line" 'a=$(grep -c "^> You are the dispatcher for OpenSpec change" "$SK"); b=$(grep -c "^> Before you ask the user a question, run .opsx-window.sh mark <change> ask." "$SK"); [ "$a" -gt 0 ] && [ "$b" -ge "$a" ]'
ok "opsx-task prompt writer has the mark . ask line" 'grep -q "mark \. ask" "$REPO/skills/opsx-task/opsx-task.sh"'
ok "fork protocol has the mark . ask line" 'grep -q "opsx-window.sh mark \. ask" "$REPO/skills/fork/fork.sh"'

# ---------------------------------------------------------------- shellcheck
if command -v shellcheck >/dev/null 2>&1; then
  ok "opsx-notify.sh is shellcheck clean" 'shellcheck "$N"'
fi

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
