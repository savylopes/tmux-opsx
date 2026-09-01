## ADDED Requirements

### Requirement: ops-security subagent exists and is installable

The system SHALL provide an `ops-security` subagent definition at `agents/opsx-security.md` and install it to the same agent paths as `ops-applier` and `ops-qa` for Claude Code, Cursor CLI, Codex CLI, OpenCode, and Gemini CLI via `install.sh`.

#### Scenario: Install copies security agent

- **WHEN** the user runs `./install.sh`
- **THEN** `ops-security` agent files are present in each supported CLI's global agents directory
- **AND** `opsx-window.sh ensure` symlinks the security agent into project `.cursor/agents/` and `.gemini/agents/` when applicable

### Requirement: ops-security is read-only

The ops-security subagent SHALL NOT edit product code, commit, or tick `tasks.md`. It SHALL only analyze the change for security issues and report findings.

#### Scenario: Security reviewer reports without fixing

- **WHEN** ops-security finds a vulnerability pattern in the diff
- **THEN** it returns a FAIL verdict with numbered findings
- **AND** it does not apply remediations itself

### Requirement: ops-security performs security-focused review

The ops-security subagent SHALL review the `opsx/<change>` branch diff for security concerns including authentication and authorization flaws, injection risks, exposure of secrets or credentials, unsafe defaults, missing input validation on trust boundaries, and risky dependency usage introduced by the change.

#### Scenario: Secret in diff

- **WHEN** the change introduces a hardcoded API key or password in source
- **THEN** ops-security returns `VERDICT: FAIL` with a P0 finding identifying the file and line

#### Scenario: Auth bypass pattern

- **WHEN** the change adds or modifies an endpoint without matching authorization checks described in design
- **THEN** ops-security returns `VERDICT: FAIL` with a P1 finding describing the gap

### Requirement: ops-security uses structured verdict output

The ops-security subagent SHALL end every run with the same parseable verdict block format as ops-qa and ops-reviewer: `VERDICT`, `CHANGE`, `FINDINGS` with `F1`, `F2`, …, and `SUMMARY`.

#### Scenario: Pass with no security issues

- **WHEN** no P0 or P1 security findings exist
- **THEN** ops-security returns `VERDICT: PASS`

### Requirement: ops-security supports SKIP

The ops-security subagent SHALL return `VERDICT: SKIP` with a one-line reason when the change has no security-relevant surface (e.g. pure documentation, comment-only, or formatting-only diffs with no trust-boundary impact).

#### Scenario: README typo fix

- **WHEN** the change diff only fixes a typo in README with no code or config logic changes
- **THEN** ops-security returns `VERDICT: SKIP` with a reason

### Requirement: security action dispatches ops-security once

The `/opsx-run <change> security` action SHALL create or reuse the change tmux window and dispatch ops-security exactly once. It SHALL NOT auto-spawn ops-applier to fix findings.

#### Scenario: Standalone security review

- **WHEN** the user runs `/opsx-run add-auth security`
- **THEN** the change window runs ops-security once
- **AND** the caller session is not blocked waiting for completion
- **AND** findings are not automatically fixed

#### Scenario: Security with extra notes

- **WHEN** the user runs `/opsx-run add-auth security "check JWT handling"`
- **THEN** the extra text is passed verbatim to ops-security as focus notes

### Requirement: applier handles security findings

The ops-applier subagent SHALL fix ops-security findings by id when instructed by the dispatcher, in the same `opsx/<change>` worktree, without reopening unrelated tasks.

#### Scenario: Security fix round

- **WHEN** the dispatcher sends ops-applier ops-security findings
- **THEN** ops-applier fixes only those findings
- **AND** reports which finding ids were addressed
