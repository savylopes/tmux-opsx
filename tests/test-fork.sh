#!/usr/bin/env bash
# Scripted tests for skills/fork/fork.sh.
#
# Runs on a private tmux server (tmux -L fork-test-$$) with fake agent CLIs, so
# it never touches your tmux session, your agent CLIs, or your fork state.
# Usage: bash tests/test-fork.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016,SC2086
set -u
command -v tmux >/dev/null 2>&1 || { echo "tmux is required"; exit 1; }
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
F=$REPO/skills/fork/fork.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/fork-test.XXXXXX")
trap 'tmux -L "fork-test-$$" kill-server 2>/dev/null; tmux -L "fork-test-stale-$$" kill-server 2>/dev/null; rm -rf "$SP"' EXIT
mkdir -p "$SP/fakebin"
for c in claude agent codex opencode gemini; do
  cat > "$SP/fakebin/$c" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$0")
{ printf 'CLI=%s
' "$name"; for a in "$@"; do printf 'ARG=%s
' "${a:0:60}"; case $a in Bash\(*) printf 'RULE=%s
' "$a" ;; esac; done; env | grep '^FORK_' ; } > "$FORK_DIR/fake-$name.log"
echo "fake $name started for fork $FORK_ID"
exec sleep 600
EOF
  chmod +x "$SP/fakebin/$c"
done
export XDG_STATE_HOME=$SP/state; rm -rf "$XDG_STATE_HOME"
export PATH=$SP/fakebin:$PATH
L="tmux -L fork-test-$$"
$L kill-server 2>/dev/null
# The server is started without CLAUDE_CODE_SESSION_ID and is reparented to
# init, so `run-shell` commands have no ancestor carrying a session id.
env -u CLAUDE_CODE_SESSION_ID $L -f /dev/null new-session -d -s fs -x 220 -y 60 'exec sleep 3000'
sock=$($L display -p '#{socket_path}'); pid=$($L display -p '#{pid}')
P=$($L display -p -t fs '#{pane_id}')
export TMUX="$sock,$pid,0" TMUX_PANE=$P
# Never detect the real agent session running these tests: host CLI and
# parent session id are fixed here and overridden per case.
export FORK_HOST_CLI=none
S=11111111-2222-4333-8444-555555555555
export CLAUDE_CODE_SESSION_ID=$S
unset FORK_NATIVE
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
SD=$XDG_STATE_HOME/agent-forks/fs

# open default pane (claude)
out=$(printf '## Question\nwhere are retries handled?\n\n## Context\n- goal: x\n' | $F open --cli claude); echo "$out"
ok "open prints id/pane" '[[ "$out" == "fork 1 pane %"* ]]'
sleep 1.5
C1=$(awk -F= '/^child_pane=/{print $2}' $SD/1/meta)
ok "child pane alive" '$L list-panes -a -F "#{pane_id}" | grep -qx "$C1"'
ok "child right of parent (horizontal)" '[ "$($L display -p -t "$C1" "#{pane_left}")" -gt 0 ]'
ok "child width ~40%" 'w=$($L display -p -t "$C1" "#{pane_width}"); [ "$w" -ge 80 ] && [ "$w" -le 92 ]'
ok "claude plan mode" 'grep -qx "ARG=--permission-mode" $SD/1/fake-claude.log && grep -qx "ARG=plan" $SD/1/fake-claude.log'
ok "no bypass flags" '! grep -Eq "bypass|--force|--yolo|--auto|dangerously|--trust|skip-trust" $SD/1/fake-claude.log $SD/1/launch.sh'
ok "env FORK_ID/DIR/PARENT" 'grep -qx "FORK_ID=1" $SD/1/fake-claude.log && grep -qx "FORK_DIR=$SD/1" $SD/1/fake-claude.log && grep -qx "FORK_PARENT=$P" $SD/1/fake-claude.log'
ok "brief has question + protocol" 'grep -q "where are retries" $SD/1/brief.md && grep -q "Fork protocol" $SD/1/brief.md && grep -q "$F return" $SD/1/brief.md'
ok "meta fields" 'for k in parent_pane child_pane cli cwd created status; do grep -q "^$k=" $SD/1/meta || exit 1; done'
ok "status open" 'grep -qx status=open $SD/1/meta'
ok "question in meta" 'grep -qx "question=where are retries handled?" $SD/1/meta'

# second fork -> layout main-vertical, parent largest
out2=$(printf 'second q\n' | $F open --cli codex); echo "$out2"; sleep 1
C2=$(awk -F= '/^child_pane=/{print $2}' $SD/2/meta)
ok "second id 2" '[[ "$out2" == "fork 2 pane %"* ]]'
ok "parent largest" 'pw=$($L display -p -t $P "#{pane_width}"); for c in $C1 $C2; do [ "$pw" -gt "$($L display -p -t $c "#{pane_width}")" ] || exit 1; done'
ok "codex read-only flags" 'grep -qx "ARG=read-only" $SD/2/fake-codex.log && grep -qx "ARG=on-request" $SD/2/fake-codex.log'

# other CLIs' launch lines
for c in agent opencode gemini; do
  o=$(printf 'q %s\n' $c | $F open --window --cli $c); id=${o#fork }; id=${id%% *}; sleep 1
  ok "$c window open" '$L list-windows -t fs -F "#{window_name}" | grep -qx "fork-$id"'
  case $c in agent) ok "agent --mode ask" 'grep -qx "ARG=ask" $SD/$id/fake-agent.log';;
    opencode) ok "opencode --agent plan" 'grep -qx "ARG=plan" $SD/$id/fake-opencode.log && grep -qx "ARG=--agent" $SD/$id/fake-opencode.log';;
    gemini) ok "gemini plan" 'grep -qx "ARG=--approval-mode" $SD/$id/fake-gemini.log && grep -qx "ARG=plan" $SD/$id/fake-gemini.log';; esac
done
ok "window mode keeps parent window panes" '[ "$($L list-panes -t $P | wc -l)" -eq 3 ]'

# return from child 2 (simulate the child's shell env)
r=$(printf '**Answer**: retries in x.sh:10\n' | env -u TMUX_PANE FORK_ID=2 FORK_DIR=$SD/2 FORK_PARENT=$P TMUX_PANE=$C2 $F return); echo "$r"
ok "return writes result" 'grep -q "x.sh:10" $SD/2/result.md && grep -qx status=returned $SD/2/meta'
ok "badge on parent" '[ "$($L display -p -t $P "#{pane_title}")" = "fork 2 ✓" ] && [ "$($L show-options -p -v -t $P @fork_badge)" = "fork 2 ✓" ]'
ok "return via pane option fallback (no FORK_DIR)" 'printf "x\n" | env -u FORK_DIR TMUX_PANE=$C1 $F return >/dev/null && [ -f $SD/1/result.md ]'
rm -f $SD/1/result.md; sed -i 's/^status=returned$/status=open/; /^returned=/d' $SD/1/meta
$F collect 1 >/dev/null  # clears badge 1 (result was removed: raw capture path)
ok "return outside fork errors" 'o=$(cd /; printf x | env -u FORK_DIR -u TMUX -u TMUX_PANE $F return 2>&1); [ $? -ne 0 ] && [[ "$o" == *"not a fork"* ]]'
ok "return without stdin errors" '! FORK_DIR=$SD/2 $F return </dev/null 2>/dev/null'
chmod a-w $SD/2; o=$(printf 'y\n' | FORK_DIR=$SD/2 $F return 2>&1); rc=$?; chmod u+w $SD/2
ok "unwritable dir -> exit 3 + marker hint" '[ $rc -eq 3 ] && [[ "$o" == *"<<<FORK-RESULT"* ]]'

# collect latest -> fork 2, clears badge
c=$($F collect); echo "$c" | head -3
ok "collect latest = fork 2" '[[ "$c" == "# fork 2 result"* ]] && [[ "$c" == *"x.sh:10"* ]]'
ok "badge cleared" '[ -z "$($L show-options -p -v -t $P @fork_badge 2>/dev/null)" ] && [ "$($L display -p -t $P "#{pane_title}")" != "fork 2 ✓" ]'

# marker block recovery from child pane 1 (print into the fake child pane)
$L respawn-pane -k -t "$C1" "printf 'noise\n  <<<FORK-RESULT\n  Answer: from marker\n  line two\n  FORK-RESULT>>>\nmore\n'; exec sleep 600"; sleep 1
$L set-option -p -t "$C1" @fork_dir "$SD/1"
c=$($F collect 1); echo "$c"
ok "collect marker block" '[[ "$c" == *"recovered from the marker"* ]] && [[ "$c" == *"Answer: from marker"*"line two"* ]] && grep -q "from marker" $SD/1/result.md'
ok "marker dedent" 'grep -qx "Answer: from marker" $SD/1/result.md'

# echoed brief (with marker instructions) must not be mistaken for a result
C3=$(awk -F= '/^child_pane=/{print $2}' $SD/3/meta)
$L respawn-pane -k -t "$C3" "cat $SD/3/brief.md; echo fake agent started; exec sleep 600"; sleep 1
$L set-option -p -t "$C3" @fork_dir "$SD/3"
# raw capture on never-returned fork 3 (agent window)
c=$($F collect 3); echo "$c" | head -2
ok "collect raw capture labelled" '[[ "$c" == *"RAW CAPTURE"* ]] && [[ "$c" == *"fake agent started"* ]]'

# list
l=$($F list); echo "$l"
ok "list shows 5 forks" '[ "$(echo "$l" | tail -n +2 | wc -l)" -eq 5 ]'
ok "list columns" 'echo "$l" | grep -Eq "^2 +returned +codex +default +brief +%[0-9]+ +second q"'

# close without result -> capture.txt, pane killed, later collect returns capture
C4=$(awk -F= '/^child_pane=/{print $2}' $SD/4/meta)
$F close 4
ok "close saves capture" '[ -f $SD/4/capture.txt ] && grep -qx status=closed $SD/4/meta'
ok "close kills window" '! $L list-windows -t fs -F "#{window_name}" | grep -qx fork-4'
c=$($F collect 4); ok "collect after close uses capture" '[[ "$c" == *"RAW CAPTURE"* ]] && [[ "$c" == *"fake opencode started"* ]]'

# close when parent pane is gone: move fork 5 away then kill parent? Kill parent pane via new parent.
NP=$($L split-window -t fs:0 -d -P -F '#{pane_id}' 'exec sleep 3000')
$L kill-pane -t $P
ok "parent gone" '! $L list-panes -a -F "#{pane_id}" | grep -qx "$P"'
export TMUX_PANE=$NP
ok "return with parent gone succeeds" 'printf "late\n" | FORK_DIR=$SD/5 $F return | grep -q "not reachable"'
ok "close --all with parent gone" '$F close --all >/dev/null && ! grep -L status=closed $SD/*/meta | grep -q .'
ok "state kept" '[ -f $SD/1/brief.md ] && [ -f $SD/5/result.md ]'

# concurrent opens -> distinct ids
for i in $(seq 1 12); do (printf 'c%s\n' $i | $F open --window --cli gemini > $SP/conc.$i 2>&1 &) ; done; sleep 3
ids=$(cat $SP/conc.* | awk '/^fork/{print $2}' | sort -n | uniq | wc -l)
ok "concurrent distinct ids" '[ "$ids" -eq 12 ]'
$F close --all >/dev/null

# ---------------------------------------------------------------------------
# model selection (every case sets FORK_HOST_CLI explicitly so the real agent
# session running these tests is never detected)
unset FORK_MODEL FORK_CLI
# mopen <var> <env…> -- <open args…>: open a window fork, set <var> to its id
mopen() {
  local var=$1 o envs=(); shift
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  o=$(printf 'model q\n' | env "${envs[@]}" "$F" open --window "$@") || { printf -v "$var" ''; return 1; }
  echo "$o" | head -n 1
  o=${o#fork }; printf -v "$var" '%s' "${o%% *}"
}
lline() { grep '^exec env' "$SD/$1/launch.sh"; }
has_flag() { lline "$1" | grep -q -- " $2 $3 "; }
no_model_flag() { ! lline "$1" | grep -Eq -- ' (--model|-m) '; }

mopen M1 FORK_HOST_CLI=claude -- --cli claude --model haiku
ok "model: explicit --model" 'has_flag $M1 --model haiku'
ok "model: meta model=haiku" 'grep -qx model=haiku $SD/$M1/meta'
mout=$(printf 'q\n' | FORK_HOST_CLI=claude $F open --window --cli claude --model haiku)
ok "model: output line" '[[ "$(echo "$mout" | head -n1)" =~ ^fork\ [0-9]+\ pane\ %[0-9]+\ cli\ claude\ model\ haiku$ ]]'
mopen M2 FORK_HOST_CLI=claude -- --cli claude
ok "model: none -> no flag" 'no_model_flag $M2'
ok "model: meta model= empty" 'grep -qx "model=" $SD/$M2/meta'
mout=$(printf 'q\n' | FORK_HOST_CLI=claude $F open --window --cli claude)
ok "model: output line default" '[[ "$(echo "$mout" | head -n1)" == *" cli claude model default" ]]'
mopen M3 FORK_HOST_CLI=claude FORK_MODEL=sonnet -- --cli claude
ok "model: \$FORK_MODEL" 'has_flag $M3 --model sonnet'
mopen M4 FORK_HOST_CLI=claude FORK_MODEL=sonnet -- --cli claude --model opus
ok "model: flag beats env" 'has_flag $M4 --model opus && ! lline $M4 | grep -q sonnet'
for c in claude agent codex opencode gemini; do
  mopen MC FORK_HOST_CLI=none -- --cli $c --model m1
  case $c in claude|agent) fl=--model ;; *) fl=-m ;; esac
  ok "model: $c spelling $fl" 'has_flag $MC $fl m1 && [ "$(lline $MC | grep -o -- " $fl m1 " | wc -l)" -eq 1 ]'
done
sleep 1
ok "model: fake claude got --model m1" 'id=$(grep -l "^cli=claude" $SD/*/meta | xargs grep -l "^model=m1" | head -n1); d=${id%/meta}; grep -A1 -x "ARG=--model" $d/fake-claude.log | grep -qx "ARG=m1"'

before=$(find "$SD" -mindepth 1 -maxdepth 1 | wc -l); pb=$($L list-panes -a | wc -l)
o=$(printf 'q\n' | FORK_HOST_CLI=claude $F open --cli claude --model "--dangerously-skip-permissions" 2>&1); rc=$?
ok "model: unsafe value rejected" '[ $rc -ne 0 ] && [[ "$o" == *"invalid --model"* ]]'
ok "model: unsafe leaves no state/pane" '[ "$(find "$SD" -mindepth 1 -maxdepth 1 | wc -l)" -eq "$before" ] && [ "$($L list-panes -a | wc -l)" -eq "$pb" ]'
ok "model: whitespace rejected" '! printf q | FORK_HOST_CLI=none $F open --cli claude --model "a b" 2>/dev/null'
ok "model: empty rejected" '! printf q | FORK_HOST_CLI=none $F open --cli claude --model "" 2>/dev/null'
ok "model: unsafe parent-model rejected" '! printf q | FORK_HOST_CLI=claude $F open --cli claude --parent-model "-x" 2>/dev/null'
ok "model: unsafe \$FORK_MODEL rejected" '! printf q | FORK_HOST_CLI=none FORK_MODEL="--yolo" $F open --cli claude 2>/dev/null'
ok "model: rejections left no state" '[ "$(find "$SD" -mindepth 1 -maxdepth 1 | wc -l)" -eq "$before" ]'

mopen M5 FORK_HOST_CLI=claude -- --parent-model claude-opus-5-5
ok "model: same CLI inherits (no --cli)" 'grep -qx cli=claude $SD/$M5/meta && has_flag $M5 --model claude-opus-5-5'
mopen M6 FORK_HOST_CLI=claude -- --cli codex --parent-model claude-opus-5-5
ok "model: cross-CLI no inheritance" 'no_model_flag $M6 && grep -qx "model=" $SD/$M6/meta'
mopen M7 FORK_HOST_CLI=claude FORK_MODEL=haiku -- --parent-model claude-opus-5-5
ok "model: env beats inheritance" 'has_flag $M7 --model haiku && ! lline $M7 | grep -q claude-opus'
mopen M8 FORK_HOST_CLI=none -- --cli claude --parent-model claude-opus-5-5
ok "model: FORK_HOST_CLI=none no inheritance" 'no_model_flag $M8'
mopen M9 FORK_HOST_CLI=opencode -- --cli opencode --parent-model gpt-5
ok "model: opencode bare id ignored" 'no_model_flag $M9'
mopen M10 FORK_HOST_CLI=opencode -- --cli opencode --parent-model openai/gpt-5
ok "model: opencode provider/model inherited" 'has_flag $M10 -m openai/gpt-5'
mopen M11 FORK_HOST_CLI=opencode -- --cli opencode --model gpt-5
ok "model: opencode explicit bare id passed" 'has_flag $M11 -m gpt-5'

l=$($F list)
ok "list: MODEL header" 'echo "$l" | head -n1 | grep -Eq "^ID +STATUS +CLI +MODEL +CONTEXT +PANE +QUESTION"'
ok "list: model haiku row" 'echo "$l" | grep -Eq "^$M1 +[a-z]+ +claude +haiku +[a-z]+ +%[0-9]+ "'
ok "list: model default row" 'echo "$l" | grep -Eq "^$M2 +[a-z]+ +claude +default +[a-z]+ +%[0-9]+ "'
$F close --all >/dev/null

# ---------------------------------------------------------------------------
# native (full-context) forks; host CLI and session id set per case
NF='--resume|--fork-session|--continue|--fork'
fargs() { grep '^ARG=' "$SD/$1/fake-$2.log" | cut -d= -f2-; }
no_native_flags() { ! grep -Eqx "ARG=($NF)" "$SD/$1/fake-$2.log" && ! lline "$1" | grep -Eq -- " ($NF)( |$)"; }

n=$(FORK_HOST_CLI=claude $F native); rc=$?
ok "native: claude host + id -> full" '[ $rc -eq 0 ] && [ "$n" = "full claude session $S" ]'
n=$(FORK_HOST_CLI=claude $F native --cli codex); rc=$?
ok "native: cross-CLI -> brief" '[ $rc -eq 0 ] && [[ "$n" == "brief "*"claude -> codex"* ]]'
n=$(FORK_HOST_CLI=claude $F native --cli gemini); rc=$?
ok "native: gemini -> brief naming gemini" '[ $rc -eq 0 ] && [[ "$n" == brief* ]] && [[ "$n" == *gemini* ]]'
n=$(FORK_HOST_CLI=gemini $F native --cli gemini)
ok "native: gemini host -> no true fork" '[[ "$n" == "brief gemini has no true fork" ]]'
n=$(FORK_HOST_CLI=agent $F native --cli agent); ok "native: agent -> brief" '[[ "$n" == brief* ]]'
n=$(FORK_HOST_CLI=codex $F native --cli codex); ok "native: codex -> brief" '[[ "$n" == brief* ]]'
n=$(FORK_HOST_CLI=claude FORK_NATIVE=0 $F native --cli claude)
ok "native: FORK_NATIVE=0 -> brief" '[[ "$n" == "brief disabled"* ]]'
n=$(FORK_HOST_CLI=claude $F native --cli claude --brief-only)
ok "native: --brief-only -> brief" '[[ "$n" == "brief disabled"* ]]'
n=$(FORK_HOST_CLI=claude $F native --cli claude --cwd "$SP")
ok "native: claude --cwd elsewhere -> still full" '[ "$n" = "full claude session $S" ]'
n=$(FORK_HOST_CLI=opencode $F native --cli opencode)
ok "native: opencode same cwd -> full" '[ "$n" = "full opencode continue" ]'
n=$(FORK_HOST_CLI=opencode $F native --cli opencode --cwd "$SP")
ok "native: opencode --cwd elsewhere -> brief" '[[ "$n" == "brief cwd differs"* ]]'
n=$(FORK_HOST_CLI=claude CLAUDE_CODE_SESSION_ID=not-a-uuid $F native --cli claude)
ok "native: malformed id -> brief" '[[ "$n" == "brief "*CLAUDE_CODE_SESSION_ID* ]]'
R=22222222-3333-4444-8555-666666666666
# `; :` keeps each bash alive (no exec of the last command), so the nearest
# ancestor holding the variable is the outer bash with $R.
n=$(CLAUDE_CODE_SESSION_ID=$R bash -c 'env -u CLAUDE_CODE_SESSION_ID FORK_HOST_CLI=claude bash -c "\"\$0\" native --cli claude; :" "$0"; :' "$F")
ok "native: stripped env recovered from ancestor" '[ "$n" = "full claude session $R" ]'
# Stale ids (F1): the claude process and the tmux server keep the id they were
# launched with. A bash symlinked as `claude` stands in for the claude process.
T=33333333-4444-4555-8666-777777777777
mkdir -p "$SP/pbin" "$SP/oc"; ln -sf "$(command -v bash)" "$SP/pbin/claude"; ln -sf "$(command -v bash)" "$SP/pbin/opencode"
n=$(CLAUDE_CODE_SESSION_ID=$T "$SP/pbin/claude" -c 'env -u CLAUDE_CODE_SESSION_ID FORK_HOST_CLI=claude bash -c "\"\$0\" native --cli claude; :" "$0"; :' "$F")
ok "native: id only on the claude process -> brief, not resumed" '[[ "$n" == "brief "*CLAUDE_CODE_SESSION_ID* ]] && [[ "$n" != *"$T"* ]]'
n=$(CLAUDE_CODE_SESSION_ID=$T "$SP/pbin/claude" -c 'CLAUDE_CODE_SESSION_ID=$1 bash -c "env -u CLAUDE_CODE_SESSION_ID FORK_HOST_CLI=claude bash -c \"\\\"\\\$0\\\" native --cli claude; :\" \"\$0\"; :" "$0"; :' "$F" "$R")
ok "native: live id below the claude process -> full with it" '[ "$n" = "full claude session $R" ]'
n=$(CLAUDE_CODE_SESSION_ID=$T "$SP/pbin/claude" -c 'CLAUDE_CODE_SESSION_ID=$1 bash -c "env -u CLAUDE_CODE_SESSION_ID FORK_HOST_CLI=claude bash -c \"\\\"\\\$0\\\" native --cli claude; :\" \"\$0\"; :" "$0"; :' "$F" "$T")
ok "native: ancestor id equal to the claude process's -> brief stale" '[[ "$n" == "brief stale CLAUDE_CODE_SESSION_ID"* ]]'
L2="tmux -L fork-test-stale-$$"
CLAUDE_CODE_SESSION_ID=$T $L2 -f /dev/null new-session -d -s st 'exec sleep 300'
$L2 run-shell "env -u CLAUDE_CODE_SESSION_ID FORK_HOST_CLI=claude PATH='$PATH' '$F' native --cli claude > '$SP/stale.native' 2>&1"
$L2 kill-server 2>/dev/null
ok "native: id only from a stale tmux server -> brief stale" 'grep -q "^brief stale CLAUDE_CODE_SESSION_ID" $SP/stale.native && ! grep -q "$T" $SP/stale.native'
# OpenCode session directory (F3): the opencode process's cwd, not the shell's.
# The `opencode` process stays in $SP/oc; its child shell (the agent's) cd's.
n=$(cd "$SP/oc" && "$SP/pbin/opencode" -c 'bash -c "cd \"\$1\" && FORK_HOST_CLI=opencode \"\$0\" native --cli opencode; :" "$0" "$1"; :' "$F" "$SP")
ok "native: opencode shell cd'd away from the session dir -> brief" '[[ "$n" == "brief cwd differs"* ]]'
n=$(cd "$SP/oc" && "$SP/pbin/opencode" -c 'bash -c "cd \"\$1\" && FORK_HOST_CLI=opencode \"\$0\" native --cli opencode --cwd \"\$2\"; :" "$0" "$1" "$2"; :' "$F" "$SP" "$SP/oc")
ok "native: opencode --cwd = session dir -> full" '[ "$n" = "full opencode continue" ]'
# Missing option values (F4): a clear error, no loop.
for sub in native open detect-cli; do
  for opt in --cwd --cli; do
    [ "$sub" = detect-cli ] && [ "$opt" = --cwd ] && continue
    e=$(timeout 5 "$F" $sub $opt </dev/null 2>&1); rc=$?
    ok "$sub $opt without value -> error" '[ $rc -eq 1 ] && [[ "$e" == *"$opt needs a value"* ]]'
  done
done
before=$(find "$SD" -mindepth 1 -maxdepth 1 | wc -l)
ok "native: needs no stdin, writes nothing" 'FORK_HOST_CLI=claude $F native </dev/null >/dev/null && [ "$(find "$SD" -mindepth 1 -maxdepth 1 | wc -l)" -eq "$before" ]'
# No id: run on the tmux server (child of init, started without the variable)
$L run-shell "env -u CLAUDE_CODE_SESSION_ID FORK_HOST_CLI=claude PATH='$PATH' '$F' native --cli claude > '$SP/noid.native' 2>&1"
ok "native: no id -> brief naming the session id" 'grep -q "^brief .*CLAUDE_CODE_SESSION_ID" $SP/noid.native'
$L run-shell "printf 'noid q\n' | env -u CLAUDE_CODE_SESSION_ID FORK_HOST_CLI=claude PATH='$PATH' XDG_STATE_HOME='$XDG_STATE_HOME' TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' '$F' open --window --cli claude > '$SP/noid.open' 2>&1"
NI=$(awk '/^fork /{print $2}' $SP/noid.open)
ok "native: no id -> open without --resume" '[ -n "$NI" ] && ! lline $NI | grep -q -- --resume && grep -qx context=brief $SD/$NI/meta && grep -q "^# context: brief" $SP/noid.open'

# Claude native launch
o=$(printf '## Question
why X?

## Role
read-only
' | FORK_HOST_CLI=claude $F open --cli claude); echo "$o"
NC=${o#fork }; NC=${NC%% *}; sleep 1.2
ok "native claude: first line unchanged" '[[ "$(echo "$o" | head -n1)" =~ ^fork\ $NC\ pane\ %[0-9]+\ cli\ claude\ model\ [^\ ]+$ ]]'
ok "native claude: # context: full line" 'echo "$o" | tail -n +2 | grep -q "^# context: full"'
ok "native claude: --resume S --fork-session" 'fargs $NC claude | grep -A1 -x -- --resume | tail -n1 | grep -qx "$S" && fargs $NC claude | grep -qx -- --fork-session'
ok "native claude: plan mode kept" 'fargs $NC claude | grep -A1 -x -- --permission-mode | tail -n1 | grep -qx plan && fargs $NC claude | grep -qx -- --allowedTools && fargs $NC claude | grep -qx -- --append-system-prompt'
ok "native claude: brief is the prompt" 'fargs $NC claude | tail -n1 | grep -q "^## Question"'
ok "native claude: no bypass flags" '! grep -Eq "bypass|--force|--yolo|--auto|dangerously|--trust|skip-trust" $SD/$NC/fake-claude.log $SD/$NC/launch.sh'
ok "native claude: meta context=full + S" 'grep -qx context=full $SD/$NC/meta && grep -q "^context_source=.*$S" $SD/$NC/meta'

# OpenCode native launch
o=$(printf 'oc q
' | FORK_HOST_CLI=opencode $F open --window --cli opencode); NO=${o#fork }; NO=${NO%% *}; sleep 1.2
ok "native opencode: --continue --fork --agent plan --prompt" 'a=$(fargs $NO opencode); for f in --continue --fork --agent plan --prompt; do echo "$a" | grep -qx -- "$f" || exit 1; done'
ok "native opencode: meta context=full" 'grep -qx context=full $SD/$NO/meta && echo "$o" | grep -q "^# context: full (opencode --continue --fork)"'

# Brief-mode fallbacks never add fork flags
o=$(printf 'bo q
' | FORK_HOST_CLI=claude $F open --window --cli claude --brief-only); NB=${o#fork }; NB=${NB%% *}
o2=$(printf 'cx q
' | FORK_HOST_CLI=claude $F open --window --cli codex); NX=${o2#fork }; NX=${NX%% *}
o3=$(printf 'gm q
' | FORK_HOST_CLI=gemini $F open --window --cli gemini); NG=${o3#fork }; NG=${NG%% *}
o4=$(printf 'ag q
' | FORK_HOST_CLI=agent $F open --window --cli agent); NA=${o4#fork }; NA=${NA%% *}
o5=$(printf 'cw q
' | FORK_HOST_CLI=opencode $F open --window --cli opencode --cwd "$SP"); NW=${o5#fork }; NW=${NW%% *}
o6=$(printf 'n0 q
' | FORK_HOST_CLI=claude FORK_NATIVE=0 $F open --window --cli claude); NZ=${o6#fork }; NZ=${NZ%% *}
o7=$(printf 'cc q\n' | FORK_HOST_CLI=claude $F open --window --cli claude --cwd "$SP"); NK=${o7#fork }; NK=${NK%% *}
sleep 1.5
ok "claude other cwd: still native" 'fargs $NK claude | grep -A1 -x -- --resume | tail -n1 | grep -qx "$S" && fargs $NK claude | grep -qx -- --fork-session && grep -qx context=full $SD/$NK/meta'
ok "brief-only: no fork flags, context=brief" 'no_native_flags $NB claude && grep -qx context=brief $SD/$NB/meta && echo "$o" | grep -q "^# context: brief"'
ok "cross-CLI codex: today flags only, context=brief" 'no_native_flags $NX codex && grep -qx "ARG=read-only" $SD/$NX/fake-codex.log && grep -qx context=brief $SD/$NX/meta'
ok "gemini: no fork flags" 'no_native_flags $NG gemini && grep -qx context=brief $SD/$NG/meta'
ok "agent: no fork flags" 'no_native_flags $NA agent && grep -qx context=brief $SD/$NA/meta'
ok "opencode other cwd: no fork flags" 'no_native_flags $NW opencode && grep -qx context=brief $SD/$NW/meta'
ok "FORK_NATIVE=0: no fork flags" 'no_native_flags $NZ claude && grep -qx context=brief $SD/$NZ/meta'

l=$($F list)
ok "list: CONTEXT header" 'echo "$l" | head -n1 | grep -Eq "^ID +STATUS +CLI +MODEL +CONTEXT +PANE +QUESTION"'
ok "list: full row" 'echo "$l" | grep -Eq "^$NC +[a-z]+ +claude +[^ ]+ +full +%[0-9]+ "'
ok "list: brief row" 'echo "$l" | grep -Eq "^$NB +[a-z]+ +claude +[^ ]+ +brief +%[0-9]+ "'
ok "help lists native and --brief-only" 'h=$($F help); [[ "$h" == *"fork.sh native"* ]] && [[ "$h" == *--brief-only* ]]'
$F close --all >/dev/null

# ---------------------------------------------------------------------------
# page forks (--page-dir, fork.sh page, allow rule, page protocol)
export FORK_HOST_CLI=none
o=$(printf '## Question\npage q\n' | $F open --window --cli claude --page-dir /x/3); PG=${o#fork }; PG=${PG%% *}
o=$(printf '## Question\nplain q\n' | $F open --window --cli claude); NP0=${o#fork }; NP0=${NP0%% *}
sleep 1.5
ok "page: meta page_dir=/x/3" 'grep -qx "page_dir=/x/3" $SD/$PG/meta'
ok "page: child env FORK_PAGE_DIR" 'grep -qx "FORK_PAGE_DIR=/x/3" $SD/$PG/fake-claude.log'
ok "page: no flag -> page_dir= and no env" 'grep -qx "page_dir=" $SD/$NP0/meta && ! grep -q "^FORK_PAGE_DIR=" $SD/$NP0/fake-claude.log'
ok "page: claude allows return and page" 'grep -Fqx "RULE=Bash($F return:*)" $SD/$PG/fake-claude.log && grep -Fqx "RULE=Bash($F page:*)" $SD/$PG/fake-claude.log && [ "$(grep -c "^RULE=" $SD/$PG/fake-claude.log)" -eq 2 ]'
ok "page: plain fork allows only return" 'grep -Fqx "RULE=Bash($F return:*)" $SD/$NP0/fake-claude.log && [ "$(grep -c "^RULE=" $SD/$NP0/fake-claude.log)" -eq 1 ]'
ok "page: launch.sh has both rules / only return" '[ "$(grep -o "Bash" $SD/$PG/launch.sh | wc -l)" -eq 2 ] && grep -q "page:" $SD/$PG/launch.sh && [ "$(grep -o "Bash" $SD/$NP0/launch.sh | wc -l)" -eq 1 ] && ! grep -q "page:" $SD/$NP0/launch.sh'
ok "page: plan mode, no bypass" 'grep -qx "ARG=--permission-mode" $SD/$PG/fake-claude.log && grep -qx "ARG=plan" $SD/$PG/fake-claude.log && ! grep -Eq "bypass|--force|--yolo|--auto|dangerously|--trust|skip-trust" $SD/$PG/fake-claude.log $SD/$PG/launch.sh'
ok "page: carve-out names both commands" 'c=$(source <(sed -n "s/.*--append-system-prompt \(.*\) \"\$(cat .*/printf \"%s\" \1/p" $SD/$PG/launch.sh)); [[ "$c" == *"$F page"* ]] && [[ "$c" == *"$F return"* ]]'
ok "page: brief has page protocol" 'grep -q "## Page protocol" $SD/$PG/brief.md && grep -q "$F page" $SD/$PG/brief.md && grep -q "manifest.tsv" $SD/$PG/brief.md && grep -q "S P D T C N" $SD/$PG/brief.md && grep -qi mermaid $SD/$PG/brief.md'
ok "page: protocol is the last section" '[ "$(grep "^## " $SD/$PG/brief.md | tail -n1)" = "## Page protocol (fork $PG)" ]'
ok "page: protocol says stop, no markers" 'sed -n "/^## Page protocol/,\$p" $SD/$PG/brief.md > $SP/pp; grep -q "stop" $SP/pp && ! grep -q "FORK-RESULT" $SP/pp'
ok "page: protocol takes the languages from the brief, identical labels when two" 'sed -n "/^## Page protocol/,\$p" $SD/$PG/brief.md > $SP/pp2; grep -q "Languages, one write" $SP/pp2 && grep -q "Languages:. line" $SP/pp2 && grep -q "<article lang=\"en\">" $SP/pp2 && grep -q "<article lang=\"pt\">" $SP/pp2 && grep -q "same labelled blocks" $SP/pp2 && grep -q "never write one language" $SP/pp2 && grep -q "no language switch" $SP/pp2 && ! grep -q "Two languages, one write" $SP/pp2'
ok "page: protocol duplicates diagrams per language, one manifest line per label, SVG first" 'grep -q "Diagrams are duplicated per" $SP/pp2 && grep -q "shared by all languages" $SP/pp2 && grep -q "inline SVG first" $SP/pp2 && grep -q "pinned Mermaid tag" $SP/pp2'
ok "page: plain brief has no page protocol" '! grep -q "Page protocol" $SD/$NP0/brief.md && ! grep -q "manifest.tsv" $SD/$NP0/brief.md && ! grep -q "Languages, one write" $SD/$NP0/brief.md'
ok "page: relative --page-dir rejected" 'e=$(printf q | $F open --cli claude --page-dir rel/3 2>&1); [ $? -ne 0 ] && [[ "$e" == *absolute* ]]'

PR=$XDG_STATE_HOME/agent-forks/explain/proj; PD=$PR/3; mkdir -p $PR
o=$(printf '<!doctype html><title>v1</title>\n' | FORK_PAGE_DIR=$PD $F page); rc=$?
ok "page: writes index.html, prints path" '[ $rc -eq 0 ] && grep -q "<title>v1</title>" $PD/index.html && [ "$o" = "$PD/index.html" ]'
o=$(printf 'S1\tsection one\nP1\tpara one\n' | FORK_PAGE_DIR=$PD $F page --manifest); rc=$?
ok "page: --manifest writes manifest.tsv only" '[ $rc -eq 0 ] && [ "$o" = "$PD/manifest.tsv" ] && grep -qx "P1	para one" $PD/manifest.tsv && grep -q "v1" $PD/index.html'
ok "page: no temp files left" '[ -z "$(find $PD -name ".page.*")" ]'
cp $PD/index.html $SP/idx.before
e=$(FORK_PAGE_DIR=$PD $F page </dev/null 2>&1); rc=$?
ok "page: empty stdin -> exit 2, unchanged" '[ $rc -eq 2 ] && cmp -s $PD/index.html $SP/idx.before'
e=$(printf '  \n' | FORK_PAGE_DIR=$PD $F page 2>&1); rc=$?
ok "page: blank stdin -> exit 2" '[ $rc -eq 2 ] && cmp -s $PD/index.html $SP/idx.before'
e=$(cd /; printf '<p>x</p>\n' | env -u FORK_DIR -u FORK_PAGE_DIR -u TMUX -u TMUX_PANE $F page 2>&1); rc=$?
ok "page: outside a fork -> exit 1 not a fork" '[ $rc -eq 1 ] && [[ "$e" == *"not a fork"* ]]'
e=$(printf '<p>x</p>\n' | env -u FORK_PAGE_DIR FORK_DIR=$SD/$NP0 $F page 2>&1); rc=$?
ok "page: fork without page dir -> exit 4 naming --page-dir" '[ $rc -eq 4 ] && [[ "$e" == *--page-dir* ]]'
CP0=$(awk -F= '/^child_pane=/{print $2}' $SD/$NP0/meta)
e=$(printf '<p>x</p>\n' | env -u FORK_DIR -u FORK_PAGE_DIR TMUX_PANE="$CP0" $F page 2>&1); rc=$?
ok "page: plain fork via pane option -> exit 4" '[ $rc -eq 4 ]'
chmod a-w $PD; e=$(printf '<p>new</p>\n' | FORK_PAGE_DIR=$PD $F page 2>&1); rc=$?; chmod u+w $PD
ok "page: unwritable -> exit 3, unchanged" '[ $rc -eq 3 ] && cmp -s $PD/index.html $SP/idx.before && [ -z "$(find $PD -name ".page.*")" ]'
# page dir from meta (no FORK_PAGE_DIR in env)
o=$(printf '## Question\nmeta q\n' | $F open --window --cli claude --page-dir $PR/7); PM=${o#fork }; PM=${PM%% *}
o=$(printf '<p>from meta</p>\n' | env -u FORK_PAGE_DIR FORK_DIR=$SD/$PM $F page); rc=$?
ok "page: dir from meta, created if missing" '[ $rc -eq 0 ] && [ "$o" = "$PR/7/index.html" ] && grep -q "from meta" $PR/7/index.html'
# .reindex hook: runs after index.html writes (status ignored), not after --manifest
printf '#!/usr/bin/env bash\ntouch "%s/reindexed"\nexit 7\n' "$SP" > $PR/.reindex; chmod +x $PR/.reindex
rm -f $SP/reindexed; o=$(printf '<p>r</p>\n' | FORK_PAGE_DIR=$PD $F page); rc=$?
ok "page: .reindex run, exit status ignored" '[ $rc -eq 0 ] && [ -f $SP/reindexed ] && [ "$o" = "$PD/index.html" ]'
rm -f $SP/reindexed; printf 'P1\tx\n' | FORK_PAGE_DIR=$PD $F page --manifest >/dev/null
ok "page: --manifest does not reindex" '[ ! -f $SP/reindexed ]'
chmod -x $PR/.reindex; printf '<p>r2</p>\n' | FORK_PAGE_DIR=$PD $F page >/dev/null
ok "page: non-executable .reindex skipped" '[ ! -f $SP/reindexed ]'
# F6: .reindex only beside page dirs under <state root>/explain, never a symlink
chmod +x $PR/.reindex
OR=$SP/pages/proj; mkdir -p $OR; cp $PR/.reindex $OR/.reindex
rm -f $SP/reindexed; o=$(printf '<p>o</p>\n' | FORK_PAGE_DIR=$OR/3 $F page); rc=$?
ok "page: .reindex outside the explain root not run" '[ $rc -eq 0 ] && [ "$o" = "$OR/3/index.html" ] && [ ! -f $SP/reindexed ]'
mkdir -p $XDG_STATE_HOME/agent-forks/explain/proj2/9 $XDG_STATE_HOME/agent-forks/explain/deep/proj
ln -s $PR/.reindex $XDG_STATE_HOME/agent-forks/explain/proj2/.reindex
rm -f $SP/reindexed; printf '<p>s</p>\n' | FORK_PAGE_DIR=$XDG_STATE_HOME/agent-forks/explain/proj2/9 $F page >/dev/null
ok "page: symlinked .reindex not run" '[ ! -f $SP/reindexed ]'
cp $PR/.reindex $XDG_STATE_HOME/agent-forks/explain/.reindex
rm -f $SP/reindexed; printf '<p>d</p>\n' | FORK_PAGE_DIR=$XDG_STATE_HOME/agent-forks/explain/deep $F page >/dev/null
ok "page: .reindex of the explain dir itself not run" '[ ! -f $SP/reindexed ]'
rm -f $XDG_STATE_HOME/agent-forks/explain/.reindex
rm -f $SP/reindexed; printf '<p>r3</p>\n' | FORK_PAGE_DIR=$PD $F page >/dev/null
ok "page: .reindex under the explain root still run" '[ -f $SP/reindexed ]'
ok "page: page file is private (600)" '[ "$(stat -c %a $PD/index.html)" = 600 ]'
ok "page: protocol forbids secrets" 'grep -q "Never put secrets in the page" $SP/pp && grep -qi "credentials" $SP/pp && grep -q "Content-Security-Policy" $SP/pp'
ok "help lists page and --page-dir" 'h=$($F help); [[ "$h" == *"fork.sh page"* ]] && [[ "$h" == *--page-dir* ]]'
$F close --all >/dev/null

# unknown cli / empty brief
ok "unknown cli rejected" '! printf q | $F open --cli foo 2>/dev/null'
ok "empty brief rejected" '! printf "  \n" | $F open --cli claude 2>/dev/null'

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
