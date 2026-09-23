# eval-suite Specification

## Purpose
TBD - created by archiving change add-ops-eval. Update Purpose after archive.
## Requirements
### Requirement: Suite layout
Checks SHALL live in `evals/<capability>/<scenario-slug>.check`, where `<capability>` matches an `openspec/specs/` or delta-spec capability name and `<scenario-slug>` is the kebab-case scenario title. Per-repo configuration SHALL live in `evals/eval.yaml`.

#### Scenario: Suite survives archive
- **WHEN** a change with checks is archived
- **THEN** its checks remain in `evals/<capability>/` and still run with `opsx-eval.sh --all`

### Requirement: Check contract
A check SHALL be an executable file in any language with header comments `# scenario: <capability> / <Scenario title>` and `# level: L1|L2|L3`. Exit code `0` SHALL mean PASS, `77` UNVERIFIABLE, and any other code or a timeout FAIL. Its stdout and stderr SHALL be captured as evidence. The runner SHALL provide `EVAL_ROOT` and a fresh `EVAL_TMP` per check, plus any `env` from `eval.yaml`.

#### Scenario: Exit codes mapped
- **WHEN** three checks exit with 0, 77 and 3
- **THEN** the scorecard shows PASS, UNVERIFIABLE and FAIL respectively

#### Scenario: Timeout
- **WHEN** a check runs longer than the configured timeout
- **THEN** it is killed and reported as FAIL with a timeout note

### Requirement: Per-repo configuration
`evals/eval.yaml` SHALL support optional `setup`, `teardown`, `env`, `timeout` (default 60 seconds) and `agentic` (`trials`, `threshold`, `cli`). `setup` SHALL run once before checks and `teardown` SHALL always run afterwards, even when checks fail. If `evals/` exists but `eval.yaml` does not, defaults SHALL apply.

#### Scenario: Teardown after failure
- **WHEN** a check fails and `teardown` is configured
- **THEN** teardown still runs before the runner exits

### Requirement: Levels
L1 and L2 checks SHALL always run. L3 checks SHALL run only with `--agentic`, each repeated `trials` times, and SHALL PASS only when the pass count reaches `threshold`; the scorecard SHALL show the pass rate. Without `--agentic`, L3 checks SHALL be reported as NOT RUN and SHALL NOT affect the exit code.

#### Scenario: L3 skipped by default
- **WHEN** `opsx-eval.sh --all` runs and the suite contains an L3 check
- **THEN** that check is reported NOT RUN and is not executed

#### Scenario: L3 pass rate
- **WHEN** `opsx-eval.sh --all --agentic --trials 5` runs an L3 check that passes 4 of 5 trials with threshold 5
- **THEN** it is reported FAIL with pass rate 4/5

### Requirement: Runner
`opsx-eval.sh` SHALL run without any LLM and accept `--change <c>`, `--capability <cap>` (repeatable), `--all` (default), `--agentic`, `--trials N`, `--json` and `--root <dir>`. It SHALL exit 0 when no check failed, 1 when any check failed, and 2 on a configuration or runner error.

#### Scenario: Scoped to a change
- **WHEN** `opsx-eval.sh --change add-auth` runs and the change has delta specs for `auth`
- **THEN** only checks in `evals/auth/` run

#### Scenario: Deterministic rerun
- **WHEN** the same suite runs twice on the same tree with only L1 checks
- **THEN** both runs produce the same results

### Requirement: Coverage report
With `--change <c>`, the runner SHALL list every scenario in the change's delta specs that has no matching check as MISSING. The scorecard SHALL show totals for PASS, FAIL, UNVERIFIABLE, NOT RUN and MISSING, and each result's scenario name and truncated evidence. `--json` SHALL include full evidence.

#### Scenario: Missing check
- **WHEN** a change's delta spec has a scenario with no check file
- **THEN** the scorecard lists it as MISSING

### Requirement: Regression comparison
The runner SHALL support comparing two runs (a baseline and a current result in JSON) and SHALL report as REGRESSION every check that passed in the baseline and fails in the current run.

#### Scenario: Regression detected
- **WHEN** check `auth/login-ok` passed on the baseline and fails on the current tree
- **THEN** it is reported as REGRESSION

