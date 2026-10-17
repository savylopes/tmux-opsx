# Design

## Context

See proposal.md and `specs/tmux-fork/spec.md`. In `skills/fork/fork.sh`, `build_launch_cmd` fixes each CLI's read-only flags and, for Claude, the allow rules and an appended system prompt saying "do not exit plan mode and do not modify files"; `protocol_footer` appends the read-only rule to every brief; `cmd_return` shows how a child-side command finds its fork (`resolve_own_fork_dir`) and reaches the parent (`notify_parent`).

## Goals / Non-Goals

**Goals:** a writable fork at creation; an unlock from inside that needs the user's own action; normal approvals in both cases.

**Non-Goals:** worktree isolation, re-locking, unattended (bypass) writes.

## Decisions

### 1. `--write` swaps the mode flags, nothing else
`build_launch_cmd` gets a `write` argument. With it each CLI drops its read-only flag for its normal one (Claude `--permission-mode manual`, or `default` on older versions, Codex `--sandbox workspace-write --ask-for-approval on-request`, OpenCode `--agent build`, Gemini `--approval-mode default`, Cursor no `--mode`). Native-fork flags, model flags and the `fork.sh return` allow rule stay. Explicit normal modes (rather than omitting the flag) keep a user's default config from silently turning a fork into a bypass session.

### 2. The unlock needs two actions, one only the user can do
A read-only child cannot leave plan mode itself. `/fork write` changes what the child is told it may do; the user's mode switch (shift+tab in Claude Code and Gemini, Tab to "build" in OpenCode, `/approvals` in Codex) changes what the CLI lets it do. The appended prompt and the protocol say both. Because the appended system prompt cannot be changed mid-session, it carries the conditional rule from the start: "read-only unless the user runs `/fork write` in this pane".

Alternative: relaunch the child with `--resume` in write mode. Rejected: different per CLI, impossible for Codex, Gemini and Cursor, and it drops the pane's scrollback.

### 3. `fork.sh write` is a state-only child command
Like `return`, it writes only the fork's state dir (`write=1`, `write_since`), sets the child pane title, and calls `notify_parent`. On Claude Code the read-only launch gets a third narrow rule, `Bash(<fork.sh> write:*)`, so plan mode does not block it.

### 4. Same checkout, said out loud
A writable fork edits its `--cwd` (the parent's checkout by default). The protocol warns that the parent may edit the same files and asks the child to list the files it changed in `/fork return`, so the parent can see them on collect.

### 5. List shows `,write` in STATUS
Columns stay as they are (existing scripts and tests parse them); `open,write` fits the 18-character STATUS column.

## Risks / Trade-offs

- [Parent and fork edit the same file] → warning in the protocol, changed files in the result; worktree isolation can come later.
- [A model claims `/fork write` was typed when it was not] → it still cannot leave plan mode; the CLI's own approval prompts remain.
