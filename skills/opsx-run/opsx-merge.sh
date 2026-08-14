#!/usr/bin/env bash
# opsx-merge.sh — merge an OpenSpec change branch into a target (default: main).
#
# Usage:
#   opsx-merge.sh <change> [options]
#
# Options:
#   --into <branch>    Merge into this branch (default: main, else master)
#   --branch <name>    The change's branch, if discovery picks wrong
#   --stay             Leave HEAD on the target after a successful merge
#                      (land uses this so it can archive on the merged tree)
#   --dry-run          Print what would happen, change nothing
#   -h, --help         Show this help
#
# Merges only. Does not validate tasks, archive, delete the branch, remove
# the worktree, or close the tmux window. Never pushes.
#
# If the change branch is checked out in a worktree with uncommitted files,
# the merge is refused — commit there first.

set -uo pipefail

CHANGE=""
TARGET=""
BRANCH=""
STAY=0
DRY_RUN=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; D=""; N=""
fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%sopsx-merge:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --into)   TARGET=${2:?--into needs a branch}; shift 2 ;;
    --branch) BRANCH=${2:?--branch needs a name}; shift 2 ;;
    --stay)   STAY=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  [ -z "$CHANGE" ] || die "one change at a time (got '$CHANGE' and '$1')"
        CHANGE=$1; shift ;;
  esac
done
[ -n "$CHANGE" ] || die "usage: opsx-merge.sh <change> [--into <branch>] (try --help)"

branch_exists() { git show-ref --verify --quiet "refs/heads/$1"; }

worktree_for_branch() {
  git worktree list --porcelain 2>/dev/null \
    | awk -v b="refs/heads/$1" '
        /^worktree /{ path=substr($0,10) }
        /^branch /  { if (substr($0,8)==b) { print path; exit } }'
}

step "Preflight"
command -v git >/dev/null 2>&1 || die "git is not installed."
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository."

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "cannot find the repository root."
cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"

if [ -d "openspec/changes/$CHANGE" ]; then
  ok "change openspec/changes/$CHANGE"
else
  warn "no change at openspec/changes/$CHANGE — merging the branch anyway"
fi

if [ -z "$TARGET" ]; then
  if branch_exists main; then TARGET=main
  elif branch_exists master; then TARGET=master
  else die "no 'main' or 'master' branch — pass --into <branch>."
  fi
fi
branch_exists "$TARGET" || die "target branch '$TARGET' does not exist."
ok "target branch $TARGET"

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

step "Gates"
if [ -n "$(git status --porcelain)" ]; then
  git status --short | sed 's/^/  /'
  die "working tree is not clean — commit or stash before merging."
fi
ok "working tree clean"

wt=$(worktree_for_branch "$BRANCH")
if [ -n "$wt" ]; then
  ok "worktree $wt"
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    git -C "$wt" status --short | sed 's/^/  /'
    die "worktree for '$BRANCH' has uncommitted files — commit them in the change's window first."
  fi
  ok "worktree clean"
else
  warn "no worktree for $BRANCH"
fi

ahead=$(git rev-list --count "$TARGET..$BRANCH" 2>/dev/null || echo 0)
if [ "$ahead" -eq 0 ]; then
  tip=$(git rev-parse --short "$BRANCH" 2>/dev/null || echo "?")
  say "ALREADY_MERGED $BRANCH -> $TARGET ($tip)"
  printf '%sopsx-merge:%s %s\n' "$R" "$N" \
    "'$BRANCH' is already in '$TARGET' (tip $tip) — nothing to merge." >&2
  exit 2
fi
ok "$ahead commit(s) to merge"

START_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")

say ""
step "Merging $CHANGE"
say "  branch:  $BRANCH"
say "  into:    $TARGET"
say "  from:    ${START_BRANCH:-(detached HEAD)}"
[ "$DRY_RUN" -eq 1 ] && say "  ${D}(dry run — nothing will change)${N}"
say ""

if [ "$DRY_RUN" -eq 1 ]; then
  printf '  %swould run:%s git checkout %s\n' "$D" "$N" "$TARGET"
  printf '  %swould run:%s git merge --no-ff %s -m "Merge change %s"\n' "$D" "$N" "$BRANCH" "$CHANGE"
  say ""
  say "${B}Dry run complete.${N} Nothing was changed."
  exit 0
fi

git checkout "$TARGET" >/dev/null 2>&1 || die "could not check out '$TARGET'."
ok "on $TARGET"

if git merge --no-ff "$BRANCH" -m "Merge change $CHANGE" >/dev/null 2>&1; then
  ok "merged $BRANCH into $TARGET"
else
  conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null)
  git merge --abort >/dev/null 2>&1
  [ -n "$START_BRANCH" ] && git checkout "$START_BRANCH" >/dev/null 2>&1
  say ""
  say "${R}Merge conflicts${N} — the merge was aborted and nothing was changed."
  [ -n "$conflicts" ] && printf '%s\n' "$conflicts" | sed 's/^/  /'
  say ""
  say "Resolve them in the change's window, then merge again:"
  say "  /opsx-run $CHANGE merge"
  say "  /opsx-run $CHANGE \"resolve the conflicts merging $BRANCH into $TARGET\""
  exit 1
fi

MERGE_COMMIT=$(git rev-parse --short HEAD)

if [ "$STAY" -eq 0 ] && [ -n "$START_BRANCH" ] && [ "$START_BRANCH" != "$TARGET" ]; then
  if branch_exists "$START_BRANCH"; then
    git checkout "$START_BRANCH" >/dev/null 2>&1 && ok "back on $START_BRANCH"
  fi
fi

say ""
say "${G}${B}Merged $CHANGE.${N}"
say "  merge commit: $MERGE_COMMIT on $TARGET"
say "  HEAD is now:  $(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
say ""
say "  push with: ${B}git push origin $TARGET${N}"
say "  land with: ${B}/opsx-run $CHANGE land --into $TARGET${N}  (archive + cleanup)"
