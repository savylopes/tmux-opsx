#!/usr/bin/env bash
# opsx-land.sh — finish an OpenSpec change: merge, archive, clean up.
#
# Usage:
#   opsx-land.sh <change> [options]
#
# Options:
#   --into <branch>    Merge into this branch (default: main, else master)
#   --branch <name>    The change's branch, if discovery picks wrong
#   --skip-specs       Pass --skip-specs to `openspec archive` (tooling/doc changes)
#   --skip-merge       Skip the merge when the change is already in the target
#                      (archive + cleanup still run). Land exits 2 without this
#                      flag if there is nothing to merge, so the caller can ask.
#   --force-tasks      Land even when tasks.md still has unchecked boxes
#   --skip-eval        Don't run the eval regression gate (see below)
#   --no-close         Leave the tmux window open
#   --keep-branch      Don't delete the change branch
#   --keep-worktree    Don't remove the change's worktree (its preview, if
#                      any, is still stopped)
#   --dry-run          Print what would happen, change nothing
#   -h, --help         Show this help
#
# Runs in the caller's session, never inside the change's own tmux window: the
# window cannot close itself while it is still running the merge.
#
# Never pushes. The push command is printed for you to run.
#
# Eval regression gate: when the target or the change branch has an evals/
# directory, land runs opsx-eval.sh (L1 + L2 only, never --agentic) on the
# target before the merge (baseline) and on the merged result (current), each
# in a temporary detached worktree. A check that PASSed on the baseline and
# FAILs on the merged result blocks the land: the target is reset to its
# pre-merge commit and nothing is archived. Other failures, UNVERIFIABLE and
# MISSING results only warn. No evals/ anywhere -> the gate is skipped silently.
#
# If the working tree is dirty, land stashes it (including untracked files),
# finishes the land, then restores the stash automatically — including on
# early exits (e.g. ALREADY_MERGED). The change branch's worktree, if dirty,
# is still refused by opsx-merge.sh.

set -uo pipefail

CHANGE=""
TARGET=""
BRANCH=""
SKIP_SPECS=0
SKIP_MERGE=0
FORCE_TASKS=0
SKIP_EVAL=0
NO_CLOSE=0
KEEP_BRANCH=0
KEEP_WORKTREE=0
DRY_RUN=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; D=""; N=""
fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
skip() { printf '  %s-%s %s\n' "$D" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%sopsx-land:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '  %swould run:%s %s\n' "$D" "$N" "$*"; else "$@"; fi; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --into)          TARGET=${2:?--into needs a branch}; shift 2 ;;
    --branch)        BRANCH=${2:?--branch needs a name}; shift 2 ;;
    --skip-specs)    SKIP_SPECS=1; shift ;;
    --skip-merge)    SKIP_MERGE=1; shift ;;
    --force-tasks)   FORCE_TASKS=1; shift ;;
    --skip-eval)     SKIP_EVAL=1; shift ;;
    --no-close)      NO_CLOSE=1; shift ;;
    --keep-branch)   KEEP_BRANCH=1; shift ;;
    --keep-worktree) KEEP_WORKTREE=1; shift ;;
    --dry-run|-n)    DRY_RUN=1; shift ;;
    -h|--help)       usage ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  [ -z "$CHANGE" ] || die "one change at a time (got '$CHANGE' and '$1')"
        CHANGE=$1; shift ;;
  esac
done
[ -n "$CHANGE" ] || die "usage: opsx-land.sh <change> [--into <branch>] (try --help)"

branch_exists() { git show-ref --verify --quiet "refs/heads/$1"; }

# ---------------------------------------------------------------- preflight
step "Preflight"
command -v git >/dev/null 2>&1 || die "git is not installed."
command -v openspec >/dev/null 2>&1 || die "openspec is not on PATH."
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository."

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "cannot find the repository root."
cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"

[ -d "openspec/changes/$CHANGE" ] \
  || die "no change at openspec/changes/$CHANGE (run from the project root; 'openspec list' shows active changes)."
ok "change openspec/changes/$CHANGE"

# Target branch: explicit, else main, else master.
if [ -z "$TARGET" ]; then
  if branch_exists main; then TARGET=main
  elif branch_exists master; then TARGET=master
  else die "no 'main' or 'master' branch — pass --into <branch>."
  fi
fi
branch_exists "$TARGET" || die "target branch '$TARGET' does not exist."
ok "target branch $TARGET"

# Branch discovery: explicit wins, then the conventional names, then a single
# fuzzy match. The applier agent has used several naming schemes over time.
if [ -n "$BRANCH" ]; then
  branch_exists "$BRANCH" || die "branch '$BRANCH' does not exist."
else
  for candidate in "opsx/$CHANGE" "feat/$CHANGE" "feature/$CHANGE" "$CHANGE"; do
    if branch_exists "$candidate"; then BRANCH=$candidate; break; fi
  done
fi
if [ -z "$BRANCH" ]; then
  matches=$(git branch --list --format='%(refname:short)' "*$CHANGE*" 2>/dev/null | grep -v "^$TARGET$")
  count=$(printf '%s' "$matches" | grep -c . || true)
  if [ "$count" -eq 1 ]; then
    BRANCH=$(printf '%s' "$matches" | tr -d ' ')
  elif [ "$count" -gt 1 ]; then
    say "branches matching '$CHANGE':"
    printf '%s\n' "$matches" | sed 's/^/  /'
    die "several branches match — pick one with --branch <name>."
  else
    die "no branch found for '$CHANGE' — was it applied? Pass --branch <name> if it is named differently."
  fi
fi
ok "change branch $BRANCH"

# ---------------------------------------------------------------- gates
step "Gates"
if out=$(openspec validate "$CHANGE" --strict 2>&1); then
  ok "openspec validate --strict"
else
  say "$out"
  die "validation failed — fix it before landing."
fi

status_json=$(openspec status --change "$CHANGE" --json 2>/dev/null) \
  || die "could not read status for '$CHANGE'."
case "$status_json" in
  *'"isComplete": true'*|*'"isComplete":true'*) ok "all artifacts present" ;;
  *) die "artifacts are incomplete — see: openspec status --change $CHANGE" ;;
esac

# `isComplete` above only means the artifacts exist; it is true even with tasks
# still unchecked. Count the checkboxes directly, the same way apply tracks them.
tasks_file="openspec/changes/$CHANGE/tasks.md"
if [ -f "$tasks_file" ]; then
  remaining=$(grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]*\]' "$tasks_file" 2>/dev/null || true)
  remaining=${remaining:-0}
  if [ "$remaining" -gt 0 ]; then
    grep -nE '^[[:space:]]*-[[:space:]]*\[[[:space:]]*\]' "$tasks_file" | head -10 | sed 's/^/  /'
    if [ "$FORCE_TASKS" -eq 1 ]; then
      warn "$remaining task(s) still unchecked in $tasks_file — continuing (--force-tasks)"
    else
      die "$remaining task(s) still unchecked in $tasks_file — finish them before landing (or pass --force-tasks)."
    fi
  else
    ok "all tasks checked"
  fi
else
  warn "no $tasks_file — skipping the task check"
fi

START_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")

# ---------------------------------------------------------------- stash WIP
# Merge needs a clean tree. Stash local WIP (incl. untracked), land, then pop.
# Restored on EXIT so ALREADY_MERGED / merge failure also give the WIP back.
DID_STASH=0
STASH_MSG="opsx-land:$CHANGE:$$"

restore_stash() {
  [ "${DID_STASH:-0}" -eq 1 ] || return 0
  DID_STASH=0
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %swould run:%s git stash pop  # restore WIP after land\n' "$D" "$N"
    return 0
  fi
  step "Restoring stashed WIP"
  # Prefer the stash we just made (match message); fall back to stash@{0}.
  local idx
  idx=$(git stash list --format='%gd %s' 2>/dev/null \
        | awk -v m="$STASH_MSG" 'index($0, m) { sub(/:.*/, "", $1); print $1; exit }')
  idx=${idx:-'stash@{0}'}
  if git stash pop "$idx" >/dev/null 2>&1; then
    ok "restored stash ($idx)"
  else
    warn "could not auto-restore stash $idx — your WIP is still in the stash list"
    warn "inspect with: git stash list   then: git stash pop"
  fi
}
trap 'restore_stash' EXIT

if [ -n "$(git status --porcelain)" ]; then
  step "Stashing local WIP"
  git status --short | sed 's/^/  /'
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %swould run:%s git stash push -u -m %s\n' "$D" "$N" "$STASH_MSG"
    DID_STASH=1
  else
    if git stash push -u -m "$STASH_MSG" >/dev/null 2>&1; then
      DID_STASH=1
      ok "stashed WIP as \"$STASH_MSG\""
    else
      die "could not stash local changes — commit or stash by hand, then land again."
    fi
  fi
else
  ok "working tree clean"
fi

say ""
step "Landing $CHANGE"
say "  branch:  $BRANCH"
say "  into:    $TARGET"
say "  from:    ${START_BRANCH:-(detached HEAD)}"
[ "$DID_STASH" -eq 1 ] && say "  stash:   yes (will restore after land)"
[ "$DRY_RUN" -eq 1 ] && say "  ${D}(dry run — nothing will change)${N}"
say ""

# ---------------------------------------------------------------- eval gate
# Runs the saved suite in a throwaway detached worktree so checks never touch
# (or leave files in) the tree that archive later commits with `git add -A`.
EVAL_SCRIPT="$(cd -- "$(dirname -- "$0")" && pwd)/opsx-eval.sh"
EVAL_DIR=""
EVAL_GATE=0
cleanup_eval() {
  [ -n "$EVAL_DIR" ] || return 0
  local w
  for w in "$EVAL_DIR/base" "$EVAL_DIR/current"; do
    [ -d "$w" ] && git worktree remove --force "$w" >/dev/null 2>&1
  done
  git worktree prune >/dev/null 2>&1
  rm -rf "$EVAL_DIR"
  EVAL_DIR=""
}
trap 'cleanup_eval; restore_stash' EXIT

# eval_run <rev> <name>: suite at <rev> -> $EVAL_DIR/<name>.json; returns the runner's exit.
eval_run() {
  local rev=$1 name=$2 wt="$EVAL_DIR/$2" rc
  git worktree add --detach "$wt" "$rev" >/dev/null 2>&1 || { warn "could not create a worktree for $rev"; return 2; }
  local args=(--all --json --root "$wt")
  [ -d "$wt/openspec/changes/$CHANGE" ] && args=(--all --change "$CHANGE" --json --root "$wt")
  "$EVAL_SCRIPT" "${args[@]}" > "$EVAL_DIR/$name.json" 2> "$EVAL_DIR/$name.err"
  rc=$?
  git worktree remove --force "$wt" >/dev/null 2>&1
  return "$rc"
}

json_total() {  # json_total <file> <key>
  sed -n 's/.*"totals": *{[^}]*"'"$2"'":\([0-9]*\).*/\1/p' "$1" | head -1
}

if [ "$SKIP_EVAL" -eq 1 ]; then
  step "Eval gate"; skip "eval skipped (--skip-eval)"
elif ! git cat-file -e "$TARGET:evals" 2>/dev/null && ! git cat-file -e "$BRANCH:evals" 2>/dev/null; then
  : # no evals/ on either side: skip silently
elif [ "$SKIP_MERGE" -eq 1 ]; then
  step "Eval gate"; skip "eval skipped (--skip-merge: no pre-merge baseline to compare against)"
elif [ ! -x "$EVAL_SCRIPT" ]; then
  step "Eval gate"; warn "opsx-eval.sh not found next to this script — eval gate skipped (re-run ./install.sh)"
elif [ "$DRY_RUN" -eq 1 ]; then
  step "Eval gate"
  printf '  %swould run:%s %s --all --json on %s (baseline) and on the merged result\n' "$D" "$N" "$EVAL_SCRIPT" "$TARGET"
else
  step "Eval gate (baseline on $TARGET)"
  EVAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/opsx-land-eval.XXXXXX") || die "cannot create a temp dir for eval"
  EVAL_GATE=1
  if git cat-file -e "$TARGET:evals" 2>/dev/null; then
    eval_run "$TARGET" base; rc=$?
    if [ "$rc" -ge 2 ]; then
      sed 's/^/  /' "$EVAL_DIR/base.err"
      warn "baseline eval errored (exit $rc) — no regression baseline; failures will only warn"
      printf '{"results":[\n]}\n' > "$EVAL_DIR/base.json"
    else
      ok "baseline: $(json_total "$EVAL_DIR/base.json" pass) pass, $(json_total "$EVAL_DIR/base.json" fail) fail"
    fi
  else
    printf '{"results":[\n]}\n' > "$EVAL_DIR/base.json"
    skip "no evals/ on $TARGET — every result on the merged tree is new"
  fi
fi

# ---------------------------------------------------------------- merge
PRE_MERGE=$(git rev-parse "$TARGET" 2>/dev/null)
ahead=$(git rev-list --count "$TARGET..$BRANCH" 2>/dev/null || echo 0)
tip=$(git rev-parse --short "$BRANCH" 2>/dev/null || echo "?")

skip_merge_onto_target() {
  if [ -n "$(git status --porcelain)" ]; then
    git status --short | sed 's/^/  /'
    die "working tree is not clean after stash — commit or stash before landing."
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %swould run:%s git checkout %s\n' "$D" "$N" "$TARGET"
    MERGE_COMMIT="(dry run, already merged)"
    return 0
  fi
  git checkout "$TARGET" >/dev/null 2>&1 || die "could not check out '$TARGET'."
  ok "on $TARGET (merge skipped — $BRANCH already in $TARGET, tip $tip)"
  MERGE_COMMIT="$(git rev-parse --short HEAD) (already merged)"
}

if [ "$SKIP_MERGE" -eq 1 ]; then
  [ "$ahead" -eq 0 ] || die "--skip-merge but '$BRANCH' still has $ahead commit(s) '$TARGET' is missing — merge them first."
  step "Skipping merge"
  skip_merge_onto_target
else
  if [ "$ahead" -eq 0 ]; then
    say "ALREADY_MERGED $BRANCH -> $TARGET ($tip)"
    warn "'$BRANCH' is already in '$TARGET' (tip $tip) — nothing to merge."
    say ""
    say "Archive, branch delete, worktree removal, and window close did not run."
    say ""
    say "Ask whether to skip the merge and finish cleanup, then re-run with --skip-merge:"
    rerun=(opsx-land.sh "$CHANGE" --skip-merge --into "$TARGET" --branch "$BRANCH")
    [ "$SKIP_SPECS" -eq 1 ] && rerun+=(--skip-specs)
    [ "$FORCE_TASKS" -eq 1 ] && rerun+=(--force-tasks)
    [ "$SKIP_EVAL" -eq 1 ] && rerun+=(--skip-eval)
    [ "$NO_CLOSE" -eq 1 ] && rerun+=(--no-close)
    [ "$KEEP_BRANCH" -eq 1 ] && rerun+=(--keep-branch)
    [ "$KEEP_WORKTREE" -eq 1 ] && rerun+=(--keep-worktree)
    [ "$DRY_RUN" -eq 1 ] && rerun+=(--dry-run)
    printf '  %s\n' "${rerun[*]}"
    exit 2
  fi
  # Merge-only lives in opsx-merge.sh; --stay leaves HEAD on $TARGET for archive.
  merge_script="$(cd -- "$(dirname -- "$0")" && pwd)/opsx-merge.sh"
  [ -x "$merge_script" ] || die "opsx-merge.sh not found next to this script — re-run ./install.sh."
  merge_args=("$CHANGE" --into "$TARGET" --branch "$BRANCH" --stay)
  [ "$DRY_RUN" -eq 1 ] && merge_args+=(--dry-run)
  "$merge_script" "${merge_args[@]}" || exit $?
  if [ "$DRY_RUN" -eq 1 ]; then MERGE_COMMIT="(dry run)"; else MERGE_COMMIT=$(git rev-parse --short HEAD); fi
fi

if [ "$EVAL_GATE" -eq 1 ]; then
  step "Eval gate (merged result)"
  eval_run HEAD current; rc=$?
  if [ "$rc" -ge 2 ]; then
    sed 's/^/  /' "$EVAL_DIR/current.err"
    warn "eval on the merged result errored (exit $rc) — cannot check for regressions; continuing"
  else
    regressions=$("$EVAL_SCRIPT" --compare "$EVAL_DIR/base.json" "$EVAL_DIR/current.json" 2>&1)
    crc=$?
    [ "$crc" -ge 2 ] && warn "eval compare errored: $regressions"
    if [ "$crc" -eq 1 ]; then
      printf '%s\n' "$regressions" | sed 's/^/  /'
      step "Restoring $TARGET"
      if git reset -q --hard "$PRE_MERGE" >/dev/null 2>&1; then
        ok "$TARGET reset to its pre-merge commit $(git rev-parse --short HEAD)"
      else
        warn "could not reset $TARGET — undo the merge by hand: git reset --hard $PRE_MERGE"
      fi
      if [ -n "$START_BRANCH" ] && [ "$START_BRANCH" != "$TARGET" ]; then
        git checkout -q "$START_BRANCH" >/dev/null 2>&1 && ok "back on $START_BRANCH"
      fi
      say ""
      say "EVAL_REGRESSION $BRANCH -> $TARGET"
      die "eval regression — checks that passed on $TARGET fail after merging $BRANCH. Nothing was archived; fix on $BRANCH (or pass --skip-eval)."
    fi
    ok "no regressions"
    f=$(json_total "$EVAL_DIR/current.json" fail)
    u=$(json_total "$EVAL_DIR/current.json" unverifiable)
    m=$(json_total "$EVAL_DIR/current.json" missing)
    p=$(json_total "$EVAL_DIR/current.json" pass)
    say "  current: ${p:-0} pass, ${f:-0} fail, ${u:-0} unverifiable, ${m:-0} missing"
    if [ "${f:-0}" -gt 0 ] || [ "${u:-0}" -gt 0 ] || [ "${m:-0}" -gt 0 ]; then
      awk '/"status":"(FAIL|UNVERIFIABLE)"/ { if (match($0, /"id":"[^"]*"/)) id = substr($0, RSTART + 6, RLENGTH - 7)
             s = ($0 ~ /"status":"FAIL"/) ? "FAIL" : "UNVERIFIABLE"; print s " " id }
           /^ *\{"capability":/ { if (match($0, /"slug":"[^"]*"/)) print "MISSING " substr($0, RSTART + 8, RLENGTH - 9) }' \
        "$EVAL_DIR/current.json" | while IFS= read -r l; do warn "$l (not a regression — continuing)"; done
    fi
  fi
  cleanup_eval
fi

# ---------------------------------------------------------------- archive
step "Archiving"
archive_cmd=(openspec archive "$CHANGE" -y)
[ "$SKIP_SPECS" -eq 1 ] && archive_cmd+=(--skip-specs)
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  %swould run:%s %s\n' "$D" "$N" "${archive_cmd[*]}"
else
  if out=$("${archive_cmd[@]}" 2>&1); then
    ok "archived to openspec/changes/archive/$CHANGE"
  else
    say "$out"
    warn "archive failed — the merge is already on $TARGET; archive by hand with: ${archive_cmd[*]}"
  fi
  if [ -n "$(git status --porcelain)" ]; then
    git add -A >/dev/null 2>&1
    if git commit -q -m "Archive change $CHANGE" >/dev/null 2>&1; then
      ok "committed the archive ($(git rev-parse --short HEAD))"
    else
      warn "could not commit the archive — do it by hand."
    fi
  else
    skip "archive produced no changes to commit"
  fi
fi

# ---------------------------------------------------------------- cleanup
step "Cleaning up"

# Stop the change's preview (route, app process group, window) before its
# worktree goes away. Never fatal; no preview is the normal case.
preview_script="$(cd -- "$(dirname -- "$0")" && pwd)/opsx-preview.sh"
if [ -x "$preview_script" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %swould run:%s %s stop %s\n' "$D" "$N" "$preview_script" "$CHANGE"
  else
    out=$("$preview_script" stop "$CHANGE" 2>&1) || true
    case "$out" in
      ''|'no preview running for '*) ;;
      *) printf '%s\n' "$out" | sed 's/^/  /' ;;
    esac
  fi
fi

if [ "$KEEP_WORKTREE" -eq 1 ]; then
  skip "worktree kept (--keep-worktree)"
else
  # The applier agent usually removes its own worktree, so absence is normal.
  wt=$(git worktree list --porcelain 2>/dev/null \
       | awk -v b="refs/heads/$BRANCH" '
           /^worktree /{ path=substr($0,10) }
           /^branch /  { if (substr($0,8)==b) { print path; exit } }')
  if [ -n "$wt" ]; then
    if run git worktree remove "$wt" >/dev/null 2>&1; then
      ok "removed worktree $wt"
    else
      warn "could not remove worktree $wt (uncommitted files? try: git worktree remove --force $wt)"
    fi
  else
    skip "no worktree for $BRANCH"
  fi
fi

if [ "$KEEP_BRANCH" -eq 1 ]; then
  skip "branch kept (--keep-branch)"
elif [ "$DRY_RUN" -eq 1 ]; then
  printf '  %swould run:%s git branch -d %s\n' "$D" "$N" "$BRANCH"
else
  if git branch -d "$BRANCH" >/dev/null 2>&1; then
    ok "deleted branch $BRANCH"
    DELETED_BRANCH=1
  else
    warn "could not delete $BRANCH — delete it by hand once you are happy: git branch -d $BRANCH"
  fi
fi

if [ "$NO_CLOSE" -eq 1 ]; then
  skip "tmux window kept (--no-close)"
else
  window_script="$(cd -- "$(dirname -- "$0")" && pwd)/opsx-window.sh"
  if [ -x "$window_script" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  %swould run:%s %s close %s\n' "$D" "$N" "$window_script" "$CHANGE"
    else
      # Non-fatal: a change landed from outside tmux may have no window at all.
      if out=$("$window_script" close "$CHANGE" 2>&1); then
        printf '%s\n' "$out" | sed 's/^/  /'
      else
        skip "no tmux window for $CHANGE"
      fi
    fi
  else
    warn "opsx-window.sh not found next to this script — close the window yourself"
  fi
fi

# Return to where the caller started, unless that branch is the one we deleted.
if [ "$DRY_RUN" -eq 0 ] && [ -n "$START_BRANCH" ] && [ "$START_BRANCH" != "$TARGET" ]; then
  if [ "$START_BRANCH" = "$BRANCH" ] && [ "${DELETED_BRANCH:-0}" -eq 1 ]; then
    warn "you started on $BRANCH, which is now deleted — staying on $TARGET"
  elif branch_exists "$START_BRANCH"; then
    git checkout "$START_BRANCH" >/dev/null 2>&1 && ok "back on $START_BRANCH"
  fi
fi

say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "${B}Dry run complete.${N} Nothing was changed."
else
  say "${G}${B}Landed $CHANGE.${N}"
  if [ "$SKIP_MERGE" -eq 1 ]; then
    say "  merge:        skipped ($MERGE_COMMIT on $TARGET)"
  else
    say "  merge commit: $MERGE_COMMIT on $TARGET"
  fi
  say "  HEAD is now:  $(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
  say ""
  say "  push with: ${B}git push origin $TARGET${N}"
fi
