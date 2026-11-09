#!/usr/bin/env bash
# Scripted tests for skills/opsx-questions/questions.sh, the /opsx-answer,
# /opsx-challenge and /opsx-settle skills, agents/opsx-researcher.md, the
# install.sh wiring and README.
#
# Uses scratch git repos and a scratch HOME; no network, no agent CLI.
# Usage: bash tests/test-questions.sh
# Assertions are eval'd strings, so variables read only there look unused.
# Literal ~/ paths are passed on purpose (cite resolves them itself).
# shellcheck disable=SC2034,SC2016,SC2088
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
ok "--help exits 0 and lists extract, cite, run, record, status, input" '[ $rc -eq 0 ] && for c in extract cite run record status input; do printf "%s" "$out" | grep -qE "questions\.sh $c( |\$)" || exit 1; done'
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
# Security round 1 F5: a symlinked artifact is not followed.
mkdir -p "$R/openspec/changes/linked/specs/s" "$SP/outside"
printf '# D\n\n## Open Questions\n\n- OUTSIDE SECRET QUESTION?\n\n## Decisions\n\n### OUTSIDE DECISION\n' > "$SP/outside/x.md"
printf '# P\n\n## Open Points\n\n- OUTSIDE POINT?\n' > "$SP/outside/p.md"
printf '### Requirement: OUTSIDE REQ\n' > "$SP/outside/s.md"
ln -s "$SP/outside/x.md" "$R/openspec/changes/linked/design.md"
ln -s "$SP/outside/p.md" "$R/openspec/changes/linked/proposal.md"
ln -s "$SP/outside/s.md" "$R/openspec/changes/linked/specs/s/spec.md"
out=$("$Q" extract linked --mode answer 2>&1); rc=$?
ok "extract: symlinked design.md and proposal.md are skipped (answer)" '[ $rc -eq 0 ] && ! printf "%s" "$out" | grep -q OUTSIDE'
out=$("$Q" extract linked --mode challenge --include-requirements 2>&1); rc=$?
ok "extract: symlinked design.md and spec.md are skipped (challenge)" '[ $rc -eq 0 ] && ! printf "%s" "$out" | grep -q OUTSIDE'
mkdir -p "$R/openspec/changes/nested"
printf '## Open Questions\n\n- Parent question?\n  - sub item\n    continuation of the sub item\n- Next question?\n' > "$R/openspec/changes/nested/design.md"
out=$("$Q" extract nested --mode answer)
ok "extract: a nested item and its continuation lines stay out of the parent text" '[ "$(printf "%s\n" "$out" | cut -f4 | tr "\n" ";")" = "Parent question?;Next question?;" ]'
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
HOME=$SP/home "$Q" cite '~/.agents/memory/m.md' 1 "remember this"; rc=$?
ok "cite: a literal ~/.agents/memory/... path resolves under HOME" '[ $rc -eq 0 ]'
HOME=$SP/home "$Q" cite '~/.agents/memory/none.md' 1 x 2>/dev/null; rc=$?
ok "cite: a missing ~/.agents/memory file exits 2" '[ $rc -eq 2 ]'
HOME=$SP/home "$Q" cite '~/other.md' 1 x 2>/dev/null; rc=$?
ok "cite: ~/ outside ~/.agents/memory exits 3" '[ $rc -eq 3 ]'
# Security round 1 F1: the values are untrusted, -h/--help in them is a value.
"$Q" cite -h 1 x >/dev/null 2>&1; rc=$?
ok "cite: path -h is a path (no such file, exit 2), not help" '[ $rc -eq 2 ]'
"$Q" cite --help 1 x >/dev/null 2>&1; rc=$?
ok "cite: path --help is a path (exit 2), not help" '[ $rc -eq 2 ]'
"$Q" cite a.md 10 -h >/dev/null 2>&1; rc=$?
ok "cite: excerpt -h is an excerpt (exit 1), not help" '[ $rc -eq 1 ]'
"$Q" cite a.md -h x >/dev/null 2>&1; rc=$?
ok "cite: line -h is a bad line (exit 2), not help" '[ $rc -eq 2 ]'
"$Q" cite -- -h 1 x >/dev/null 2>&1; rc=$?
ok "cite: -- then -h is a path (exit 2)" '[ $rc -eq 2 ]'
"$Q" cite -- a.md 9 "quick brown"; rc=$?
ok "cite: -- before the values still matches (exit 0)" '[ $rc -eq 0 ]'
"$Q" cite --repo "$R" -- a.md 9 "quick brown"; rc=$?
ok "cite: leading --repo then -- matches (exit 0)" '[ $rc -eq 0 ]'
(cd / && "$Q" cite a.md 9 "quick brown" --repo "$R"); rc=$?
ok "cite: trailing --repo still works (exit 0)" '[ $rc -eq 0 ]'
"$Q" cite a.md 9 --repo "$R" >/dev/null 2>&1; rc=$?
ok "cite: --repo among the values is a value, too few values exit 2" '[ $rc -eq 2 ]'
"$Q" cite a.md 9 "quick brown" extra >/dev/null 2>&1; rc=$?
ok "cite: a fourth value exits 2" '[ $rc -eq 2 ]'
out=$("$Q" cite --help); rc=$?
ok "cite --help alone is help (exit 0)" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "questions.sh cite"'

# ---------------------------------------------------------------- url (security round 1 F2, F3)
for u in "https://docs.python.org/3/library/os.html" "https://github.com/a/b/commit/0123456789012345678901234567890123456789" "https://Example.COM" "https://example.com/a/b#frag"; do
  "$Q" url -- "$u" >/dev/null; rc=$?
  ok "url: plain https document URL passes: $u" '[ $rc -eq 0 ]'
done
out=$("$Q" url "https://example.com/a/b#frag")
ok "url: prints the URL without its fragment" '[ "$out" = "https://example.com/a/b" ]'
out=$("$Q" url "https://Example.COM")
ok "url: lowercases the host and adds the root path" '[ "$out" = "https://example.com/" ]'
long=$(printf 'A%.0s' $(seq 65)); huge=$(printf 'a/%.0s' $(seq 110))
for u in "https://attacker.example/?q=secret" "https://attacker.example/x?d=1" "http://example.com/" "https://u:p@example.com/" \
         "https://user@example.com/" "https://example.com:8443/" "https://127.0.0.1/" "https://localhost/" "https://x.localhost/" \
         "https://intranet/" "https://[::1]/" "https://example.com/$long" "https://example.com/$huge" "https://example.com/a b" \
         "https://example.com/a\"b" "ftp://example.com/" "-h" "https://example.com/%0a;\$(id)"; do
  "$Q" url -- "$u" >/dev/null 2>&1; rc=$?
  ok "url: refused (exit 1): ${u:0:60}" '[ $rc -eq 1 ]'
done
"$Q" url -h >/dev/null 2>&1; rc=$?
ok "url: -h alone is help (exit 0)" '[ $rc -eq 0 ]'
"$Q" url -- -h >/dev/null 2>&1; rc=$?
ok "url: -- -h is a URL, refused (exit 1)" '[ $rc -eq 1 ]'
"$Q" url >/dev/null 2>&1; rc=$?
ok "url: no URL exits 2" '[ $rc -eq 2 ]'
WG=$REPO/skills/opsx-questions/webfetch-guard.sh
printf '{"tool_input":{"url":"https://evil.example/?d=secret","prompt":"x"}}' | "$WG" 2>"$SP/wg.err"; rc=$?
ok "webfetch-guard: URL with a query string is blocked (exit 2, reason)" '[ $rc -eq 2 ] && grep -q "query string" "$SP/wg.err"'
printf '{"tool_input":{"url":"https://docs.example.com/guide","prompt":"x"}}' | "$WG"; rc=$?
ok "webfetch-guard: plain docs URL is allowed (exit 0)" '[ $rc -eq 0 ]'
printf 'not json' | "$WG" 2>/dev/null; rc=$?
ok "webfetch-guard: unreadable payload is blocked" '[ $rc -eq 2 ]'
printf '{"tool_input":{"prompt":"x"}}' | "$WG" 2>/dev/null; rc=$?
ok "webfetch-guard: payload without a URL is blocked" '[ $rc -eq 2 ]'
printf '{"tool_input":{"url":["https://docs.example.com/"]}}' | "$WG" 2>/dev/null; rc=$?
ok "webfetch-guard: non-string URL is blocked" '[ $rc -eq 2 ]'
printf '{"tool_input":{"url":"https://docs.example.com/a\\nhttps://evil.example/?d=1"}}' | "$WG" 2>/dev/null; rc=$?
ok "webfetch-guard: multi-line URL is blocked" '[ $rc -eq 2 ]'
mkdir -p "$SP/wgonly"; cp "$WG" "$SP/wgonly/"
printf '{"tool_input":{"url":"https://docs.example.com/"}}' | "$SP/wgonly/webfetch-guard.sh" 2>/dev/null; rc=$?
ok "webfetch-guard: no questions.sh next to it blocks (fails closed)" '[ $rc -eq 2 ]'

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
# Security round 1 F6: control characters are stripped from the source too.
printf 'Q1\topen\tsrc\033[31mRED\033]0;title\007\177x\tQ\033[2Jtext?\n' > "$SP/esc.tsv"
E1=$("$Q" run new answer --questions-file "$SP/esc.tsv"); rc=$?
ok "run new: no control character in questions.tsv source or text" '[ $rc -eq 0 ] && ! LC_ALL=C grep -q "[[:cntrl:]]" <(tr -d "\t\n" < "$R2/.opsx/questions/$E1/questions.tsv") && [ "$(cut -f3 "$R2/.opsx/questions/$E1/questions.tsv")" = "src[31mRED]0;titlex" ]'
printf 'Q1\topen\t\033\001\tQ?\n' > "$SP/esc2.tsv"
"$Q" run new answer --questions-file "$SP/esc2.tsv" >/dev/null 2>&1; rc=$?
ok "run new: a source of only control characters is empty, rejected" '[ $rc -eq 2 ]'

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
rec "$S1" Q1 --round 2 --stage answer --verdict invalidated; rc=$?
ok "record: still validates the vocabulary after settling" '[ $rc -ne 0 ] && st "$S1" | grep -q "^Q1 settled round=1 subagents=3 "'

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
rec "$S4" Q1 --round 1 --stage challenge-b --verdict stands --sources 1; rc=$?
ok "cap: the parallel second challenger still records, state stays contested" '[ $rc -eq 0 ] && st "$S4" | grep -q "^Q1 contested round=1 subagents=3 history=answer:answered,challenge-a:weakened,challenge-b:stands$"'
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

S8=$("$Q" run new settle --questions-file "$(qf 1)")
rec "$S8" Q1 --round 1 --stage answer --verdict answered --sources 1 --attempts 2
ok "a retried result counts two subagents" 'st "$S8" | grep -q "^Q1 challenging round=1 subagents=2 "'
rec "$S8" Q1 --round 1 --stage challenge-a --verdict stands --attempts 3; rc=$?
ok "record: --attempts above 2 rejected" '[ $rc -ne 0 ]'

printf 'Q1\treq-spec\tspec.md:3\tThe thing SHALL bar.\nQ2\tdecision\tdesign.md:5\tUse SQLite\nQ3\topen\tconversation\tWhy?\n' > "$SP/req.tsv"
S9=$("$Q" run new settle --questions-file "$SP/req.tsv")
ok "settle: a requirement and a decision start challenging, an open question open" 'st "$S9" Q1 | grep -q "^Q1 challenging round=1 subagents=0 " && st "$S9" Q2 | grep -q "^Q2 challenging round=1 " && st "$S9" Q3 | grep -q "^Q3 open round=1 "'
rec "$S9" Q1 --round 1 --stage challenge-a --verdict stands --sources 1
rec "$S9" Q1 --round 1 --stage challenge-b --verdict stands --sources 1
ok "settle: a requirement settles with no answer subagent" 'st "$S9" Q1 | grep -q "^Q1 settled round=1 subagents=2 "'
rec "$S9" Q2 --round 1 --stage challenge-a --verdict invalidated --sources 1
ok "settle: an attacked decision reopens for an answer" 'st "$S9" Q2 | grep -q "^Q2 open round=2 "'

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
rec "$C1" Q1 --round 1 --stage challenge-b --verdict stands --sources 1
ok "challenge mode: a later stands does not hide the attack" 'st "$C1" | grep -q "^Q1 invalidated round=1 subagents=2 "'

ok "run leaves the repo untouched except .gitignore" '[ "$(git -C "$R2" status --porcelain | grep -vE "^(\?\?| M) \.gitignore$")" = "" ]'

# ---------------------------------------------------------------- input save (6.1)
R3=$(newrepo r3)
out=$(printf 'line one\nwhere does X write?\n' | "$Q" input save --repo "$R3"); rc=$?
ok "input save: prints a repo-relative path under .opsx/questions/input-" '[ $rc -eq 0 ] && [[ $out =~ ^\.opsx/questions/input-[0-9]{8}-[0-9]{6}-[a-z0-9]{4}/input\.md$ ]] && [ -f "$R3/$out" ]'
IN1=$out
"$Q" cite --repo "$R3" -- "$IN1" 2 "where does X write" >/dev/null 2>&1; rc=$?
ok "input save: the saved input is citable (cite line 2 exits 0)" '[ $rc -eq 0 ]'
IN2=$(printf 'again\n' | "$Q" input save --repo "$R3")
ok "input save: .opsx/questions/ in .gitignore exactly once after two saves" '[ "$(grep -cx ".opsx/questions/" "$R3/.gitignore")" -eq 1 ] && [ "$IN1" != "$IN2" ]'
IN3=$(printf 'a\tb\033[31m red\rx\001\n' | "$Q" input save --repo "$R3")
ok "input save: control characters stripped except newlines, tab becomes a space" '! LC_ALL=C grep -q "[[:cntrl:]]" <(tr -d "\n" < "$R3/$IN3") && grep -qF "a b[31m red x" "$R3/$IN3"'
printf '' | "$Q" input save --repo "$R3" >/dev/null 2>&1; rc=$?
ok "input save: empty stdin exits 2" '[ $rc -eq 2 ]'
"$Q" input --repo "$R3" </dev/null >/dev/null 2>&1; rc=$?
ok "input: without save exits 2" '[ $rc -eq 2 ]'
R4=$(newrepo r4); mkdir -p "$SP/elsewhere"
ln -s "$SP/elsewhere" "$R4/.opsx"
printf 'x\n' | "$Q" input save --repo "$R4" >/dev/null 2>&1; rc=$?
ok "input save: symlinked .opsx refused, nothing written" '[ $rc -eq 2 ] && [ -z "$(ls -A "$SP/elsewhere")" ] && [ ! -e "$R4/.gitignore" ]'
R5=$(newrepo r5); mkdir -p "$R5/.opsx" "$SP/elsewhere2"
ln -s "$SP/elsewhere2" "$R5/.opsx/questions"
printf 'x\n' | "$Q" input save --repo "$R5" >/dev/null 2>&1; rc=$?
ok "input save: symlinked .opsx/questions refused, nothing written" '[ $rc -eq 2 ] && [ -z "$(ls -A "$SP/elsewhere2")" ]'
# Scenario "Gap with a fabricated citation is dropped".
IN4=$(printf 'We cache results.\nThe cache is local.\nNothing else.\nX is kept in memory.\n' | "$Q" input save --repo "$R3")
"$Q" cite --repo "$R3" -- "$IN4" 4 "X is stored" >/dev/null 2>&1; rc=$?
ok "coverage: a gap with a fabricated citation fails cite -- (exit 1)" '[ $rc -eq 1 ]'
"$Q" cite --repo "$R3" -- "$IN4" 4 "X is kept in memory" >/dev/null 2>&1; rc=$?
ok "coverage: a gap with a real citation passes cite -- (exit 0)" '[ $rc -eq 0 ]'

# ---------------------------------------------------------------- shellcheck (1.6)
if command -v shellcheck >/dev/null 2>&1; then
  ok "shellcheck questions.sh, webfetch-guard.sh and this test" 'shellcheck "$Q" "$REPO/skills/opsx-questions/webfetch-guard.sh" "$REPO/tests/test-questions.sh"'
fi

cd "$REPO" || exit 1
# ---------------------------------------------------------------- agent + reference (2.x)
AG=$REPO/agents/opsx-researcher.md
REFMD=$REPO/skills/opsx-questions/reference.md
fm(){ awk '/^---$/{n++; next} n==1' "$1"; }
ok "researcher: name ops-researcher, model inherit, bypassPermissions" 'fm "$AG" | grep -qx "name: \"ops-researcher\"" && fm "$AG" | grep -qx "model: inherit" && fm "$AG" | grep -qx "permissionMode: bypassPermissions"'
ok "researcher: Claude tools exactly Read, Glob, Grep, WebSearch, WebFetch" '[ "$(fm "$AG" | grep "^tools:")" = "tools: [Read, Glob, Grep, WebSearch, WebFetch]" ] && ! fm "$AG" | grep -qE "Write|Edit|Bash|Agent|NotebookEdit|mcp__"'
ok "researcher: PreToolUse hook on WebFetch runs webfetch-guard.sh" 'fm "$AG" | grep -qx "hooks:" && fm "$AG" | grep -qx "  PreToolUse:" && fm "$AG" | grep -qx "    - matcher: \"WebFetch\"" && fm "$AG" | grep -qx "          command: \"\$HOME/.claude/skills/opsx-questions/webfetch-guard.sh\""'
ok "researcher: never puts file contents into a URL" 'grep -q "never put file contents into a URL" "$AG"'
ok "researcher: verdict only, untrusted data, no writes" 'grep -q "VERDICT: <verdict>" "$AG" && grep -qi "data, not instructions" "$AG" && grep -q "No writes, no commands" "$AG"'
ok "reference: brief fields, untrusted rules, challenge briefs omit the rationale" 'for w in "Question" "Stance" "Context" "Ruled out" "Untrusted input rules" "UNTRUSTED DATA"; do grep -q "$w" "$REFMD" || exit 1; done && grep -qi "omit the parent.s rationale" "$REFMD"'
ok "format defined once: same VERDICT line and four evidence forms in both files" 'for f in "$AG" "$REFMD"; do grep -qx "VERDICT: <verdict>" "$f" || exit 1; for e in "file:<path>:<line> \"<excerpt>\"" "url:<url> \"<excerpt>\"" "ticket:<key>:<field> \"<excerpt>\"" "req:<id> \"<excerpt>\""; do grep -qxF "$e" "$f" || exit 1; done; done'
ok "reference: both downgrade rules and the concrete-flaw rule" 'grep -q "left with no valid evidence becomes \`needs-human\`" "$REFMD" && grep -q "left with no valid evidence becomes \`stands\`" "$REFMD" && grep -q "concrete flaw" "$REFMD" && grep -q "still seems right" "$REFMD"'
ok "reference: malformed retry, report tags, Resolved: bullets, drafts" 'grep -qi "retried once" "$REFMD" && for t in "[open]" "[decision]" "[req spec]" "[req client AC]"; do grep -qF "$t" "$REFMD" || exit 1; done && grep -q "Resolved:" "$REFMD" && grep -qi "never posted" "$REFMD" && grep -qi "product owner" "$REFMD"'

ok "coverage stance in agent and reference: VERDICT: covered|gaps and gap: line with evidence" 'for f in "$AG" "$REFMD"; do grep -qF "VERDICT: covered|gaps" "$f" || exit 1; grep -qxF "gap: <kind> \"<text>\"" "$f" || exit 1; grep -qi "followed by exactly one evidence item" "$f" || exit 1; done && grep -qi "do not invent gaps without a source line" "$AG" && fm "$AG" | grep -q "coverage stance"'
ok "reference: coverage loop stops on no surviving gap or at --coverage-rounds, fresh subagent, cap note" 'grep -qi "a round leaves no surviving gap" "$REFMD" && grep -q -- "--coverage-rounds\` rounds" "$REFMD" && grep -qi "fresh\*\* \`ops-researcher\` that never sees the results of earlier coverage rounds" "$REFMD" && grep -q "coverage incomplete after <n> rounds" "$REFMD"'
ok "reference: gap validated with cite --, fabricated dropped and listed, duplicates, coverage:<round>, counted" 'grep -q "only with evidence that passes \`cite --\`" "$REFMD" && grep -qi "fabricated citation exits 1" "$REFMD" && grep -qi "Dropped gaps are shown" "$REFMD" && grep -qi "duplicates an item already in the list" "$REFMD" && grep -q "coverage:<round>" "$REFMD" && grep -qi "plus the coverage subagents" "$REFMD" && grep -q "questions.sh input save" "$REFMD"'

# ---------------------------------------------------------------- skills (3.x)
for s in opsx-answer opsx-challenge opsx-settle; do
  SK=$REPO/skills/$s/SKILL.md
  ok "$s: frontmatter name and description" 'fm "$SK" | grep -qx "name: $s" && fm "$SK" | grep -q "^description: ."'
  ok "$s: names questions.sh, --max defaults to 6, six skill folders" 'grep -q "questions.sh" "$SK" && grep -q -- "--max\` defaults to 6" "$SK" && for d in .claude .cursor .agents .codex .config/opencode .gemini; do grep -q "~/$d/skills/opsx-questions/questions.sh" "$SK" || exit 1; done'
  ok "$s: coverage check first, then the list confirmed before any research subagent" 'grep -q "Confirm the list" "$SK" && grep -qi "do not start any research subagent" "$SK" && [ "$(grep -n "\*\*Coverage check\*\*" "$SK" | cut -d: -f1)" -lt "$(grep -n "\*\*Confirm the list\.\*\*" "$SK" | cut -d: -f1)" ] && grep -q "After the coverage check" "$SK"'
  ok "$s: --coverage-rounds defaults to 3, 0 skips, in the usage line" 'grep -q -- "--coverage-rounds\` defaults to 3" "$SK" && grep -q -- "\`0\` skips the check" "$SK" && grep -m1 -E "^/$s \[input\]" "$SK" | grep -q -- "\[--coverage-rounds N\]"'
  ok "$s: coverage loop: fresh subagent, gap needs cite --, duplicates, stop, cap note, Codex/Gemini parent" 'grep -q "fresh\*\* \`ops-researcher\`" "$SK" && grep -qi "never sees earlier coverage results" "$SK" && grep -q "only with evidence that passes \`\"\$QS\" cite --" "$SK" && grep -qi "duplicates a listed item" "$SK" && grep -q "coverage:<round>" "$SK" && grep -q "coverage incomplete after <n> rounds" "$SK" && grep -q "questions.sh input save" "$SK" && grep -qi "Gemini CLI you do the coverage pass yourself" "$SK" && grep -qi "coverage subagents" "$SK"'
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
ok "install: Claude researcher hook names the installed webfetch-guard.sh, which is executable" 'fm "$IH/.claude/agents/opsx-researcher.md" | grep -qxF "          command: '"'"'$IH/.claude/skills/opsx-questions/webfetch-guard.sh'"'"'" && [ -x "$IH/.claude/skills/opsx-questions/webfetch-guard.sh" ]'
ok "install: the installed guard blocks a built URL and allows a docs URL" 'printf "{\"tool_input\":{\"url\":\"https://e.example/?d=1\"}}" | "$IH/.claude/skills/opsx-questions/webfetch-guard.sh" 2>/dev/null; [ $? -eq 2 ] && printf "{\"tool_input\":{\"url\":\"https://docs.example.com/\"}}" | "$IH/.claude/skills/opsx-questions/webfetch-guard.sh"'
ok "install: Gemini researcher carries no Claude hooks block" '! fm "$IH/.gemini/agents/opsx-researcher.md" | grep -qE "^hooks:|webfetch-guard|PreToolUse"'
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
ok "README: coverage check, --coverage-rounds default and its cost" 'sed -n "/^### Answering and challenging questions/,/^---\$/p" "$RD" > "$SP/rdq" && grep -q "^\*\*Coverage check\.\*\*" "$SP/rdq" && grep -q -- "--coverage-rounds\` to 3" "$SP/rdq" && grep -q "questions.sh input save" "$SP/rdq" && grep -q "coverage subagents" "$SP/rdq"'
ok "README questions.sh commands exist in the script usage" '( for c in $(grep -oE "questions\.sh [a-z]+" "$RD" | awk "{print \$2}" | sort -u); do "$Q" --help | grep -qE "questions\.sh $c( |\$)" || { echo "missing: $c"; exit 1; }; done )'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
