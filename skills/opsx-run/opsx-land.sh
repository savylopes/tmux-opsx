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
#   --force-tasks      Land even when tasks.md still has unchecked boxes
#   --no-close         Leave the tmux window open
#   --keep-branch      Don't delete the change branch
#   --keep-worktree    Don't remove the change's worktree
#   --dry-run          Print what would happen, change nothing
#   -h, --help         Show this help
#
# Runs in the caller's session, never inside the change's own tmux window: the
# window cannot close itself while it is still running the merge.
#
# Never pushes. The push command is printed for you to run.

set -uo pipefail

CHANGE=""
TARGET=""
BRANCH=""
SKIP_SPECS=0
FORCE_TASKS=0
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
    --force-tasks)   FORCE_TASKS=1; shift ;;
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

say ""
step "Landing $CHANGE"
say "  branch:  $BRANCH"
say "  into:    $TARGET"
say "  from:    ${START_BRANCH:-(detached HEAD)}"
[ "$DRY_RUN" -eq 1 ] && say "  ${D}(dry run — nothing will change)${N}"
say ""

# ---------------------------------------------------------------- merge
# Merge-only lives in opsx-merge.sh; --stay leaves HEAD on $TARGET for archive.
merge_script="$(cd -- "$(dirname -- "$0")" && pwd)/opsx-merge.sh"
[ -x "$merge_script" ] || die "opsx-merge.sh not found next to this script — re-run ./install.sh."
merge_args=("$CHANGE" --into "$TARGET" --branch "$BRANCH" --stay)
[ "$DRY_RUN" -eq 1 ] && merge_args+=(--dry-run)
"$merge_script" "${merge_args[@]}" || exit $?
MERGE_COMMIT=$([ "$DRY_RUN" -eq 1 ] && echo "(dry run)" || git rev-parse --short HEAD)

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
  say "  merge commit: $MERGE_COMMIT on $TARGET"
  say "  HEAD is now:  $(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
  say ""
  say "  push with: ${B}git push origin $TARGET${N}"
fi
