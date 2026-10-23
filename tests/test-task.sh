#!/usr/bin/env bash
# Scripted tests for skills/opsx-task/opsx-task.sh, its SKILL.md, install.sh
# wiring and README.
#
# Uses a scratch git repo, stub agent CLIs (claude, agent, codex, opencode,
# gemini) that only record their arguments and sleep, and a private tmux server:
# a `tmux` wrapper on PATH forces `-L task-test-$$` for every call the script
# makes, so your tmux sessions and real agents are never touched.
# Usage: bash tests/test-task.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016,SC2086
set -u
command -v tmux >/dev/null 2>&1 || { echo "tmux is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
TS=$REPO/skills/opsx-task/opsx-task.sh
REAL_TMUX=$(command -v tmux)
SP=$(cd -P -- "$(mktemp -d "${TMPDIR:-/tmp}/task-test.XXXXXX")" && pwd)
SOCK=task-test-$$
L="$REAL_TMUX -L $SOCK"
SOCK2=task-test-fresh-$$
trap '$L kill-server 2>/dev/null; "$REAL_TMUX" -L "$SOCK2" kill-server 2>/dev/null; rm -rf "$SP"' EXIT
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
# wait_for <seconds> <condition>
wait_for(){ local i=0; while [ "$i" -lt $(( $1 * 10 )) ]; do eval "$2" && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

# ---------------------------------------------------------------- stubs
FB=$SP/fakebin; mkdir -p "$FB" "$SP/log" "$SP/codex/sessions"
cat > "$FB/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
cat > "$FB/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = --help ] && { echo "claude stub"; exit 0; }
{ printf -- '--- call\n'; printf '%s\n' "\$@"; } >> "$SP/log/claude"
for a in "\$@"; do
  if [ "\$a" = -r ] && [ -f "$SP/claude.fail-resume" ]; then echo "No conversation found"; exit 1; fi
  if [ "\$a" = -r ] && [ -f "$SP/claude.exit-resume" ]; then echo "interrupted"; exit 130; fi
done
exec sleep 300
EOF
cat > "$FB/opencode" <<EOF
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = "session list" ]; then
  printf '[{"id":"ses_old","directory":"%s","time":{"created":1000000}}' "\$PWD"
  if [ -f "$SP/opencode.launched" ] && [ "\$(cat "$SP/opencode.mode")" = new ]; then
    printf ',{"id":"ses_new1","directory":"%s","time":{"created":%s000}}' "\$PWD" "\$(date +%s)"
  fi
  printf ']\n'; exit 0
fi
{ printf -- '--- call\n'; printf '%s\n' "\$@"; } >> "$SP/log/opencode"
touch "$SP/opencode.launched"
exec sleep 300
EOF
cat > "$FB/codex" <<EOF
#!/usr/bin/env bash
{ printf -- '--- call\n'; printf '%s\n' "\$@"; } >> "$SP/log/codex"
mkdir -p "\$CODEX_HOME/sessions/2026/10/23"
printf '{"type":"session_meta","payload":{"id":"0199aaaa-bbbb-cccc-dddd-eeeeffff0001","cwd":"%s"}}\n' "\$PWD" \
  > "\$CODEX_HOME/sessions/2026/10/23/rollout-new.jsonl"
exec sleep 300
EOF
cat > "$FB/gemini" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --list-sessions ]; then
  echo "Available sessions:"
  echo "  1. old chat (3 days ago) [11111111-2222-3333-4444-555555555555]"
  [ -f "$SP/gemini.launched" ] && echo "  2. new chat (just now) [aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee]"
  exit 0
fi
{ printf -- '--- call\n'; printf '%s\n' "\$@"; } >> "$SP/log/gemini"
touch "$SP/gemini.launched"
exec sleep 300
EOF
cat > "$FB/agent" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = ls ]; then
  echo "chat 99999999-8888-7777-6666-555555555555 old"
  [ -f "$SP/agent.launched" ] && echo "chat 12345678-1234-1234-1234-123456789abc new"
  exit 0
fi
{ printf -- '--- call\n'; printf '%s\n' "\$@"; } >> "$SP/log/agent"
touch "$SP/agent.launched"
exec sleep 300
EOF
chmod +x "$FB"/*
echo new > "$SP/opencode.mode"

mkdir -p "$SP/claudecfg/projects/-work-app"
export PATH="$FB:$PATH" CODEX_HOME=$SP/codex CLAUDE_CONFIG_DIR=$SP/claudecfg OPSX_TASK_CLAUDE_MODE=default OPSX_TASK_ID_TIMEOUT=4 SHELL=/bin/sh
unset TMUX TMUX_PANE OPSX_AGENT_CLI CLAUDECODE CLAUDE_CODE_ENTRYPOINT CURSOR_AGENT CODEX_SANDBOX GEMINI_CLI
# The private server inherits this PATH, so panes find the stubs.
$L -f /dev/null new-session -d -s keep -x 200 -y 50 'exec sleep 600'
$L set-option -g default-size 200x50 >/dev/null 2>&1

# ---------------------------------------------------------------- scratch repo
G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
R=$SP/work/app; mkdir -p "$R"
$G -C "$R" init -q
printf 'node_modules/\n' > "$R/.gitignore"
$G -C "$R" add .gitignore; $G -C "$R" commit -qm init
T() { "$TS" "$@" --repo "$R"; }
B=$R/.opsx/tasks
hdr() { awk -v k="$2: " 'NR>4{exit} index($0,k)==1{print substr($0,length(k)+1); exit}' "$1"; }
last_call() { awk '/^--- call$/{n++; delete a; i=0; next} {a[++i]=$0} END{for(j=1;j<=i;j++) print a[j]}' "$SP/log/$1"; }
calls() { grep -c '^--- call$' "$SP/log/$1" 2>/dev/null || echo 0; }
has() { $L list-sessions -F '#{session_name}' | grep -qx -- "$1"; }

# ---------------------------------------------------------------- key (1.1)
out=$("$TS" key med-43); rc=$?
ok "key: lower-case key upper-cased" '[ $rc -eq 0 ] && [ "$out" = MED-43 ]'
out=$("$TS" key https://acme.atlassian.net/browse/MED-43); rc=$?
ok "key: tracker URL" '[ $rc -eq 0 ] && [ "$out" = MED-43 ]'
out=$("$TS" key "add rate limiting to the api"); rc=$?
ok "key: no key prints nothing, exit 1" '[ $rc -eq 1 ] && [ -z "$out" ]'
out=$("$TS" key "please look at MED-7 and XY-9"); rc=$?
ok "key: first key in text" '[ $rc -eq 0 ] && [ "$out" = MED-7 ]'
out=$("$TS" key "please look at abc-7 and XY-9"); rc=$?
ok "key: lower-case word in text is not a key" '[ $rc -eq 0 ] && [ "$out" = XY-9 ]'
for t in "convert the importer to utf-8" "support sha-256 hashes" "store dates as ISO-8601" "fix UTF-8 handling" \
         "https://github.com/acme/my-app-2/issues/5" "https://med-43.example.com/x" "see CVE-2024-1234"; do
  out=$("$TS" key "$t"); rc=$?
  ok "key: no false key in '$t'" '[ $rc -eq 1 ] && [ -z "$out" ]'
done
out=$("$TS" key "fix UTF-8 in MED-12"); rc=$?
ok "key: technical names skipped, real key found" '[ $rc -eq 0 ] && [ "$out" = MED-12 ]'
out=$("$TS" key "https://linear.app/acme/issue/eng-12/fix-the-thing"); rc=$?
ok "key: URL path segment (any case)" '[ $rc -eq 0 ] && [ "$out" = ENG-12 ]'
out=$("$TS" key "https://acme.atlassian.net/jira/software/projects/MED/boards/1?selectedIssue=MED-7"); rc=$?
ok "key: URL query value" '[ $rc -eq 0 ] && [ "$out" = MED-7 ]'
printf 'task\n' > "$SP/MED-99.md"
out=$("$TS" key "$SP/MED-99.md"); rc=$?
ok "key: existing file path is never matched" '[ $rc -eq 1 ] && [ -z "$out" ]'
out=$("$TS" key MED-43x 2>/dev/null); rc=$?
ok "key: only whole keys" '[ $rc -eq 1 ]'

# ---------------------------------------------------------------- name (1.2)
out=$(T name rate-limit-api --source "text:add rate limiting"); rc=$?
ok "name: free name" '[ $rc -eq 0 ] && [ "$out" = rate-limit-api ]'
mkdir -p "$B"
printf 'source: text:add rate limiting\ncli: \nsession_id: \ncreated: x\n\nbody\n' > "$B/rate-limit-api.md"
out=$(T name rate-limit-api --source "text:add rate limiting")
ok "name: same source reuses" '[ "$out" = rate-limit-api ]'
sed -i 's/^source: .*/source: text:something else/' "$B/rate-limit-api.md"
out=$(T name rate-limit-api --source "text:add rate limiting")
ok "name: different task gets -2" '[ "$out" = rate-limit-api-2 ]'
printf 'source: file:/x\ncli: \nsession_id: \ncreated: x\n\nb\n' > "$B/rate-limit-api-2.md"
out=$(T name rate-limit-api --source "text:add rate limiting")
ok "name: -2 taken by another task gives -3" '[ "$out" = rate-limit-api-3 ]'
out=$(T name 'a;rm -rf x' --source s 2>/dev/null); rc=$?
ok "name: unsafe name refused, nothing printed" '[ $rc -ne 0 ] && [ -z "$out" ]'
out=$(T name "$(printf 'a%.0s' $(seq 31))" --source s 2>/dev/null); rc=$?
ok "name: 31 characters refused" '[ $rc -ne 0 ] && [ -z "$out" ]'
out=$(T name -- -abc --source s 2>/dev/null); rc=$?
ok "name: leading dash refused" '[ $rc -ne 0 ] && [ -z "$out" ]'
long=abcdefghij-abcdefghij-abcdefgh  # 30 chars
printf 'source: other\ncli: \nsession_id: \ncreated: x\n\nb\n' > "$B/$long.md"
out=$(T name "$long" --source mine)
ok "name: suffix keeps the 30-character limit" '[ ${#out} -le 30 ] && [[ $out == *-2 ]]'
rm -f "$B"/*.md

# ---------------------------------------------------------------- find (same input, any proposed name)
: > "$SP/empty.md"
long80=$(printf 'x%.0s' $(seq 100))
T brief rate-limit-api --source "text:add   rate limiting
to the api" --body-file "$SP/empty.md" >/dev/null
ok "find: text source normalised to one squeezed line" '[ "$(hdr "$B/rate-limit-api.md" source)" = "text:add rate limiting to the api" ]'
out=$(T find --source "text:add rate limiting to the api"); rc=$?
ok "find: same text finds the task" '[ $rc -eq 0 ] && [ "$out" = rate-limit-api ]'
out=$(T find --source "text:add rate limiting to the web"); rc=$?
ok "find: other text finds nothing, exit 1" '[ $rc -eq 1 ] && [ -z "$out" ]'
T brief long-text --source "text:$long80" --body-file "$SP/empty.md" >/dev/null
ok "find: text: cut to its first 80 characters" '[ "$(hdr "$B/long-text.md" source)" = "text:${long80:0:80}" ]'
out=$(T find --source "text:${long80}yyy")
ok "find: long text matches on its first 80 characters" '[ "$out" = long-text ]'
mkdir -p "$SP/docs"; printf 'task\n' > "$SP/docs/t.md"
T brief file-task --source "file:$SP/docs/../docs/t.md" --body-file "$SP/empty.md" >/dev/null
ok "find: file: source made absolute" '[ "$(hdr "$B/file-task.md" source)" = "file:$SP/docs/t.md" ]'
out=$(cd "$SP" && T find --source "file:docs/t.md")
ok "find: relative path to the same file finds the task" '[ "$out" = file-task ]'
out=$(T name limit-requests --source "text:add rate limiting to the api")
ok "name: a different proposed name is not a new task when find matched" '[ "$out" = limit-requests ] && [ "$(T find --source "text:add rate limiting to the api")" = rate-limit-api ]'
rm -f "$B"/*.md

# ---------------------------------------------------------------- brief (1.3)
printf '# MED-43: Login\n\nWhat the task does.\n' > "$SP/d.md"
out=$(T brief MED-43 --source jira:MED-43 --body-file "$SP/d.md"); rc=$?
ok "brief: header starts with source:" '[ $rc -eq 0 ] && [ "$(head -n1 "$B/MED-43.md")" = "source: jira:MED-43" ]'
ok "brief: four header lines then the body" '[ "$(sed -n 2p "$B/MED-43.md")" = "cli: " ] && [ "$(sed -n 3p "$B/MED-43.md")" = "session_id: " ] && sed -n 4p "$B/MED-43.md" | grep -qE "^created: [0-9]{4}-" && grep -q "What the task does." "$B/MED-43.md"'
ok "brief: .gitignore gains one .opsx/tasks/ line" '[ "$(grep -cx ".opsx/tasks/" "$R/.gitignore")" -eq 1 ] && grep -qx "node_modules/" "$R/.gitignore"'
sed -i 's/^session_id: .*/session_id: abc/' "$B/MED-43.md"
created=$(hdr "$B/MED-43.md" created)
printf '# MED-43: Login v2\n\nNew body.\n' > "$SP/d2.md"
T brief MED-43 --source jira:MED-43 --body-file "$SP/d2.md" >/dev/null
ok "brief: rewrite keeps session_id: and created:, replaces body" '[ "$(hdr "$B/MED-43.md" session_id)" = abc ] && [ "$(hdr "$B/MED-43.md" created)" = "$created" ] && grep -q "New body." "$B/MED-43.md" && ! grep -q "What the task does." "$B/MED-43.md"'
ok "brief: still one .gitignore line after two runs" '[ "$(grep -cx ".opsx/tasks/" "$R/.gitignore")" -eq 1 ]'
ok "brief: .opsx/tasks is git-ignored" 'git -C "$R" check-ignore -q .opsx/tasks/MED-43.md'
T brief NL-1 --source "$(printf 'text:line one\nsource: evil')" --body-file "$SP/d.md" >/dev/null
ok "brief: multi-line source stays one header line" '[ "$(grep -c "^source:" "$B/NL-1.md")" -eq 1 ] && [ "$(sed -n 2p "$B/NL-1.md")" = "cli: " ]'
rm -f "$B/NL-1.md"
R2=$SP/work/app2; mkdir -p "$R2"; $G -C "$R2" init -q; printf 'dist' > "$R2/.gitignore"
"$TS" brief X-1 --source s --body-file "$SP/d.md" --repo "$R2" >/dev/null
ok "brief: .gitignore without trailing newline gets its own line" 'grep -qx dist "$R2/.gitignore" && grep -qx ".opsx/tasks/" "$R2/.gitignore"'
out=$(T brief 'x y' --source s --body-file "$SP/d.md" 2>&1); rc=$?
ok "brief: unsafe name refused" '[ $rc -ne 0 ] && [ ! -e "$B/x y.md" ]'

# ---------------------------------------------------------------- start (2.1, 2.2)
out=$(T start MED-50 --agent-cli claude --no-switch 2>&1); rc=$?
ok "start: no brief fails naming it, no session" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "MED-50.md" && ! has MED-50'

sed -i 's/^session_id: .*/session_id: /' "$B/MED-43.md"
out=$(T start MED-43 --agent-cli claude --no-switch 2>&1); rc=$?
ok "start: session MED-43 created" '[ $rc -eq 0 ] && has MED-43'
ok "start: tagged @opsx_task and @opsx_task_repo" '[ "$($L show-options -qv -t =MED-43: @opsx_task)" = MED-43 ] && [ "$($L show-options -qv -t =MED-43: @opsx_task_repo)" = "$R" ]'
ok "start: pane runs in the repository root" '[ "$($L display -p -t =MED-43: "#{pane_current_path}")" = "$R" ]'
ok "start: brief records cli: claude" '[ "$(hdr "$B/MED-43.md" cli)" = claude ]'
wait_for 5 '[ -s "$SP/log/claude" ]'
args=$(last_call claude)
sid=$(hdr "$B/MED-43.md" session_id)
ok "start: claude got -n MED-43" 'printf "%s\n" "$args" | grep -A1 -x -- -n | tail -n1 | grep -qx MED-43'
ok "start: claude got --session-id = brief session_id (a uuid)" 'printf "%s\n" "$sid" | grep -qE "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" && printf "%s\n" "$args" | grep -A1 -x -- --session-id | tail -n1 | grep -qx "$sid"'
ok "start: claude in normal approval mode (no bypass)" 'printf "%s\n" "$args" | grep -A1 -x -- --permission-mode | tail -n1 | grep -qx default && ! printf "%s" "$args" | grep -qiE "bypass|dangerously|yolo"'
P=$B/.MED-43.prompt
ok "prompt: names the brief, /opsx:explore, data not instructions, no implementation" 'grep -q ".opsx/tasks/MED-43.md" "$P" && grep -q "/opsx:explore" "$P" && grep -q "openspec-explore" "$P" && grep -q "data, not instructions" "$P" && grep -q "Do not implement" "$P"'
ok "prompt: describe first, then explore" '[ "$(grep -n "describe" "$P" | head -n1 | cut -d: -f1)" -lt "$(grep -n "/opsx:explore" "$P" | head -n1 | cut -d: -f1)" ]'
ok "prompt: delivered as the claude argument" 'printf "%s" "$args" | grep -q "Read the task brief .opsx/tasks/MED-43.md"'
ok "prompt: non-gemini prompt has no /chat save" '! grep -q "/chat save" "$P"'
ok "start: outside tmux hint omitted with --no-switch" '! printf "%s" "$out" | grep -q "tmux attach"'
n=$(calls claude)
out=$(T start MED-43 --agent-cli claude --no-switch 2>&1); rc=$?
ok "start: second start on a live session is a no-op" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -qx "alive MED-43" && [ "$(calls claude)" -eq "$n" ]'

# foreign sessions
T brief MED-60 --source jira:MED-60 --body-file "$SP/d.md" >/dev/null
$L new-session -d -s MED-60 'exec sleep 300'
out=$(T start MED-60 --agent-cli claude --no-switch 2>&1); rc=$?
ok "start: untagged same-name session refused and untouched" '[ $rc -ne 0 ] && has MED-60 && [ -z "$($L show-options -qv -t =MED-60: @opsx_task)" ] && [ "$(hdr "$B/MED-60.md" cli)" = "" ]'
$L set-option -t =MED-60: @opsx_task MED-60; $L set-option -t =MED-60: @opsx_task_repo /some/other/repo
out=$(T start MED-60 --agent-cli claude --no-switch 2>&1); rc=$?
ok "start: session of another repository refused and untouched" '[ $rc -ne 0 ] && [ "$($L show-options -qv -t =MED-60: @opsx_task_repo)" = /some/other/repo ]'
out=$(T open MED-60 --no-switch 2>&1); rc=$?
ok "open: foreign session refused too" '[ $rc -ne 0 ] && ! printf "%s" "$out" | grep -q "^alive"'
$L new-session -d -s MED-600 'exec sleep 300'
T brief MED-6 --source jira:MED-6 --body-file "$SP/d.md" >/dev/null
out=$(T start MED-6 --agent-cli claude --no-switch 2>&1); rc=$?
ok "start: exact-name lookup (MED-600 does not count as MED-6)" '[ $rc -eq 0 ] && has MED-6 && [ "$($L show-options -qv -t =MED-600: @opsx_task)" = "" ]'
$L kill-session -t =MED-6; $L kill-session -t =MED-600

# captured ids
T brief OC-1 --source text:oc --body-file "$SP/d.md" >/dev/null
out=$(T start OC-1 --agent-cli opencode --no-switch 2>&1); rc=$?
ok "capture: opencode session newer than launch recorded" '[ $rc -eq 0 ] && [ "$(hdr "$B/OC-1.md" session_id)" = ses_new1 ] && [ "$(hdr "$B/OC-1.md" cli)" = opencode ]'
ok "capture: opencode launched with the plan agent (edits denied, shell asks) and the prompt" 'last_call opencode | grep -A1 -x -- --agent | tail -n1 | grep -qx plan && last_call opencode | grep -q "Read the task brief .opsx/tasks/OC-1.md"'
$L kill-session -t =OC-1; rm -f "$SP/opencode.launched"; echo none > "$SP/opencode.mode"
T brief OC-2 --source text:oc2 --body-file "$SP/d.md" >/dev/null
t0=$(date +%s)
out=$(OPSX_TASK_ID_TIMEOUT=1 T start OC-2 --agent-cli opencode --no-switch 2>&1); rc=$?
ok "capture: no newer session leaves session_id: empty, start succeeds" '[ $rc -eq 0 ] && [ -z "$(hdr "$B/OC-2.md" session_id)" ] && grep -qx "session_id: " "$B/OC-2.md" && has OC-2'
ok "capture: gives up within the timeout" '[ $(( $(date +%s) - t0 )) -le 6 ]'
$L kill-session -t =OC-2; echo new > "$SP/opencode.mode"
T brief CX-1 --source text:cx --body-file "$SP/d.md" >/dev/null
out=$(T start CX-1 --agent-cli codex --no-switch 2>&1); rc=$?
ok "capture: codex id from the newest ~/.codex/sessions file" '[ $rc -eq 0 ] && [ "$(hdr "$B/CX-1.md" session_id)" = 0199aaaa-bbbb-cccc-dddd-eeeeffff0001 ]'
ok "capture: codex in a read-only sandbox, writes on request" 'last_call codex | grep -A1 -x -- --sandbox | tail -n1 | grep -qx read-only && last_call codex | grep -qx on-request && ! last_call codex | grep -qx workspace-write'
$L kill-session -t =CX-1
T brief GM-1 --source text:gm --body-file "$SP/d.md" >/dev/null
out=$(T start GM-1 --agent-cli gemini --no-switch 2>&1); rc=$?
ok "capture: gemini id from --list-sessions" '[ $rc -eq 0 ] && [ "$(hdr "$B/GM-1.md" session_id)" = aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee ]'
ok "prompt: gemini asks for /chat save <name>" 'grep -q "/chat save GM-1" "$B/.GM-1.prompt" && last_call gemini | grep -qx default'
$L kill-session -t =GM-1
T brief CU-1 --source text:cu --body-file "$SP/d.md" >/dev/null
out=$(T start CU-1 --agent-cli cursor --no-switch 2>&1); rc=$?
ok "capture: cursor (agent) id from agent ls" '[ $rc -eq 0 ] && [ "$(hdr "$B/CU-1.md" cli)" = agent ] && [ "$(hdr "$B/CU-1.md" session_id)" = 12345678-1234-1234-1234-123456789abc ]'
ok "capture: cursor without --mode ask" '! last_call agent | grep -qx -- --mode'
$L kill-session -t =CU-1

# outside tmux: attach hint (detached from this process tree so no $TMUX is recovered)
T brief OUT-1 --source text:out --body-file "$SP/d.md" >/dev/null
( setsid env -u TMUX -u TMUX_PANE sh -c '"$1" start OUT-1 --agent-cli claude --repo "$2" > "$3/out1" 2>&1; echo $? > "$3/out1.rc"' _ "$TS" "$R" "$SP" & )
wait_for 15 '[ -s "$SP/out1.rc" ]'
ok "start: outside tmux prints tmux attach -t <name>" '[ "$(cat "$SP/out1.rc")" = 0 ] && grep -qx "tmux attach -t OUT-1" "$SP/out1"'
$L kill-session -t =OUT-1

# inside tmux: switch-client for the caller's client (no client attached here)
$L new-session -d -s caller 'exec sleep 300'
CP=$($L display -p -t =caller: '#{pane_id}'); sock=$($L display -p '#{socket_path}'); spid=$($L display -p '#{pid}')
T brief IN-1 --source text:in --body-file "$SP/d.md" >/dev/null
out=$(TMUX="$sock,$spid,0" TMUX_PANE=$CP T start IN-1 --agent-cli claude 2>&1); rc=$?
ok "start: inside tmux tries to switch, never prints attach" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "switch-client -t IN-1" && ! printf "%s" "$out" | grep -q "tmux attach"'
$L kill-session -t =IN-1

# ---------------------------------------------------------------- open (2.3)
n=$(calls claude)
before=$($L capture-pane -p -t =MED-43:)
out=$(T open MED-43 --no-switch 2>&1); rc=$?
sleep 0.5
ok "open: alive session prints alive, creates and sends nothing" '[ $rc -eq 0 ] && [ "$out" = "alive MED-43" ] && [ "$(calls claude)" -eq "$n" ] && [ "$($L capture-pane -p -t =MED-43:)" = "$before" ]'

$L kill-session -t =MED-43
sid=$(hdr "$B/MED-43.md" session_id)
out=$(T open MED-43 --no-switch 2>&1); rc=$?
wait_for 5 '[ "$(calls claude)" -gt "$n" ]'
ok "open: gone session with id resumes claude -r <id>" '[ $rc -eq 0 ] && has MED-43 && last_call claude | grep -A1 -x -- -r | tail -n1 | grep -qx "$sid" && printf "%s" "$out" | grep -q "^resumed MED-43"'
ok "open: resume sends no new prompt" '! last_call claude | grep -q "Read the task brief"'
ok "open: resumed session is tagged for this repo" '[ "$($L show-options -qv -t =MED-43: @opsx_task_repo)" = "$R" ]'

$L kill-session -t =MED-43
touch "$SP/claude.fail-resume"
out=$(T open MED-43 --no-switch 2>&1); rc=$?
wait_for 8 '[ -z "$(hdr "$B/MED-43.md" session_id)" ]'
ok "open: failed resume clears session_id:" '[ $rc -eq 0 ] && [ -z "$(hdr "$B/MED-43.md" session_id)" ] && grep -q "New body." "$B/MED-43.md"'
wait_for 3 '$L capture-pane -J -p -t =MED-43: | grep -q "resume failed"'
ok "open: failed resume leaves a message in the pane" '$L capture-pane -J -p -t =MED-43: | grep -q "resume failed, run /opsx-task MED-43 again to restart from the brief"'
rm -f "$SP/claude.fail-resume"
$L kill-session -t =MED-43

# A non-zero exit after a normal session keeps the id the CLI still knows.
sed -i 's/^session_id: .*/session_id: 0e0e0e0e-1111-2222-3333-444455556666/' "$B/MED-43.md"
touch "$SP/claudecfg/projects/-work-app/0e0e0e0e-1111-2222-3333-444455556666.jsonl" "$SP/claude.exit-resume"
out=$(T open MED-43 --no-switch 2>&1); rc=$?
wait_for 8 '$L capture-pane -J -p -t =MED-43: | grep -q "session id kept"'
ok "open: non-zero exit of a known conversation keeps session_id:" '[ $rc -eq 0 ] && [ "$(hdr "$B/MED-43.md" session_id)" = 0e0e0e0e-1111-2222-3333-444455556666 ] && $L capture-pane -J -p -t =MED-43: | grep -q "claude exited with code 130; session id kept" && ! $L capture-pane -J -p -t =MED-43: | grep -q "resume failed"'
rm -f "$SP/claude.exit-resume"
$L kill-session -t =MED-43
"$TS" _resume-failed MED-43 --repo "$R" --cli claude --sid 0e0e0e0e-1111-2222-3333-444455556666 --rc 1 --elapsed 0 >/dev/null
ok "_resume-failed: known id kept even on a fast exit" '[ "$(hdr "$B/MED-43.md" session_id)" = 0e0e0e0e-1111-2222-3333-444455556666 ]'
"$TS" _resume-failed MED-43 --repo "$R" --cli claude --sid 99999999-1111-2222-3333-444455556666 --rc 1 --elapsed 0 >/dev/null
ok "_resume-failed: never clears an id other than the one tried" '[ "$(hdr "$B/MED-43.md" session_id)" = 0e0e0e0e-1111-2222-3333-444455556666 ]'
mv "$SP/claudecfg/projects" "$SP/claudecfg/projects.off"
"$TS" _resume-failed MED-43 --repo "$R" --cli claude --sid 0e0e0e0e-1111-2222-3333-444455556666 --rc 1 --elapsed 60 >/dev/null
ok "_resume-failed: cannot check, long run keeps the id" '[ "$(hdr "$B/MED-43.md" session_id)" = 0e0e0e0e-1111-2222-3333-444455556666 ]'
out=$("$TS" _resume-failed MED-43 --repo "$R" --cli claude --sid 0e0e0e0e-1111-2222-3333-444455556666 --rc 1 --elapsed 1)
ok "_resume-failed: cannot check, fast exit clears the id" '[ -z "$(hdr "$B/MED-43.md" session_id)" ] && printf "%s" "$out" | grep -q "resume failed"'
mv "$SP/claudecfg/projects.off" "$SP/claudecfg/projects"

n=$(calls claude)
out=$(T open MED-43 --no-switch 2>&1); rc=$?
wait_for 5 '[ "$(calls claude)" -gt "$n" ]'
ok "open: no id restarts from the brief and says so" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "restarts from the brief" && has MED-43 && last_call claude | grep -q "Read the task brief .opsx/tasks/MED-43.md"'
ok "open: restart records a new session id" '[ -n "$(hdr "$B/MED-43.md" session_id)" ] && last_call claude | grep -qx -- "$(hdr "$B/MED-43.md" session_id)"'
ok "open: never resumes a latest conversation" '! grep -qxE -- "--continue|-c|--resume|resume --last|--last" "$SP/log/claude"'

$L kill-session -t =OC-2 2>/dev/null
n=$(calls opencode)
out=$(T open OC-1 --no-switch 2>&1); rc=$?
wait_for 5 '[ "$(calls opencode)" -gt "$n" ]'
ok "open: opencode resumes with -s <id>" '[ $rc -eq 0 ] && last_call opencode | grep -A1 -x -- -s | tail -n1 | grep -qx ses_new1'
ok "open: opencode resumes in the plan agent" 'last_call opencode | grep -A1 -x -- --agent | tail -n1 | grep -qx plan'
$L kill-session -t =OC-1
n=$(calls codex)
T open CX-1 --no-switch >/dev/null 2>&1
wait_for 5 '[ "$(calls codex)" -gt "$n" ]'
ok "open: codex resumes with resume <id>" 'last_call codex | grep -A1 -x resume | tail -n1 | grep -qx 0199aaaa-bbbb-cccc-dddd-eeeeffff0001'
ok "open: codex resumes in a read-only sandbox" 'last_call codex | grep -A1 -x -- --sandbox | tail -n1 | grep -qx read-only'
$L kill-session -t =CX-1
n=$(calls gemini)
T open GM-1 --no-switch >/dev/null 2>&1
wait_for 5 '[ "$(calls gemini)" -gt "$n" ]'
ok "open: gemini resumes with --resume <id>" 'last_call gemini | grep -A1 -x -- --resume | tail -n1 | grep -qx aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$L kill-session -t =GM-1
n=$(calls agent)
T open CU-1 --no-switch >/dev/null 2>&1
wait_for 5 '[ "$(calls agent)" -gt "$n" ]'
ok "open: cursor resumes with --resume=<id>" 'last_call agent | grep -qx -- "--resume=12345678-1234-1234-1234-123456789abc"'
$L kill-session -t =CU-1
out=$(T open NOPE-1 --no-switch 2>&1); rc=$?
ok "open: unknown task without a brief fails" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "NOPE-1.md" && ! has NOPE-1'

# ---------------------------------------------------------------- refresh (2.4)
sid=$(hdr "$B/MED-43.md" session_id)
printf '# MED-43: Login v3\n\nRefreshed body.\n' > "$SP/new.md"
out=$(T refresh MED-43 --body-file "$SP/new.md" 2>&1); rc=$?
ok "refresh: new description, old header" '[ $rc -eq 0 ] && grep -q "Refreshed body." "$B/MED-43.md" && ! grep -q "New body." "$B/MED-43.md" && [ "$(hdr "$B/MED-43.md" session_id)" = "$sid" ] && [ "$(hdr "$B/MED-43.md" source)" = jira:MED-43 ]'
wait_for 3 '$L capture-pane -J -p -t =MED-43: | grep -q "MED-43.md was refreshed"'
ok "refresh: live session received one message naming the brief" 'printf "%s" "$out" | grep -qx "notified MED-43" && [ "$($L capture-pane -J -p -t =MED-43: | grep -c ".opsx/tasks/MED-43.md was refreshed")" -eq 1 ]'
# A split shell pane that is active never gets the message: only the agent pane.
AP=$($L show-options -qv -t =MED-43: @opsx_task_pane)
ok "refresh: start/open record the agent pane id" 'printf "%s" "$AP" | grep -qE "^%[0-9]+$" && [ "$($L display -p -t "$AP" "#{session_name}")" = MED-43 ]'
SPN=$($L split-window -P -F '#{pane_id}' -t =MED-43: "cat > '$SP/shellpane'")
$L select-pane -t "$SPN"
out=$(T refresh MED-43 --body-file "$SP/new.md" 2>&1); rc=$?
wait_for 3 '[ "$($L capture-pane -J -p -t "$AP" | grep -c ".opsx/tasks/MED-43.md was refreshed")" -eq 2 ]'
ok "refresh: sent to the recorded agent pane, not the active split pane" '[ $rc -eq 0 ] && [ "$($L display -p -t =MED-43: "#{pane_id}")" = "$SPN" ] && [ "$($L capture-pane -J -p -t "$AP" | grep -c ".opsx/tasks/MED-43.md was refreshed")" -eq 2 ] && ! grep -q refreshed "$SP/shellpane" 2>/dev/null'
$L kill-pane -t "$SPN"
$L set-option -t =MED-43: @opsx_task_pane "%99999" >/dev/null
out=$(T refresh MED-43 --body-file "$SP/new.md" 2>&1); rc=$?
ok "refresh: unknown agent pane sends nothing, says so" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "agent pane of session MED-43 not found" && ! printf "%s" "$out" | grep -q notified'
$L set-option -t =MED-43: @opsx_task_pane "$AP" >/dev/null
out=$(T refresh OC-2 --body-file "$SP/new.md" 2>&1); rc=$?
ok "refresh: no live session only rewrites" '[ $rc -eq 0 ] && grep -q "Refreshed body." "$B/OC-2.md" && printf "%s" "$out" | grep -q "not running"'

# ---------------------------------------------------------------- safety
ok "safety: launch commands read the prompt from a file" '! $L list-panes -a -F "#{pane_start_command}" | grep -q "What the task does"'
mkdir -p "$SP/evil"
printf '$(touch %s/pwned) `touch %s/pwned2`\n' "$SP" "$SP" > "$SP/evil.md"
T brief EV-1 --source 'text:$(touch '"$SP"'/pwned3)' --body-file "$SP/evil.md" >/dev/null
T start EV-1 --agent-cli claude --no-switch >/dev/null 2>&1
T refresh EV-1 --body-file "$SP/evil.md" >/dev/null 2>&1
sleep 1
ok "safety: task text is never executed" '[ ! -e "$SP/pwned" ] && [ ! -e "$SP/pwned2" ] && [ ! -e "$SP/pwned3" ]'
$L kill-session -t =EV-1
ok "safety: lock file under .opsx/tasks" '[ -f "$B/.lock" ]'
ok "safety: user tmux server untouched (all sessions on the private socket)" '$L has-session -t =keep'

# ---------------------------------------------------------------- symlinks planted by a clone (F1)
R2=$SP/work/clone; mkdir -p "$R2"
$G -C "$R2" init -q; printf 'x\n' > "$R2/f"; $G -C "$R2" add f; $G -C "$R2" commit -qm init
V=$SP/victims; mkdir -p "$V"
for v in lock prompt gi brief; do printf 'precious-%s\n' "$v" > "$V/$v"; done
mkdir -p "$R2/.opsx/tasks"
ln -s "$V/lock" "$R2/.opsx/tasks/.lock"; ln -s "$V/prompt" "$R2/.opsx/tasks/.T1.prompt"
out=$("$TS" brief T1 --source text:x --body-file "$SP/d.md" --repo "$R2" 2>&1); rc=$?
ok "symlink: brief in a clone with planted links still works" '[ $rc -eq 0 ] && [ -f "$R2/.opsx/tasks/T1.md" ] && [ ! -L "$R2/.opsx/tasks/T1.md" ]'
out=$("$TS" start T1 --agent-cli claude --no-switch --repo "$R2" 2>&1); rc=$?
ok "symlink: start refuses a symlinked .lock, victim untouched" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "symlink" && [ "$(cat "$V/lock")" = precious-lock ] && ! has T1'
rm "$R2/.opsx/tasks/.lock"
out=$("$TS" start T1 --agent-cli claude --no-switch --repo "$R2" 2>&1); rc=$?
ok "symlink: start refuses a symlinked prompt file, victim untouched" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "symlink" && [ "$(cat "$V/prompt")" = precious-prompt ] && ! has T1'
ok "symlink: .lock is created as a regular file" '[ -f "$R2/.opsx/tasks/.lock" ] && [ ! -L "$R2/.opsx/tasks/.lock" ]'
rm "$R2/.opsx/tasks/.T1.prompt"
ln -s "$V/brief" "$R2/.opsx/tasks/T2.md"
out=$("$TS" brief T2 --source text:y --body-file "$SP/d.md" --repo "$R2" 2>&1); rc=$?
ok "symlink: brief refuses a symlinked brief file" '[ $rc -ne 0 ] && [ "$(cat "$V/brief")" = precious-brief ]'
out=$("$TS" open T2 --agent-cli claude --no-switch --repo "$R2" 2>&1); rc=$?
ok "symlink: open refuses a symlinked brief file" '[ $rc -ne 0 ] && ! has T2'
rm -rf "$R2/.opsx"; mkdir -p "$V/tasksdir" "$R2/.opsx"; ln -s "$V/tasksdir" "$R2/.opsx/tasks"
out=$("$TS" brief T3 --source text:z --body-file "$SP/d.md" --repo "$R2" 2>&1); rc=$?
ok "symlink: brief refuses a symlinked .opsx/tasks" '[ $rc -ne 0 ] && [ -z "$(ls -A "$V/tasksdir")" ]'
rm -rf "$R2/.opsx"; ln -s "$V/tasksdir" "$R2/.opsx"
out=$("$TS" brief T3 --source text:z --body-file "$SP/d.md" --repo "$R2" 2>&1); rc=$?
ok "symlink: brief refuses a symlinked .opsx" '[ $rc -ne 0 ] && [ -z "$(ls -A "$V/tasksdir")" ]'
rm -f "$R2/.opsx" "$R2/.gitignore"; ln -s "$V/gi" "$R2/.gitignore"
out=$("$TS" brief T3 --source text:z --body-file "$SP/d.md" --repo "$R2" 2>&1); rc=$?
ok "symlink: brief refuses a symlinked .gitignore, writes nothing" '[ $rc -ne 0 ] && [ "$(cat "$V/gi")" = precious-gi ] && [ ! -e "$R2/.opsx/tasks/T3.md" ]'
rm -f "$R2/.gitignore"

# ---------------------------------------------------------------- planted session ids (F4)
printf 'source: jira:PL-1\ncli: claude\nsession_id: my-other-conversation\ncreated: x\n\nb\n' > "$B/PL-1.md"
n=$(calls claude)
out=$(T open PL-1 --no-switch 2>&1); rc=$?
wait_for 5 '[ "$(calls claude)" -gt "$n" ]'
ok "planted id: claude conversation name is never resumed" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "restarts from the brief" && ! last_call claude | grep -qx -- -r && ! last_call claude | grep -qx my-other-conversation'
$L kill-session -t =PL-1
printf 'source: jira:PL-2\ncli: codex\nsession_id: some-thread-name\ncreated: x\n\nb\n' > "$B/PL-2.md"
n=$(calls codex)
out=$(T open PL-2 --no-switch 2>&1); rc=$?
wait_for 5 '[ "$(calls codex)" -gt "$n" ]'
ok "planted id: codex non-uuid id is never resumed" '[ $rc -eq 0 ] && ! last_call codex | grep -qx resume && ! last_call codex | grep -qx some-thread-name'
$L kill-session -t =PL-2

# ---------------------------------------------------------------- fresh tmux server (start launches it)
# No server runs on this socket: the first start forks it and must not hand it the lock.
FB2=$SP/fakebin2; mkdir -p "$FB2"
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK2" > "$FB2/tmux"; chmod +x "$FB2/tmux"
"$REAL_TMUX" -L "$SOCK2" kill-server 2>/dev/null
ok "fresh: no server on the second socket" '! "$REAL_TMUX" -L "$SOCK2" list-sessions >/dev/null 2>&1'
T brief A-1 --source jira:A-1 --body-file "$SP/d.md" >/dev/null
T brief A-2 --source jira:A-2 --body-file "$SP/d.md" >/dev/null
t0=$(date +%s)
out=$(PATH="$FB2:$PATH" timeout 30 "$TS" start A-1 --agent-cli claude --no-switch --repo "$R" 2>&1); rc1=$?
spid=$("$REAL_TMUX" -L "$SOCK2" display -p '#{pid}' 2>/dev/null)
ok "fresh: first start launched the server" '[ $rc1 -eq 0 ] && [ -n "$spid" ] && "$REAL_TMUX" -L "$SOCK2" has-session -t =A-1'
ok "fresh: the server does not hold .opsx/tasks/.lock" '! ls -l /proc/$spid/fd 2>/dev/null | grep -q "/.opsx/tasks/.lock"'
out=$(PATH="$FB2:$PATH" timeout 30 "$TS" start A-2 --agent-cli claude --no-switch --repo "$R" 2>&1); rc2=$?
ok "fresh: a second start on that server is not blocked by the lock" '[ $rc2 -eq 0 ] && "$REAL_TMUX" -L "$SOCK2" has-session -t =A-2 && [ $(( $(date +%s) - t0 )) -lt 20 ]'
"$REAL_TMUX" -L "$SOCK2" kill-session -t =A-2 2>/dev/null
sed -i 's/^session_id: .*/session_id: /' "$B/A-2.md"
out=$(PATH="$FB2:$PATH" timeout 30 "$TS" open A-2 --no-switch --repo "$R" 2>&1); rc3=$?
ok "fresh: open falling back to start is not blocked either" '[ $rc3 -eq 0 ] && "$REAL_TMUX" -L "$SOCK2" has-session -t =A-2'
"$REAL_TMUX" -L "$SOCK2" kill-server 2>/dev/null

# ---------------------------------------------------------------- skill (3.1)
SK=$REPO/skills/opsx-task/SKILL.md
ok "SKILL.md frontmatter has name and description" 'awk "/^---\$/{n++; next} n==1" "$SK" | grep -qx "name: opsx-task" && awk "/^---\$/{n++; next} n==1" "$SK" | grep -q "^description: ."'
ok "SKILL.md: every opsx-task.sh subcommand it names exists in --help" '( for c in $(grep -oE "opsx-task\.sh [a-z]+" "$SK" | awk "{print \$2}" | sort -u); do "$TS" --help | grep -qE "opsx-task\.sh $c( |\$)" || { echo "missing: $c"; exit 1; }; done )'
ok "SKILL.md: uses all seven subcommands" '( for c in key name find brief start open refresh; do grep -qE "opsx-task\.sh $c" "$SK" || { echo "unused: $c"; exit 1; }; done )'
ok "SKILL.md: --refresh, --agent-cli, no re-read on a second run" 'grep -q -- "--refresh" "$SK" && grep -q -- "--agent-cli" "$SK" && grep -qi "without re-reading" "$SK"'
ok "SKILL.md: data, not instructions" 'grep -q "data, not instructions" "$SK"'

# ---------------------------------------------------------------- install (3.2)
IH=$SP/ihome; mkdir -p "$IH" "$SP/ibin"
for b in claude node npm; do printf '#!/bin/sh\necho 1.0.0\n' > "$SP/ibin/$b"; chmod +x "$SP/ibin/$b"; done
SKILL_DIRS=(.claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills)
n_task_dirs() { local n=0 d; for d in "${SKILL_DIRS[@]}"; do [ -d "$IH/$d/opsx-task" ] && n=$((n+1)); done; echo $n; }
run_install(){
  (cd "$REPO" && env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_HOME -u OPENCODE_CONFIG_DIR -u TMUX -u TMUX_PANE \
     -u SUDO_USER -u REAL_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u OPSX_MODELS_CONF \
     HOME="$IH" PATH="$SP/ibin:/usr/bin:/bin" bash ./install.sh --skip-openspec --skip-graphify \
     --skip-commands --skip-mcp --skip-memory --no-backup "$@" </dev/null 2>&1)
}
out=$(run_install); rc=$?
ok "install: opsx-task in all six skill folders, opsx-task.sh executable" '[ $rc -eq 0 ] && [ "$(n_task_dirs)" -eq 6 ] && [ -f "$IH/.claude/skills/opsx-task/SKILL.md" ] && [ -x "$IH/.claude/skills/opsx-task/opsx-task.sh" ]'
ok "install: verify step checks opsx-task" 'printf "%s" "$out" | grep -q "opsx-task/{SKILL.md,opsx-task.sh}" && printf "%s" "$out" | grep -q "opsx-task.sh parses"'
out=$(run_install --uninstall); rc=$?
ok "uninstall removes all six opsx-task folders" '[ $rc -eq 0 ] && [ "$(n_task_dirs)" -eq 0 ]'
rm -rf "$IH"; mkdir -p "$IH"
out=$(run_install --skip-task); rc=$?
ok "--skip-task installs no opsx-task folder" '[ $rc -eq 0 ] && [ "$(n_task_dirs)" -eq 0 ] && [ -d "$IH/.claude/skills/opsx-review" ]'
ok "install --help lists --skip-task" 'bash "$REPO/install.sh" --help | grep -q -- "--skip-task"'

# ---------------------------------------------------------------- docs (3.3)
RD=$REPO/README.md
ok "README documents /opsx-task" 'grep -q "/opsx-task" "$RD" && grep -q "opsx-task/" "$RD"'
ok "README opsx-task.sh commands exist in the script usage" '( for c in $(grep -oE "opsx-task\.sh [a-z]+" "$RD" | awk "{print \$2}" | sort -u); do "$TS" --help | grep -qE "opsx-task\.sh $c( |\$)" || { echo "missing: $c"; exit 1; }; done )'
ok "README mentions the brief folder and resume" 'grep -q ".opsx/tasks/" "$RD" && grep -qi "resum" "$RD"'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
