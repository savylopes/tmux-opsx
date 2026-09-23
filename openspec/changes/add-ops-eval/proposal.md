## Why

The existing gates judge a change by reading it: ops-reviewer reads the diff against proposal, design and tasks; ops-security reads the diff; ops-qa clicks through UIs. None of them reads the spec scenarios (`#### Scenario` WHEN/THEN) — the actual acceptance criteria — and none produces evidence that each scenario holds. Many repos using tmux-opsx (this one included) also have no test suite for the reviewer to run. The user wants a real, repeatable eval as part of their development harness: every scenario becomes an executable check that stays in the repo and guards against regressions.

## What Changes

- Add an **ops-eval** agent that runs after apply and verifies **spec fidelity by execution**:
  - reads the change's delta specs (plus main specs for context) and `evals/eval.yaml`;
  - writes one executable **check** per scenario under `evals/<capability>/`, blind to the applier's reasoning and tests;
  - updates checks for modified scenarios and deletes checks for removed ones;
  - runs them through a deterministic runner and judges failures (real defect vs broken check);
  - returns `VERDICT: PASS | FAIL | SKIP` with findings keyed by scenario.
- Add a **saved eval suite** format that works in any repo using tmux-opsx:
  - `evals/eval.yaml` per repo (setup, teardown, env, timeouts);
  - `evals/<capability>/<scenario-slug>.check` executables in any language, with a header naming the scenario and level, and an exit-code contract (0 pass, 77 unverifiable, other fail); stdout is evidence.
- Add **`opsx-eval.sh`**, a runner with no LLM: runs checks, reports coverage (scenarios without a check), and prints a scorecard; usable by hand or CI.
- Levels: **L1** script contracts and **L2** environment behaviour (e.g. tmux on a private socket) always run; **L3** agent-in-the-loop checks run only with `--agentic`, repeated N trials and reported as a pass rate.
- **SKIP** when the repo has no OpenSpec specs, the change has no scenarios, or the change diff is markdown-only (same rule as ops-reviewer).
- **The applier never edits `evals/`.** It fixes product code only; if it thinks a check is wrong it reports a dispute, which ops-eval resolves on the next round.
- `/opsx-run`:
  - new one-shot action `/opsx-run <change> eval [--agentic]`;
  - `apply --validate` runs eval as the first gate: apply → eval → review → security → qa;
  - `land` runs the suite on the target branch and on the merged result: a check that passed before and now fails **blocks** the land; other failures and unverifiable checks only **warn**.
- ops-reviewer is kept unchanged.
- `install.sh` installs `ops-eval` for all five CLIs like the other ops agents, and `opsx-eval.sh` with the `opsx-run` skill.

## Capabilities

### New Capabilities

- `ops-eval`: The ops-eval agent — inputs, blind check generation, check lifecycle, judging, SKIP rules, verdict format, ownership of `evals/`, the `/opsx-run <change> eval` action, and installation.
- `eval-suite`: The on-disk suite and runner — `evals/eval.yaml`, check file contract, levels, `opsx-eval.sh` options, coverage and scorecard output, regression comparison.

### Modified Capabilities

- `opsx-validate-pipeline`: eval becomes the first gate of `apply --validate`, failed eval findings go through the applier without touching `evals/`, the goal includes eval, and `land` gains the eval regression gate.

## Impact

- **New files**: `agents/opsx-eval.md`, `skills/opsx-run/opsx-eval.sh`, `evals/eval.yaml` for this repo (scratch `HOME`, private tmux socket) and checks for this change's own scenarios
- **Modified files**: `skills/opsx-run/SKILL.md`, `skills/opsx-run/opsx-land.sh`, `skills/opsx-run/opsx-window.sh` (agent links), `agents/opsx-applier.md` (never edit `evals/`, report disputes), `install.sh`, `README.md`
- **Repos using tmux-opsx** gain an `evals/` directory, created and committed by ops-eval on the change branch
- **Behaviour change**: `apply --validate` runs one more gate; `land` can now be blocked by an eval regression
- **Depends on**: nothing; can land before or after `reposition-dev-harness` (which lists ops-eval in the README overview once shipped)
