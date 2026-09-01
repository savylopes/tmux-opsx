# ops-reviewer Specification

## Purpose
TBD - created by archiving change add-ops-reviewer-security. Update Purpose after archive.
## Requirements
### Requirement: ops-reviewer subagent exists and is installable

The system SHALL provide an `ops-reviewer` subagent definition at `agents/opsx-reviewer.md` and install it to the same agent paths as `ops-applier` and `ops-qa` for Claude Code, Cursor CLI, Codex CLI, OpenCode, and Gemini CLI via `install.sh`.

#### Scenario: Install copies reviewer agent

- **WHEN** the user runs `./install.sh`
- **THEN** `ops-reviewer` agent files are present in each supported CLI's global agents directory
- **AND** `opsx-window.sh ensure` symlinks the reviewer into project `.cursor/agents/` and `.gemini/agents/` when applicable

### Requirement: ops-reviewer is read-only

The ops-reviewer subagent SHALL NOT edit product code, commit, or tick `tasks.md`. It SHALL only read artifacts, diffs, and run non-mutating checks (e.g. tests in read-only verification mode).

#### Scenario: Reviewer reports without fixing

- **WHEN** ops-reviewer finds a logic bug in the implementation
- **THEN** it returns a FAIL verdict with numbered findings
- **AND** it does not apply code fixes itself

### Requirement: ops-reviewer performs full implementation review

The ops-reviewer subagent SHALL review the change branch (`opsx/<change>`) against OpenSpec artifacts (`proposal.md`, `design.md`, `tasks.md`) and the code diff. It SHALL check spec fidelity, logic correctness, error handling, test coverage where tests exist, and maintainability relative to `design.md`.

#### Scenario: Spec drift detected

- **WHEN** a checked task claims a feature is implemented but the code does not provide it
- **THEN** ops-reviewer returns `VERDICT: FAIL` with at least one P0 or P1 finding referencing the task and file

#### Scenario: Tests exist and fail

- **WHEN** the repository has relevant automated tests for the changed area
- **AND** those tests fail on the change branch
- **THEN** ops-reviewer returns `VERDICT: FAIL` with a finding describing the failing test

### Requirement: ops-reviewer uses structured verdict output

The ops-reviewer subagent SHALL end every run with a parseable block containing `VERDICT: PASS`, `VERDICT: FAIL`, or `VERDICT: SKIP`, `CHANGE: <name>`, `FINDINGS:` with entries `F1`, `F2`, …, and `SUMMARY:`.

#### Scenario: Pass with no blocking issues

- **WHEN** no P0 or P1 findings exist
- **THEN** ops-reviewer returns `VERDICT: PASS`
- **AND** P2 polish items may be listed without failing the gate

### Requirement: ops-reviewer supports SKIP

The ops-reviewer subagent SHALL return `VERDICT: SKIP` with a one-line reason when the change has no implementation surface to review (e.g. documentation-only or spec-only changes with no product code diff).

#### Scenario: Docs-only change

- **WHEN** the change diff contains only documentation and OpenSpec metadata
- **THEN** ops-reviewer returns `VERDICT: SKIP` with a reason
- **AND** a gated validate loop treats SKIP as satisfying the review gate

### Requirement: review action dispatches ops-reviewer once

The `/opsx-run <change> review` action SHALL create or reuse the change tmux window and dispatch ops-reviewer exactly once. It SHALL NOT auto-spawn ops-applier to fix findings.

#### Scenario: Standalone review

- **WHEN** the user runs `/opsx-run add-auth review`
- **THEN** the change window runs ops-reviewer once
- **AND** the caller session is not blocked waiting for completion
- **AND** findings are not automatically fixed

#### Scenario: Review with extra notes

- **WHEN** the user runs `/opsx-run add-auth review "focus on error handling"`
- **THEN** the extra text is passed verbatim to ops-reviewer as focus notes

### Requirement: applier handles review findings

The ops-applier subagent SHALL fix ops-reviewer findings by id (`F1`, `F2`, …) when instructed by the dispatcher, in the same `opsx/<change>` worktree, without reopening unrelated `tasks.md` work.

#### Scenario: Review fix round

- **WHEN** the dispatcher sends ops-applier a list of ops-reviewer findings
- **THEN** ops-applier fixes only those findings
- **AND** reports which finding ids were addressed

