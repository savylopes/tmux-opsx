# opsx-validate-pipeline Specification

## Purpose
TBD - created by archiving change add-ops-reviewer-security. Update Purpose after archive.
## Requirements
### Requirement: validate loop includes review and security gates

When the user runs `/opsx-run <change> apply --validate`, the change window dispatcher SHALL run gates in order: ops-applier (apply), ops-reviewer, ops-security, ops-qa. Each gate MUST reach `VERDICT: PASS` or `VERDICT: SKIP` before advancing to the next gate.

#### Scenario: Full validate success path

- **WHEN** apply completes successfully
- **AND** ops-reviewer returns PASS or SKIP
- **AND** ops-security returns PASS or SKIP
- **AND** ops-qa returns PASS or SKIP
- **THEN** the dispatcher marks the change window done and completes the validate goal

### Requirement: validate loop retries failed gates via applier

When ops-reviewer, ops-security, or ops-qa returns `VERDICT: FAIL`, the dispatcher SHALL delegate to ops-applier to fix that gate's findings verbatim (preserving F1, F2, …), then re-run only that gate before proceeding.

#### Scenario: Review fails then passes

- **WHEN** ops-reviewer returns FAIL with findings F1 and F2
- **THEN** the dispatcher delegates ops-applier to fix F1 and F2
- **AND** re-runs ops-reviewer
- **AND** does not run ops-security or ops-qa until review returns PASS or SKIP

#### Scenario: Security fails after review passes

- **WHEN** ops-reviewer returns PASS
- **AND** ops-security returns FAIL
- **THEN** the dispatcher delegates ops-applier to fix security findings
- **AND** re-runs ops-security only
- **AND** does not re-run ops-reviewer unless a new apply phase is started

### Requirement: validate goal includes all gates

The `apply --validate` window goal SHALL require ops-reviewer and ops-security to reach PASS or SKIP with no leftover P0/P1 findings, in addition to the existing ops-qa requirement.

#### Scenario: Goal text reflects new gates

- **WHEN** the validate dispatcher prompt is sent to the change window
- **THEN** the goal mentions review and security PASS or SKIP in addition to qa

### Requirement: land is not gated by review or security

The `/opsx-run <change> land` action SHALL NOT require ops-reviewer or ops-security to have passed. It SHALL retain existing OpenSpec validate and tasks.md completion gates only.

#### Scenario: Land without review

- **WHEN** the user runs `/opsx-run add-auth land`
- **AND** `openspec validate` passes and tasks are complete
- **AND** no review or security run was ever executed
- **THEN** land proceeds according to existing merge/archive behavior

### Requirement: plain apply unchanged

The `/opsx-run <change> apply` action without `--validate` SHALL NOT run ops-reviewer or ops-security.

#### Scenario: Apply only

- **WHEN** the user runs `/opsx-run add-auth apply`
- **THEN** only ops-applier is dispatched
- **AND** neither ops-reviewer nor ops-security runs

### Requirement: validate dispatcher uses subagent delegation on supported CLIs

On Claude Code, Cursor CLI, and OpenCode, the validate dispatcher SHALL delegate review and security to subagents (`ops-reviewer`, `ops-security`) and SHALL NOT perform review or security analysis in the dispatcher window itself. On Codex CLI and Gemini CLI, the dispatcher window SHALL perform review and security inline in the worktree, consistent with existing applier/qa behavior.

#### Scenario: Cursor validate delegates review

- **WHEN** validate runs in a Cursor CLI change window
- **THEN** implementation review is performed via Task `subagent_type: "ops-reviewer"`
- **AND** security review is performed via Task `subagent_type: "ops-security"`

