#!/usr/bin/env bash
# Scripted tests for skills/opsx-run/opsx-sessions.sh (session restore), the
# `type` subcommand and @opsx_goal of opsx-window.sh, `opsx sessions`, and the
# install.sh wiring (Claude SessionStart hook, ~/.tmux.conf block).
#
# Runs on a private tmux server: a `tmux` wrapper on PATH forces
# `-L restore-test-$$` for every call, and TMUX/TMUX_PANE are unset, so your
# tmux sessions are never touched. A stub `claude` records its arguments, cwd
# and pane, optionally runs the hook like Claude Code would, then shows up as
# `claude` in pane_current_command. A stub pr.sh, loginctl and sudo stand in
# for the real ones; HOME and the state dir are scratch.
# Usage: bash tests/test-restore.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016,SC2086
set -u
command -v tmux >/dev/null 2>&1 || { echo "tmux is required"; exit 1; }
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
SELF=$REPO/tests/$(basename -- "$0")
S=$REPO/skills/opsx-run/opsx-sessions.sh
W=$REPO/skills/opsx-run/opsx-window.sh
REAL_TMUX=$(command -v tmux)
SP=$(cd -P -- "$(mktemp -d "${TMPDIR:-/tmp}/restore-test.XXXXXX")" && pwd)
SOCK=restore-test-$$
L="$REAL_TMUX -L $SOCK"
SOCKFILE=${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK
trap '$L kill-server 2>/dev/null; $REAL_TMUX -L $SOCK-b kill-server 2>/dev/null; rm -rf "$SP"; rm -f "$SOCKFILE" "$SOCKFILE-b"' EXIT
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
# wait_for <seconds> <condition>
wait_for(){ local i=0; while [ "$i" -lt $(( $1 * 10 )) ]; do eval "$2" && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

# ---------------------------------------------------------------- stubs
FB=$SP/fakebin; mkdir -p "$FB" "$SP/log" "$SP/home" "$SP/r" "$SP/r2" "$SP/r3" "$SP/r4" "$SP/json"
cat > "$FB/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
# claude: log the call; STUB_HOOK_JSON runs the hook like Claude Code
# (stdout/exit code to STUB_HOOK_OUT); STUB_EXIT=1 exits instead of staying.
cat > "$FB/claude" <<EOF
#!/usr/bin/env bash
{ printf -- '--- call\n'; printf 'cwd=%s\n' "\$PWD"; printf 'pane=%s\n' "\${TMUX_PANE:-}"; printf '%s\n' "\$@"; } >> "$SP/log/claude"
if [ -n "\${STUB_HOOK_JSON:-}" ]; then
  out=\$(bash "$S" hook < "\$STUB_HOOK_JSON"); rc=\$?
  [ -z "\${STUB_HOOK_OUT:-}" ] || { printf '%s' "\$out" > "\$STUB_HOOK_OUT.out"; echo "\$rc" > "\$STUB_HOOK_OUT.rc"; }
fi
[ -n "\${STUB_EXIT:-}" ] && exit 0
exec -a claude sleep 600
EOF
# pr.sh: restart-input 16 prints a goal, 19 a goal led by DELs, 17 is merged; every call is logged.
cat > "$SP/pr.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SP/log/pr"
[ "\$1" = restart-input ] || exit 9
case "\$2" in
  16) echo "/goal keep PR 16 mergeable" ;;
  19) printf '\177\177\177\177\177\177\177\177\177;touch %s/pwned4 #\n' "$SP" ;;
  *)  echo "pr: PR o/app#\$2 is MERGED; only an OPEN PR can be maintained." >&2; exit 1 ;;
esac
EOF
chmod +x "$FB"/* "$SP/pr.sh"
export PATH="$FB:$PATH" HOME=$SP/home SHELL=/bin/bash OPSX_SESSIONS_DIR=$SP/state OPSX_PR_SH=$SP/pr.sh
unset TMUX TMUX_PANE XDG_STATE_HOME OPSX_AGENT_CLI OPSX_MODEL CLAUDECODE CLAUDE_CODE_ENTRYPOINT
ST=$SP/state
# A cd function that refuses `--` (like zoxide's `--cmd cd`): restore must not depend on it.
printf '%s\n' 'cd(){ echo "broken cd: $*" >&2; return 1; }' > "$SP/home/.bashrc"
printf '%s\n' '. ~/.bashrc' > "$SP/home/.bash_profile"

start_server(){
  $L -f /dev/null new-session -d -s keep -x 200 -y 50 'exec sleep 3000'
  $L set-option -g default-size 200x50 >/dev/null 2>&1
  $L set-option -g base-index 0 >/dev/null 2>&1
}
U1=11111111-1111-4111-8111-111111111111
U2=22222222-2222-4222-8222-222222222222
uuid(){ printf '%08d-0000-4000-8000-%012d' "$1" "$1"; }
json(){ # file id cwd mode source
  printf '{"session_id":"%s","cwd":"%s","permission_mode":"%s","hook_event_name":"SessionStart","source":"%s"}\n' "$2" "$3" "$4" "$5" > "$1"
}
live_files(){ find "$ST/live" -type f ! -name '.*' 2>/dev/null | wc -l; }
pane_of(){ $L display -p -t "$1" '#{pane_id}'; }
# Shell pane: wait until bash shows as the current command.
shell_ready(){ wait_for 5 '[ "$($L display -p -t "$1" "#{pane_current_command}")" = bash ]'; }
# run_in_pane <target> <command line>: type into a test shell (test-only send-keys).
run_in_pane(){ $L send-keys -t "$1" -l -- "$2"; $L send-keys -t "$1" Enter; }
calls(){ grep -c '^--- call$' "$SP/log/claude" 2>/dev/null || echo 0; }
# Arguments (after cwd= and pane= lines) of the last claude call that resumed $1.
call_for(){ awk -v id="$1" '
  /^--- call$/ { if (hit) { out = cur }; cur = ""; hit = 0; next }
  { cur = cur $0 "\n"; if ($0 == id) hit = 1 }
  END { if (hit) out = cur; printf "%s", out }' "$SP/log/claude"; }
args_of(){ call_for "$1" | grep -v '^cwd=' | grep -v '^pane='; }
cwd_of(){ call_for "$1" | sed -n 's/^cwd=//p'; }
pane_called(){ call_for "$1" | sed -n 's/^pane=//p'; }
nargs(){ args_of "$1" | wc -l; }
last_arg(){ args_of "$1" | tail -1; }

start_server
$L new-session -d -s work -n w0 -c "$SP/r"

# ================================================================ 1. hook
# ---- 1.3 empty snapshot (2.2 list)
out=$(bash "$S" list); rc=$?
ok "list: empty snapshot says no recorded sessions" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "no recorded sessions"'

# ---- hook records the pane (work:2.0)
json "$SP/json/a" "$U1" /r bypassPermissions startup
$L new-window -d -t work:2 -n w2 -c "$SP/r"
shell_ready work:2
P2=$(pane_of work:2)
run_in_pane work:2 "STUB_HOOK_JSON=$SP/json/a STUB_HOOK_OUT=$SP/h1 STUB_EXIT=1 claude"
wait_for 10 '[ -f "$SP/h1.rc" ]'
out=$(bash "$S" list --live)
ok "hook: exit 0, empty stdout" '[ "$(cat "$SP/h1.rc")" = 0 ] && [ ! -s "$SP/h1.out" ]'
ok "hook: list --live shows work:2.0 with id, cwd /r and mode" 'printf "%s\n" "$out" | grep -F "work:2.0" | grep -F "$U1" | grep -F "/r" | grep -q bypassPermissions'
ok "hook: record lives under live/<server-key>/<pane-id>" '[ "$(find "$ST/live" -type f -name "$P2" | wc -l)" -eq 1 ]'

# ---- clear replaces the id
json "$SP/json/b" "$U2" /r bypassPermissions clear
run_in_pane work:2 "STUB_HOOK_JSON=$SP/json/b STUB_HOOK_OUT=$SP/h2 STUB_EXIT=1 claude"
wait_for 10 '[ -f "$SP/h2.rc" ]'
out=$(bash "$S" list --live)
ok "hook: clear replaces the id (one record, new id)" '[ "$(printf "%s\n" "$out" | grep -c "^work:2.0")" -eq 1 ] && printf "%s" "$out" | grep -q "$U2" && ! printf "%s" "$out" | grep -q "$U1"'

# ---- no permission_mode in the JSON (real Claude Code): taken from claude's command line
U8=$(uuid 8); printf '{"session_id":"%s","cwd":"/r","hook_event_name":"SessionStart","source":"startup"}\n' "$U8" > "$SP/json/m"
$L new-window -d -t work:12 -n w12 -c "$SP/r"
shell_ready work:12
run_in_pane work:12 "STUB_HOOK_JSON=$SP/json/m STUB_HOOK_OUT=$SP/h8 STUB_EXIT=1 claude --model x --permission-mode bypassPermissions"
wait_for 10 '[ -f "$SP/h8.rc" ]'
out=$(bash "$S" list --live)
ok "hook: mode taken from --permission-mode when the JSON has none" '[ "$(cat "$SP/h8.rc")" = 0 ] && printf "%s\n" "$out" | grep -F "work:12.0" | grep -F "$U8" | grep -q "bypassPermissions$"'
U9=$(uuid 9); printf '{"session_id":"%s","cwd":"/r","source":"resume"}\n' "$U9" > "$SP/json/n"
run_in_pane work:12 "STUB_HOOK_JSON=$SP/json/n STUB_HOOK_OUT=$SP/h9 STUB_EXIT=1 claude --permission-mode=acceptEdits"
wait_for 10 '[ -f "$SP/h9.rc" ]'
out=$(bash "$S" list --live)
ok "hook: --permission-mode=<m> form read too" 'printf "%s\n" "$out" | grep -F "work:12.0" | grep -F "$U9" | grep -q "acceptEdits$"'
$L kill-window -t work:12

# ---- stripped TMUX_PANE: the pane is found through process ancestry
U3=$(uuid 3); json "$SP/json/c" "$U3" /r3 default startup
$L new-window -d -t work:4 -n w4 -c "$SP/r3" "exec env -u TMUX_PANE STUB_HOOK_JSON=$SP/json/c STUB_HOOK_OUT=$SP/h3 claude"
wait_for 10 '[ -f "$SP/h3.rc" ]'
P4=$(pane_of work:4)
out=$(bash "$S" list --live)
ok "hook: stripped TMUX_PANE still records the pane" '[ "$(cat "$SP/h3.rc")" = 0 ] && grep -qx "pane=" "$SP/log/claude" && printf "%s\n" "$out" | grep -F "work:4.0" | grep -F "$P4" | grep -q "$U3"'

# ---- outside tmux: no pane anywhere in the ancestry (orphaned to init)
before=$(live_files)
U4=$(uuid 4); json "$SP/json/d" "$U4" /r default startup
( setsid env -u TMUX -u TMUX_PANE bash -c "sleep 0.3; bash '$S' hook < '$SP/json/d' > '$SP/h4.out'; echo \$? > '$SP/h4.rc'" </dev/null >/dev/null 2>&1 & )
wait_for 10 '[ -f "$SP/h4.rc" ]'
ok "hook: outside tmux exits 0, prints nothing, writes no record" '[ "$(cat "$SP/h4.rc")" = 0 ] && [ ! -s "$SP/h4.out" ] && [ "$(live_files)" -eq "$before" ] && ! grep -rqs "$U4" "$ST/live"'

# ---- print mode
U5=$(uuid 5); json "$SP/json/e" "$U5" /r default startup
$L new-window -d -t work:9 -n w9 -c "$SP/r"
shell_ready work:9
run_in_pane work:9 "STUB_HOOK_JSON=$SP/json/e STUB_HOOK_OUT=$SP/h5 STUB_EXIT=1 claude -p 'hi'"
wait_for 10 '[ -f "$SP/h5.rc" ]'
ok "hook: print mode (-p) exits 0 and writes no record" '[ "$(cat "$SP/h5.rc")" = 0 ] && [ ! -s "$SP/h5.out" ] && ! grep -rqs "$U5" "$ST/live" && [ ! -e "$ST/live/"*"/$(pane_of work:9)" ]'
run_in_pane work:9 "STUB_HOOK_JSON=$SP/json/e STUB_HOOK_OUT=$SP/h5b STUB_EXIT=1 claude --print 'hi'"
wait_for 10 '[ -f "$SP/h5b.rc" ]'
ok "hook: --print also skipped" '[ "$(cat "$SP/h5b.rc")" = 0 ] && ! grep -rqs "$U5" "$ST/live"'

# ---- malformed id
json "$SP/json/f" "../x" /r default startup
run_in_pane work:9 "STUB_HOOK_JSON=$SP/json/f STUB_HOOK_OUT=$SP/h6 STUB_EXIT=1 claude"
wait_for 10 '[ -f "$SP/h6.rc" ]'
ok "hook: malformed id ../x exits 0 and writes no record" '[ "$(cat "$SP/h6.rc")" = 0 ] && [ ! -s "$SP/h6.out" ] && [ ! -e "$ST/live/"*"/$(pane_of work:9)" ] && [ ! -e "$ST/x" ] && [ ! -e "$ST/live/x" ]'
printf 'not json' > "$SP/json/g"
run_in_pane work:9 "STUB_HOOK_JSON=$SP/json/g STUB_HOOK_OUT=$SP/h7 STUB_EXIT=1 claude"
wait_for 10 '[ -f "$SP/h7.rc" ]'
ok "hook: garbage input exits 0, no record" '[ "$(cat "$SP/h7.rc")" = 0 ] && [ ! -s "$SP/h7.out" ] && [ ! -e "$ST/live/"*"/$(pane_of work:9)" ]'

# ================================================================ 2. save
# Fresh layout on this server ("A") for the save and restore cases.
$L kill-window -t work:2; $L kill-window -t work:4; $L kill-window -t work:9
UA=$(uuid 10); UC=$(uuid 11); UD=$(uuid 12); UE=$(uuid 13); UF=$(uuid 14); UG=$(uuid 15); UB=$(uuid 16)
json "$SP/json/A" "$UA" "$SP/r" bypassPermissions startup
json "$SP/json/C" "$UC" "$SP/r2" bypassPermissions startup
json "$SP/json/D" "$UD" "$SP/r2" bypassPermissions startup
json "$SP/json/E" "$UE" "$SP/r3" default startup
json "$SP/json/F" "$UF" "$SP/r4" acceptEdits startup
json "$SP/json/G" "$UG" "$SP/r" bypassPermissions startup
json "$SP/json/B" "$UB" "$SP/r" bypassPermissions startup
launch(){ printf 'exec env STUB_HOOK_JSON=%s/json/%s claude' "$SP" "$1"; }
$L new-window -d -t work:2 -n w2 -c "$SP/r" "$(launch A)"
$L new-window -d -t work:6 -n "two panes" -c "$SP/r2" "$(launch C)"
wait_for 10 'grep -rqs "$UC" "$ST/live"'
$L split-window -d -t work:6 -c "$SP/r2" "$(launch D)"
$L new-session -d -s hand -n mine -c "$SP/r3" "$(launch E)"
$L new-window -d -t work:3 -n "ox ·fix-y" -c "$SP/r4" "$(launch F)"
$L new-window -d -t work:7 -n w7 -c "$SP/r" "$(launch G)"
$L new-window -d -t work:8 -n w8 -c "$SP/r"
shell_ready work:8
run_in_pane work:8 "STUB_HOOK_JSON=$SP/json/B STUB_EXIT=1 claude"
for u in "$UA" "$UC" "$UD" "$UE" "$UF" "$UG" "$UB"; do wait_for 10 'grep -rqs "$u" "$ST/live"'; done
wait_for 10 '[ "$($L display -p -t work:8 "#{pane_current_command}")" = bash ]'
wait_for 10 '[ "$($L display -p -t work:2 "#{pane_current_command}")" = claude ]'
# Tags set after the hook ran, then the window moves and is renamed.
$L set-option -w -t work:2 @opsx_change add-auth
$L set-option -w -t work:2 @opsx_agent_cli claude
$L set-option -w -t work:2 @opsx_goal "all gates PASS"
$L move-window -s work:2 -t work:5
$L rename-window -t work:5 "ox ·add-auth"
$L set-option -w -t work:3 @opsx_change fix-y
$L set-option -w -t work:3 @opsx_model sonnet
KEY_A=$(ls "$ST/live")

out=$(bash "$S" save </dev/null); rc=$?
ok "save: exit 0, quiet without a terminal" '[ $rc -eq 0 ] && [ -z "$out" ] && [ -f "$ST/snapshot.tsv" ]'
out=$(bash "$S" list)
ok "save: moved window is work:5.0 named ox ·add-auth" 'printf "%s\n" "$out" | grep -F "$UA" | grep -q "^work:5.0	ox ·add-auth	"'
ok "save: exited conversation (pane now bash) dropped" '! grep -q "$UB" "$ST/snapshot.tsv"'
ok "save: tags set after the hook captured at save" 'grep -F "$UA" "$ST/snapshot.tsv" | grep -q "@opsx_change=add-auth" && grep -F "$UA" "$ST/snapshot.tsv" | grep -q "@opsx_goal=all gates PASS"'
ok "save: two panes of one window are two entries" 'printf "%s\n" "$out" | grep -q "^work:6.0	two panes	.*$UC" && printf "%s\n" "$out" | grep -q "^work:6.1	two panes	.*$UD"'
ok "save: hand-started session recorded" 'printf "%s\n" "$out" | grep -q "^hand:0.0	mine	$SP/r3	$UE	pending"'
ok "save: snapshot written atomically (no temp left)" '[ -z "$(ls "$ST" | grep "snapshot.tsv.tmp")" ]'

# ---- new server: unrestored entries survive a save before any restore
$L kill-server; sleep 1.1
start_server
$L new-session -d -s work -n w0 -c "$SP/r"
for i in 5 6 7; do $L new-window -d -t work:$i -n w$i -c "$SP/r"; done
$L split-window -d -t work:6 -c "$SP/r"
$L respawn-pane -k -t work:7 "exec -a nvim sleep 600" 2>/dev/null || $L respawn-pane -k -t work:7 "bash -c 'exec -a nvim sleep 600'"
$L new-window -d -t work:20 -n w20 -c "$SP/r"
for t in work:5 work:6.0 work:6.1 work:20; do shell_ready $t; done
wait_for 5 '[ "$($L display -p -t work:7 "#{pane_current_command}")" = nvim ]'
KEY_B=$($L display -p '#{socket_path}' | tr -d '\n' | cksum | cut -d' ' -f1)-$($L display -p '#{start_time}')
out=$(bash "$S" save </dev/null); rc=$?
out=$(bash "$S" list)
ok "save on a new server keeps earlier entries pending" '[ $rc -eq 0 ] && [ "$KEY_A" != "$KEY_B" ] && [ "$(printf "%s\n" "$out" | grep -c "	pending$")" -eq 6 ] && grep -q "$UA" "$ST/snapshot.tsv"'
ok "save keeps the dead server's live records while entries are pending" '[ -d "$ST/live/$KEY_A" ]'

# ================================================================ 3. restore
n0=$(calls)
out=$(bash "$S" restore 2>&1); rc=$?
printf '%s\n' "$out" > "$SP/restore1.out"
for u in "$UA" "$UC" "$UD" "$UE" "$UF"; do wait_for 10 'grep -qx -- "$u" "$SP/log/claude"'; done
sleep 0.3
ok "restore: exit 0" '[ $rc -eq 0 ]'
ok "restore: pane resumed in its cwd with --resume <id> --permission-mode bypassPermissions" '[ "$(cwd_of "$UA")" = "$SP/r" ] && [ "$(args_of "$UA" | tr "\n" " ")" = "--resume $UA --permission-mode bypassPermissions " ]'
ok "restore: a shell function named cd does not stop the resume" 'grep -qs "broken cd" "$SP/home/.bashrc" && [ -n "$(cwd_of "$UA")" ]'
ok "restore: two split panes each resume their own id" '[ "$(pane_called "$UC")" = "$($L display -p -t work:6.0 "#{pane_id}")" ] && [ "$(pane_called "$UD")" = "$($L display -p -t work:6.1 "#{pane_id}")" ] && [ "$(cwd_of "$UD")" = "$SP/r2" ]'
ok "restore: missing session created, default mode passes no --permission-mode" '$L list-sessions -F "#{session_name}" | grep -qx hand && [ "$($L display -p -t "=hand:0" "#{window_name}")" = mine ] && [ "$(args_of "$UE" | tr "\n" " ")" = "--resume $UE " ] && [ "$(cwd_of "$UE")" = "$SP/r3" ]'
ok "restore: missing window created with recorded name and cwd" '[ "$($L display -p -t "=work:3" "#{window_name}")" = "ox ·fix-y" ] && [ "$(cwd_of "$UF")" = "$SP/r4" ] && args_of "$UF" | grep -qx -- --resume'
ok "restore: --model from @opsx_model, recorded mode kept" '[ "$(args_of "$UF" | tr "\n" " ")" = "--resume $UF --permission-mode acceptEdits --model sonnet " ]'
ok "restore: busy pane (nvim) left alone, named as skipped, still pending" '! grep -qx -- "$UG" "$SP/log/claude" && grep -q "skipped work:7.0" "$SP/restore1.out" && bash "$S" list | grep "$UG" | grep -q "pending$"'
ok "restore: tags put back (@opsx_change add-auth, @opsx_agent_cli claude)" '$L show-options -w -t "=work:5" | grep -qx "@opsx_change add-auth" && $L show-options -w -t "=work:5" | grep -qx "@opsx_agent_cli claude"'
ok "restore: restored entries marked" '[ "$(bash "$S" list | grep -c "	restored$")" -eq 5 ]'
ok "restore: a status-less window is not continued (no prompt)" '[ "$(nargs "$UA")" -eq 4 ]'
n1=$(calls)
out=$(bash "$S" restore 2>&1); rc=$?
sleep 1
ok "restore twice: no pane receives input" '[ $rc -eq 0 ] && [ "$(calls)" -eq "$n1" ] && [ $((n1 - n0)) -eq 5 ]'

# ---- 7.1 (private server part): opsx-window.sh finds the restored window
printf 'next step\n' > "$SP/prompt.md"
WP=$($L display -p -t "=work:20" '#{pane_id}')
TM="$($L display -p '#{socket_path}'),$($L display -p '#{pid}'),0"
out=$(cd "$SP/r" && TMUX=$TM TMUX_PANE=$WP bash "$W" ensure add-auth --prompt-file "$SP/prompt.md" --agent-cli claude 2>&1); rc=$?
ok "restored change window found by @opsx_change, no duplicate" '[ $rc -eq 0 ] && [ "${out%% *}" = reused ] && [ "$($L list-windows -t work -F "#{@opsx_change}" | grep -cx add-auth)" -eq 1 ]'

# ================================================================ 3.1 opsx-window.sh type
printf 'echo typed-ok > %s/typed\n' "$SP" > "$SP/t.txt"
out=$(bash "$W" type "=work:20.0" --text-file "$SP/t.txt" 2>&1); rc=$?
wait_for 5 '[ -f "$SP/typed" ]'
ok "type: literal text + Enter into a pane" '[ $rc -eq 0 ] && [ "$(cat "$SP/typed" 2>/dev/null)" = typed-ok ]'
out=$(bash "$W" type "=work:99.0" --text-file "$SP/t.txt" 2>&1); rc=$?
ok "type: refuses a missing target" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "no pane"'

# ================================================================ 4. continue unfinished work
# ---- 4.1 ensure --goal-file stores @opsx_goal
printf 'all gates\nPASS\n' > "$SP/g.txt"
out=$(cd "$SP/r" && TMUX=$TM TMUX_PANE=$WP bash "$W" ensure add-goal --prompt-file "$SP/prompt.md" --goal-file "$SP/g.txt" --agent-cli claude 2>&1); rc=$?
GW=$($L list-windows -t work -F '#{window_id} #{@opsx_change}' | awk '$2=="add-goal"{print $1}')
ok "ensure --goal-file stores @opsx_goal (newlines folded)" '[ $rc -eq 0 ] && [ "$($L show-options -wqv -t "$GW" @opsx_goal)" = "all gates PASS" ]'
out=$(cd "$SP/r" && TMUX=$TM TMUX_PANE=$WP bash "$W" ensure add-goal --prompt-file "$SP/prompt.md" --agent-cli claude 2>&1); rc=$?
ok "ensure without --goal-file leaves @opsx_goal" '[ $rc -eq 0 ] && [ "$($L show-options -wqv -t "$GW" @opsx_goal)" = "all gates PASS" ]'

# ---- 4.4 synthetic snapshot of a dead server
NOW=$(date +%s)
entry(){ # widx id status-and-tags...
  local w=$1 id=$2; shift 2
  local line
  line=$(printf 'pending\t999-1\t%%9%s\twork\t%s\tox ·w%s\t0\t%s\t%s\tbypassPermissions\t%s' "$w" "$w" "$w" "$SP/r" "$id" "$NOW")
  for t in "$@"; do line+=$'\t'"$t"; done
  printf '%s\n' "$line"
}
V1=$(uuid 31); V2=$(uuid 32); V3=$(uuid 33); V4=$(uuid 34); V5=$(uuid 35); V6=$(uuid 36)
V7=$(uuid 37); V8=$(uuid 38); V9=$(uuid 39); V10=$(uuid 40)
{
  printf '# test snapshot\n'
  entry 31 "$V1" @opsx_change=feat-a @opsx_agent_cli=claude @opsx_status=busy "@opsx_goal=all gates PASS"
  entry 32 "$V2" @opsx_change=feat-b @opsx_status=busy
  entry 33 "$V3" @opsx_change=feat-c @opsx_status=idle
  entry 34 "$V4" @opsx_change=feat-d @opsx_status=done
  entry 35 "$V5" @opsx_change=feat-e @opsx_status=fail
  entry 36 "$V6" @opsx_change=feat-f @opsx_status=ask
  entry 37 "$V7" @opsx_status=busy
  entry 38 "$V8" @opsx_change=pr-16 @opsx_pr_repo=o/app @opsx_status=idle
  entry 39 "$V9" @opsx_change=pr-17 @opsx_pr_repo=o/app @opsx_status=busy
  entry 40 "$V10" @opsx_change=pr-18 @opsx_pr_repo=o/app @opsx_status=done
} > "$ST/snapshot.tsv"
rm -f "$SP/log/pr"
out=$(bash "$S" restore 2>&1); rc=$?
printf '%s\n' "$out" > "$SP/restore2.out"
for u in "$V1" "$V2" "$V3" "$V4" "$V5" "$V6" "$V7" "$V8" "$V9" "$V10"; do wait_for 10 'grep -qx -- "$u" "$SP/log/claude"'; done
sleep 0.3
FW=$($L list-windows -t work -F '#{window_id} #{@opsx_change}' | awk '$2=="feat-a"{print $1}')
ok "busy change window continued: message names the restart and says continue" '[ $rc -eq 0 ] && [ "$(nargs "$V2")" -eq 5 ] && last_arg "$V2" | grep -q "tmux restarted" && last_arg "$V2" | grep -q "continue the same steps" && last_arg "$V2" | grep -q "where you stopped" && [ "$(args_of "$V2" | head -3 | tr "\n" " ")" = "--resume $V2 --permission-mode " ]'
ok "busy change window marked busy again" '[ "$($L show-options -wqv -t "$FW" @opsx_status)" = busy ] && [ "$($L list-windows -t work -F "#{@opsx_change} #{@opsx_status}" | grep -c "^feat-b busy$")" -eq 1 ]'
ok "goal re-armed: prompt starts with /goal all gates PASS" '[ "$(nargs "$V1")" -eq 5 ] && [[ "$(last_arg "$V1")" == "/goal all gates PASS "* ]] && last_arg "$V1" | grep -q "tmux restarted"'
ok "idle/done/fail/ask change windows only resumed" 'for u in "$V3" "$V4" "$V5" "$V6"; do [ "$(nargs "$u")" -eq 4 ] || exit 1; done'
ok "window without @opsx_change only resumed" '[ "$(nargs "$V7")" -eq 4 ]'
ok "open PR window continued with pr.sh restart-input output" '[ "$(nargs "$V8")" -eq 5 ] && [ "$(last_arg "$V8")" = "/goal keep PR 16 mergeable" ] && grep -qx "restart-input 16 --repo $SP/r" "$SP/log/pr"'
ok "merged PR window only resumed, output names pr-17 and MERGED" '[ "$(nargs "$V9")" -eq 4 ] && grep "pr-17" "$SP/restore2.out" | grep -q MERGED'
ok "done PR window: pr.sh not called, only resumed" '! grep -q "restart-input 18" "$SP/log/pr" && [ "$(nargs "$V10")" -eq 4 ]'
ok "idle window keeps idle, colours back (ox ·feat-c)" '[ "$($L list-windows -t work -F "#{@opsx_change}|#{@opsx_status}|#{window_name}" | grep "^feat-c|")" = "feat-c|idle|ox ·feat-c" ]'

# ---- --no-nudge
W1=$(uuid 41); W2=$(uuid 42)
{
  entry 41 "$W1" @opsx_change=feat-n @opsx_status=busy "@opsx_goal=g"
  entry 42 "$W2" @opsx_change=pr-16 @opsx_pr_repo=o/app @opsx_status=idle
} > "$ST/snapshot.tsv"
rm -f "$SP/log/pr"
out=$(bash "$S" restore --no-nudge 2>&1); rc=$?
for u in "$W1" "$W2"; do wait_for 10 'grep -qx -- "$u" "$SP/log/claude"'; done
sleep 0.3
ok "--no-nudge: both resumed with no prompt, pr.sh not called" '[ $rc -eq 0 ] && [ "$(nargs "$W1")" -eq 4 ] && [ "$(nargs "$W2")" -eq 4 ] && [ ! -e "$SP/log/pr" ]'

# ---- snapshot content cannot inject shell text
X1=$(uuid 51)
{
  printf 'pending\t999-1\t%%60\twork\t50\tw50\t0\t%s\t%s\tdefault\t%s\t@opsx_change=x\t@opsx_status=busy\t@opsx_goal=$(touch %s/pwned)\n' "$SP/r" "$X1" "$NOW" "$SP"
  printf 'pending\t999-1\t%%61\two:rk\t51\tw51\t0\t%s\t%s\tdefault\t%s\n' "$SP/r" "$(uuid 52)" "$NOW"
  printf 'pending\t999-1\t%%62\twork\t52\tw52\t0\t%s\t;touch %s/pwned2\tdefault\t%s\n' "$SP/r" "$SP" "$NOW"
} > "$ST/snapshot.tsv"
out=$(bash "$S" restore 2>&1); rc=$?
wait_for 10 'grep -qx -- "$X1" "$SP/log/claude"'; sleep 0.5
ok "snapshot text is quoted: goal with \$(...) is passed literally" '[ ! -e "$SP/pwned" ] && last_arg "$X1" | grep -qF "/goal \$(touch"'
ok "invalid session name or id refused" '[ ! -e "$SP/pwned2" ] && [ "$(printf "%s\n" "$out" | grep -c "^invalid")" -eq 2 ]'

# ---- control characters and DEL are never typed (cwd refused, prompt stripped)
C1=$(uuid 53); C2=$(uuid 54); C3=$(uuid 55); C4=$(uuid 56)
{
  printf 'pending\t999-1\t%%63\twork\t53\tw53\t0\t%s\025touch %s/pwned5 #\t%s\tdefault\t%s\n' "$SP/r" "$SP" "$C1" "$NOW"
  printf 'pending\t999-1\t%%64\twork\t54\tw54\t0\t%s\177\177\177touch %s/pwned6 #\t%s\tdefault\t%s\n' "$SP/r" "$SP" "$C2" "$NOW"
  printf 'pending\t999-1\t%%65\twork\t55\tw55\t0\t%s\t%s\tdefault\t%s\t@opsx_change=x55\t@opsx_status=busy\t@opsx_goal=\177\177\177\177\177\177\177\177\177;touch %s/pwned3 #\n' "$SP/r" "$C3" "$NOW" "$SP"
  printf 'pending\t999-1\t%%66\twork\t56\tw56\t0\t%s\t%s\tdefault\t%s\t@opsx_change=pr-19\t@opsx_pr_repo=o/app\t@opsx_status=idle\n' "$SP/r" "$C4" "$NOW"
} > "$ST/snapshot.tsv"
out=$(bash "$S" restore 2>&1); rc=$?
printf '%s\n' "$out" > "$SP/restore-cntrl.out"
for u in "$C3" "$C4"; do wait_for 10 'grep -qx -- "$u" "$SP/log/claude"'; done; sleep 1
ok "cwd with Ctrl-U or DEL refused: nothing typed, entry still pending" '[ ! -e "$SP/pwned5" ] && [ ! -e "$SP/pwned6" ] && ! grep -qx -- "$C1" "$SP/log/claude" && ! grep -qx -- "$C2" "$SP/log/claude" && grep -q "^invalid work:53.0" "$SP/restore-cntrl.out" && grep -q "^invalid work:54.0" "$SP/restore-cntrl.out" && bash "$S" list | grep "$C1" | grep -q "pending$"'
ok "DEL in @opsx_goal stripped: goal stays inside the quoted prompt" '[ ! -e "$SP/pwned3" ] && [[ "$(last_arg "$C3")" == "/goal ;touch $SP/pwned3 # tmux restarted"* ]]'
ok "DEL in pr.sh restart-input output stripped: prompt stays quoted" '[ ! -e "$SP/pwned4" ] && [ "$(last_arg "$C4")" = ";touch $SP/pwned4 #" ]'

# ---- dash pane: no `builtin` there, `command cd` resumes
D1=$(uuid 57)
$L new-window -d -t work:57 -n w57 -c "$SP/r" dash
wait_for 5 '[ "$($L display -p -t work:57 "#{pane_current_command}")" = dash ]'
printf 'pending\t999-1\t%%67\twork\t57\tw57\t0\t%s\t%s\tdefault\t%s\n' "$SP/r2" "$D1" "$NOW" > "$ST/snapshot.tsv"
out=$(bash "$S" restore 2>&1); rc=$?
wait_for 10 'grep -qx -- "$D1" "$SP/log/claude"'
ok "dash pane: resumed in the recorded cwd, entry restored" '[ $rc -eq 0 ] && [ "$(cwd_of "$D1")" = "$SP/r2" ] && [ "$(args_of "$D1" | tr "\n" " ")" = "--resume $D1 " ] && bash "$S" list | grep "$D1" | grep -q "restored$"'

# ---- fish pane: fish quoting (\\ and \' are escapes inside '...'), `; and`
# A sleep named fish stands in for fish; a stub opsx-window.sh records the line.
mkdir -p "$SP/fishbin"; ln -sf "$(command -v sleep)" "$SP/fishbin/fish"
printf '#!/usr/bin/env bash\n[ "$1" = type ] && cat "$4" > %q\nexit 0\n' "$SP/typed-fish" > "$SP/win-stub.sh"
$L new-window -d -t work:58 -n w58 -c "$SP/r" "$SP/fishbin/fish 600"
wait_for 5 '[ "$($L display -p -t work:58 "#{pane_current_command}")" = fish ]'
F1=$(uuid 58)
# cwd /tmp/x\';echo INJECTED #   goal it's a \ test   (\ escaped as \\ in the TSV)
printf 'pending\t999-1\t%%68\twork\t58\tw58\t0\t%s\t%s\tbypassPermissions\t%s\t@opsx_change=x58\t@opsx_status=busy\t%s\n' \
  "/tmp/x\\\\';echo INJECTED #" "$F1" "$NOW" "@opsx_goal=it's a \\\\ test" > "$ST/snapshot.tsv"
out=$(OPSX_WINDOW=$SP/win-stub.sh bash "$S" restore 2>&1); rc=$?
FT=$(cat "$SP/typed-fish" 2>/dev/null)
FWANT="builtin cd '/tmp/x\\\\\\';echo INJECTED #'; and claude --resume $F1 --permission-mode bypassPermissions '/goal it\\'s a \\\\ test tmux restarted"
ok "fish pane: cwd fish-quoted, then ; and claude" '[ $rc -eq 0 ] && [[ "$FT" == "$FWANT"* ]]'
FAPOS="window\\'s last task"; FPOSIX="'\\''"
ok "fish pane: apostrophes escaped as backslash-quote, no POSIX quote-backslash-quote form" '[[ "$FT" == *"$FAPOS"* ]] && [[ "$FT" != *"$FPOSIX"* ]]'

# ---- restore with no server running: the server it starts keeps the user's umask
FB2=$SP/fakebin2; mkdir -p "$FB2"
printf '#!/bin/sh\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCK-b" > "$FB2/tmux"; chmod +x "$FB2/tmux"
printf 'pending\t999-1\t%%69\tfresh\t0\tw0\t0\t%s\t%s\tdefault\t%s\n' "$SP/r" "$(uuid 59)" "$NOW" > "$ST/snapshot.tsv"
out=$(umask 022; PATH="$FB2:$PATH" bash "$S" restore 2>&1); rc=$?
PP=$("$REAL_TMUX" -L "$SOCK-b" display -p -t "=fresh:0.0" '#{pane_pid}' 2>/dev/null)
ok "restore starting a server: panes keep umask 022, not the state dir's 077" '[ $rc -eq 0 ] && [ -n "$PP" ] && grep -q "^Umask:[[:space:]]*0022$" "/proc/$PP/status"'
"$REAL_TMUX" -L "$SOCK-b" kill-server 2>/dev/null; rm -f "${SOCKFILE}-b"

# ---- state dir private
chmod 755 "$ST"
bash "$S" save >/dev/null 2>&1
ok "state dir 0700, nothing in it readable by others" '[ "$(stat -c %a "$ST")" = 700 ] && [ -z "$(find "$ST" -perm /077 ! -type l)" ]'

# ================================================================ 5. install
mkdir -p "$SP/ibin"
for b in claude node npm; do printf '#!/bin/sh\necho 1.0.0\n' > "$SP/ibin/$b"; chmod +x "$SP/ibin/$b"; done
cp "$FB/tmux" "$SP/ibin/tmux"
echo no > "$SP/linger"
printf '#!/bin/sh\necho "$*" >> "%s/log/loginctl"\nprintf "Linger=%%s\\n" "$(cat "%s/linger")"\n' "$SP" "$SP" > "$SP/ibin/loginctl"
printf '#!/bin/sh\necho "$*" >> "%s/log/sudo"\nexit 1\n' "$SP" > "$SP/ibin/sudo"
chmod +x "$SP/ibin"/*
run_install(){ # home args...
  local h=$1; shift
  (cd "$REPO" && env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_HOME -u OPENCODE_CONFIG_DIR -u TMUX -u TMUX_PANE \
     -u SUDO_USER -u REAL_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u OPSX_MODELS_CONF -u OPSX_SESSIONS_DIR \
     HOME="$h" USER=tester PATH="$SP/ibin:/usr/bin:/bin" bash ./install.sh --skip-openspec --skip-graphify \
     --skip-commands --skip-mcp --skip-memory --no-backup "$@" </dev/null 2>&1)
}
conf_with_resurrect(){ # file [extra line]
  mkdir -p "$(dirname "$1")"
  {
    echo "set -g mouse on"
    echo "set -g @plugin 'tmux-plugins/tpm'"
    echo "set -g @plugin 'tmux-plugins/tmux-resurrect'"
    echo "set -g @plugin 'tmux-plugins/tmux-continuum'"
    echo "set -g @continuum-restore 'on'"
    [ -z "${2:-}" ] || echo "$2"
    echo "run '~/.tmux/plugins/tpm/tpm'"
  } > "$1"
}
# Number of SessionStart hook commands naming opsx-sessions.sh hook.
n_hooks(){ python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for g in d.get("hooks",{}).get("SessionStart",[]) for h in g.get("hooks",[]) if "opsx-sessions.sh" in h.get("command","") and h["command"].endswith(" hook")))' "$1" 2>/dev/null || echo 0; }
START='# >>> tmux-opsx session restore >>>'
line_of(){ grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

IH=$SP/ih1; mkdir -p "$IH"; conf_with_resurrect "$IH/.tmux.conf"
out=$(run_install "$IH"); rc=$?
printf '%s\n' "$out" > "$SP/install1.out"
TC=$IH/.tmux.conf
ok "install: exit 0" '[ $rc -eq 0 ]'
ok "install: one SessionStart hook naming opsx-sessions.sh hook (startup|resume|clear, timeout)" '[ "$(n_hooks "$IH/.claude/settings.json")" -eq 1 ] && grep -q "startup|resume|clear" "$IH/.claude/settings.json" && grep -q "\"timeout\": 10" "$IH/.claude/settings.json"'
ok "install: opsx-sessions.sh installed executable in every opsx-run skill dir" 'for d in .claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills; do [ -x "$IH/$d/opsx-run/opsx-sessions.sh" ] || exit 1; done'
ok "install: marked block above the tpm run line with both hooks (absolute opsx path)" '[ -n "$(line_of "$TC" "$START")" ] && [ "$(line_of "$TC" "$START")" -lt "$(line_of "$TC" "run '\''~/.tmux/plugins/tpm/tpm'\''")" ] && grep -qxF "set -g @resurrect-hook-post-save-all '\''$IH/.local/bin/opsx sessions save'\''" "$TC" && grep -qxF "set -g @resurrect-hook-post-restore-all '\''$IH/.local/bin/opsx sessions restore'\''" "$TC"'
ok "install: no @continuum-boot without --restore-at-boot, no linger check" '! grep -q "@continuum-boot" "$TC" && [ ! -e "$SP/log/loginctl" ] && ! grep -q enable-linger "$SP/install1.out"'
ok "install: verify step reports the hook and the block" 'grep -q "session restore SessionStart hook in" "$SP/install1.out" && grep -q "session restore block in" "$SP/install1.out"'
# 5.1 dispatch
a=$(env -u OPSX_SESSIONS_DIR HOME="$IH" "$IH/.local/bin/opsx" sessions list 2>&1); b=$(env -u OPSX_SESSIONS_DIR HOME="$IH" bash "$IH/.claude/skills/opsx-run/opsx-sessions.sh" list 2>&1)
ok "opsx sessions list matches opsx-sessions.sh list" '[ -n "$a" ] && [ "$a" = "$b" ] && printf "%s" "$a" | grep -q "no recorded sessions"'
ok "opsx help lists sessions" '"$IH/.local/bin/opsx" help | grep -q "^  sessions"'
cp "$TC" "$SP/tc.before"; cp "$IH/.claude/settings.json" "$SP/settings.before"
out=$(run_install "$IH"); rc=$?
ok "re-install is idempotent: one hook, one block, files unchanged" '[ $rc -eq 0 ] && [ "$(n_hooks "$IH/.claude/settings.json")" -eq 1 ] && [ "$(grep -cxF "$START" "$TC")" -eq 1 ] && cmp -s "$TC" "$SP/tc.before" && cmp -s "$IH/.claude/settings.json" "$SP/settings.before"'

# user hook kept
IH2=$SP/ih2; mkdir -p "$IH2"; conf_with_resurrect "$IH2/.tmux.conf" "set -g @resurrect-hook-post-restore-all 'echo mine'"
cp "$IH2/.tmux.conf" "$SP/tc2.before"
out=$(run_install "$IH2"); rc=$?
ok "user's resurrect hook kept: file unchanged, lines printed" '[ $rc -eq 0 ] && cmp -s "$IH2/.tmux.conf" "$SP/tc2.before" && printf "%s" "$out" | grep -q "@resurrect-hook-post-restore-all '\''$IH2/.local/bin/opsx sessions restore'\''" && printf "%s" "$out" | grep -q "@resurrect-hook-post-save-all"'
# no resurrect: print only
IH3=$SP/ih3; mkdir -p "$IH3"; printf 'set -g mouse on\n' > "$IH3/.tmux.conf"
out=$(run_install "$IH3"); rc=$?
ok "without tmux-resurrect: file unchanged, lines printed, install succeeds" '[ $rc -eq 0 ] && [ "$(cat "$IH3/.tmux.conf")" = "set -g mouse on" ] && printf "%s" "$out" | grep -q "does not load tmux-resurrect" && printf "%s" "$out" | grep -q "@resurrect-hook-post-save-all"'
# --skip-restore
IH4=$SP/ih4; mkdir -p "$IH4"; conf_with_resurrect "$IH4/.tmux.conf"
out=$(run_install "$IH4" --skip-restore); rc=$?
ok "--skip-restore: no hook, no block" '[ $rc -eq 0 ] && ! grep -qs "opsx-sessions.sh" "$IH4/.claude/settings.json" && ! grep -qF "$START" "$IH4/.tmux.conf"'
ok "install --help lists --skip-restore and --restore-at-boot" 'bash "$REPO/install.sh" --help | grep -q -- "--skip-restore" && bash "$REPO/install.sh" --help | grep -q -- "--restore-at-boot"'
# --uninstall keeps an unrelated hook
python3 - "$IH/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["hooks"]["SessionStart"].append({"matcher": "startup", "hooks": [{"type": "command", "command": "echo other"}]})
d["hooks"]["PreToolUse"] = [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}]
json.dump(d, open(p, "w"), indent=2)
PY
out=$(run_install "$IH" --uninstall); rc=$?
ok "--uninstall: unrelated hooks remain, ours and the block are gone" '[ $rc -eq 0 ] && grep -q "echo other" "$IH/.claude/settings.json" && grep -q "echo pre" "$IH/.claude/settings.json" && ! grep -q "opsx-sessions.sh" "$IH/.claude/settings.json" && ! grep -qF "$START" "$TC" && ! grep -q "@resurrect-hook" "$TC" && grep -q "tmux-resurrect" "$TC"'

# 5.4 --restore-at-boot
IH5=$SP/ih5; mkdir -p "$IH5"; conf_with_resurrect "$IH5/.tmux.conf"
echo no > "$SP/linger"; rm -f "$SP/log/sudo" "$SP/log/loginctl"
out=$(run_install "$IH5" --restore-at-boot); rc=$?
ok "--restore-at-boot: @continuum-boot 'on' inside the block" '[ $rc -eq 0 ] && sed -n "/^# >>> tmux-opsx session restore >>>/,/^# <<< tmux-opsx session restore <<</p" "$IH5/.tmux.conf" | grep -qxF "set -g @continuum-boot '\''on'\''"'
ok "--restore-at-boot, Linger=no: prints sudo loginctl enable-linger" 'printf "%s" "$out" | grep -q "sudo loginctl enable-linger tester" && grep -q "show-user tester -p Linger" "$SP/log/loginctl"'
ok "--restore-at-boot: sudo never invoked" '[ ! -e "$SP/log/sudo" ]'
ok "--restore-at-boot: reminds to tmux source the config" 'printf "%s" "$out" | grep -q "tmux source"'
out=$(run_install "$IH5"); rc=$?
ok "re-install without the flag keeps the boot line" '[ $rc -eq 0 ] && grep -c "@continuum-boot" "$IH5/.tmux.conf" | grep -qx 1'
echo yes > "$SP/linger"
out=$(run_install "$IH5" --restore-at-boot); rc=$?
ok "--restore-at-boot, Linger=yes: no enable-linger hint" '[ $rc -eq 0 ] && ! printf "%s" "$out" | grep -q "enable-linger" && [ ! -e "$SP/log/sudo" ]'
sed -i "s|\(@resurrect-hook-post-restore-all '[^']*sessions restore\)'|\1 --no-nudge'|" "$IH5/.tmux.conf"
out=$(run_install "$IH5"); rc=$?
ok "re-install keeps a --no-nudge added to the block" '[ $rc -eq 0 ] && grep -qxF "set -g @resurrect-hook-post-restore-all '\''$IH5/.local/bin/opsx sessions restore --no-nudge'\''" "$IH5/.tmux.conf"'
out=$(run_install "$IH5" --uninstall); rc=$?
ok "--uninstall removes the boot line with the block" '[ $rc -eq 0 ] && ! grep -q "@continuum-boot" "$IH5/.tmux.conf" && ! grep -qF "$START" "$IH5/.tmux.conf"'

# ================================================================ 6. docs
RD=$REPO/README.md
ok "README documents restore (restore cmd, resurrect hook, --restore-at-boot, enable-linger, other CLIs)" 'grep -q "opsx sessions restore" "$RD" && grep -q "@resurrect-hook-post-restore-all" "$RD" && grep -q -- "--restore-at-boot" "$RD" && grep -q "enable-linger" "$RD" && grep -q "other CLIs are not restored" "$RD" && grep -q -- "--skip-restore" "$RD"'
ok "README overview tree names opsx sessions" 'sed -n "/^ your dev harness/,/^\`\`\`/p" "$RD" | grep -q "opsx sessions"'
ok "config.yaml product surface names opsx-sessions.sh" 'grep -q "opsx-sessions.sh" "$REPO/openspec/config.yaml"'

# ================================================================ shellcheck
ok "shellcheck opsx-sessions.sh and this test" '! command -v shellcheck >/dev/null || shellcheck "$S" "$SELF"'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
