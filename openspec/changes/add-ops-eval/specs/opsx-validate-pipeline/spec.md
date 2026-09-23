## MODIFIED Requirements

### Requirement: validate loop includes review and security gates

When the user runs `/opsx-run <change> apply --validate`, the change window dispatcher SHALL run gates in order: ops-applier (apply), ops-eval, ops-reviewer, ops-security, ops-qa. Each gate MUST reach `VERDICT: PASS` or `VERDICT: SKIP` before advancing to the next gate.

#### Scenario: Full validate success path

- **WHEN** apply completes successfully
- **AND** ops-eval returns PASS or SKIP
- **AND** ops-reviewer returns PASS or SKIP
- **AND** ops-security returns PASS or SKIP
- **AND** ops-qa returns PASS or SKIP
- **THEN** the dispatcher marks the change window done and completes the validate goal

#### Scenario: Eval runs before review

- **WHEN** apply completes successfully
- **THEN** ops-eval runs before ops-reviewer

### Requirement: validate loop retries failed gates via applier

When ops-eval, ops-reviewer, ops-security, or ops-qa returns `VERDICT: FAIL`, the dispatcher SHALL delegate to ops-applier to fix that gate's findings verbatim (preserving F1, F2, …), then re-run only that gate before proceeding. When fixing eval findings, ops-applier SHALL NOT modify `evals/`, and any `DISPUTE` lines it reports SHALL be passed to the next ops-eval run.

#### Scenario: Eval fails then passes

- **WHEN** ops-eval returns FAIL with findings F1 and F2
- **THEN** the dispatcher delegates ops-applier to fix F1 and F2 without touching `evals/`
- **AND** re-runs ops-eval with any disputes the applier reported
- **AND** does not run ops-reviewer until eval returns PASS or SKIP

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

The `apply --validate` window goal SHALL require ops-eval, ops-reviewer and ops-security to reach PASS or SKIP with no leftover P0/P1 findings, in addition to the existing ops-qa requirement.

#### Scenario: Goal text reflects new gates

- **WHEN** the validate dispatcher prompt is sent to the change window
- **THEN** the goal mentions eval, review and security PASS or SKIP in addition to qa

### Requirement: land is not gated by review or security

The `/opsx-run <change> land` action SHALL NOT require ops-reviewer, ops-security or ops-eval to have passed. It SHALL retain existing OpenSpec validate and tasks.md completion gates. When the repo has an `evals/` directory, land SHALL run `opsx-eval.sh` (L1 and L2 only) on the target branch and on the merged result, SHALL block when any check that passed on the target fails on the merged result, and SHALL only warn about other failures, UNVERIFIABLE or MISSING results. `land --skip-eval` SHALL bypass the eval run.

#### Scenario: Land without review

- **WHEN** the user runs `/opsx-run add-auth land`
- **AND** `openspec validate` passes and tasks are complete
- **AND** no review, security or eval run was ever executed
- **AND** the repo has no `evals/` directory
- **THEN** land proceeds according to existing merge/archive behavior

#### Scenario: Eval regression blocks land

- **WHEN** check `auth/login-ok` passes on `main` and fails after merging `opsx/add-auth`
- **THEN** land stops before archive, reports the regression, and leaves the target branch as it was before the merge

#### Scenario: New failure only warns

- **WHEN** a check added by the change fails on the merged result and has no baseline on `main`
- **THEN** land prints a warning and continues

#### Scenario: Skip eval

- **WHEN** the user runs `/opsx-run add-auth land --skip-eval`
- **THEN** no eval run happens and land proceeds with its other gates
