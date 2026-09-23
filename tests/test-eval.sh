#!/usr/bin/env bash
# Scripted tests for skills/opsx-run/opsx-eval.sh and the eval gate in opsx-land.sh.
#
# Everything runs in a scratch dir with fixture suites and scratch git repos;
# `openspec` is replaced by a fake on PATH so land's OpenSpec gates are
# predictable. Never touches your repos, tmux session or agent CLIs.
# Usage: bash tests/test-eval.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016
set -u
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
E=$REPO/skills/opsx-run/opsx-eval.sh
LAND=$REPO/skills/opsx-run/opsx-land.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/eval-test.XXXXXX")
trap 'rm -rf "$SP"' EXIT
export NO_COLOR=1
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

# mkcheck <root> <cap> <slug> <scenario> <level> <body>
mkcheck() {
  mkdir -p "$1/evals/$2"
  printf '#!/usr/bin/env bash\n# scenario: %s / %s\n# level: %s\n%s\n' "$2" "$4" "$5" "$6" > "$1/evals/$2/$3.check"
  chmod +x "$1/evals/$2/$3.check"
}

# ------------------------------------------------------------ runner fixture
F=$SP/fx
mkdir -p "$F/evals"
cat > "$F/evals/eval.yaml" <<'EOF'
# fixture config
setup: printf 'FROM_SETUP=yes\n' >> "$EVAL_ENV_FILE"; : > "$EVAL_ROOT/setup.ran"
teardown: : > "$EVAL_ROOT/teardown.ran"
env:
  GREETING: "hello # not a comment"
timeout: 2
agentic: { trials: 3, threshold: 5, cli: fakecli }
EOF
mkcheck "$F" core ok "Passes" L1 'echo "g=$GREETING s=$FROM_SETUP"; [ -d "$EVAL_TMP" ] && [ -n "$EVAL_ROOT" ]'
mkcheck "$F" core unv "Unverifiable" L1 'echo "needs a display"; exit 77'
mkcheck "$F" core bad "Fails" L2 'echo "boom"; exit 3'
mkcheck "$F" core slow "Too slow" L1 'sleep 30'
mkcheck "$F" core tmpfresh "Fresh tmp" L1 '[ -z "$(ls -A "$EVAL_TMP")" ] && touch "$EVAL_TMP/x"'
# L3 passes on trials 1-4 only; counts invocations in the fixture dir.
mkcheck "$F" agent flaky "Flaky agent" L3 'echo "$EVAL_TRIAL" >> "$EVAL_ROOT/l3.log"; [ "$EVAL_AGENT_CLI" = fakecli ] && [ "$EVAL_TRIAL" -le 4 ]'
mkdir -p "$F/openspec/changes/chg/specs/core"
cat > "$F/openspec/changes/chg/specs/core/spec.md" <<'EOF'
## ADDED Requirements
### Requirement: Stuff
#### Scenario: Passes
- **WHEN** x
- **THEN** y
#### Scenario: Not yet checked
- **WHEN** x
- **THEN** y
## REMOVED Requirements
### Requirement: Old
#### Scenario: Removed one
EOF

out=$("$E" --root "$F" --all); rc=$?
ok "exit 1 when a check fails"               '[ "$rc" -eq 1 ]'
ok "exit 0 -> PASS"                           'grep -q "^PASS .*core/ok" <<<"$out"'
ok "exit 77 -> UNVERIFIABLE"                  'grep -q "^UNVERIFIABLE .*core/unv" <<<"$out"'
ok "exit 3 -> FAIL"                           'grep -q "^FAIL .*core/bad" <<<"$out"'
ok "timeout -> FAIL with note"                'grep -A1 "^FAIL .*core/slow" <<<"$out" | grep -q "timeout after 2s"'
ok "evidence shown for FAIL"                  'grep -A2 "core/bad" <<<"$out" | grep -q "boom"'
ok "L3 NOT RUN by default"                    'grep -q "^NOT RUN .*agent/flaky" <<<"$out" && [ ! -e "$F/l3.log" ]'
ok "fresh EVAL_TMP per check"                 'grep -q "^PASS .*core/tmpfresh" <<<"$out"'
ok "totals line"                              'grep -q "Total 6 · 2 pass · 2 fail · 1 unverifiable · 1 not run · 0 missing" <<<"$out"'
ok "setup and teardown ran"                   '[ -e "$F/setup.ran" ] && [ -e "$F/teardown.ran" ]'

json=$("$E" --root "$F" --all --json)
ok "--json is valid JSON"                     'if command -v jq >/dev/null; then jq -e . >/dev/null <<<"$json"; else python3 -m json.tool >/dev/null <<<"$json"; fi'
ok "--json has env + setup evidence"          'grep -q "\"evidence\":\"g=hello # not a comment s=yes\"" <<<"$json"'
ok "--json keeps full evidence"               'grep -q "\"evidence\":\"needs a display\"" <<<"$json"'

rm -f "$F/l3.log"
out=$("$E" --root "$F" --capability agent --agentic --trials 5); rc=$?
ok "--agentic runs N trials"                  '[ "$(wc -l < "$F/l3.log")" -eq 5 ]'
ok "L3 4/5 with threshold 5 -> FAIL"          'grep -q "^FAIL .*agent/flaky" <<<"$out" && grep -q "pass rate 4/5" <<<"$out" && [ "$rc" -eq 1 ]'
rm -f "$F/l3.log"
out=$("$E" --root "$F" --capability agent --agentic --trials 4); rc=$?
ok "L3 4/4 -> PASS (threshold capped)"        'grep -q "^PASS .*agent/flaky" <<<"$out" && [ "$rc" -eq 0 ]'

out=$("$E" --root "$F" --change chg)
ok "--change scopes to delta capabilities"    '! grep -q "agent/flaky" <<<"$out" && grep -q "core/ok" <<<"$out"'
ok "--change reports MISSING"                 'grep -q "^MISSING .*core/not-yet-checked" <<<"$out"'
ok "REMOVED scenarios are not MISSING"        '! grep -q "removed-one" <<<"$out"'
ok "covered scenario not MISSING"             '! grep -q "MISSING .*core/passes" <<<"$out"'

rm -f "$F/teardown.ran"
mkcheck "$F" gone only "Only" L1 'exit 5'
"$E" --root "$F" --capability gone >/dev/null; rc=$?
ok "teardown runs after a failure"            '[ "$rc" -eq 1 ] && [ -e "$F/teardown.ran" ]'
rm -rf "$F/evals/gone"

# Interrupt: teardown still runs.
rm -f "$F/teardown.ran"
"$E" --root "$F" --capability core >/dev/null 2>&1 &
epid=$!; sleep 1; kill -INT "$epid" 2>/dev/null; wait "$epid" 2>/dev/null
ok "teardown runs on interrupt"               '[ -e "$F/teardown.ran" ]'

a=$("$E" --root "$F" --capability core --json | grep '"id"' | sed 's/"seconds":[0-9]*//; s/tmp\.[A-Za-z0-9]*//g')
b=$("$E" --root "$F" --capability core --json | grep '"id"' | sed 's/"seconds":[0-9]*//; s/tmp\.[A-Za-z0-9]*//g')
ok "deterministic rerun"                      '[ "$a" = "$b" ]'

# Config / runner errors -> exit 2
C=$SP/cfg; mkdir -p "$C/evals"; printf 'timeout: soon\n' > "$C/evals/eval.yaml"
"$E" --root "$C" >/dev/null 2>&1; rc=$?
ok "bad eval.yaml -> exit 2"                  '[ "$rc" -eq 2 ]'
"$E" --root "$F" --change nope >/dev/null 2>&1; rc=$?
ok "unknown change -> exit 2"                 '[ "$rc" -eq 2 ]'
"$E" --bogus >/dev/null 2>&1; rc=$?
ok "unknown option -> exit 2"                 '[ "$rc" -eq 2 ]'
printf 'setup: exit 4\nteardown: : > "$EVAL_ROOT/td"\n' > "$C/evals/eval.yaml"; mkcheck "$C" x y "Y" L1 'exit 0'
"$E" --root "$C" >/dev/null 2>&1; rc=$?
ok "setup failure -> exit 2, teardown runs"   '[ "$rc" -eq 2 ] && [ -e "$C/td" ]'

# Defaults without eval.yaml
D=$SP/defaults; mkcheck "$D" cap a "A" L1 'exit 0'
out=$("$E" --root "$D"); rc=$?
ok "no eval.yaml -> defaults"                 '[ "$rc" -eq 0 ] && grep -q "^PASS .*cap/a" <<<"$out"'
out=$("$E" --root "$SP/empty-nowhere" 2>&1); rc=$?
ok "missing root -> exit 2"                   '[ "$rc" -eq 2 ]'
mkdir -p "$SP/noevals"; out=$("$E" --root "$SP/noevals"); rc=$?
ok "no evals/ -> exit 0, no checks"           '[ "$rc" -eq 0 ] && grep -q "no checks in scope" <<<"$out"'

# Regression compare
mkcheck "$SP/cmp" auth login-ok "Login ok" L1 'exit 0'
mkcheck "$SP/cmp" auth new-thing "New thing" L1 'exit 1'
"$E" --root "$SP/cmp" --json > "$SP/base.json"
mkcheck "$SP/cmp" auth login-ok "Login ok" L1 'exit 1'
mkcheck "$SP/cmp" auth brand-new "Brand new" L1 'exit 1'
"$E" --root "$SP/cmp" --json > "$SP/cur.json"
out=$("$E" --compare "$SP/base.json" "$SP/cur.json"); rc=$?
ok "compare reports REGRESSION"               '[ "$rc" -eq 1 ] && grep -q "^REGRESSION auth/login-ok" <<<"$out"'
ok "compare ignores old/new failures"         '! grep -q "new-thing\|brand-new" <<<"$out"'
out=$("$E" --compare "$SP/base.json" "$SP/base.json"); rc=$?
ok "compare identical -> exit 0"              '[ "$rc" -eq 0 ]'

# ------------------------------------------------------------ land gate
mkdir -p "$SP/bin"
cat > "$SP/bin/openspec" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  validate) exit 0 ;;
  status)   echo '{"isComplete": true}' ;;
  archive)  mkdir -p openspec/changes/archive && mv "openspec/changes/$2" "openspec/changes/archive/$2" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SP/bin/openspec"
export PATH=$SP/bin:$PATH
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# newrepo <dir> [with-evals]: main with a passing auth/login-ok check (optional)
newrepo() {
  rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q -b main
  mkdir -p "$1/openspec/changes/chg"; printf -- '- [x] done\n' > "$1/openspec/changes/chg/tasks.md"
  echo good > "$1/app.txt"
  if [ "${2:-}" = with-evals ]; then
    mkcheck "$1" auth login-ok "Login ok" L1 'grep -qx good "$EVAL_ROOT/app.txt"'
  fi
  git -C "$1" add -A; git -C "$1" commit -q -m init
  git -C "$1" checkout -q -b opsx/chg
}
land() { ( cd "$1" && shift && "$LAND" chg --no-close "$@" ) 2>&1; }

# 1. regression blocks and restores target
R=$SP/land1; newrepo "$R" with-evals
echo broken > "$R/app.txt"; git -C "$R" commit -qam "break app"
git -C "$R" checkout -q main; before=$(git -C "$R" rev-parse main)
out=$(land "$R"); rc=$?
ok "land: regression blocks"                  '[ "$rc" -ne 0 ] && grep -q "EVAL_REGRESSION" <<<"$out" && grep -q "REGRESSION auth/login-ok" <<<"$out"'
ok "land: target restored to pre-merge"       '[ "$(git -C "$R" rev-parse main)" = "$before" ]'
ok "land: nothing archived"                   '[ -d "$R/openspec/changes/chg" ] && [ ! -d "$R/openspec/changes/archive" ]'
ok "land: branch kept after block"            'git -C "$R" show-ref -q refs/heads/opsx/chg'
ok "land: no temp worktrees left"             '[ "$(git -C "$R" worktree list | wc -l)" -eq 1 ]'

# 2. new failing check only warns
R=$SP/land2; newrepo "$R" with-evals
mkcheck "$R" auth new-check "New check" L1 'exit 1'
git -C "$R" add -A; git -C "$R" commit -qm "add failing check"
git -C "$R" checkout -q main
out=$(land "$R"); rc=$?
ok "land: new failure warns and continues"    '[ "$rc" -eq 0 ] && grep -q "FAIL auth/new-check (not a regression" <<<"$out" && [ -d "$R/openspec/changes/archive/chg" ]'

# 3. no evals/ -> silent skip
R=$SP/land3; newrepo "$R"
echo more >> "$R/app.txt"; git -C "$R" commit -qam change
git -C "$R" checkout -q main
out=$(land "$R"); rc=$?
ok "land: no evals/ skips silently"           '[ "$rc" -eq 0 ] && ! grep -qi "eval" <<<"$out"'

# 4. --skip-eval bypasses a regression
R=$SP/land4; newrepo "$R" with-evals
echo broken > "$R/app.txt"; git -C "$R" commit -qam "break app"
git -C "$R" checkout -q main
out=$(land "$R" --skip-eval); rc=$?
ok "land: --skip-eval bypasses eval"          '[ "$rc" -eq 0 ] && grep -q "eval skipped (--skip-eval)" <<<"$out" && ! grep -q REGRESSION <<<"$out"'

# 5. L3 never runs during land
R=$SP/land5; newrepo "$R" with-evals
mkcheck "$R" agent l3 "Agentic" L3 'exit 1'
echo more >> "$R/app.txt"; git -C "$R" add -A; git -C "$R" commit -qm "add l3"
git -C "$R" checkout -q main
out=$(land "$R"); rc=$?
ok "land: L3 not run, not blocking"           '[ "$rc" -eq 0 ] && ! grep -q "agent/l3" <<<"$out"'

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
