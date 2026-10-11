# Spec Delta

## MODIFIED Requirements

### Requirement: land is not gated by review or security

The `/opsx-run <change> land` action SHALL NOT require ops-reviewer, ops-security or ops-eval to have passed. It SHALL retain existing OpenSpec validate and tasks.md completion gates. Land SHALL NOT run the eval regression gate unless `--eval` is passed. With `land --eval` and an `evals/` directory on the target or the change branch, land SHALL run `opsx-eval.sh` (L1 and L2 only) on the target branch and on the merged result, SHALL block when any check that passed on the target fails on the merged result, and SHALL only warn about other failures, UNVERIFIABLE or MISSING results. `--skip-eval` SHALL remain accepted as a no-op.

#### Scenario: Land without review

- **WHEN** the user runs `/opsx-run add-auth land`
- **AND** `openspec validate` passes and tasks are complete
- **AND** no review, security or eval run was ever executed
- **AND** the repo has no `evals/` directory
- **THEN** land proceeds according to existing merge/archive behavior

#### Scenario: Eval gate off by default

- **WHEN** the user runs `/opsx-run add-auth land` without `--eval`
- **AND** the repo has an `evals/` directory in which check `auth/login-ok` passes on `main` and fails after merging `opsx/add-auth`
- **THEN** no eval run happens, land prints one line saying the eval gate is off and names `--eval`, and land proceeds with its other gates to merge and archive

#### Scenario: Eval regression blocks land

- **WHEN** the user runs `/opsx-run add-auth land --eval`
- **AND** check `auth/login-ok` passes on `main` and fails after merging `opsx/add-auth`
- **THEN** land stops before archive, reports the regression, and leaves the target branch as it was before the merge

#### Scenario: New failure only warns

- **WHEN** the user runs `/opsx-run add-auth land --eval`
- **AND** a check added by the change fails on the merged result and has no baseline on `main`
- **THEN** land prints a warning and continues

#### Scenario: Skip eval

- **WHEN** the user runs `/opsx-run add-auth land --skip-eval`
- **THEN** no eval run happens, land prints one note that the gate is already off by default, and land proceeds with its other gates

#### Scenario: Dry run shows the gate state

- **WHEN** the user runs `opsx-land.sh add-auth --dry-run` in a repo with `evals/`
- **THEN** the output says the eval gate would not run and names `--eval`
- **AND** with `--dry-run --eval` the output names the eval runner and the target it would run on, and still runs nothing
