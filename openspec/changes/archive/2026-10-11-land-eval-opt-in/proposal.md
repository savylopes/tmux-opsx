# Proposal

## Why

`opsx-land.sh` runs the whole eval suite twice (baseline on the target, then on the merged result) whenever `evals/` exists. In this repo that is 185 checks per run and 20 to 25 minutes per land, even when the target has not moved since the branch was cut and ops-eval already ran the change's own checks in its window. The gate costs far more time than the regressions it catches, so it should be something the user asks for, not something every land pays.

## What Changes

- **BREAKING** (behavioral): the eval regression gate in `opsx-land.sh` is **off by default**. Land no longer runs `opsx-eval.sh` unless asked.
- New flag `opsx-land.sh <change> --eval` turns the gate on; its behavior when enabled is unchanged (baseline on the target, run on the merged result, block on a PASS to FAIL regression, warn on everything else, L1 and L2 only).
- `--skip-eval` stays accepted so existing prompts and habits keep working. It is now a no-op that prints one note saying the gate is already off.
- Land prints one `Eval gate` line when `evals/` exists and the gate is off, naming `--eval`, so a skipped gate is visible rather than silent.
- `--dry-run` reflects the new default: it says the gate would not run unless `--eval` is passed, and with `--eval` keeps printing what it would run.
- The `ALREADY_MERGED` re-run hint propagates `--eval` the way it propagates the other flags.
- `/opsx-run <change> land --eval` is documented in `skills/opsx-run/SKILL.md` and `README.md`; the `--skip-eval` entries are reworded as compatibility aliases.
- `tests/test-eval.sh` land cases pass `--eval` where they exercise the gate, and gain a case for the new default and one for `--skip-eval` as a no-op.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `opsx-validate-pipeline`: the requirement "land is not gated by review or security" changes from "land SHALL run the eval gate when `evals/` exists, `--skip-eval` bypasses it" to "land SHALL NOT run the eval gate unless `--eval` is passed; `--skip-eval` is an accepted no-op". The "Skip eval" scenario becomes the default-off scenario; the regression and new-failure scenarios gain `--eval` in their WHEN.

## Impact

- `skills/opsx-run/opsx-land.sh`: option parsing, the eval gate branch, the dry-run text, the `ALREADY_MERGED` re-run hint.
- `skills/opsx-run/SKILL.md` and `README.md`: land usage lines, the land action row, the eval regression gate paragraphs, the tests paragraph.
- `tests/test-eval.sh`: land gate cases.
- `evals/opsx-validate-pipeline/*.check` (`eval-regression-blocks-land`, `new-failure-only-warns`, `skip-eval`) and `evals/_lib/land.sh` are owned by ops-eval and will need `--eval` and a new default-off check; they are not edited by the applier.
- `evals/opsx-preview/land-without-preview.check` compares a base land against the new land in the same repo; it is unaffected by the default as long as both sides are run the same way.
- `install.sh` copies the script and skill text as before; no new files.
- No change to `opsx-eval.sh`, `opsx-merge.sh` or the ops-eval agent. Speeding up the dev-container eval helper is a separate change.
