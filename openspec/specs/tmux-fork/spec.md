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
The parent agent SHALL write a brief containing: the question (or "general exploration" if none), a statement that the child answers questions and must not modify files, and instructions to run `/fork return` when the user asks. In brief mode it SHALL also contain 5–15 lines of context from the current conversation (goal, relevant files, current state or hypothesis); in full-context mode (see "Native fork") the context section SHALL be omitted. When `open` is given `--page-dir`, `fork.sh` SHALL append a page protocol section naming the exact `fork.sh page` command, requiring the page in the language or languages the brief names (its `Languages:` line) and, when more than one is named, identical labels in every write, after the fork protocol. The brief SHALL be stored as `brief.md` in the fork's state directory and used as the child's first prompt.

#### Scenario: Brief seeded
- **WHEN** a fork is opened with a question
- **THEN** `brief.md` contains the question, a context section and the read-only role, and the child's first turn responds to it

#### Scenario: Short brief in full-context mode
- **WHEN** `fork.sh native` reported `full` and the parent opens the fork
- **THEN** `brief.md` contains the question, the read-only role and the fork protocol, and no context section

#### Scenario: Page protocol appended
- **WHEN** `fork.sh open --page-dir <dir>` runs
- **THEN** `brief.md` ends with a page protocol section containing the literal `fork.sh page` command, the rule that the page is written in the languages the brief's `Languages:` line names with identical labels when there are two, and inline SVG before Mermaid for diagrams; a fork opened without `--page-dir` has no such section

### Requirement: Read-only children
The child SHALL be launched in the CLI's read-only or plan mode where one exists (for example `claude --permission-mode plan`, `codex --sandbox read-only`). The child SHALL never be launched with approval-bypass flags. Where a CLI has no enforceable read-only mode, the child SHALL run with normal interactive approvals and rely on the brief's instruction.

#### Scenario: Claude child
- **WHEN** the child CLI is Claude Code
- **THEN** it is launched with `--permission-mode plan` and without `bypassPermissions`

#### Scenario: CLI without read-only mode
- **WHEN** the child CLI has no read-only flag
- **THEN** it is launched without force/auto-approve flags, and any file write requires the user's approval

### Requirement: Fork state and ids
Each fork SHALL have a state directory `${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/<tmux-session>/<id>/` holding `brief.md`, `meta` and, once written, `result.md`. Ids SHALL be small integers, unique within the tmux session and allocated atomically. `meta` SHALL record the parent pane, child pane, CLI, model (empty when the CLI default is used), cwd, creation time, status (`open`, `returned`, `closed`), `context` (`full` or `brief`, with the source session when known) and `page_dir` (empty when the fork writes no page). The child process SHALL receive `FORK_ID`, `FORK_DIR`, `FORK_PARENT` and, for a page fork, `FORK_PAGE_DIR` environment variables.

#### Scenario: Concurrent forks
- **WHEN** two parents in the same tmux session fork at the same moment
- **THEN** they receive different ids and separate state directories

#### Scenario: Model recorded
- **WHEN** a fork is opened with `--model haiku`
- **THEN** its `meta` contains `model=haiku`, and a fork opened with no model contains `model=`

#### Scenario: Context recorded
- **WHEN** a Claude Code parent with session id `S` opens a Claude child natively, and another fork is opened with `--brief-only`
- **THEN** the first `meta` contains `context=full` and `S`, and the second contains `context=brief`

#### Scenario: Page dir recorded
- **WHEN** a fork is opened with `--page-dir /x/explain/shop/3`
- **THEN** its `meta` contains `page_dir=/x/explain/shop/3` and the fake CLI saw `FORK_PAGE_DIR=/x/explain/shop/3`; a fork opened without it has `page_dir=`

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

### Requirement: Require tmux
If `$TMUX` is unset, every `/fork` command except `return` SHALL fail with a clear message and change nothing.

#### Scenario: Not in tmux
- **WHEN** the user runs `/fork "question"` outside tmux
- **THEN** the command reports that tmux is required and opens nothing

### Requirement: Choose the child's model
`fork.sh open` SHALL accept `--model <m>` and read `$FORK_MODEL`. The child's model SHALL be chosen as: `--model`, else `$FORK_MODEL`, else an inherited parent model (see "Inherit the parent's model"), else none. When a model is chosen, the child SHALL be launched with its CLI's model flag set to that value; when none is chosen, no model flag SHALL be passed. A model value that is empty, contains whitespace or starts with `-` SHALL be rejected before anything is opened.

#### Scenario: Explicit model
- **WHEN** the user runs `fork.sh open --cli claude --model haiku` with a brief
- **THEN** the child's `launch.sh` passes `--model haiku` to `claude`

#### Scenario: No model anywhere
- **WHEN** `fork.sh open --cli claude` runs with no `--model`, no `--parent-model` and `$FORK_MODEL` unset
- **THEN** `launch.sh` contains no model flag, as before this change

#### Scenario: Environment default
- **WHEN** `$FORK_MODEL=sonnet` and `fork.sh open --cli claude` runs without `--model`
- **THEN** the child is launched with `--model sonnet`

#### Scenario: Flag beats environment
- **WHEN** `$FORK_MODEL=sonnet` and `fork.sh open --cli claude --model opus` runs
- **THEN** the child is launched with `--model opus`

#### Scenario: Per-CLI flag spelling
- **WHEN** a fork is opened with `--model m1` for each of `claude`, `agent`, `codex`, `opencode` and `gemini`
- **THEN** each child's launch line passes `m1` through that CLI's model flag (`--model` for claude and agent, `-m` for codex, opencode and gemini)

#### Scenario: Unsafe model value
- **WHEN** `fork.sh open --model "--dangerously-skip-permissions"` runs
- **THEN** it exits non-zero with a clear message, and no fork id, state directory or pane is created

### Requirement: Inherit the parent's model
`fork.sh open` SHALL accept `--parent-model <m>`, the parent agent's own model. It SHALL be used only when neither `--model` nor `$FORK_MODEL` gives a model and the child CLI is the same CLI as the host CLI; otherwise it SHALL be ignored without error. For OpenCode children it SHALL be used only if it has the `provider/model` form.

#### Scenario: Same CLI inherits
- **WHEN** the parent runs under Claude Code and calls `fork.sh open --parent-model claude-opus-5-5` without `--cli`
- **THEN** the Claude child is launched with `--model claude-opus-5-5`

#### Scenario: Cross-CLI fork does not inherit
- **WHEN** the parent runs under Claude Code and calls `fork.sh open --cli codex --parent-model claude-opus-5-5`
- **THEN** the Codex child is launched with no model flag

#### Scenario: Environment default beats inheritance
- **WHEN** `$FORK_MODEL=haiku` and the parent calls `fork.sh open --parent-model claude-opus-5-5` from Claude Code
- **THEN** the child is launched with `--model haiku`

#### Scenario: OpenCode id without provider
- **WHEN** the parent runs under OpenCode and passes `--parent-model gpt-5`
- **THEN** the OpenCode child is launched with no model flag

### Requirement: Host CLI for inheritance
The host CLI used to decide inheritance SHALL be taken from `$FORK_HOST_CLI` when set, with `none` meaning undetected; otherwise it SHALL be detected. When the host is undetected, `--parent-model` SHALL be ignored.

#### Scenario: Host not detected
- **WHEN** `$FORK_HOST_CLI=none` and `fork.sh open --cli claude --parent-model claude-opus-5-5` runs
- **THEN** the child is launched with no model flag

### Requirement: Skill passes the parent's model
The `/fork` skill SHALL instruct the parent agent to always pass `--parent-model` with its own model id.

#### Scenario: Skill instruction
- **WHEN** `skills/fork/SKILL.md` is read
- **THEN** its open step tells the parent to pass `--parent-model <its own model id>`

### Requirement: Report the child's model
The `open` output line SHALL end with `model <m>` naming the chosen model, or `model default` when none was chosen.

#### Scenario: Output line
- **WHEN** `fork.sh open --cli claude --model haiku` succeeds as fork 3
- **THEN** its first output line has the form `fork 3 pane %<n> cli claude model haiku`

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

### Requirement: Page write from the child
`fork.sh page` SHALL read a complete HTML document on stdin and write it atomically to `<page_dir>/index.html` of the calling fork (page dir from `$FORK_PAGE_DIR`, else `meta`), creating the directory if needed; with `--manifest` it SHALL write `<page_dir>/manifest.tsv` instead. It SHALL never write anywhere else and SHALL refuse empty input, a non-fork caller, a fork without a page directory, and an unwritable target, each with a distinct non-zero exit.

#### Scenario: Page written
- **WHEN** a child with `FORK_PAGE_DIR=/x/3` runs `fork.sh page` with an HTML document on stdin
- **THEN** `/x/3/index.html` contains that document and the command prints the page path

#### Scenario: Manifest written
- **WHEN** the child runs `fork.sh page --manifest` with TSV lines on stdin
- **THEN** `/x/3/manifest.tsv` contains them and `index.html` is untouched

#### Scenario: Not a page fork
- **WHEN** `fork.sh page` runs in a fork opened without `--page-dir`
- **THEN** it exits 4, names `--page-dir`, and writes nothing

#### Scenario: Outside a fork
- **WHEN** `fork.sh page` runs with no `FORK_DIR` and no fork pane option
- **THEN** it exits 1 and says the session is not a fork

#### Scenario: Empty input
- **WHEN** `fork.sh page` runs with empty stdin
- **THEN** it exits non-zero and `index.html` is unchanged

### Requirement: Library hook confined
After an `index.html` write, `fork.sh page` SHALL run `<page_dir>/../.reindex` only when `<page_dir>/..` lies directly under `<state root>/explain/` and the hook is an executable regular file (not a symlink) owned by the user.

#### Scenario: Library hook confined
- **WHEN** `fork.sh page` writes a page whose parent directory is not under `<state root>/explain/`, or whose `.reindex` is a symlink
- **THEN** the page is written and that `.reindex` is not run

### Requirement: Page command allowed in read-only mode
When a fork has a page directory, the child's read-only launch SHALL allow exactly `fork.sh page` in addition to `fork.sh return` (for Claude Code, a second narrow `--allowedTools` rule and a sentence in the appended system prompt), and the launch SHALL still carry no bypass flags. On a CLI whose sandbox blocks the command, the page protocol SHALL tell the child to report that the page cannot be written and stop, never to print the HTML into the pane.

#### Scenario: Claude page fork launch
- **WHEN** `fork.sh open --cli claude --page-dir /x/3` runs
- **THEN** the fake claude log contains an allow rule for `fork.sh page`, one for `fork.sh return`, `--permission-mode plan`, and no bypass flags

#### Scenario: No marker fallback for pages
- **WHEN** an explain fork's `brief.md` is read
- **THEN** its page protocol says to stop and report when `fork.sh page` is blocked, and does not mention the `<<<FORK-RESULT` markers for the page
