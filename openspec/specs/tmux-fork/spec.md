# tmux-fork Specification

## Purpose
TBD - created by archiving change add-tmux-fork. Update Purpose after archive.
## Requirements
### Requirement: Open a fork in a pane by default
`/fork ["question"]` SHALL write a brief and open a child agent in a new tmux pane split side-by-side from the parent pane (`$TMUX_PANE`), taking about 40% of the width. With `--vertical` it SHALL split top/bottom. With `--window` it SHALL open a new window named `fork-<id>` instead. The child SHALL start in the parent's current working directory and use the parent's CLI unless `--cli <claude|agent|codex|opencode|gemini>` is given. The command SHALL print the fork id and child pane id.

#### Scenario: Default pane
- **WHEN** the user runs `/fork "where are retries handled?"` in a Claude Code pane `%3`
- **THEN** a new pane appears to the right of `%3`, running Claude Code seeded with the brief, and the parent prints `fork 1` with the child's pane id

#### Scenario: Window mode
- **WHEN** the user runs `/fork --window "review the install flow"`
- **THEN** a new tmux window `fork-<id>` opens with the child agent, and the parent pane is unchanged

#### Scenario: Several forks
- **WHEN** a parent already has one child pane and the user forks again
- **THEN** the layout is rearranged so the parent remains the largest pane and both children are visible

### Requirement: Brief content
The parent agent SHALL write a brief containing: the question (or "general exploration" if none), 5–15 lines of context from the current conversation (goal, relevant files, current state or hypothesis), a statement that the child answers questions and must not modify files, and instructions to run `/fork return` when the user asks. The brief SHALL be stored as `brief.md` in the fork's state directory and used as the child's first prompt.

#### Scenario: Brief seeded
- **WHEN** a fork is opened with a question
- **THEN** `brief.md` contains the question, a context section and the read-only role, and the child's first turn responds to it

### Requirement: Read-only children
The child SHALL be launched in the CLI's read-only or plan mode where one exists (for example `claude --permission-mode plan`, `codex --sandbox read-only`). The child SHALL never be launched with approval-bypass flags. Where a CLI has no enforceable read-only mode, the child SHALL run with normal interactive approvals and rely on the brief's instruction.

#### Scenario: Claude child
- **WHEN** the child CLI is Claude Code
- **THEN** it is launched with `--permission-mode plan` and without `bypassPermissions`

#### Scenario: CLI without read-only mode
- **WHEN** the child CLI has no read-only flag
- **THEN** it is launched without force/auto-approve flags, and any file write requires the user's approval

### Requirement: Fork state and ids
Each fork SHALL have a state directory `${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/<tmux-session>/<id>/` holding `brief.md`, `meta` and, once written, `result.md`. Ids SHALL be small integers, unique within the tmux session and allocated atomically. `meta` SHALL record the parent pane, child pane, CLI, cwd, creation time and status (`open`, `returned`, `closed`). The child process SHALL receive `FORK_ID`, `FORK_DIR` and `FORK_PARENT` environment variables.

#### Scenario: Concurrent forks
- **WHEN** two parents in the same tmux session fork at the same moment
- **THEN** they receive different ids and separate state directories

### Requirement: Return a result from the child
In a child, `/fork return` SHALL have the agent write a concise result (answer, evidence such as `file:line` or commands run, unresolved points) to `result.md` via `fork.sh return`, set status `returned`, and notify the parent. If writing fails (for example due to a sandbox), the agent SHALL instead print the result between `<<<FORK-RESULT` and `FORK-RESULT>>>` marker lines. Running `/fork return` outside a fork (no `FORK_DIR`) SHALL report that this session is not a fork.

#### Scenario: Normal return
- **WHEN** the user types `/fork return` in child `2`
- **THEN** `result.md` is written, status is `returned`, and the parent is notified

#### Scenario: Sandbox blocks the write
- **WHEN** `fork.sh return` cannot write to `FORK_DIR`
- **THEN** the child prints the result between the marker lines so the parent can recover it

### Requirement: Notify the parent without typing into it
On return, the parent pane SHALL be notified with a tmux message and a visible badge (for example in the pane title) naming the fork. The fork tooling SHALL NOT send keys into the parent pane at any time. If the parent pane no longer exists, the result SHALL still be saved and the command SHALL succeed.

#### Scenario: Parent busy
- **WHEN** the parent agent is mid-task and child `1` returns
- **THEN** a tmux message and badge appear, and the parent agent's input is untouched

### Requirement: Collect a result in the parent
`/fork collect [id]` SHALL print the fork's `result.md` into the parent's context. Without an id it SHALL pick the most recently returned fork of the current session. If there is no `result.md`, it SHALL extract the last marker block from the child pane's scrollback; failing that, it SHALL return the tail of the pane capture, clearly labelled as a raw capture. Collecting SHALL clear the parent's badge for that fork.

#### Scenario: Collect latest
- **WHEN** forks 1 and 2 exist, only 2 has returned, and the user runs `/fork collect`
- **THEN** fork 2's result is shown in the parent

#### Scenario: No result written
- **WHEN** the user collects fork 1, which never returned
- **THEN** the marker block from its pane is used if present, otherwise a labelled raw capture

### Requirement: List and close forks
`/fork list` SHALL show every fork of the current tmux session with id, status, CLI, pane and the first line of its question. `/fork close <id>` SHALL save a capture if no result exists, kill the child pane or window, and set status `closed`. `/fork close --all` SHALL do this for every open fork of the session. State directories SHALL be kept after closing.

#### Scenario: Close without result
- **WHEN** the user closes fork 1, which has no `result.md`
- **THEN** `capture.txt` is saved, the pane is killed, and a later `collect 1` returns that capture

### Requirement: Require tmux
If `$TMUX` is unset, every `/fork` command except `return` SHALL fail with a clear message and change nothing.

#### Scenario: Not in tmux
- **WHEN** the user runs `/fork "question"` outside tmux
- **THEN** the command reports that tmux is required and opens nothing

