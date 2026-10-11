# Spec Delta

## MODIFIED Requirements

### Requirement: Brief content
The parent agent SHALL write a brief containing: the question (or "general exploration" if none), a statement that the child answers questions and must not modify files, and instructions to run `/fork return` when the user asks. In brief mode it SHALL also contain 5–15 lines of context from the current conversation (goal, relevant files, current state or hypothesis); in full-context mode (see "Native fork") the context section SHALL be omitted. When `open` is given `--page-dir`, `fork.sh` SHALL append a page protocol section naming the exact `fork.sh page` command, and requiring an English and a Portuguese version of the page with identical labels in each write, after the fork protocol. The brief SHALL be stored as `brief.md` in the fork's state directory and used as the child's first prompt.

#### Scenario: Brief seeded
- **WHEN** a fork is opened with a question
- **THEN** `brief.md` contains the question, a context section and the read-only role, and the child's first turn responds to it

#### Scenario: Short brief in full-context mode
- **WHEN** `fork.sh native` reported `full` and the parent opens the fork
- **THEN** `brief.md` contains the question, the read-only role and the fork protocol, and no context section

#### Scenario: Page protocol appended
- **WHEN** `fork.sh open --page-dir <dir>` runs
- **THEN** `brief.md` ends with a page protocol section containing the literal `fork.sh page` command and the rule that every page is written in English and Portuguese (`lang="en"`, `lang="pt"`) with identical labels, and a fork opened without `--page-dir` has no such section

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

## ADDED Requirements

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
