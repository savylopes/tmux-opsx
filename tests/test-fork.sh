#!/usr/bin/env bash
# Scripted tests for skills/fork/fork.sh.
#
# Runs on a private tmux server (tmux -L fork-test-$$) with fake agent CLIs, so
# it never touches your tmux session, your agent CLIs, or your fork state.
# Usage: bash tests/test-fork.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034
set -u
command -v tmux >/dev/null 2>&1 || { echo "tmux is required"; exit 1; }
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
F=$REPO/skills/fork/fork.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/fork-test.XXXXXX")
trap 'tmux -L "fork-test-$$" kill-server 2>/dev/null; rm -rf "$SP"' EXIT
mkdir -p "$SP/fakebin"
for c in claude agent codex opencode gemini; do
  cat > "$SP/fakebin/$c" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$0")
{ printf 'CLI=%s
' "$name"; for a in "$@"; do printf 'ARG=%s
' "${a:0:60}"; done; env | grep '^FORK_' ; } > "$FORK_DIR/fake-$name.log"
echo "fake $name started for fork $FORK_ID"
exec sleep 600
EOF
  chmod +x "$SP/fakebin/$c"
done
export XDG_STATE_HOME=$SP/state; rm -rf "$XDG_STATE_HOME"
export PATH=$SP/fakebin:$PATH
L="tmux -L fork-test-$$"
$L kill-server 2>/dev/null
$L -f /dev/null new-session -d -s fs -x 220 -y 60 'exec sleep 3000'
sock=$($L display -p '#{socket_path}'); pid=$($L display -p '#{pid}')
P=$($L display -p -t fs '#{pane_id}')
export TMUX="$sock,$pid,0" TMUX_PANE=$P
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
ok "list columns" 'echo "$l" | grep -Eq "^2 +returned +codex +%[0-9]+ +second q"'

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

# unknown cli / empty brief
ok "unknown cli rejected" '! printf q | $F open --cli foo 2>/dev/null'
ok "empty brief rejected" '! printf "  \n" | $F open --cli claude 2>/dev/null'

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
