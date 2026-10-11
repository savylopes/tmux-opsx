# Spec Delta

## MODIFIED Requirements

### Requirement: Brief content
The parent agent SHALL write a brief containing: the question (or "general exploration" if none), a statement that the child answers questions and must not modify files, and instructions to run `/fork return` when the user asks. In brief mode it SHALL also contain 5–15 lines of context from the current conversation (goal, relevant files, current state or hypothesis); in full-context mode (see "Native fork") the context section SHALL be omitted. The brief SHALL be stored as `brief.md` in the fork's state directory and used as the child's first prompt.

#### Scenario: Brief seeded
- **WHEN** a fork is opened with a question
- **THEN** `brief.md` contains the question, a context section and the read-only role, and the child's first turn responds to it

#### Scenario: Short brief in full-context mode
- **WHEN** `fork.sh native` reported `full` and the parent opens the fork
- **THEN** `brief.md` contains the question, the read-only role and the fork protocol, and no context section

### Requirement: Fork state and ids
Each fork SHALL have a state directory `${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/<tmux-session>/<id>/` holding `brief.md`, `meta` and, once written, `result.md`. Ids SHALL be small integers, unique within the tmux session and allocated atomically. `meta` SHALL record the parent pane, child pane, CLI, model (empty when the CLI default is used), cwd, creation time, status (`open`, `returned`, `closed`) and `context` (`full` or `brief`, with the source session when known). The child process SHALL receive `FORK_ID`, `FORK_DIR` and `FORK_PARENT` environment variables.

#### Scenario: Concurrent forks
- **WHEN** two parents in the same tmux session fork at the same moment
- **THEN** they receive different ids and separate state directories

#### Scenario: Model recorded
- **WHEN** a fork is opened with `--model haiku`
- **THEN** its `meta` contains `model=haiku`, and a fork opened with no model contains `model=`

#### Scenario: Context recorded
- **WHEN** a Claude Code parent with session id `S` opens a Claude child natively, and another fork is opened with `--brief-only`
- **THEN** the first `meta` contains `context=full` and `S`, and the second contains `context=brief`

### Requirement: List and close forks
`/fork list` SHALL show every fork of the current tmux session with id, status, CLI, model (`default` when none), context (`full` or `brief`), pane and the first line of its question. `/fork close <id>` SHALL save a capture if no result exists, kill the child pane or window, and set status `closed`. `/fork close --all` SHALL do this for every open fork of the session. State directories SHALL be kept after closing.

#### Scenario: Close without result
- **WHEN** the user closes fork 1, which has no `result.md`
- **THEN** `capture.txt` is saved, the pane is killed, and a later `collect 1` returns that capture

#### Scenario: Model column
- **WHEN** fork 1 was opened with `--model haiku` and fork 2 with no model, and the user runs `fork.sh list`
- **THEN** the header has a MODEL column, fork 1's row shows `haiku` and fork 2's row shows `default`

#### Scenario: Context column
- **WHEN** fork 1 was opened natively and fork 2 with `--brief-only`, and the user runs `fork.sh list`
- **THEN** the header has a CONTEXT column, fork 1's row shows `full` and fork 2's row shows `brief`

## ADDED Requirements

### Requirement: Native fork
When the child CLI is the host CLI, that CLI has a true fork, the child's cwd is the parent's cwd and native mode is not disabled, `fork.sh open` SHALL launch the child as a fork of the parent's session so it starts with the whole conversation. The parent's own session SHALL NOT be written to: Claude Code SHALL use `--resume <parent session id> --fork-session`; OpenCode SHALL use `--continue --fork`. All read-only, allow-rule, system-prompt and model flags of the normal launch SHALL be kept.

#### Scenario: Claude native launch
- **WHEN** the host is Claude Code with `CLAUDE_CODE_SESSION_ID=S` in the environment and `fork.sh open --cli claude` runs
- **THEN** the fake claude was called with `--resume S`, `--fork-session`, `--permission-mode plan` and the brief, and without bypass flags

#### Scenario: OpenCode native launch
- **WHEN** the host is OpenCode and `fork.sh open --cli opencode` runs
- **THEN** the fake opencode was called with `--continue`, `--fork`, `--agent plan` and `--prompt`

### Requirement: Parent session discovery
`fork.sh` SHALL take the parent's Claude Code session id from `CLAUDE_CODE_SESSION_ID`, recovering it from the parent process chain when the variable was stripped from the shell, as it already does for `TMUX`. When no id can be found, the fork SHALL fall back to brief mode and say why.

#### Scenario: Stripped environment
- **WHEN** `CLAUDE_CODE_SESSION_ID` is unset in the shell running `fork.sh` but set on an ancestor process
- **THEN** the launch uses that ancestor's id

#### Scenario: No id
- **WHEN** the host is Claude Code and no session id is available
- **THEN** `fork.sh native --cli claude` prints `brief` with a reason naming the session id, and `open` launches without `--resume`

### Requirement: Stale session id
The process-chain recovery SHALL NOT take the id from the claude process or a tmux server, which keep the id they were launched with (possibly an earlier conversation's), and SHALL reject a recovered id equal to theirs as stale, falling back to brief mode instead of resuming a session it cannot attribute to the parent.

#### Scenario: Stale id
- **WHEN** `CLAUDE_CODE_SESSION_ID` is unset in the shell running `fork.sh` and the only id on the process chain is held by the claude process or the tmux server (or equals theirs)
- **THEN** `fork.sh native --cli claude` prints `brief` with a reason naming the session id, and `open` launches without `--resume`

### Requirement: Fallback to brief mode
`fork.sh open` SHALL use brief mode, launching exactly as before this change, when any of these holds: the child CLI differs from the host CLI; the CLI is Codex, Gemini or Cursor; the CLI is OpenCode and `--cwd` names a directory other than the parent's; `--brief-only` is given; `FORK_NATIVE` is `0`. Brief mode SHALL never add `--resume`, `--fork-session`, `--continue` or `--fork`.

#### Scenario: Cross-CLI fork
- **WHEN** the host is Claude Code and `fork.sh open --cli codex` runs
- **THEN** the fake codex is launched with today's flags only and `meta` has `context=brief`

#### Scenario: Different cwd
- **WHEN** the host is OpenCode and `fork.sh open --cli opencode --cwd /other/dir` runs
- **THEN** the launch has no `--continue` or `--fork` and `meta` has `context=brief`

#### Scenario: Forced brief
- **WHEN** `fork.sh open --cli claude --brief-only` runs on a Claude Code host with a session id
- **THEN** the launch has no `--resume` and `--fork-session`

### Requirement: Working directory and native mode
The working directory SHALL restrict native mode only for OpenCode, whose `--continue` resumes the last session of the current directory. A Claude Code child SHALL stay native when `--cwd` differs from the parent's directory, because `--resume <id>` finds the parent's session from any directory (verified in task 1.1).

#### Scenario: Claude in another cwd
- **WHEN** the host is Claude Code with session id `S` and `fork.sh open --cli claude --cwd /other/dir` runs
- **THEN** the launch has `--resume S` and `--fork-session` and `meta` has `context=full`

### Requirement: OpenCode session directory
For OpenCode the child's `--cwd` SHALL be compared with the session's directory, the working directory of the nearest `opencode` ancestor process (else the shell's directory), not with wherever the agent's shell has changed to.

#### Scenario: OpenCode shell changed directory
- **WHEN** the host is OpenCode started in directory `D`, the agent's shell has `cd`'d to another directory and `fork.sh native --cli opencode` runs with no `--cwd`
- **THEN** it prints `brief` (cwd differs), and with `--cwd D` it prints `full opencode continue`

### Requirement: Native mode query
`fork.sh native [--cli <name>] [--cwd <dir>]` SHALL resolve the child CLI exactly as `open` would and print one line: `full <cli> <source>` when a native fork would be used, else `brief <reason>`. It SHALL exit 0 in both cases, write nothing and not require a brief on stdin. `--cli` or `--cwd` given without a value (in `native` or `open`) SHALL fail with a "needs a value" error.

#### Scenario: Full
- **WHEN** the host is Claude Code with session id `S` and `fork.sh native` runs
- **THEN** it prints `full claude session S` and exits 0

#### Scenario: Brief with reason
- **WHEN** `fork.sh native --cli gemini` runs on a Claude Code host
- **THEN** it prints a line starting with `brief` that names gemini, and exits 0

#### Scenario: Missing option value
- **WHEN** `fork.sh native --cwd` runs with no value after `--cwd`
- **THEN** it exits 1 with `--cwd needs a value`

### Requirement: Open reports the context mode
The `open` output SHALL include a `# context: full …` or `# context: brief …` line after the first line, leaving the first line's `fork <id> pane <pane> cli <cli> model <m>` form unchanged.

#### Scenario: Context line
- **WHEN** `fork.sh open --cli claude` succeeds natively as fork 3
- **THEN** the first output line still matches `fork 3 pane %<n> cli claude model <m>` and a later line starts with `# context: full`

### Requirement: Skill chooses the brief form
The `/fork` skill SHALL instruct the parent to run `fork.sh native` with the same `--cli`/`--cwd` it will pass to `open`, write the short brief when it prints `full` and the full brief otherwise, pass `--brief-only` when the user said `/fork --brief`, and remind the parent that in full mode the child sees the entire conversation including anything sensitive in it.

#### Scenario: Skill text
- **WHEN** the installed `fork/SKILL.md` is read
- **THEN** it mentions `fork.sh native`, `--brief`, `--brief-only` and the short brief form

### Requirement: Documentation
`README.md` SHALL document native forking: which CLIs fork natively, the fallbacks, `/fork --brief`, the CONTEXT column, and that a native child inherits the parent's full context and context-window usage.

#### Scenario: README
- **WHEN** `README.md` is read
- **THEN** it mentions `--fork-session`, `--brief` and the brief fallback
