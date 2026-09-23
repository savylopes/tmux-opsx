## 1. Runner (opsx-eval.sh)

- [ ] 1.1 Create `skills/opsx-run/opsx-eval.sh` with option parsing (`--change`, `--capability`, `--all`, `--agentic`, `--trials`, `--json`, `--root`) and exit codes 0/1/2
- [ ] 1.2 Parse `evals/eval.yaml` (setup, teardown, env, timeout, agentic.trials/threshold/cli) with defaults when missing; keep dependencies to bash + standard tools
- [ ] 1.3 Discover checks, read headers (scenario, level), resolve scope from `--change` delta specs or `--capability`
- [ ] 1.4 Run each check with `EVAL_ROOT`, fresh `EVAL_TMP`, env and timeout; map exit codes 0/77/other; capture evidence
- [ ] 1.5 L3 handling: NOT RUN without `--agentic`; with it, N trials and threshold → pass rate
- [ ] 1.6 Coverage: parse `#### Scenario` titles from the change's delta specs, report MISSING
- [ ] 1.7 Output: human scorecard with totals; `--json` with full evidence
- [ ] 1.8 Regression mode: compare baseline and current JSON, report REGRESSION entries
- [ ] 1.9 Always run teardown (trap), including on failure and interrupt

## 2. ops-eval agent

- [ ] 2.1 Create `agents/opsx-eval.md` (persona, inputs, blind-generation rules, allowed reads)
- [ ] 2.2 Document the check contract, slug rule, layout, and how to create/update/delete checks from delta specs
- [ ] 2.3 Document creating a minimal `eval.yaml` when missing and flagging it for review
- [ ] 2.4 Document judging (defect vs broken check), dispute handling, UNVERIFIABLE/MISSING severities
- [ ] 2.5 Document SKIP rules (no specs, no scenarios, markdown-only diff) and the separate `eval: <change>` commit touching only `evals/`
- [ ] 2.6 Document the required verdict block

## 3. Applier rules

- [ ] 3.1 Update `agents/opsx-applier.md`: never modify `evals/`; report `DISPUTE <id>: <reason>` for suspected broken checks

## 4. /opsx-run integration

- [ ] 4.1 `skills/opsx-run/SKILL.md`: add `eval` / `eval --agentic` action, `/opsx-run eval` change picking, and the eval window prompt template (no applier report passed)
- [ ] 4.2 Add an **eval-fix** prompt template that forwards findings verbatim and forbids touching `evals/`
- [ ] 4.3 Update the **validate** template: apply → eval → review → security → qa, disputes forwarded to the next eval, goal text includes eval
- [ ] 4.4 Update the host table (Claude/Cursor/OpenCode subagent `ops-eval`; Codex/Gemini inline)
- [ ] 4.5 `opsx-window.sh ensure`: link the eval agent into project `.cursor/agents/`, `.gemini/agents/`, `.opencode/agents/` like the other ops agents

## 5. land regression gate

- [ ] 5.1 `opsx-land.sh`: when `evals/` exists, run `opsx-eval.sh --all --json` on the target in a temporary worktree (baseline), then on the merged tree (current)
- [ ] 5.2 Block on REGRESSION before archive, restoring the target branch to its pre-merge state; warn on other failures/UNVERIFIABLE/MISSING
- [ ] 5.3 Add `--skip-eval`; skip silently when there is no `evals/`; never run L3 during land

## 6. install.sh

- [ ] 6.1 Install `ops-eval` to all agent locations (Claude, Cursor, Codex toml conversion, OpenCode, Gemini) following the ops-reviewer pattern; add it to the header comment and source checks
- [ ] 6.2 Install `opsx-eval.sh` with the `opsx-run` skill (executable)
- [ ] 6.3 Remove `ops-eval` files on `--uninstall`

## 7. This repo's suite (dogfood)

- [ ] 7.1 Add `evals/eval.yaml` for this repo: setup with scratch `HOME` and private tmux socket, teardown killing that tmux server
- [ ] 7.2 Run ops-eval on this change itself to generate checks for the `eval-suite` scenarios (L1) and review them

## 8. Docs and verification

- [ ] 8.1 README: Gates section entry for ops-eval, `evals/` layout, check contract, levels, `eval` action, land regression gate, `--skip-eval`
- [ ] 8.2 `bash -n` and `shellcheck` on `opsx-eval.sh`, `opsx-land.sh`, `install.sh`
- [ ] 8.3 Runner tests with a fixture suite: exit-code mapping, timeout, teardown on failure, L3 NOT RUN, `--agentic` pass rate, MISSING, `--json`, regression compare
- [ ] 8.4 Land tests in a scratch repo: regression blocks and restores target, new failure warns, no `evals/` skips, `--skip-eval`
- [ ] 8.5 Scratch `HOME` install test: fresh, re-run, `--uninstall` for the eval agent and runner
