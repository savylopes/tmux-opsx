# Spec Delta

## ADDED Requirements

### Requirement: Writable fork at creation
`fork.sh open --write` SHALL launch the child in its CLI's normal, non-read-only mode with normal interactive approvals and never a bypass mode; for Claude Code that is the prompting mode its `--help` lists (`manual`, else `default`), overridable with `$FORK_CLAUDE_WRITE_MODE` (`manual`, `default` or `acceptEdits` only). It SHALL record `write=1` in `meta` (`write=0` without the flag) and SHALL be refused together with `--page-dir`.

#### Scenario: Claude writable child
- **WHEN** `fork.sh open --write --cli claude` runs
- **THEN** the child is launched with `--permission-mode manual` when `claude --help` lists it (else `default`), not `plan`, without bypass flags, and `meta` has `write=1`

#### Scenario: Other CLIs writable
- **WHEN** `fork.sh open --write` runs with `--cli codex`, `opencode`, `gemini` and `agent`
- **THEN** they are launched with `--sandbox workspace-write`, `--agent build`, `--approval-mode default`, and without `--mode ask`, respectively, and none with a bypass or force flag

#### Scenario: Claude mode override
- **WHEN** `FORK_CLAUDE_WRITE_MODE=acceptEdits fork.sh open --write --cli claude` runs, and separately with `FORK_CLAUDE_WRITE_MODE=bypassPermissions`
- **THEN** the first child is launched with `--permission-mode acceptEdits`, and the second `open` exits non-zero and launches nothing

#### Scenario: Not with a page dir
- **WHEN** `fork.sh open --write --page-dir /x/1` runs
- **THEN** it exits non-zero naming both options, and no fork is created

### Requirement: Unlock writing from inside a fork
`fork.sh write`, run inside a fork child, SHALL set `write=1` and `write_since` in that fork's `meta`, retitle the child pane `fork <id> (write)`, notify the parent pane, and print that writing is unlocked and that the CLI must also leave its read-only mode. Run again it SHALL say the fork is already writable and exit 0. Outside a fork it SHALL exit 1; in a page fork it SHALL exit 4. On Claude Code, a read-only fork's launch SHALL allow `fork.sh write` beside `fork.sh return`.

#### Scenario: Unlocked
- **WHEN** `fork.sh write` runs in fork 3's child pane
- **THEN** fork 3's `meta` has `write=1` and a `write_since` time, its pane title is `fork 3 (write)`, and the output mentions leaving the read-only mode

#### Scenario: Not a fork
- **WHEN** `fork.sh write` runs outside any fork
- **THEN** it exits 1 with a message that it only works inside a fork

#### Scenario: Claude allow rule
- **WHEN** a read-only fork is opened with `--cli claude`
- **THEN** its launch allows exactly `fork.sh return` and `fork.sh write`, and a page fork's launch allows exactly `fork.sh return` and `fork.sh page`

#### Scenario: Page fork stays locked
- **WHEN** `fork.sh write` runs in a page fork
- **THEN** it exits 4 and `meta` keeps `write=0`, and the page fork's protocol has no unlock rule

### Requirement: Writable forks in the list
`fork.sh list` SHALL show a fork whose `meta` has `write=1` with the status `<status>,write`, keeping the columns unchanged.

#### Scenario: Listed
- **WHEN** fork 2 is open and writable and fork 1 is open and read-only
- **THEN** `list` shows `open,write` for fork 2 and `open` for fork 1

## MODIFIED Requirements

### Requirement: Read-only children
The child SHALL be launched in the CLI's read-only or plan mode where one exists (for example `claude --permission-mode plan`, `codex --sandbox read-only`), unless the fork is opened with `--write` (see "Writable fork at creation"). The child SHALL never be launched with approval-bypass flags. Where a CLI has no enforceable read-only mode, the child SHALL run with normal interactive approvals and rely on the brief's instruction.

#### Scenario: Claude child
- **WHEN** the child CLI is Claude Code and `--write` is not given
- **THEN** it is launched with `--permission-mode plan` and without `bypassPermissions`

#### Scenario: CLI without read-only mode
- **WHEN** the child CLI has no read-only flag
- **THEN** it is launched without force/auto-approve flags, and any file write requires the user's approval

### Requirement: Brief content
The parent agent SHALL write a brief containing: the question (or "general exploration" if none), a statement that the child answers questions and must not modify files, and instructions to run `/fork return` when the user asks. In brief mode it SHALL also contain 5–15 lines of context from the current conversation (goal, relevant files, current state or hypothesis); in full-context mode (see "Native fork") the context section SHALL be omitted. When `open` is given `--page-dir`, `fork.sh` SHALL append a page protocol section naming the exact `fork.sh page` command, requiring the page in the language or languages the brief names (its `Languages:` line) and, when more than one is named, identical labels in every write, after the fork protocol. The brief SHALL be stored as `brief.md` in the fork's state directory and used as the child's first prompt. The fork protocol of a read-only fork SHALL say writing is allowed only after the user runs `/fork write` in that pane and SHALL name the exact `fork.sh write` command; that of a fork opened with `--write` SHALL say the child may edit files in its working directory, that the parent may be editing the same checkout, and that its result lists the files it changed.

#### Scenario: Brief seeded
- **WHEN** a fork is opened with a question
- **THEN** `brief.md` contains the question, a context section and the read-only role, and the child's first turn responds to it

#### Scenario: Short brief in full-context mode
- **WHEN** `fork.sh native` reported `full` and the parent opens the fork
- **THEN** `brief.md` contains the question, the read-only role and the fork protocol, and no context section

#### Scenario: Page protocol appended
- **WHEN** `fork.sh open --page-dir <dir>` runs
- **THEN** `brief.md` ends with a page protocol section containing the literal `fork.sh page` command, the rule that the page is written in the languages the brief's `Languages:` line names with identical labels when there are two, and inline SVG before Mermaid for diagrams; a fork opened without `--page-dir` has no such section

#### Scenario: Unlock rule in a read-only fork
- **WHEN** a fork is opened without `--write` and without `--page-dir`
- **THEN** its fork protocol names `/fork write` and the literal `fork.sh write` command, and says files stay untouched until the user runs it

#### Scenario: Writable protocol
- **WHEN** a fork is opened with `--write`
- **THEN** its fork protocol says the child may edit files, warns that the parent may edit the same checkout, asks for the changed files in the result, and does not contain the read-only rule
