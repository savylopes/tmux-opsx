# Proposal

> Captures the `/opsx-review` skill drafted on 2026-10-15 (`skills/opsx-review/`, `tests/test-review.sh`, the install and README hunks), which existed only as uncommitted work, so it goes through the same plan, verify, land and install path as every other component.

## Why

Reviewing someone else's pull request against its ticket and the project's specification is today an ad-hoc conversation: the PR is read in the shared checkout, the acceptance criteria are checked from memory, and green CI is taken as proof. tmux-opsx already has everything a disciplined review needs (OpenSpec changes, `/opsx-run --validate` with its gates, detached worktrees); `/opsx-review` wires them into one command whose output is a report, a conformance matrix, executed evidence and a draft PR comment, with nothing posted unless the user asks.

## What Changes

- **New `/opsx-review` skill** (`skills/opsx-review/SKILL.md`), installed for all five CLIs like `/fork`: `/opsx-review <PR | URL | TICKET-KEY> ["focus"] [--no-run] [--no-session] [--agent-cli …]` resolves the PR and its ticket, renames the tmux session `<TICKET>-review`, does a first read-only pass of the PR, the ticket and the project's requirement sources, writes a review change (proposal, baseline spec, design, tasks) through the propose workflow, validates it with `--strict`, and launches `/opsx-run <change> --validate` with review constraints added to the prompt.
- **`opsx-review.sh`**, the deterministic parts: `resolve` (PR number, `#N`, URL or ticket key → `key=value` lines; exit 2 none, exit 3 several candidates), `session <name>` (rename the pane's tmux session, fold tmux metacharacters, refuse an existing name, print the `/rename` hint under Claude Code) and `worktree <change> <sha>` (a detached `../wt-<change>` at the head SHA, reused when already there, refused when at another SHA). It only reads from `gh` and never switches a branch.
- **Install, tests and docs.** `install.sh` installs `skills/opsx-review/` into the six skill folders, `--skip-review` skips it, `--uninstall` removes it, and the verify step checks it; `tests/test-review.sh` covers the script with a fake `gh`; README gains the overview line, the component row, the `--skip-review` flag and a "Reviewing a pull request" section.
- Not in scope: posting reviews or comments, touching the ticket, fixing the PR, any CI integration.

## Capabilities

### New Capabilities
- `pr-review`: the `/opsx-review` skill and `opsx-review.sh`: PR and ticket resolution, session naming, the detached review worktree, the review change it writes and launches, its read-only and no-posting rules, and its install and documentation.

### Modified Capabilities

None.

## Impact

- New `skills/opsx-review/SKILL.md`, `skills/opsx-review/opsx-review.sh`, `tests/test-review.sh`.
- `install.sh`: `install_review_skill`, `--skip-review`, uninstall and verify entries. `README.md`: overview, component table, flags, a section under Workflow.
- Needs `gh` (authenticated) and `jq` at run time; uses `/opsx-run` and the propose workflow, both already installed.
