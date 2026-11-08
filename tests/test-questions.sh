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
# @@DOCS@@

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
