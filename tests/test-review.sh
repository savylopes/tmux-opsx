#!/usr/bin/env bash
# Scripted tests for skills/opsx-review/opsx-review.sh.
#
# Uses a fake `gh` that serves canned PR JSON, a scratch git repo, and a private
# tmux server (tmux -L review-test-$$), so your repos, GitHub and tmux sessions
# are never touched.
# Usage: bash tests/test-review.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016,SC2086
set -u
command -v tmux >/dev/null 2>&1 || { echo "tmux is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
RV=$REPO/skills/opsx-review/opsx-review.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/review-test.XXXXXX")
L="tmux -L review-test-$$"
trap '$L kill-server 2>/dev/null; rm -rf "$SP"' EXIT
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

# ---------------------------------------------------------------- fakes
mkdir -p "$SP/fakebin"
G="git -c user.name=t -c user.email=t@t"
R=$SP/work/app; mkdir -p "$R"
$G -C "$R" init -q -b main
echo a > "$R/a"; $G -C "$R" add a; $G -C "$R" commit -qm init
SHA=$($G -C "$R" rev-parse HEAD)
pr_json() { # number head title body state
  jq -nc --argjson n "$1" --arg h "$2" --arg t "$3" --arg b "$4" --arg s "$5" --arg sha "$SHA" \
    '{number:$n,url:"https://github.com/o/app/pull/\($n)",title:$t,author:{login:"leo"},
      headRefName:$h,headRefOid:$sha,baseRefName:"dev",state:$s,body:$b}'
}
{
  pr_json 8 feat/MED-35-db-foundation "Add database foundation" "" OPEN
  pr_json 9 feat/MED-77-logto-client "Add Logto client" "Jira: MED-77. Overlaps MED-35x" OPEN
  pr_json 10 fix-typo "Fix typo" "Refs ABC-4" OPEN
  pr_json 11 feat/MED-50-a "Part A" "" OPEN
  pr_json 12 feat/MED-50-b "Part B" "" OPEN
  pr_json 13 chore/cleanup "Old MED-60 work" "" MERGED
} > "$SP/prs.jsonl"
cat > "$SP/fakebin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SP/gh.log"
case "\$1 \$2" in
  "pr view")
    jq -c --argjson n "\$3" 'select(.number==\$n)' "$SP/prs.jsonl" | grep . || { echo "no pull requests found" >&2; exit 1; } ;;
  "pr list")
    state=open; while [ \$# -gt 0 ]; do [ "\$1" = --state ] && state=\$2; shift; done
    if [ "\$state" = open ]; then jq -s -c '[.[] | select(.state=="OPEN")]' "$SP/prs.jsonl"
    else jq -s -c '.' "$SP/prs.jsonl"; fi ;;
  *) echo "unexpected gh \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$SP/fakebin/gh"
export PATH=$SP/fakebin:$PATH
get() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# ---------------------------------------------------------------- resolve
out=$("$RV" resolve 8 --repo "$R"); rc=$?
ok "resolve PR number" '[ $rc -eq 0 ] && [ "$(get "$out" ticket)" = MED-35 ] && [ "$(get "$out" change)" = review-med-35-db-foundation ] && [ "$(get "$out" head_sha)" = "$SHA" ] && [ "$(get "$out" base)" = dev ]'
out=$("$RV" resolve '#8' --repo "$R")
ok "resolve #N form" '[ "$(get "$out" pr)" = 8 ]'
out=$("$RV" resolve https://github.com/o/app/pull/9 --repo "$R")
ok "resolve PR URL, ticket from branch" '[ "$(get "$out" ticket)" = MED-77 ] && [ "$(get "$out" change)" = review-med-77-logto-client ]'
out=$("$RV" resolve 10 --repo "$R")
ok "ticket from body when branch and title have none" '[ "$(get "$out" ticket)" = ABC-4 ] && [ "$(get "$out" change)" = review-abc-4-fix-typo ]'
out=$("$RV" resolve med-35 --repo "$R"); rc=$?
ok "resolve ticket key (lower case), whole-key match only" '[ $rc -eq 0 ] && [ "$(get "$out" pr)" = 8 ]'
out=$("$RV" resolve MED-50 --repo "$R" 2>&1); rc=$?
ok "ambiguous ticket exits 3 and lists candidates" '[ $rc -eq 3 ] && printf "%s" "$out" | grep -q "pr=11" && printf "%s" "$out" | grep -q "pr=12"'
out=$("$RV" resolve MED-60 --repo "$R"); rc=$?
ok "falls back to closed/merged PRs" '[ $rc -eq 0 ] && [ "$(get "$out" pr)" = 13 ] && [ "$(get "$out" ticket)" = MED-60 ] && [ "$(get "$out" change)" = review-med-60-cleanup ]'
out=$("$RV" resolve MED-999 --repo "$R" 2>&1); rc=$?
ok "unknown ticket exits 2" '[ $rc -eq 2 ] && printf "%s" "$out" | grep -q "no pull request mentions MED-999"'
out=$("$RV" resolve 404 --repo "$R" 2>&1); rc=$?
ok "unknown PR exits 2" '[ $rc -eq 2 ]'
out=$("$RV" resolve 'not a thing' --repo "$R" 2>&1); rc=$?
ok "garbage argument rejected" '[ $rc -eq 1 ]'
out=$(cd "$SP" && "$RV" resolve 8 2>&1); rc=$?
ok "outside a repo without --repo fails clearly" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q -- "--repo"'

# ---------------------------------------------------------------- worktree
out=$("$RV" worktree review-med-35-db-foundation "$SHA" --repo "$R"); rc=$?
WT=$SP/work/wt-review-med-35-db-foundation
ok "worktree created detached at the SHA" '[ $rc -eq 0 ] && [ "$(git -C "$WT" rev-parse HEAD)" = "$SHA" ] && ! git -C "$WT" symbolic-ref -q HEAD >/dev/null'
ok "shared checkout branch untouched" '[ "$(git -C "$R" symbolic-ref --short HEAD)" = main ]'
out=$("$RV" worktree review-med-35-db-foundation "$SHA" --repo "$R")
ok "worktree reused on second call" 'printf "%s" "$out" | grep -q "worktree reused"'
echo b > "$R/b"; $G -C "$R" add b; $G -C "$R" commit -qm two
out=$("$RV" worktree review-med-35-db-foundation "$($G -C "$R" rev-parse HEAD)" --repo "$R" 2>&1); rc=$?
ok "worktree at another SHA refused" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "remove it first"'

# ---------------------------------------------------------------- session
$L kill-server 2>/dev/null
$L -f /dev/null new-session -d -s 12 -x 120 -y 40 'exec sleep 300'
$L -f /dev/null new-session -d -s taken 'exec sleep 300'
sock=$($L display -p '#{socket_path}'); pid=$($L display -p '#{pid}')
P=$($L display -p -t 12 '#{pane_id}')
run_session() { env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID TMUX="$sock,$pid,0" TMUX_PANE=$P "$RV" session "$@" 2>&1; }
out=$(run_session MED-35-review); rc=$?
ok "session renamed" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "session renamed 12 -> MED-35-review" && $L has-session -t "=MED-35-review"'
ok "no /rename hint outside Claude Code" '! printf "%s" "$out" | grep -q /rename'
out=$(run_session MED-35-review)
ok "same name is unchanged" 'printf "%s" "$out" | grep -q "session unchanged MED-35-review"'
out=$(run_session taken); rc=$?
ok "existing session name refused, both sessions keep their names" '[ $rc -eq 1 ] && $L has-session -t "=MED-35-review" && $L has-session -t "=taken"'
out=$(run_session 'v1.2: x'); rc=$?
ok "tmux metacharacters folded" '[ $rc -eq 0 ] && $L has-session -t "=v1-2-x"'
out=$(env CLAUDECODE=1 TMUX="$sock,$pid,0" TMUX_PANE=$P "$RV" session MED-35-review 2>&1)
ok "Claude Code gets the /rename hint" 'printf "%s" "$out" | grep -q "claude: type /rename MED-35-review"'
out=$(env -u TMUX -u TMUX_PANE "$RV" session X 2>&1); rc=$?
ok "outside tmux is a no-op" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "not inside tmux"'

# ---------------------------------------------------------------- safety
ok "gh only ever read (view/list)" '! grep -vE "^pr (view|list) " "$SP/gh.log"'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
