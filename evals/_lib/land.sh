# Shared helpers for land checks: a throwaway git + OpenSpec repo under
# $EVAL_TMP with change `add-auth` (committed on main, implemented on
# opsx/add-auth). Sourced by checks; not a check itself.
LAND="$EVAL_ROOT/skills/opsx-run/opsx-land.sh"
fail() { echo "FAIL: $*"; exit 1; }
command -v openspec >/dev/null || { echo "openspec CLI not on PATH"; exit 77; }
# Keep git/openspec state inside the scratch HOME the suite setup provides.
export GIT_CONFIG_NOSYSTEM=1
REPO="$EVAL_TMP/repo"
g() { git -C "$REPO" "$@"; }
mk_repo() {
  mkdir -p "$REPO/openspec/specs" "$REPO/openspec/changes/add-auth/specs/auth"
  git init -q -b main "$REPO"
  g config user.email eval@example.invalid; g config user.name eval; g config commit.gpgsign false
  cat > "$REPO/openspec/changes/add-auth/proposal.md" <<'S'
## Why
Users need to log in so the service can tell them apart and protect their data.

## What Changes
- Add a login command.
S
  printf '## Context\nA plain login check.\n\n## Decisions\nStore the result in login.txt.\n' > "$REPO/openspec/changes/add-auth/design.md"
  printf '## 1. Login\n\n- [x] 1.1 Add login\n' > "$REPO/openspec/changes/add-auth/tasks.md"   # WHEN: tasks are complete
  cat > "$REPO/openspec/changes/add-auth/specs/auth/spec.md" <<'S'
## ADDED Requirements

### Requirement: Login
The service SHALL log users in with valid credentials.

#### Scenario: Login ok
- **WHEN** valid credentials are given
- **THEN** login succeeds
S
  echo ok > "$REPO/login.txt"
  g add -A; g commit -qm "init + change proposal"
}
# on_branch: switch to opsx/add-auth, run "$@" in the repo, tick tasks, commit, back to main.
on_branch() {
  g checkout -qB opsx/add-auth
  ( cd "$REPO" && "$@" )
  printf '## 1. Login\n\n- [x] 1.1 Add login\n' > "$REPO/openspec/changes/add-auth/tasks.md"
  g add -A; g commit -qm "implement add-auth"
  g checkout -q main
}
# add_check <repo-relative path> <scenario> <body>
add_check() {
  mkdir -p "$(dirname "$REPO/$1")"
  printf '#!/usr/bin/env bash\n# scenario: %s\n# level: L1\n%s\n' "$2" "$3" > "$REPO/$1"
  chmod +x "$REPO/$1"
}
run_land() {
  ( cd "$REPO" && env -u EVAL_ENV_FILE -u EVAL_ROOT -u EVAL_TMP "$LAND" add-auth --no-close "$@" ) </dev/null 2>&1
}
archived() { ls -d "$REPO"/openspec/changes/archive/*add-auth 2>/dev/null | head -1; }
