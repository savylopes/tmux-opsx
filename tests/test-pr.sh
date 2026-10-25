#!/usr/bin/env bash
# Scripted tests for skills/opsx-pr/pr.sh and the `ask` mark of opsx-window.sh.
#
# Uses a fake `gh` that serves PR JSON from files, a scratch git repo with a
# bare `origin`, a scratch XDG_STATE_HOME, a stub agent CLI and a private tmux
# server (tmux -L pr-test-$$), so your repos, GitHub and tmux sessions are
# never touched.
# Usage: bash tests/test-pr.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016,SC2086
set -u
command -v tmux >/dev/null 2>&1 || { echo "tmux is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
SELF=$REPO/tests/$(basename -- "$0")
PRSH=$REPO/skills/opsx-pr/pr.sh
W=$REPO/skills/opsx-run/opsx-window.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/pr-test.XXXXXX")
SOCK=pr-test-$$
L="tmux -L $SOCK"
trap '$L kill-server 2>/dev/null; rm -rf "$SP"' EXIT
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
get() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# ---------------------------------------------------------------- scratch repo
G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
mkdir -p "$SP/work" "$SP/gh/api" "$SP/gh/checks" "$SP/fakebin" "$SP/home"
ORIGIN=$SP/origin.git
$G init -q --bare "$ORIGIN"
R=$SP/work/app
$G clone -q "$ORIGIN" "$R" 2>/dev/null
commit() { # dir file content msg
  printf '%s\n' "$3" > "$1/$2"; $G -C "$1" add "$2"; $G -C "$1" commit -qm "$4"
}
commit "$R" base.txt base init
$G -C "$R" push -q origin main
$G -C "$R" checkout -q -b feat-a
commit "$R" a.txt A "A"; commit "$R" b.txt B "B"
SHA_A=$($G -C "$R" rev-parse HEAD)
$G -C "$R" checkout -q -b feat-b
commit "$R" c.txt C "C"; commit "$R" d.txt D "D"
SHA_B=$($G -C "$R" rev-parse HEAD)
$G -C "$R" push -q origin feat-a feat-b
$G -C "$R" checkout -q main

# ---------------------------------------------------------------- fake gh
pr_obj() { # n head sha base state
  jq -nc --argjson n "$1" --arg h "$2" --arg s "$3" --arg b "$4" --arg st "$5" \
    '{number:$n,url:"https://github.com/o/app/pull/\($n)",headRefName:$h,headRefOid:$s,
      baseRefName:$b,state:$st,author:{login:"leo"},title:"t"}'
}
{
  pr_obj 41 old-x "$SHA_A" main MERGED
  pr_obj 42 feat-a "$SHA_A" main OPEN
  pr_obj 43 feat-b "$SHA_B" feat-a OPEN
  pr_obj 45 main "$SHA_A" main OPEN | jq -c '.isCrossRepository=true | .headRepositoryOwner={login:"evil"}'
} | jq -s . > "$SP/gh/prs.json"
setpr() { jq --argjson n "$1" "map(if .number==\$n then $2 else . end)" "$SP/gh/prs.json" > "$SP/gh/prs.tmp" && mv "$SP/gh/prs.tmp" "$SP/gh/prs.json"; }
api_file() { printf '%s/gh/api/%s' "$SP" "$(printf '%s' "$1" | tr '/' '_')"; }
cat > "$SP/fakebin/gh" <<EOF
#!/usr/bin/env bash
D=$SP/gh
printf '%s\n' "\$*" >> "\$D/gh.log"
opt() { local k=\$1; shift; while [ \$# -gt 0 ]; do [ "\$1" = "\$k" ] && { printf '%s' "\$2"; return; }; shift; done; }
case "\$1 \$2" in
  "repo view") case "\$*" in *defaultBranchRef*) echo main ;; *) echo o/app ;; esac ;;
  "pr view")
    jq -c --argjson n "\$3" '.[] | select(.number==\$n)' "\$D/prs.json" | grep . || { echo "no pull requests found" >&2; exit 1; } ;;
  "pr list")
    h=\$(opt --head "\$@"); st=\$(opt --state "\$@")
    jq -c --arg h "\$h" --arg st "\$st" '[.[] | select((\$h=="" or .headRefName==\$h) and (\$st!="open" or .state=="OPEN"))]' "\$D/prs.json" ;;
  "pr create")
    h=\$(opt --head "\$@"); n=\$(jq '[.[].number] | max + 1' "\$D/prs.json")
    jq --argjson n "\$n" --arg h "\$h" '. + [{number:\$n,url:"https://github.com/o/app/pull/\(\$n)",headRefName:\$h,headRefOid:"0",baseRefName:"main",state:"OPEN",author:{login:"leo"}}]' "\$D/prs.json" > "\$D/prs.tmp" && mv "\$D/prs.tmp" "\$D/prs.json"
    echo "https://github.com/o/app/pull/\$n" ;;
  "pr checks")
    f="\$D/checks/\$3.json"; [ -f "\$f" ] || { echo "no checks reported" >&2; exit 1; }; cat "\$f" ;;
  "api --paginate")
    [ -e "\$D/api_fail" ] && { echo "HTTP 502" >&2; exit 1; }
    f="\$D/api/\$(printf '%s' "\$3" | tr '/' '_')"; [ -f "\$f" ] || { echo '[]' | jq -r '.[].id'; exit 0; }
    jq -r '.[].id' "\$f" ;;
  "run rerun")
    [ -e "\$D/rerun_fail" ] && { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
    exit 0 ;;
  *) echo "unexpected gh \$*" >&2; exit 9 ;;
esac
EOF
cat > "$SP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
exec sleep 600
EOF
chmod +x "$SP/fakebin/gh" "$SP/fakebin/claude"
export PATH=$SP/fakebin:$PATH
export XDG_STATE_HOME=$SP/state HOME=$SP/home
unset OPSX_AGENT_CLI OPSX_MODEL OPSX_WINDOW CLAUDECODE CLAUDE_CODE_SESSION_ID
SD=$SP/state/tmux-opsx/pr
P() { "$PRSH" "$@" --repo "$R"; }

# ---------------------------------------------------------------- resolve (2.1)
out=$(P resolve 42); rc=$?
ok "resolve PR number" '[ $rc -eq 0 ] && [ "$(get "$out" pr)" = 42 ] && [ "$(get "$out" head)" = feat-a ] && [ "$(get "$out" base)" = main ] && [ "$(get "$out" state)" = OPEN ] && [ "$(get "$out" repo)" = o/app ] && [ "$(get "$out" author)" = leo ]'
out=$(P resolve '#42')
ok "resolve #N form" '[ "$(get "$out" pr)" = 42 ]'
out=$(P resolve https://github.com/o/app/pull/43)
ok "resolve PR URL" '[ "$(get "$out" pr)" = 43 ] && [ "$(get "$out" base)" = feat-a ]'
out=$(P resolve 999 2>&1); rc=$?
ok "unknown PR exits 2" '[ $rc -eq 2 ]'
out=$(P resolve not-a-pr 2>&1); rc=$?
ok "bad argument fails with a message, no pr= line" '[ $rc -ne 0 ] && [ -n "$out" ] && ! printf "%s" "$out" | grep -q "^pr="'
out=$(cd "$SP" && "$PRSH" resolve 42 2>&1); rc=$?
ok "outside a repo without --repo fails clearly" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q -- "--repo"'
out=$(P resolve https://github.com/x/other/pull/42 2>&1); rc=$?
ok "F2: URL of another repository refused" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "x/other" && ! printf "%s" "$out" | grep -q "^pr="'
ok "F2: gh pr calls name the repository with -R" 'grep "^pr view" "$SP/gh/gh.log" | grep -q -- "-R o/app" && ! grep "^pr view" "$SP/gh/gh.log" | grep -vq -- "-R o/app"'

# ---------------------------------------------------------------- state (2.2)
ST42=$SD/o-app-42/state; ST43=$SD/o-app-43/state
api42c=$(api_file repos/o/app/pulls/42/comments)
echo '[{"id":5},{"id":7}]' > "$api42c"
out=$(P seen 42); rc=$?
ok "seen writes the state file" '[ $rc -eq 0 ] && grep -qx "head_sha=$SHA_A" "$ST42" && grep -qx "base=main" "$ST42" && grep -q "^base_sha=[0-9a-f]\{40\}$" "$ST42" && grep -qx "last_comment_id=7" "$ST42"'
ok "state of an unstacked PR has no parent (a fork PR on a branch named main is not one)" 'grep -qx "parent=" "$ST42"'
P seen 43 >/dev/null
ok "stacked PR records its parent and parent tip" 'grep -qx "parent=42" "$ST43" && grep -qx "parent_tip=$SHA_A" "$ST43" && grep -qx "parent_base=main" "$ST43"'

# ---------------------------------------------------------------- wait (2.3)
t0=$(date +%s); out=$(P wait 42 --slice 2 --poll 1 2>/dev/null); rc=$?; dt=$(( $(date +%s) - t0 ))
ok "nothing changes: exit 3 within a few seconds, no event" '[ $rc -eq 3 ] && [ $dt -le 8 ] && ! printf "%s" "$out" | grep -q "^event="'
echo '[{"id":5},{"id":7},{"id":12}]' > "$api42c"
out=$(P wait 42 --slice 5 --poll 1); rc=$?
ok "new review comment -> event=comments" '[ $rc -eq 0 ] && [ "$out" = "event=comments" ] && grep -qx "last_event=comments" "$ST42"'
P seen 42 >/dev/null
out=$(P wait 42 --slice 1 --poll 1 2>/dev/null); rc=$?
ok "after seen the comment is no longer an event" '[ $rc -eq 3 ]'
echo '[{"id":3}]' > "$(api_file repos/o/app/issues/42/comments)"
out=$(P wait 42 --slice 2 --poll 1)
ok "new PR (issue) comment -> event=comments" '[ "$out" = "event=comments" ]'
P seen 42 >/dev/null
$G clone -q "$ORIGIN" "$SP/other" 2>/dev/null
commit "$SP/other" m1.txt m1 "main moves"; $G -C "$SP/other" push -q origin main
out=$(P wait 42 --slice 5 --poll 1)
ok "base moved -> event=base-moved" '[ "$out" = "event=base-moved" ]'
P seen 42 >/dev/null
setpr 42 '.headRefOid="1111111111111111111111111111111111111111"'
out=$(P wait 42 --slice 5 --poll 1)
ok "someone else pushed -> event=head-moved" '[ "$out" = "event=head-moved" ]'
setpr 42 ".headRefOid=\"$SHA_A\""
echo '[{"bucket":"pass"},{"bucket":"fail"}]' > "$SP/gh/checks/42.json"
out=$(P wait 42 --slice 5 --poll 1)
ok "failing check -> event=ci-failed" '[ "$out" = "event=ci-failed" ]'
P seen 42 >/dev/null
out=$(P wait 42 --slice 1 --poll 1 2>/dev/null); rc=$?
ok "a CI failure already seen is not reported again" '[ $rc -eq 3 ]'
# fix-opsx-pr-ci-gaps 1.1-1.3: cancelled checks fail, ci-failed once per head.
CK42=$SP/gh/checks/42.json
BBB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CCC=cccccccccccccccccccccccccccccccccccccccc
ok "wait records the reported head as ci_reported" 'grep -qx "ci_reported=$SHA_A" "$ST42"'
echo '[{"bucket":"pass"}]' > "$CK42"; P seen 42 >/dev/null
ok "seen with passing CI clears ci_reported" 'grep -qx "ci_reported=" "$ST42" && grep -qx "ci=pass" "$ST42"'
echo '[{"bucket":"pass"},{"bucket":"cancel"}]' > "$CK42"
out=$(P wait 42 --slice 5 --poll 1); rc=$?
ok "cancelled check -> event=ci-failed, exit 0" '[ $rc -eq 0 ] && [ "$out" = "event=ci-failed" ]'
P seen 42 >/dev/null
out=$(P wait 42 --slice 2 --poll 1 2>/dev/null); rc=$?
ok "reported failure stays quiet after seen (exit 3, no event)" '[ $rc -eq 3 ] && ! printf "%s" "$out" | grep -q "^event="'
echo '[{"bucket":"pass"}]' > "$CK42"; P seen 42 >/dev/null
echo '[{"bucket":"fail"}]' > "$CK42"; P seen 42 >/dev/null
ok "seen records ci=fail but never ci_reported" 'grep -qx "ci=fail" "$ST42" && grep -qx "ci_reported=" "$ST42"'
out=$(P wait 42 --slice 5 --poll 1)
ok "failure absorbed by seen is still reported" '[ "$out" = "event=ci-failed" ]'
P seen 42 >/dev/null
setpr 42 ".headRefOid=\"$BBB\""
out=$(P wait 42 --slice 5 --poll 1)
ok "new head with failing CI -> head-moved first" '[ "$out" = "event=head-moved" ]'
P seen 42 >/dev/null
out=$(P wait 42 --slice 5 --poll 1)
ok "failure on a new head is reported again" '[ "$out" = "event=ci-failed" ] && grep -qx "ci_reported=$BBB" "$ST42"'
setpr 42 ".headRefOid=\"$SHA_A\""; P seen 42 >/dev/null
sed -i '/^ci_reported=/d' "$ST42"
out=$(P wait 42 --slice 5 --poll 1)
ok "state without ci_reported reports a red PR once" '[ "$out" = "event=ci-failed" ]'
P seen 42 >/dev/null
out=$(P wait 42 --slice 1 --poll 1 2>/dev/null); rc=$?
ok "... and only once" '[ $rc -eq 3 ]'
# fix-opsx-pr-ci-gaps 2.1-2.3: pr.sh rerun, once per head.
run_link() { printf 'https://github.com/o/app/actions/runs/%s/job/%s' "$1" "$2"; }
jq -nc --arg l76 "$(run_link 76 9)" --arg l77a "$(run_link 77 1)" --arg l77b "$(run_link 77 2)" --arg l78 "$(run_link 78 3)" \
  '[{bucket:"pass",link:$l76},{bucket:"fail",link:$l77a},{bucket:"fail",link:$l77b},{bucket:"cancel",link:$l78}]' > "$CK42"
: > "$SP/gh/gh.log"
out=$(P rerun 42 2>/dev/null); rc=$?
ok "rerun: runs 77 and 78 once each with --failed, exit 0, rerun_head set" '[ $rc -eq 0 ] && [ "$(grep -c "^run rerun 77 --failed -R o/app$" "$SP/gh/gh.log")" -eq 1 ] && [ "$(grep -c "^run rerun 78 --failed -R o/app$" "$SP/gh/gh.log")" -eq 1 ] && ! grep -q "^run rerun 76" "$SP/gh/gh.log" && grep -qx "rerun_head=$SHA_A" "$ST42" && [ "$(get "$out" rerun_head)" = "$SHA_A" ]'
ok "rerun keeps the current failure reported (ci_reported=head)" 'grep -qx "ci_reported=$SHA_A" "$ST42"'
# F1: GitHub still shows the old failed checks right after the re-run.
P seen 42 >/dev/null
out=$(P wait 42 --slice 2 --poll 1 2>/dev/null); rc=$?
ok "old failed checks still showing after rerun are not a repeat failure" '[ $rc -eq 3 ] && [ -z "$out" ] && grep -qx "ci_reported=$SHA_A" "$ST42"'
CKFAIL=$(cat "$CK42")
jq -nc --arg l "$(run_link 77 4)" '[{bucket:"pending",link:$l}]' > "$CK42"
out=$(P wait 42 --slice 2 --poll 1 2>/dev/null); rc=$?
ok "wait sees the re-run pending: no event, ci_reported cleared" '[ $rc -eq 3 ] && grep -qx "ci_reported=" "$ST42"'
printf '%s\n' "$CKFAIL" > "$CK42"
out=$(P wait 42 --slice 5 --poll 1)
ok "failure again after a re-run on the same head is reported" '[ "$out" = "event=ci-failed" ]'
P seen 42 >/dev/null
: > "$SP/gh/gh.log"
out=$(P rerun 42 2>&1); rc=$?
ok "second rerun on the same head: exit 6, no gh run rerun" '[ $rc -eq 6 ] && printf "%s" "$out" | grep -q "already re-ran CI for $SHA_A" && ! grep -q "^run rerun" "$SP/gh/gh.log"'
setpr 42 ".headRefOid=\"$BBB\""
: > "$SP/gh/gh.log"
out=$(P rerun 42 2>/dev/null); rc=$?
ok "rerun on a new head re-runs again" '[ $rc -eq 0 ] && grep -q "^run rerun 77 --failed" "$SP/gh/gh.log" && grep -qx "rerun_head=$BBB" "$ST42"'
setpr 42 ".headRefOid=\"$SHA_A\""
echo '[{"bucket":"fail","link":"https://ci.example.com/o/app/builds/5"},{"bucket":"pass","link":"https://github.com/o/app/actions/runs/79/job/1"}]' > "$CK42"
: > "$SP/gh/gh.log"
out=$(P rerun 42 2>&1); rc=$?
ok "rerun with only an external CI failure: exit 7, no gh run rerun" '[ $rc -eq 7 ] && ! grep -q "^run rerun" "$SP/gh/gh.log" && grep -qx "rerun_head=$BBB" "$ST42"'
jq -nc --arg l "$(run_link 77 1)" '[{bucket:"fail",link:$l}]' > "$CK42"
touch "$SP/gh/rerun_fail"
out=$(P rerun 42 2>&1); rc=$?
ok "rerun when every gh run rerun fails: exit 1 with gh's error, rerun_head kept" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "HTTP 403" && grep -qx "rerun_head=$BBB" "$ST42"'
rm -f "$SP/gh/rerun_fail"
for CK in '[]' '[{"bucket":"pass","link":"https://github.com/o/app/actions/runs/79/job/1"}]'; do
  setpr 42 ".headRefOid=\"$CCC\""
  echo "$CK" > "$CK42"
  : > "$SP/gh/gh.log"
  out=$(P rerun 42 2>&1); rc=$?
  ok "rerun with nothing failing ($CK): exit 7, says nothing is failing (F2)" '[ $rc -eq 7 ] && printf "%s" "$out" | grep -q "no check of o/app#42 is failing" && ! printf "%s" "$out" | grep -q "GitHub Actions" && ! grep -q "^run rerun" "$SP/gh/gh.log"'
done
setpr 42 ".headRefOid=\"$SHA_A\""
ok "pr.sh --help lists rerun" '"$PRSH" --help | grep -qE "pr\.sh rerun "'
rm -f "$SP/gh/checks/42.json"; P seen 42 >/dev/null
setpr 42 '.state="MERGED"'
echo '[{"id":5},{"id":7},{"id":12},{"id":99}]' > "$api42c"
out=$(P wait 42 --slice 5 --poll 1)
ok "merged wins over new comments" '[ "$out" = "event=merged" ]'
setpr 42 '.state="CLOSED"'
out=$(P wait 42 --slice 5 --poll 1)
ok "closed -> event=closed" '[ "$out" = "event=closed" ]'
setpr 42 '.state="OPEN"'; P seen 42 >/dev/null
setpr 42 '.headRefOid="2222222222222222222222222222222222222222"'
out=$(P wait 43 --slice 5 --poll 1)
ok "parent head moved -> event=parent-moved on the child" '[ "$out" = "event=parent-moved" ]'
setpr 42 '.state="MERGED"'
out=$(P wait 43 --slice 5 --poll 1)
ok "parent merged -> event=parent-merged" '[ "$out" = "event=parent-merged" ]'
setpr 42 ".state=\"OPEN\" | .headRefOid=\"$SHA_A\""
# F1: parent merged, its branch deleted, GitHub moved the child's base to main.
P seen 43 >/dev/null
setpr 42 '.state="MERGED"'; setpr 43 '.baseRefName="main"'
out=$(P wait 43 --slice 5 --poll 1)
ok "F1: base retargeted by GitHub after the parent merged -> parent-merged" '[ "$out" = "event=parent-merged" ]'
P seen 43 >/dev/null
ok "F1: seen keeps parent and the pre-merge parent tip" 'grep -qx "parent=42" "$ST43" && grep -qx "parent_tip=$SHA_A" "$ST43" && grep -qx "parent_state=MERGED" "$ST43" && grep -qx "base=main" "$ST43"'
out=$(P wait 43 --slice 1 --poll 1 2>/dev/null); rc=$?
ok "F1: the merge is not reported again" '[ $rc -eq 3 ]'
setpr 42 '.state="OPEN"'; setpr 43 '.baseRefName="feat-a"'; P seen 43 >/dev/null
# F5: a failed comment fetch keeps the recorded ids.
before=$(grep "^last_comment_id=" "$ST42")
touch "$SP/gh/api_fail"; P seen 42 >/dev/null
ok "F5: failed gh api during seen keeps the comment ids" '[ "$(grep "^last_comment_id=" "$ST42")" = "$before" ] && [ "$before" != "last_comment_id=0" ]'
rm -f "$SP/gh/api_fail"
out=$(P wait 42 --slice 1 --poll 1 2>/dev/null); rc=$?
ok "F5: no false comments event afterwards" '[ $rc -eq 3 ]'
mv "$ST42" "$ST42.bak"
out=$(P wait 42 --slice 1 --poll 1 2>&1); rc=$?
ok "wait without a state file fails clearly" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "start"'
mv "$ST42.bak" "$ST42"

# ---------------------------------------------------------------- worktree (2.4)
out=$(P worktree 42 2>/dev/null); rc=$?
WT42=$SP/work/wt-pr-42
ok "new worktree ../wt-pr-42 on the head branch" '[ $rc -eq 0 ] && [ "$out" = "$WT42" ] && [ "$(git -C "$WT42" symbolic-ref --short HEAD)" = feat-a ]'
ok "main checkout branch unchanged" '[ "$(git -C "$R" symbolic-ref --short HEAD)" = main ]'
out=$(P worktree 42 2>&1 >/dev/null)
ok "second call reuses it" 'printf "%s" "$out" | grep -q "worktree reused"'
$G -C "$R" worktree add -q "$SP/work/wt-add-thing" feat-b
out=$(P worktree 43 2>/dev/null); rc=$?
ok "existing worktree of the branch reused" '[ $rc -eq 0 ] && [ "$out" = "$SP/work/wt-add-thing" ] && [ ! -e "$SP/work/wt-pr-43" ]'
echo dirty > "$SP/work/wt-add-thing/dirty.txt"
out=$(P worktree 43 2>&1); rc=$?
ok "dirty worktree refused" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "uncommitted"'
rm -f "$SP/work/wt-add-thing/dirty.txt"
# Security F1: a PR from a fork's `main` must never map onto origin/main.
for c in worktree restack push; do
  out=$(P $c 45 2>&1); rc=$?
  ok "fork PR refused by $c" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "fork (evil:main)"'
done
ok "fork PR: no worktree created" '[ ! -e "$SP/work/wt-pr-45" ]'
# Security F3: push leases the recorded head SHA.
commit "$WT42" p.txt P "P"
out=$(P push 42 2>/dev/null); rc=$?
NEW42=$(git -C "$WT42" rev-parse HEAD)
ok "push: lease on the recorded head, records the pushed SHA" '[ $rc -eq 0 ] && [ "$(get "$out" pushed)" = 1 ] && [ "$(git -C "$ORIGIN" rev-parse refs/heads/feat-a)" = "$NEW42" ] && grep -qx "head_sha=$NEW42" "$ST42"'
$G -C "$SP/other" fetch -q origin feat-a && $G -C "$SP/other" checkout -q -b feat-a FETCH_HEAD
commit "$SP/other" r.txt R "reviewer commit"; $G -C "$SP/other" push -q origin feat-a
THEIRS=$(git -C "$ORIGIN" rev-parse refs/heads/feat-a)
git -C "$WT42" fetch -q origin   # moves origin/feat-a; a bare --force-with-lease would now pass
$G -C "$WT42" commit -q --amend -m "P amended"
out=$(P push 42 2>&1); rc=$?
ok "push: someone else's newer commit is never overwritten (exit 5)" '[ $rc -eq 5 ] && [ "$(git -C "$ORIGIN" rev-parse refs/heads/feat-a)" = "$THEIRS" ] && grep -qx "head_sha=$NEW42" "$ST42"'
$G -C "$SP/other" checkout -q main

# ---------------------------------------------------------------- restack (2.5)
# Squash-merge parent 42 (A, B) into main on origin.
$G -C "$SP/other" pull -q origin main
printf 'A\n' > "$SP/other/a.txt"; printf 'B\n' > "$SP/other/b.txt"
$G -C "$SP/other" add a.txt b.txt; $G -C "$SP/other" commit -qm "Squashed: A and B (#42)"
$G -C "$SP/other" push -q origin main
setpr 42 '.state="MERGED"'; setpr 43 '.baseRefName="main"'
out=$(P restack 43 2>/dev/null); rc=$?
WTB=$SP/work/wt-add-thing
ok "squash-merged parent: branch holds only C and D on top of main" '[ $rc -eq 0 ] && [ "$(git -C "$WTB" log --format=%s origin/main..HEAD | tr "\n" " ")" = "D C " ] && git -C "$WTB" merge-base --is-ancestor origin/main HEAD && [ "$(get "$out" onto)" = origin/main ]'
# Conflict: main gets a different c.txt, then restack from the original D.
$G -C "$WTB" reset -q --hard "$SHA_B"
commit "$SP/other" c.txt "main's C" "main changes c"; $G -C "$SP/other" push -q origin main
out=$(P restack 43 2>/dev/null); rc=$?
ok "conflict stops with exit 4 and names the file" '[ $rc -eq 4 ] && printf "%s" "$out" | grep -qx "conflict=c.txt"'
ok "rebase left in progress for the agent" '[ -d "$(git -C "$WTB" rev-parse --git-path rebase-merge)" ] || [ -d "$(git -C "$WTB" rev-parse --git-path rebase-apply)" ]'
git -C "$WTB" rebase --abort 2>/dev/null
setpr 42 '.state="OPEN"'; setpr 43 '.baseRefName="feat-a"'

# ---------------------------------------------------------------- open (2.6)
$G -C "$R" checkout -q -b feat-new main; commit "$R" n.txt N "N"; $G -C "$R" checkout -q main
echo body > "$SP/b.md"
: > "$SP/gh/gh.log"
out=$(P open feat-new --title T --body-file "$SP/b.md"); rc=$?
ok "new PR: one pr create with head feat-new, pr= line" '[ $rc -eq 0 ] && [ "$(grep -c "^pr create" "$SP/gh/gh.log")" -eq 1 ] && grep -q "^pr create --head feat-new " "$SP/gh/gh.log" && [ "$(get "$out" pr)" = 46 ]'
ok "new PR: branch pushed to origin" 'git -C "$ORIGIN" rev-parse -q --verify refs/heads/feat-new >/dev/null'
: > "$SP/gh/gh.log"
out=$(P open feat-a --title T --body-file "$SP/b.md"); rc=$?
ok "existing PR: prints pr=42, no pr create" '[ $rc -eq 0 ] && [ "$(get "$out" pr)" = 42 ] && ! grep -q "^pr create" "$SP/gh/gh.log"'
out=$(P open feat-new2 --title T --body-file "$SP/b.md" 2>&1); rc=$?
ok "open of a missing branch fails" '[ $rc -eq 1 ]'
: > "$SP/gh/gh.log"
out=$(P open main --title T --body-file "$SP/b.md" 2>&1); rc=$?
ok "security F5: open refuses the default branch, pushes nothing" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "default branch" && ! grep -q "^pr create" "$SP/gh/gh.log"'
$G -C "$R" branch -q feat-x main
out=$(P open feat-x --base feat-x --title T --body-file "$SP/b.md" 2>&1); rc=$?
ok "security F5: open refuses a branch equal to --base" '[ $rc -eq 1 ] && ! git -C "$ORIGIN" rev-parse -q --verify refs/heads/feat-x >/dev/null'

# ---------------------------------------------------------------- shellcheck (2.7)
ok "shellcheck pr.sh and this test" '! command -v shellcheck >/dev/null || shellcheck "$PRSH" "$SELF"'

# ---------------------------------------------------------------- tmux server
$L kill-server 2>/dev/null
$L -f /dev/null new-session -d -s app -x 200 -y 50 -c "$R" 'exec sleep 3000'
sock=$($L display -p '#{socket_path}'); pid=$($L display -p '#{pid}')
PANE=$($L display -p -t app '#{pane_id}')
export TMUX="$sock,$pid,0" TMUX_PANE=$PANE
winof(){ $L list-windows -a -F '#{window_id} #{@opsx_change}' | awk -v n="$1" '$2==n{print $1}'; }
opt(){ $L show-options -wqv -t "$1" "$2"; }

# ---------------------------------------------------------------- start (3.2, 3.3)
rm -rf "$SD/o-app-42"
out=$("$PRSH" start 42 --repo "$WT42" --agent-cli claude 2>&1); rc=$?  # --repo is a worktree (F4)
WIN=$(winof pr-42)
ok "start: window tagged @opsx_change=pr-42" '[ $rc -eq 0 ] && [ -n "$WIN" ] && [ "$(winof pr-42 | wc -l)" -eq 1 ]'
ok "start: window tagged with the repo" '[ "$(opt "$WIN" @opsx_pr_repo)" = o/app ]'
GOAL=$SD/o-app-42/goal.txt; PROMPT=$SD/o-app-42/prompt.md
ok "start: goal names PR 42 and the merged, closed and stop exits" 'grep -q "o/app#42" "$GOAL" && grep -q MERGED "$GOAL" && grep -q CLOSED "$GOAL" && grep -q "said stop" "$GOAL"'
ok "start: Claude gets /goal with the dispatcher line, under 4000 chars" '[ -f "$PROMPT.goal" ] && head -c 6 "$PROMPT.goal" | grep -q "^/goal " && grep -q "Dispatcher steps: read $PROMPT" "$PROMPT.goal" && [ $(( $(wc -c < "$PROMPT.goal") - 7 )) -le 4000 ]'
ok "start writes state (head_sha, base, last_comment_id)" 'grep -q "^head_sha=" "$ST42" && grep -q "^base=" "$ST42" && grep -q "^last_comment_id=" "$ST42"'
ok "F3: a fresh start leaves CI unrecorded" 'grep -qx "ci=" "$ST42"'
ok "F3: prompt has a first-turn step for the current state" 'grep -q "^## First turn" "$PROMPT" && grep -q "gh pr checks 42 -R o/app" "$PROMPT" && grep -q "unresolved review threads" "$PROMPT"'
echo '[{"bucket":"fail"}]' > "$SP/gh/checks/42.json"
out=$(P wait 42 --slice 3 --poll 1 2>/dev/null)
ok "F3: CI already failing at start is reported by the first wait" '[ "$out" = "event=ci-failed" ]'
rm -f "$SP/gh/checks/42.json"; P seen 42 >/dev/null
ok "F4: window runs in the main checkout (the session name source)" '[ "$($L display -p -t "$WIN" "#{pane_start_path}")" = "$R" ] || [ "$($L display -p -t "$WIN" "#{pane_current_path}")" = "$R" ]'
ok "prompt: --force-with-lease, never merges, forbids plain --force" 'grep -q -- "--force-with-lease" "$PROMPT" && grep -q "Never merge the PR" "$PROMPT" && grep -q "no plain \`--force\`" "$PROMPT"'
ok "prompt: wait/seen usage and marks" 'grep -q "pr.sh wait 42\|$PRSH wait 42" "$PROMPT" && grep -q "seen 42" "$PROMPT" && grep -q "opsx-window.sh mark pr-42 ask" "$PROMPT" && grep -q "mark pr-42 busy" "$PROMPT" && grep -q "mark pr-42 idle" "$PROMPT"'
ok "prompt: ask list" 'grep -q "both sides changed behaviour" "$PROMPT" && grep -q "scope or design change" "$PROMPT" && grep -q "new dependency" "$PROMPT" && grep -q "disabling or deleting tests" "$PROMPT" && grep -q "contradict each other" "$PROMPT" && grep -q "disagree" "$PROMPT" && grep -q "author is not trusted" "$PROMPT" && grep -q "write access" "$PROMPT" && grep -q "overwriting commits someone else pushed" "$PROMPT" && grep -q "closing the PR" "$PROMPT" && grep -q "another PR" "$PROMPT" && grep -q "failed twice" "$PROMPT"'
ok "prompt: comment text is untrusted input" 'grep -q "untrusted input" "$PROMPT"'
ok "security F2: only requested reviewers, a submitted review does not count, [bot] defined" 'grep -q "reviewRequests" "$PROMPT" && grep -q "Having submitted a review does NOT make someone trusted" "$PROMPT" && grep -q "admin\`, \`maintain\` or \`write" "$PROMPT" && grep -q "ends in \`\[bot\]\`" "$PROMPT" && ! grep -q "a reviewer on the PR" "$PROMPT"'
ok "security F3: prompt pushes only through pr.sh push with an explicit lease" 'grep -q "push 42 --repo" "$PROMPT" && grep -q -- "--force-with-lease=<head>:<head_sha>" "$PROMPT" && ! grep -q "force-if-includes" "$PROMPT"'
ok "security F4: every GitHub-sourced text is untrusted" 'for t in "review comments and reviews" "PR (issue) comments" "PR title and body" "commit messages" "CI logs" "bot comments"; do grep -q "$t" "$PROMPT" || { echo "missing: $t"; exit 1; }; done'
ok "prompt: gates (tests, ops-reviewer for comment and CI fixes)" 'grep -q "tests must pass before every push" "$PROMPT" && grep -q "ops-reviewer pass" "$PROMPT" && grep -q "P0/P1" "$PROMPT" && grep -q "review comment or for CI" "$PROMPT"'
ok "prompt: ci-failed step triages before a re-run (rerun 42, not caused by the PR, repeat failure is real)" 'sed -n "/^- ci-failed:/,/^- comments:/p" "$PROMPT" > "$SP/cistep" && grep -q "rerun 42" "$SP/cistep" && grep -q "not clearly caused by this PR" "$SP/cistep" && grep -q "fails again on the same head" "$SP/cistep" && grep -q "exits 6" "$SP/cistep" && grep -q "untrusted input" "$SP/cistep" && grep -q "Never re-run it again on the same head" "$SP/cistep"'
ok "prompt: on its own list includes one CI re-run per head with rerun 42" 'sed -n "/^## You may do on your own/,/^## Gates/p" "$PROMPT" | grep -q "re-run a failed CI once per head with .*rerun 42"'
ok "prompt: resolveReviewThread, retarget, repo PR skill" 'grep -q resolveReviewThread "$PROMPT" && grep -q "gh pr edit 42 --base" "$PROMPT" && grep -q "own PR skill" "$PROMPT"'
out=$(P start 42 --agent-cli claude 2>/dev/null); rc=$?
ok "second start reuses the window" '[ $rc -eq 0 ] && [ "${out%% *}" = reused ] && [ "$(winof pr-42 | wc -l)" -eq 1 ]'
out=$(P start 41 --agent-cli claude 2>&1); rc=$?
ok "merged PR refused, no window" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q MERGED && [ -z "$(winof pr-41)" ]'
out=$(P start 45 --agent-cli claude 2>&1); rc=$?
ok "security F1: fork PR refused by start, no window, no state" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q fork && [ -z "$(winof pr-45)" ] && [ ! -e "$SD/o-app-45" ]'
$L set-option -w -t "$WIN" @opsx_pr_repo x/other
out=$(P start 42 --agent-cli claude 2>&1); rc=$?
ok "pr-42 window of another repo refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "x/other"'
$L set-option -w -t "$WIN" @opsx_pr_repo o/app

# ---------------------------------------------------------------- ask mark (3.1)
out=$("$W" mark pr-42 ask); rc=$?
ok "mark ask: status ask, title ox ?pr-42" '[ $rc -eq 0 ] && [ "$(opt "$WIN" @opsx_status)" = ask ] && [ "$($L display -p -t "$WIN" "#{window_name}")" = "ox ?pr-42" ]'
ok "ask colour differs from idle, busy and fail" 's=$(opt "$WIN" window-status-style); [[ "$s" == *"#b9a3e0"* ]] && [[ "$s" != *"#8fbfb8"* ]] && [[ "$s" != *"#cbb27a"* ]] && [[ "$s" != *"#c98a8a"* ]]'
ok "ask disarms the silence watch" '[ "$(opt "$WIN" monitor-silence)" = 0 ] || [ -z "$(opt "$WIN" monitor-silence)" ]'
out=$("$W" mark pr-42 idle --if-busy); rc=$?
ok "silence (idle --if-busy) keeps ask" '[ $rc -eq 0 ] && [ "$(opt "$WIN" @opsx_status)" = ask ] && [ "$($L display -p -t "$WIN" "#{window_name}")" = "ox ?pr-42" ]'
out=$("$W" mark pr-42 bogus 2>&1); rc=$?
ok "unknown status names ask in the expected list" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "busy|done|fail|idle|ask"'

# ---------------------------------------------------------------- list, stop, note (3.4)
P note 42 "rename the flag?" >/dev/null
ok "note records an ask= line" 'grep -qx "ask=rename the flag?" "$ST42"'
P seen 42 >/dev/null
ok "seen keeps ask= lines" 'grep -qx "ask=rename the flag?" "$ST42"'
P note 42 --clear >/dev/null
ok "note --clear removes them" '! grep -q "^ask=" "$ST42"'

# note -> decision push (add-mobile-notify 2.2): fake curl logs each call; the
# notify config lives in the scratch HOME.
export XDG_CONFIG_HOME=$SP/home/.config
NENV=$XDG_CONFIG_HOME/tmux-opsx/notify.env; mkdir -p "${NENV%/*}"
NC=$SP/ncalls; mkdir -p "$NC"
cat > "$SP/fakebin/curl" <<EOF
#!/usr/bin/env bash
f=$NC/call-\$(date +%s%N)-\$\$
{ printf 'ARGV: %s\n' "\$*"; printf 'BODY:\n'; cat; } > "\$f.tmp"; mv "\$f.tmp" "\$f.call"
printf ' %s ' "\$@" | grep -q ' -w ' && printf 200
exit 0
EOF
chmod +x "$SP/fakebin/curl"
ncalls() { find "$NC" -name '*.call' | wc -l | tr -d ' '; }
nbody() { sed -n '/^BODY:$/,$p' "$(find "$NC" -name '*.call' | sort | tail -n1)" | sed 1d; }
out=$(P note 42 "keep theirs or ours in api.ts?"); rc=$?
ok "note without notify.env: exit 0, ask= written, no push" '[ $rc -eq 0 ] && grep -qx "ask=keep theirs or ours in api.ts?" "$ST42" && [ "$(ncalls)" -eq 0 ]'
P note 42 --clear >/dev/null
printf 'NTFY_URL=https://ntfy.dev.example.com\nNTFY_TOPIC=opsx-0123456789ab\nNTFY_TOKEN=tk_t\n' > "$NENV"; chmod 600 "$NENV"
out=$(P note 42 "keep theirs or ours in api.ts?"); rc=$?
ok "note: one decision push whose body is the question" '[ $rc -eq 0 ] && [ "$(ncalls)" -eq 1 ] && nbody | grep -qF "keep theirs or ours in api.ts?"'
ok "note: records @opsx_notify_last_decision on the PR window" '[ -n "$(opt "$WIN" @opsx_notify_last_decision)" ]'
P note 42 --clear >/dev/null
rm -f "$NC"/*; $L set-option -wu -t "$WIN" @opsx_notify_last_decision
"$W" mark pr-42 ask >/dev/null
sleep 2
P note 42 "rebase onto main or develop?" >/dev/null
sleep 5
ok "mark ask, then note 2 s later: exactly one push, with the question" '[ "$(ncalls)" -eq 1 ] && nbody | grep -qF "rebase onto main or develop?"'
P note 42 --clear >/dev/null
rm -f "$NENV" "$SP/fakebin/curl"
out=$("$PRSH" list)
ok "list shows the running PR with its window status" 'printf "%s\n" "$out" | grep -P "^o/app\t42\task\t" >/dev/null'
ok "list shows a PR without a window as none" 'printf "%s\n" "$out" | grep -P "^o/app\t43\tnone\t" >/dev/null'
out=$(P stop 42); rc=$?
ok "stop closes the window, keeps the state file" '[ $rc -eq 0 ] && [ -z "$(winof pr-42)" ] && [ -f "$ST42" ]'
ok "stop keeps the worktree" '[ -d "$WT42" ]'
out=$("$PRSH" list)
ok "list after stop shows none" 'printf "%s\n" "$out" | grep -P "^o/app\t42\tnone\tstopped" >/dev/null'
out=$(P start 42 --agent-cli claude 2>&1); rc=$?
ok "restart after stop keeps the state file" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "state kept" && [ -n "$(winof pr-42)" ]'
P stop 42 >/dev/null

# ---------------------------------------------------------------- skill (4.1)
SK=$REPO/skills/opsx-pr/SKILL.md
ok "SKILL.md frontmatter has name and description" 'awk "/^---\$/{n++; next} n==1" "$SK" | grep -qx "name: opsx-pr" && awk "/^---\$/{n++; next} n==1" "$SK" | grep -q "^description: ."'
ok "every pr.sh subcommand named in SKILL.md exists" 'for c in $(grep -oE "pr\.sh [a-z]+" "$SK" | awk "{print \$2}" | sort -u); do "$PRSH" --help | grep -qE "pr\.sh $c( |\$)" || { echo "missing: $c"; exit 1; }; done'

# ---------------------------------------------------------------- install (4.2)
unset TMUX TMUX_PANE
IH=$SP/ihome; mkdir -p "$IH" "$SP/ibin"
for b in claude node npm; do printf '#!/bin/sh\necho 1.0.0\n' > "$SP/ibin/$b"; chmod +x "$SP/ibin/$b"; done
SKILL_DIRS=(.claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills)
n_pr_dirs() { local n=0 d; for d in "${SKILL_DIRS[@]}"; do [ -d "$IH/$d/opsx-pr" ] && n=$((n+1)); done; echo $n; }
run_install(){
  (cd "$REPO" && env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_HOME -u OPENCODE_CONFIG_DIR -u TMUX -u TMUX_PANE \
     -u SUDO_USER -u REAL_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u OPSX_MODELS_CONF \
     HOME="$IH" PATH="$SP/ibin:/usr/bin:/bin" bash ./install.sh --skip-openspec --skip-graphify \
     --skip-commands --skip-mcp --skip-memory --no-backup "$@" </dev/null 2>&1)
}
out=$(run_install); rc=$?
ok "install: opsx-pr in all six skill folders, pr.sh executable" '[ $rc -eq 0 ] && [ "$(n_pr_dirs)" -eq 6 ] && [ -f "$IH/.claude/skills/opsx-pr/SKILL.md" ] && [ -x "$IH/.claude/skills/opsx-pr/pr.sh" ]'
ok "install: installed pr.sh has the rerun command" '"$IH/.claude/skills/opsx-pr/pr.sh" --help | grep -qE "pr\.sh rerun "'
ok "install: verify step checks opsx-pr" 'printf "%s" "$out" | grep -q "opsx-pr/{SKILL.md,pr.sh}" && printf "%s" "$out" | grep -q "pr.sh parses"'
ok "installed pr.sh finds the installed opsx-window.sh" '[ -f "$IH/.claude/skills/opsx-pr/../opsx-run/opsx-window.sh" ]'
out=$(run_install --uninstall); rc=$?
ok "uninstall removes all six opsx-pr folders" '[ $rc -eq 0 ] && [ "$(n_pr_dirs)" -eq 0 ]'
rm -rf "$IH"; mkdir -p "$IH"
out=$(run_install --skip-pr); rc=$?
ok "--skip-pr installs no opsx-pr folder" '[ $rc -eq 0 ] && [ "$(n_pr_dirs)" -eq 0 ] && [ -d "$IH/.claude/skills/opsx-review" ]'
ok "install --help lists --skip-pr" 'bash "$REPO/install.sh" --help | grep -q -- "--skip-pr"'

# ---------------------------------------------------------------- docs (4.3)
RD=$REPO/README.md
ok "README documents /opsx-pr" 'grep -q "/opsx-pr" "$RD" && grep -q "opsx-pr/" "$RD"'
ok "README pr.sh commands exist in pr.sh usage" 'for c in $(grep -oE "pr\.sh [a-z]+" "$RD" | awk "{print \$2}" | sort -u); do "$PRSH" --help | grep -qE "pr\.sh $c( |\$)" || { echo "missing: $c"; exit 1; }; done'
ok "config.yaml states the /opsx-pr push exception" 'grep -q "/opsx-pr" "$REPO/openspec/config.yaml"'

# ---------------------------------------------------------------- safety
ok "gh never merged, approved or closed anything" '! grep -E "^pr (merge|review|close)" "$SP/gh/gh.log"'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
