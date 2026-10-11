# Design

## Context

See proposal.md - Why. `opsx-land.sh` decides in one `if/elif` chain (around the `Eval gate` step) whether to run `opsx-eval.sh`: `--skip-eval` first, then "no `evals/` on either side" (silent), then `--skip-merge`, then a missing runner, then `--dry-run`, else run. The `ALREADY_MERGED` hint rebuilds the command line flag by flag. `tests/test-eval.sh` drives land in scratch repos with a fake `openspec` and expects the gate to run by default. The eval checks under `evals/opsx-validate-pipeline/` call land through `evals/_lib/land.sh` and are written only by ops-eval.

The repo copy `skills/opsx-run/opsx-land.sh` and the installed `~/.claude/skills/opsx-run/opsx-land.sh` are identical today; `install.sh` copies the former over the latter.

## Goals / Non-Goals

**Goals:**
- Landing is fast by default: no eval run unless asked.
- The gate's behavior, when asked for, is byte-for-byte what it is today, so the existing regression and warn tests keep their meaning.
- A skipped gate is visible in the output when there is something it could have run.
- Nothing that passes `--skip-eval` today breaks.

**Non-Goals:**
- Making the suite faster (the dev-container PATH mirror) - separate change.
- Caching baselines per target commit - separate change if ever wanted.
- A per-repo config knob (eval.yaml or openspec/config.yaml) to flip the default back on. One flag is enough for a single-user harness; add a knob only if the flag gets tedious.
- Changing `/opsx-run` prompt handling: the skill already forwards arbitrary land flags to `opsx-land.sh`.

## Decisions

- **Opt-in flag is `--eval`.** Alternatives: `--with-eval`, `--eval-gate`, `--check`. `--eval` is the shortest, mirrors the existing `/opsx-run <change> eval` action name, and reads naturally in `land --eval`. It carries no value.
- **`--skip-eval` stays, as a no-op with a note.** Alternatives: remove it (breaks the SKILL.md examples, user muscle memory and any prompt that still says it); accept it silently (hides that the flag no longer does anything). Printing `skip "eval gate is off by default; --skip-eval is a no-op"` under the `Eval gate` step is the middle ground. `--skip-eval --eval` together: `--eval` wins and the note is not printed, because the user asked for the gate explicitly. Keep this rule simple rather than erroring.
- **Default-off is visible only when `evals/` exists.** When neither side has `evals/`, keep today's silence (the "Land without review" scenario and `land: no evals/ skips silently` test assert no `eval` word in the output). When `evals/` exists and `--eval` is absent, print `step "Eval gate"; skip "eval gate off (pass --eval to run the regression gate)"`. The branch order becomes: `--eval` absent -> (no evals: silent | evals: one skip line) ; `--eval` present -> existing chain minus the `--skip-eval` arm.
- **`--dry-run` honours the same branch.** Without `--eval` it prints the off line; with `--eval` it prints the existing `would run:` line. No new wording beyond the off line.
- **Re-run hint.** Replace the `SKIP_EVAL` propagation with `RUN_EVAL` so `opsx-land.sh <change> --skip-merge ... --eval` is suggested when the user had asked for the gate. `--skip-eval` is not propagated (it does nothing).
- **Internal variable.** Rename `SKIP_EVAL` to `RUN_EVAL` (0 default) so the meaning is not inverted in the reader's head; keep `--skip-eval` setting a separate `SKIP_EVAL_NOTE=1` only used for the note.
- **Tests.** Existing land cases 1, 2 and 5 in `tests/test-eval.sh` add `--eval`. Case 4 (`--skip-eval`) now asserts the no-op note and that the regression did not block. Two new cases: default without `--eval` lands despite a planted regression and prints the off line; `--dry-run` with and without `--eval` prints the right line and changes nothing. The `land: no evals/ skips silently` case stays as is.
- **Evals.** The checks `eval-regression-blocks-land`, `new-failure-only-warns` and `skip-eval` plus the new `eval-gate-off-by-default` and `dry-run-shows-the-gate-state` are ops-eval's to write or update; the applier only changes product code, tests and docs. `evals/_lib/land.sh`'s `run_land` already forwards extra arguments, so `run_land --eval` needs no helper change.

## Risks / Trade-offs

- [A real regression slips into main because nobody passed `--eval`] -> the ops-eval run in the change window still covers the change's own scenarios on every validate; the user can run `/opsx-run <change> land --eval` for risky merges, and `opsx-eval.sh --all` on main at any time.
- [Prompts or notes elsewhere still say "land runs the eval gate"] -> grep `skills/`, `agents/` and `README.md` for `eval gate`, `regression gate`, `--skip-eval` and update every hit in the docs task.
- [Installed copy and repo copy diverge during the change] -> the applier works in the worktree only; `install.sh` on land brings the installed copy up to date, as for every skill change.
- [The `land-without-preview` eval check compares base land vs new land] -> both are run without flags, so both now skip the gate; the comparison stays like-for-like. If the check's base checkout is older than this change, base would run the gate and new would not, differing only in the eval lines; the check compares repo state, not output, so it is unaffected.
