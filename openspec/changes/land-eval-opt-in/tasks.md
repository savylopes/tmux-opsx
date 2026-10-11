# Tasks

## 1. opsx-land.sh: gate off by default, `--eval` opt-in

- [x] 1.1 In `skills/opsx-run/opsx-land.sh`, replace `SKIP_EVAL` with `RUN_EVAL=0`, add `--eval` (sets `RUN_EVAL=1`) to the option parser and to the usage header (describe `--skip-eval` there as "accepted, no-op: the gate is off by default"), and keep `--skip-eval` parsing into `SKIP_EVAL_NOTE=1`; verify `opsx-land.sh --help` lists both flags and `bash -n` plus shellcheck are clean
- [x] 1.2 Rewrite the `Eval gate` branch: when `RUN_EVAL=0` and neither `$TARGET:evals` nor `$BRANCH:evals` exists stay silent; when `RUN_EVAL=0` and `evals/` exists print the `Eval gate` step with the off line naming `--eval` (plus the `--skip-eval` no-op note only when `SKIP_EVAL_NOTE=1` and `RUN_EVAL=0`); when `RUN_EVAL=1` run today's chain unchanged (`--skip-merge` skip, missing runner warn, `--dry-run` would-run line, else baseline + merged run); verify in a scratch repo with `evals/` that plain land prints the off line and does not create an `opsx-land-eval.*` temp dir, and `land --eval` does run `opsx-eval.sh`
- [x] 1.3 Update the `ALREADY_MERGED` re-run hint to append `--eval` when `RUN_EVAL=1` and never append `--skip-eval`; verify by landing an already-merged branch in a scratch repo with and without `--eval` and reading the printed command
- [x] 1.4 Update `tests/test-eval.sh` land cases: add `--eval` to cases 1 (regression blocks), 2 (new failure warns) and 5 (L3 not run); change case 4 to assert `--skip-eval` prints the no-op note, the planted regression does not block and the change is archived; add a case where plain land with a planted regression prints the off line, lands and archives; add a case where `--dry-run` without `--eval` prints the off line and `--dry-run --eval` prints the `would run:` line, both leaving `main` and `openspec/changes/chg` untouched; keep `land: no evals/ skips silently` unchanged; verify `bash tests/test-eval.sh` passes with no FAIL lines

## 2. Docs

- [x] 2.1 Update `skills/opsx-run/SKILL.md`: usage block (`land --eval` runs the eval regression gate; `--skip-eval` accepted, no-op), the `land` action row, the `opsx-land.sh` synopsis and the "Eval regression gate" bullet (off by default, `--eval` turns it on, `--skip-eval` no-op, say so when relaying); verify by grepping the file for `--skip-eval` and `eval gate` and reading every hit
- [x] 2.2 Update `README.md`: the components table row for `opsx-land.sh`, the `/opsx-run <change> land --skip-eval` row (now `--eval`), the `opsx-land.sh` synopsis, the "Eval regression gate" paragraph, the "Other flags" sentence and the `tests/test-eval.sh` paragraph (default-off and `--skip-eval` no-op cases); verify by grepping `README.md` for `--skip-eval`, `eval gate` and `regression gate` and reading every hit
- [x] 2.3 Grep `agents/` and the other `skills/*/SKILL.md` for `--skip-eval`, `eval gate` and `regression gate` and fix any text that still says land runs the gate by default; verify the grep shows only the intended wording

## 3. Integration

- [ ] 3.1 Run `bash tests/test-eval.sh` and `~/.claude/skills/opsx-run/opsx-eval.sh --change land-eval-opt-in --json` from the worktree after ops-eval has written its checks (expect MISSING only for scenarios ops-eval has not yet covered); then `opsx-land.sh land-eval-opt-in --dry-run` from the worktree's main checkout and confirm the output shows the off line and no eval run; record results in this file

## Workflow follow-up

- Land with `/opsx-run land-eval-opt-in land` (no `--eval`), which itself demonstrates the new default; the installed copy is refreshed by `install.sh` during the land.
