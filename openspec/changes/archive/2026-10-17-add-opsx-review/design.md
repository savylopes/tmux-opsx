# Design

## Context

See proposal.md for motivation and `specs/pr-review/spec.md` for behaviour. The implementation already exists as uncommitted work (2026-10-15): `skills/opsx-review/SKILL.md` (the agent workflow), `opsx-review.sh` (resolve, session, worktree), `tests/test-review.sh` (23 assertions with a fake `gh`, a scratch repo and a private tmux server), and the install and README hunks. This change verifies it against the spec and lands it.

## Goals / Non-Goals

**Goals:**
- Keep the deterministic parts (PR lookup, naming, worktree) in a script that tests can drive without GitHub; keep judgement (the first read, the review change, the launch prompt) in the skill text.
- Reuse the harness: the propose workflow writes the change, `/opsx-run --validate` runs it, the existing gates judge it.

**Non-Goals:**
- Posting to GitHub or the issue tracker; fixing the PR; CI integration.

## Decisions

### 1. The review is an OpenSpec change, not a one-shot report
A change gives the review a plan the user can read before it runs, tasks that are ticked with evidence, and the same gates (eval, reviewer, security) as product work. Alternative: a single agent prompt that writes a report. Rejected: nothing would check the report's claims.

### 2. Detached worktree at the head SHA
`worktree` pins the review to one commit beside the repository, so the user's checkout and branches are never touched and a PR that moves is detected (the SHA differs). Alternative: `gh pr checkout` in a fresh clone. Rejected: slower and it creates a branch.

### 3. Ticket key from branch, title, then body
Branch names are the most reliable carrier in the projects this is used on; the body is last because it often mentions related tickets. Whole-key matching (`MED-35` does not match `MED-35x`) avoids false hits. Ambiguity is exit 3 with candidates, and the skill asks the user; it never guesses.

### 4. Session rename, with the Claude Code hint
The tmux session name makes the review window findable (`MED-35-review`); Claude Code keeps its own title, which only the user can change, so the script prints the `/rename` command instead of trying.

### 5. Install like `/fork`
Six skill folders, `--skip-review`, uninstall and verify entries, the same `install_file` helper and `.bak` behaviour.

## Risks / Trade-offs

- [`gh pr list --limit 200` misses very old PRs in large repos] → a PR number or URL always works; the limit is documented in the script.
- [Under Codex or Gemini the launched window may lack a tracker MCP] → the skill says to use the PR description and state that the ticket was not read.
- [install.sh carries other uncommitted work (sudo service install)] → only the review hunks are landed with this change.
