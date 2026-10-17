# Proposal

> Captured from the `/opsx:explore` session of 2026-10-17. Decisions confirmed there: one opt-out at creation (`/fork --write`) and one from inside a running fork (`/fork write`); a writable fork edits the checkout it runs in (no separate worktree); approvals stay normal, never bypass. Using `/explain` from inside a fork was dropped.

## Why

Every fork is read-only, with no way out: the child is launched in its CLI's plan or read-only mode and told in its prompt never to modify files. Sometimes a side conversation ends in "then just fix it", and today that means going back to the parent or starting another agent that lacks the fork's context. The user wants to allow writes either when opening the fork or later, from inside it.

## What Changes

- **`fork.sh open --write`** (and `/fork --write "<question>"`): the child launches in its CLI's normal mode with normal approvals (Claude `--permission-mode manual`, or `default` on older versions, Codex `--sandbox workspace-write --ask-for-approval on-request`, OpenCode `--agent build`, Gemini `--approval-mode default`, Cursor without `--mode ask`), and its brief and prompt say it may edit files in its working directory. `--write` cannot be combined with `--page-dir`.
- **`fork.sh write`** (and `/fork write`, typed inside a read-only fork): the child-side unlock. It records the fork as writable, retitles the child pane `fork <id> (write)` and notifies the parent pane. The read-only fork's prompt and protocol say writing is allowed only after the user has run `/fork write` in that pane; the user also switches the CLI out of its read-only mode (for example shift+tab in Claude Code), which the child cannot do itself. On Claude Code a narrow allow rule permits exactly `fork.sh write`, like `fork.sh return`.
- **State and listing.** `meta` gets `write=0|1` (and `write_since` when unlocked). `fork.sh list` shows a writable fork's status as `<status>,write`.
- Not in scope: a separate worktree for writable forks, making a writable fork read-only again, `/explain` from inside a fork.

## Capabilities

### New Capabilities

None.

### Modified Capabilities
- `tmux-fork`: "Read-only children" gains the `--write` exception; "Brief content" gains the writable variant of the fork protocol and the `/fork write` rule; new requirements "Writable fork at creation" and "Unlock writing from inside a fork".

## Impact

- `skills/fork/fork.sh`: `--write` on `open`, `write` subcommand, launch modes, protocol text, allow rule, meta, list.
- `skills/fork/SKILL.md`: parent-side `--write`, child-side `/fork write`, the per-CLI table.
- `tests/test-fork.sh`: launch flags per CLI with `--write`, protocol variants, `write` command, list status.
- `README.md`: Fork section.
