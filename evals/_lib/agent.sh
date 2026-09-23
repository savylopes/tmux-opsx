# Shared helpers for L3 checks: run an ops agent (agents/opsx-*.md) headless via
# $EVAL_AGENT_CLI on a throwaway git + OpenSpec repo under $EVAL_TMP.
# Sourced by checks; not a check itself.
fail() { echo "FAIL: $*"; exit 1; }
# The suite gives checks a scratch HOME with no CLI login, so an API key or
# token must come from the environment.
l3_require() {
  case "$(basename "${EVAL_AGENT_CLI:-}")" in
    claude) ;;
    *) echo "L3 helper drives Claude Code only (EVAL_AGENT_CLI='${EVAL_AGENT_CLI:-}')"; exit 77 ;;
  esac
  command -v "$EVAL_AGENT_CLI" >/dev/null || { echo "$EVAL_AGENT_CLI not on PATH"; exit 77; }
  [ -n "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
    || { echo "needs ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN (scratch HOME has no login)"; exit 77; }
  export HOME="$EVAL_TMP/home" CLAUDE_CONFIG_DIR="$EVAL_TMP/home/.claude"
  mkdir -p "$HOME/.claude/skills/opsx-run"
  cp "$EVAL_ROOT/skills/opsx-run/opsx-eval.sh" "$HOME/.claude/skills/opsx-run/"
}
REPO="$EVAL_TMP/repo"
g() { git -C "$REPO" "$@"; }
# Base product: greet.sh prints "hello"; capability greet with one scenario.
mk_repo() {
  mkdir -p "$REPO/openspec/specs/greet"
  git init -q -b main "$REPO"
  g config user.email eval@example.invalid; g config user.name eval; g config commit.gpgsign false
  cat > "$REPO/openspec/specs/greet/spec.md" <<'S'
# greet Specification

## Purpose
Greet the user.

## Requirements
### Requirement: Hello
`greet.sh` SHALL print `hello` and exit 0.

#### Scenario: Says hello
- **WHEN** `sh greet.sh` runs
- **THEN** it prints `hello` and exits 0
S
  printf '#!/bin/sh\n[ "$1" = --bye ] && { echo bye; exit 0; }\necho hello\n' > "$REPO/greet.sh"
  g add -A; g commit -qm init
}
# start_change <name>: branch opsx/<name>, write proposal/tasks; caller adds specs + code, then commit_change.
start_change() {
  CHANGE=$1
  g checkout -qb "opsx/$CHANGE"
  mkdir -p "$REPO/openspec/changes/$CHANGE"
  printf '## Why\nEval fixture change used to exercise the ops agents end to end.\n\n## What Changes\n- %s\n' "$CHANGE" \
    > "$REPO/openspec/changes/$CHANGE/proposal.md"
  printf '## 1. Do it\n\n- [x] 1.1 %s\n' "$CHANGE" > "$REPO/openspec/changes/$CHANGE/tasks.md"
}
commit_change() { g add -A; g commit -qm "${1:-implement $CHANGE}"; }
# delta <cap> <content>
delta() { mkdir -p "$REPO/openspec/changes/$CHANGE/specs/$1"; printf '%s\n' "$2" > "$REPO/openspec/changes/$CHANGE/specs/$1/spec.md"; }
# run_agent <agent file basename> <prompt>  -> prints agent output; $AGENT_OUT holds it
run_agent() {
  local sys
  sys=$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' "$EVAL_ROOT/agents/$1")
  AGENT_OUT=$( cd "$REPO" && "$EVAL_AGENT_CLI" -p --dangerously-skip-permissions \
      --append-system-prompt "$sys" "$2" </dev/null 2>&1 )
  echo "---- agent output ----"; echo "$AGENT_OUT"; echo "---- end ----"
}
eval_prompt() {
  printf 'Change: %s\nBranch: opsx/%s\nWorktree: %s\n%s\nFollow your agent instructions. Do not edit anything outside evals/.' \
    "$CHANGE" "$CHANGE" "$REPO" "${1:-}"
}
verdict() { printf '%s\n' "$AGENT_OUT" | grep -Eo 'VERDICT: *(PASS|FAIL|SKIP)' | tail -1 | awk '{print $2}'; }
