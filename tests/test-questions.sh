#!/usr/bin/env bash
# Scripted tests for skills/opsx-questions/questions.sh, the /opsx-answer,
# /opsx-challenge and /opsx-settle skills, agents/opsx-researcher.md, the
# install.sh wiring and README.
#
# Uses scratch git repos and a scratch HOME; no network, no agent CLI.
# Usage: bash tests/test-questions.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016
set -u
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
Q=$REPO/skills/opsx-questions/questions.sh
SP=$(cd -P -- "$(mktemp -d "${TMPDIR:-/tmp}/questions-test.XXXXXX")" && pwd)
trap 'rm -rf "$SP"' EXIT
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
newrepo(){ local d=$SP/$1; mkdir -p "$d"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t; printf '%s' "$d"; }

# ---------------------------------------------------------------- usage (1.1)
out=$("$Q" --help); rc=$?
ok "--help exits 0 and lists extract, cite, run, record, status" '[ $rc -eq 0 ] && for c in extract cite run record status; do printf "%s" "$out" | grep -qE "questions\.sh $c( |\$)" || exit 1; done'
"$Q" bogus >/dev/null 2>&1; rc=$?
ok "unknown command exits non-zero" '[ $rc -ne 0 ]'

# ---------------------------------------------------------------- extract (1.2)
R=$(newrepo r1)
C=$R/openspec/changes/demo; mkdir -p "$C/specs/foo"
cat > "$C/design.md" <<'EOF'
# Design

## Decisions

### Use SQLite
Because it is simple.

- not a decision of its own

### One window per change
Text.

## Open Questions

- Where does X write?
- Resolved: Y uses Z.
EOF
cat > "$C/proposal.md" <<'EOF'
# Proposal

## Open Points

- Who owns the cache?
  It spans two lines.
- Resolved: nothing else.
EOF
cat > "$C/specs/foo/spec.md" <<'EOF'
## ADDED Requirements

### Requirement: Bar
The thing SHALL bar.
EOF
cd "$R" || exit 1
out=$("$Q" extract demo --mode answer); rc=$?
ln=$(grep -n 'Where does X write' "$C/design.md" | cut -d: -f1)
ok "extract answer: open question, Resolved: skipped" '[ $rc -eq 0 ] && [ "$(printf "%s\n" "$out" | head -n1)" = "$(printf "Q1\topen\topenspec/changes/demo/design.md:%s\tWhere does X write?" "$ln")" ]'
ok "extract answer: design.md exactly one line, then proposal Open Points" '[ "$(printf "%s\n" "$out" | grep -c "design.md")" -eq 1 ] && [ "$(printf "%s\n" "$out" | sed -n 2p | cut -f1,2,4)" = "$(printf "Q2\topen\tWho owns the cache? It spans two lines.")" ] && [ "$(printf "%s\n" "$out" | wc -l)" -eq 2 ]'
out=$("$Q" extract demo --mode challenge); rc=$?
ok "extract challenge: two decisions Q1 then Q2" '[ $rc -eq 0 ] && [ "$(printf "%s\n" "$out" | cut -f1,2,4 | tr "\t\n" "|;")" = "Q1|decision|Use SQLite;Q2|decision|One window per change;" ]'
ok "extract challenge: no req-spec without the flag" '! printf "%s\n" "$out" | grep -q req-spec'
out=$("$Q" extract demo --mode challenge --include-requirements)
ok "extract --include-requirements adds Q3 req-spec Bar" '[ "$(printf "%s\n" "$out" | sed -n 3p | cut -f1,2,4)" = "$(printf "Q3\treq-spec\tBar")" ] && printf "%s\n" "$out" | sed -n 3p | cut -f3 | grep -qx "openspec/changes/demo/specs/foo/spec.md:3"'
mkdir -p "$R/openspec/changes/flat"
printf '# D\n\n## Decisions\n\n- Use tabs.\n- Ship weekly.\n\n## Risks\n\n- none\n' > "$R/openspec/changes/flat/design.md"
out=$("$Q" extract flat --mode challenge)
ok "extract challenge: top-level items when there are no ### headings" '[ "$(printf "%s\n" "$out" | cut -f4 | tr "\n" ";")" = "Use tabs.;Ship weekly.;" ]'
mkdir -p "$R/openspec/changes/empty"; printf '## Open Questions\n\n- Resolved: done.\n' > "$R/openspec/changes/empty/design.md"
out=$("$Q" extract empty --mode answer); rc=$?
ok "extract: sections without questions print nothing, exit 0" '[ $rc -eq 0 ] && [ -z "$out" ]'
out=$("$Q" extract no-such-change --mode answer 2>/dev/null); rc=$?
ok "extract: unknown change exits 2, no question line" '[ $rc -eq 2 ] && [ -z "$out" ]'
mkdir -p "$SP/etc"; printf '## Open Questions\n\n- secret?\n' > "$SP/etc/design.md"
out=$("$Q" extract '../../etc' --mode answer 2>/dev/null); rc=$?
ok "extract: unsafe change name exits 2, nothing read" '[ $rc -eq 2 ] && [ -z "$out" ]'
"$Q" extract 'a/b' --mode answer >/dev/null 2>&1; rc=$?
ok "extract: slash in name exits 2" '[ $rc -eq 2 ]'
if [ -d "$REPO/openspec/changes/add-opsx-workspace" ]; then
  out=$("$Q" extract add-opsx-workspace --mode answer --repo "$REPO")
  ok "extract add-opsx-workspace prints its two open questions" '[ "$(printf "%s\n" "$out" | grep -c "	open	")" -eq 2 ]'
fi

# ---------------------------------------------------------------- cite (1.3)
for i in 1 2 3 4 5 6 7 8 9; do echo "line $i"; done > "$R/a.md"
printf 'the   quick brown fox\n' >> "$R/a.md"
for i in 11 12 13 14 15; do echo "line $i"; done >> "$R/a.md"
"$Q" cite a.md 9 "quick brown"; rc=$?
ok "cite: match two lines away with collapsed whitespace exits 0" '[ $rc -eq 0 ]'
"$Q" cite a.md 10 "the quick   brown"; rc=$?
ok "cite: excerpt whitespace collapsed too" '[ $rc -eq 0 ]'
"$Q" cite a.md 10 "lazy dog"; rc=$?
ok "cite: fabricated excerpt exits 1" '[ $rc -eq 1 ]'
"$Q" cite a.md 4 "quick brown"; rc=$?
ok "cite: match outside the +-2 window exits 1" '[ $rc -eq 1 ]'
"$Q" cite missing.md 1 x 2>/dev/null; rc=$?
ok "cite: missing file exits 2" '[ $rc -eq 2 ]'
"$Q" cite /etc/hostname 1 x 2>/dev/null; rc=$?
ok "cite: path outside the repo exits 3" '[ $rc -eq 3 ]'
"$Q" cite ../../../../etc/passwd 1 root 2>/dev/null; rc=$?
ok "cite: ../ escape exits 3" '[ $rc -eq 3 ]'
"$Q" cite /no/such/outside 1 x 2>/dev/null; rc=$?
ok "cite: missing file outside the repo exits 3 (confinement first)" '[ $rc -eq 3 ]'
ln -s /etc/hostname "$R/link.md"
"$Q" cite link.md 1 x 2>/dev/null; rc=$?
ok "cite: symlink pointing outside exits 3" '[ $rc -eq 3 ]'
rm -f "$R/link.md"
mkdir -p "$SP/home/.agents/memory"; printf 'remember this\n' > "$SP/home/.agents/memory/m.md"
HOME=$SP/home "$Q" cite "$SP/home/.agents/memory/m.md" 1 "remember this"; rc=$?
ok "cite: ~/.agents/memory is allowed" '[ $rc -eq 0 ]'

# ---------------------------------------------------------------- run (1.4)
R2=$(newrepo r2); cd "$R2" || exit 1
echo seed > seed.txt; git add seed.txt; git commit -qm seed
qf(){ local n=$1 i; for i in $(seq 1 "$n"); do printf 'Q%d\topen\tconversation\tQuestion %d?\n' "$i" "$i"; done > "$SP/q$n.tsv"; printf '%s' "$SP/q$n.tsv"; }
"$Q" run new settle --questions-file "$(qf 7)" >/dev/null 2>&1; rc=$?
ok "run new: 7 questions with default --max exits non-zero, no run dir" '[ $rc -ne 0 ] && [ -z "$(ls -A "$R2/.opsx/questions" 2>/dev/null)" ]'
ok "run new: refusal leaves .gitignore alone" '[ ! -e "$R2/.gitignore" ]'
RUN=$("$Q" run new settle --questions-file "$(qf 2)"); rc=$?
ok "run new: prints a run id YYYYmmdd-HHMMSS-rand4" '[ $rc -eq 0 ] && [[ $RUN =~ ^[0-9]{8}-[0-9]{6}-[a-z0-9]{4}$ ]]'
D=$R2/.opsx/questions/$RUN
ok "run new: questions.tsv, meta and empty verdicts.tsv" '[ -s "$D/questions.tsv" ] && grep -qx "mode=settle" "$D/meta" && grep -qx "rounds=3" "$D/meta" && [ -f "$D/verdicts.tsv" ] && [ ! -s "$D/verdicts.tsv" ]'
RUN2=$("$Q" run new answer --questions-file "$(qf 1)")
ok "run new: .opsx/questions/ in .gitignore exactly once after two runs" '[ "$(grep -cx ".opsx/questions/" "$R2/.gitignore")" -eq 1 ] && [ "$RUN" != "$RUN2" ]'
ok "run new: --max raises the limit" '"$Q" run new answer --questions-file "$(qf 7)" --max 7 >/dev/null'
printf 'Q1\tbogus\tx\ty\n' > "$SP/bad.tsv"
"$Q" run new answer --questions-file "$SP/bad.tsv" >/dev/null 2>&1; rc=$?
ok "run new: unknown kind rejected" '[ $rc -ne 0 ]'

# ---------------------------------------------------------------- record + status (1.5)
st(){ "$Q" status "$1" | awk -v q="${2:-Q1}" '$1==q'; }
rec(){ "$Q" record "$@" >/dev/null 2>&1; }
S1=$("$Q" run new settle --questions-file "$(qf 1)")
ok "status: a new settle question is open round=1" '[ "$(st "$S1")" = "Q1 open round=1 subagents=0 history=-" ]'
rec "$S1" Q1 --round 1 --stage answer --verdict answered --sources 1
ok "status: an answered question is challenging" 'st "$S1" | grep -q "^Q1 challenging round=1 subagents=1 "'
rec "$S1" Q1 --round 1 --stage challenge-a --verdict stands --sources 2
rec "$S1" Q1 --round 1 --stage challenge-b --verdict stands --sources 1
ok "settled in one round" 'st "$S1" | grep -q "^Q1 settled round=1 subagents=3 history=answer:answered,challenge-a:stands,challenge-b:stands$"'
rec "$S1" Q1 --round 2 --stage answer --verdict answered; rc=$?
ok "record: a final question takes no more verdicts" '[ $rc -ne 0 ] && st "$S1" | grep -q "subagents=3"'

S2=$("$Q" run new settle --questions-file "$(qf 1)")
rec "$S2" Q1 --round 1 --stage answer --verdict answered --sources 1
rec "$S2" Q1 --round 1 --stage challenge-a --verdict invalidated --sources 1
rec "$S2" Q1 --round 1 --stage challenge-b --verdict stands --sources 1
ok "successful attack reopens: open round=2" 'st "$S2" | grep -q "^Q1 open round=2 subagents=3 "'
rec "$S2" Q1 --round 2 --stage answer --verdict partial --sources 1
rec "$S2" Q1 --round 2 --stage challenge-a --verdict stands --sources 1
rec "$S2" Q1 --round 2 --stage challenge-b --verdict stands --sources 3
ok "reopened question settles in round 2" 'st "$S2" | grep -q "^Q1 settled round=2 subagents=6 "'

S3=$("$Q" run new settle --questions-file "$(qf 1)")
rec "$S3" Q1 --round 1 --stage answer --verdict answered --sources 1
rec "$S3" Q1 --round 1 --stage challenge-a --verdict stands --sources 1
rec "$S3" Q1 --round 1 --stage challenge-b --verdict stands --sources 0
ok "untested stands costs a round: challenging round=2" 'st "$S3" | grep -q "^Q1 challenging round=2 "'

S4=$("$Q" run new settle --questions-file "$(qf 1)" --rounds 1)
rec "$S4" Q1 --round 1 --stage answer --verdict answered --sources 1
rec "$S4" Q1 --round 1 --stage challenge-a --verdict weakened --sources 1
ok "cap reached while contested" 'st "$S4" | grep -q "^Q1 contested "'
rec "$S4" Q1 --round 2 --stage answer --verdict answered; rc=$?
ok "record: round above the cap rejected" '[ $rc -ne 0 ]'

S5=$("$Q" run new settle --questions-file "$(qf 1)" --rounds 1)
rec "$S5" Q1 --round 1 --stage answer --verdict answered --sources 1
rec "$S5" Q1 --round 1 --stage challenge-a --verdict stands --sources 0
rec "$S5" Q1 --round 1 --stage challenge-b --verdict stands --sources 0
ok "untested at the cap: needs-human" 'st "$S5" | grep -q "^Q1 needs-human "'

S6=$("$Q" run new settle --questions-file "$(qf 1)")
rec "$S6" Q1 --round 1 --stage answer --verdict unanswerable
ok "an unanswerable answer ends the question" 'st "$S6" | grep -q "^Q1 unanswerable round=1 subagents=1 "'

S7=$("$Q" run new settle --questions-file "$(qf 1)")
before=$("$Q" status "$S7"); vb=$(cat "$R2/.opsx/questions/$S7/verdicts.tsv")
rec "$S7" Q1 --round 1 --stage answer --verdict stands; rc=$?
ok "wrong vocabulary rejected, status unchanged" '[ $rc -ne 0 ] && [ "$("$Q" status "$S7")" = "$before" ] && [ "$(cat "$R2/.opsx/questions/$S7/verdicts.tsv")" = "$vb" ]'
rec "$S7" Q9 --round 1 --stage answer --verdict answered; rc=$?
ok "record: unknown question rejected" '[ $rc -ne 0 ]'
rec "$S7" Q1 --round 1 --stage challenge-a --verdict answered; rc=$?
ok "record: answer verdict on a challenge stage rejected" '[ $rc -ne 0 ]'
"$Q" status ../../etc >/dev/null 2>&1; rc=$?
ok "status: invalid run id rejected" '[ $rc -ne 0 ]'

A1=$("$Q" run new answer --questions-file "$(qf 2)")
rec "$A1" Q1 --round 1 --stage answer --verdict partial --sources 1
ok "answer mode: state is the recorded verdict" 'st "$A1" | grep -q "^Q1 partial round=1 subagents=1 " && st "$A1" Q2 | grep -q "^Q2 pending "'
rec "$A1" Q1 --round 1 --stage challenge-a --verdict stands; rc=$?
ok "answer mode: challenge stages rejected" '[ $rc -ne 0 ]'
C1=$("$Q" run new challenge --questions-file "$(qf 1)")
rec "$C1" Q1 --round 1 --stage challenge-a --verdict invalidated --sources 2
ok "challenge mode: state is the recorded verdict" 'st "$C1" | grep -q "^Q1 invalidated "'

ok "run leaves the repo untouched except .gitignore" '[ "$(git -C "$R2" status --porcelain | grep -vE "^(\?\?| M) \.gitignore$")" = "" ]'

# ---------------------------------------------------------------- shellcheck (1.6)
if command -v shellcheck >/dev/null 2>&1; then
  ok "shellcheck questions.sh and this test" 'shellcheck "$Q" "$REPO/tests/test-questions.sh"'
fi

cd "$REPO" || exit 1
# ---------------------------------------------------------------- agent + reference (2.x)
AG=$REPO/agents/opsx-researcher.md
REFMD=$REPO/skills/opsx-questions/reference.md
fm(){ awk '/^---$/{n++; next} n==1' "$1"; }
ok "researcher: name ops-researcher, model inherit, bypassPermissions" 'fm "$AG" | grep -qx "name: \"ops-researcher\"" && fm "$AG" | grep -qx "model: inherit" && fm "$AG" | grep -qx "permissionMode: bypassPermissions"'
ok "researcher: Claude tools exactly Read, Glob, Grep, WebSearch, WebFetch" '[ "$(fm "$AG" | grep "^tools:")" = "tools: [Read, Glob, Grep, WebSearch, WebFetch]" ] && ! fm "$AG" | grep -qE "Write|Edit|Bash|Agent|NotebookEdit|mcp__"'
ok "researcher: verdict only, untrusted data, no writes" 'grep -q "VERDICT: <verdict>" "$AG" && grep -qi "data, not instructions" "$AG" && grep -q "No writes, no commands" "$AG"'
ok "reference: brief fields, untrusted rules, challenge briefs omit the rationale" 'for w in "Question" "Stance" "Context" "Ruled out" "Untrusted input rules" "UNTRUSTED DATA"; do grep -q "$w" "$REFMD" || exit 1; done && grep -qi "omit the parent.s rationale" "$REFMD"'
ok "format defined once: same VERDICT line and four evidence forms in both files" 'for f in "$AG" "$REFMD"; do grep -qx "VERDICT: <verdict>" "$f" || exit 1; for e in "file:<path>:<line> \"<excerpt>\"" "url:<url> \"<excerpt>\"" "ticket:<key>:<field> \"<excerpt>\"" "req:<id> \"<excerpt>\""; do grep -qxF "$e" "$f" || exit 1; done; done'
ok "reference: both downgrade rules and the concrete-flaw rule" 'grep -q "left with no valid evidence becomes \`needs-human\`" "$REFMD" && grep -q "left with no valid evidence becomes \`stands\`" "$REFMD" && grep -q "concrete flaw" "$REFMD" && grep -q "still seems right" "$REFMD"'
ok "reference: malformed retry, report tags, Resolved: bullets, drafts" 'grep -qi "retried once" "$REFMD" && for t in "[open]" "[decision]" "[req spec]" "[req client AC]"; do grep -qF "$t" "$REFMD" || exit 1; done && grep -q "Resolved:" "$REFMD" && grep -qi "never posted" "$REFMD" && grep -qi "product owner" "$REFMD"'

# ---------------------------------------------------------------- skills (3.x)
for s in opsx-answer opsx-challenge opsx-settle; do
  SK=$REPO/skills/$s/SKILL.md
  ok "$s: frontmatter name and description" 'fm "$SK" | grep -qx "name: $s" && fm "$SK" | grep -q "^description: ."'
  ok "$s: names questions.sh, --max defaults to 6, six skill folders" 'grep -q "questions.sh" "$SK" && grep -q -- "--max\` defaults to 6" "$SK" && for d in .claude .cursor .agents .codex .config/opencode .gemini; do grep -q "~/$d/skills/opsx-questions/questions.sh" "$SK" || exit 1; done'
  ok "$s: list confirmed before any subagent" 'grep -q "Confirm the list" "$SK" && grep -qi "do not start any subagent" "$SK"'
  ok "$s: nothing written until commanded, ticket comments are drafts" 'grep -q "Nothing is written or posted until the user commands it" "$SK" && grep -qi "ticket comments are drafts only" "$SK"'
  ok "$s: subagents on Claude/Cursor/OpenCode, parent on Codex/Gemini" 'grep -q "ops-researcher" "$SK" && grep -q "Codex CLI, Gemini CLI" "$SK" && grep -qi "read-only guarantee" "$SK"'
  ok "$s: every questions.sh subcommand it names exists in --help" '( for c in $(grep -oE "questions\.sh [a-z]+" "$SK" | awk "{print \$2}" | sort -u); do "$Q" --help | grep -qE "questions\.sh $c( |\$)" || { echo "missing: $c"; exit 1; }; done )'
done
SS=$REPO/skills/opsx-settle/SKILL.md
ok "opsx-settle: --rounds defaults to 3" 'grep -q -- "--rounds\` defaults to 3" "$SS"'
ok "opsx-settle: parallel independent A and B, carried attack, stop condition" 'grep -q "A, internal" "$SS" && grep -q "B, external" "$SS" && grep -q "in parallel" "$SS" && grep -qi "neither seeing the other" "$SS" && grep -qi "carries the attack that succeeded" "$SS" && grep -q "Stop" "$SS"'
ok "opsx-challenge: --include-requirements, PO draft" 'grep -q -- "--include-requirements" "$REPO/skills/opsx-challenge/SKILL.md" && grep -qi "product owner" "$REPO/skills/opsx-challenge/SKILL.md"'

# ---------------------------------------------------------------- install (4.x)
IH=$SP/ihome; mkdir -p "$IH" "$SP/ibin"
for b in claude node npm; do printf '#!/bin/sh\necho 1.0.0\n' > "$SP/ibin/$b"; chmod +x "$SP/ibin/$b"; done
SKILL_DIRS=(.claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills)
RFILES=(.claude/agents/opsx-researcher.md .cursor/agents/opsx-researcher.md .codex/agents/ops-researcher.toml .config/opencode/agents/ops-researcher.md .gemini/agents/opsx-researcher.md)
n_q_dirs(){ local n=0 d s; for d in "${SKILL_DIRS[@]}"; do for s in opsx-questions opsx-answer opsx-challenge opsx-settle; do [ -d "$IH/$d/$s" ] && n=$((n+1)); done; done; echo $n; }
n_r_files(){ local n=0 f; for f in "${RFILES[@]}"; do [ -e "$IH/$f" ] && n=$((n+1)); done; echo $n; }
run_install(){
  (cd "$REPO" && env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_HOME -u OPENCODE_CONFIG_DIR -u TMUX -u TMUX_PANE \
     -u SUDO_USER -u REAL_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u OPSX_MODELS_CONF \
     HOME="$IH" PATH="$SP/ibin:/usr/bin:/bin" bash ./install.sh --skip-openspec --skip-graphify \
     --skip-commands --skip-mcp --skip-memory --no-backup "$@" </dev/null 2>&1)
}
out=$(run_install); rc=$?
ok "install: questions.sh executable, four folders in all six skill dirs" '[ $rc -eq 0 ] && [ -x "$IH/.claude/skills/opsx-questions/questions.sh" ] && [ -f "$IH/.claude/skills/opsx-questions/reference.md" ] && [ "$(n_q_dirs)" -eq 24 ]'
ok "install: three skill folders under ~/.claude, ~/.agents and ~/.gemini" 'for d in .claude/skills .agents/skills .gemini/skills; do for s in opsx-answer opsx-challenge opsx-settle; do [ -f "$IH/$d/$s/SKILL.md" ] || exit 1; done; done'
ok "install: verify reports the files and that questions.sh parses, no warning for them" 'printf "%s" "$out" | grep -q "opsx-questions/questions.sh" && printf "%s" "$out" | grep -q "questions.sh parses" && ! printf "%s" "$out" | grep -E "missing|not executable|failed to parse" | grep -qE "questions|researcher|opsx-(answer|challenge|settle)"'
ok "install: ops-researcher on all five CLIs" '[ "$(n_r_files)" -eq 5 ]'
ok "install: Claude researcher keeps the read-only tool list, model inherit" 'fm "$IH/.claude/agents/opsx-researcher.md" | grep -qx "tools: \[Read, Glob, Grep, WebSearch, WebFetch\]" && fm "$IH/.claude/agents/opsx-researcher.md" | grep -qx "model: inherit"'
ok "install: Cursor researcher readonly: true" 'fm "$IH/.cursor/agents/opsx-researcher.md" | grep -qx "readonly: true"'
OR=$IH/.config/opencode/agents/ops-researcher.md
ok "install: OpenCode researcher denies edits, applier still allows" 'grep -qx "  edit: deny" "$OR" && grep -qx "  bash: deny" "$OR" && grep -qx "  task: deny" "$OR" && ! grep -qE "^  (edit|bash): allow" "$OR" && for k in read glob grep list webfetch websearch; do grep -qx "  $k: allow" "$OR" || exit 1; done && grep -qx "  edit: allow" "$IH/.config/opencode/agents/ops-applier.md"'
ok "install: Codex researcher turns off the shell" 'grep -qx "shell_tool = false" "$IH/.codex/agents/ops-researcher.toml" && grep -q "^name = \"ops-researcher\"" "$IH/.codex/agents/ops-researcher.toml"'
GR=$IH/.gemini/agents/opsx-researcher.md
ok "install: Gemini researcher has read and web tools only" '[ "$(fm "$GR" | awk "/^tools:/{t=1; next} t && /^  - /{print \$2; next} {t=0}" | tr "\n" " ")" = "read_file read_many_files glob grep_search list_directory google_web_search web_fetch " ] && ! grep -qE "^  - (run_shell_command|write_file|replace)$|^tools: \[" "$GR"'
ok "install: other agents unchanged (no readonly, no [features], Gemini copies as is)" '! grep -q "^readonly" "$IH/.cursor/agents/opsx-applier.md" && ! grep -q "^\[features\]" "$IH/.codex/agents/ops-applier.toml" && cmp -s "$REPO/agents/opsx-applier.md" "$IH/.gemini/agents/opsx-applier.md" && fm "$IH/.claude/agents/opsx-applier.md" | grep -q "^tools:"'
ok "researcher is not in models.conf" '! grep -q researcher "$REPO/agents/models.conf"'
out=$(run_install --uninstall); rc=$?
ok "uninstall removes the four skill folders and every ops-researcher file" '[ $rc -eq 0 ] && [ "$(n_q_dirs)" -eq 0 ] && [ "$(n_r_files)" -eq 0 ]'
rm -rf "$IH"; mkdir -p "$IH"
out=$(run_install --skip-questions); rc=$?
ok "--skip-questions installs no question skill and no ops-researcher" '[ $rc -eq 0 ] && [ "$(n_q_dirs)" -eq 0 ] && [ "$(n_r_files)" -eq 0 ] && [ -f "$IH/.claude/agents/opsx-applier.md" ]'
ok "install --help lists --skip-questions" 'bash "$REPO/install.sh" --help | grep -q -- "--skip-questions"'

# ---------------------------------------------------------------- docs (4.4)
RD=$REPO/README.md
ok "README lists the three skills and ops-researcher in the overview" 'sed -n "/^ your dev harness/,/^\`\`\`/p" "$RD" | grep -q "/opsx-answer" && sed -n "/^ your dev harness/,/^\`\`\`/p" "$RD" | grep -q "ops-researcher" && grep -q "^| \`ops-researcher\` subagent" "$RD" && grep -q "^| \`/opsx-answer\`, \`/opsx-challenge\`, \`/opsx-settle\`" "$RD"'
ok "README: Codex and Gemini research sequentially in the parent without the read-only guarantee" 'sed -n "/^### Answering and challenging questions/,/^---\$/p" "$RD" | grep -q "Codex CLI and Gemini CLI.*one at a time, without the read-only guarantee"'
ok "README: flags match the SKILL.md usage lines" 'for s in answer challenge settle; do u=$(grep -m1 -E "^/opsx-$s \[input\]" "$REPO/skills/opsx-$s/SKILL.md"); grep -qF "$u" "$RD" || { echo "README lacks: $u"; exit 1; }; done'
ok "README questions.sh commands exist in the script usage" '( for c in $(grep -oE "questions\.sh [a-z]+" "$RD" | awk "{print \$2}" | sort -u); do "$Q" --help | grep -qE "questions\.sh $c( |\$)" || { echo "missing: $c"; exit 1; }; done )'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
