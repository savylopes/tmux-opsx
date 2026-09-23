## Context

Gates today (`agents/opsx-*.md`): ops-reviewer (reads proposal, design, tasks and diff; runs existing tests; SKIPs markdown-only diffs), ops-security (reads diff), ops-qa (browser, SKIPs non-UI). Scenarios in `specs/*/spec.md` are not read by any gate. `apply --validate` loops apply → review → security → qa in the change window; `land` is gated only by `openspec validate` and tasks.md.

tmux-opsx is used across the user's repositories, so the eval design must not assume bash, tmux or any language — only OpenSpec specs.

## Goals / Non-Goals

**Goals:**
- Every scenario in a change maps to an executable check with evidence.
- Checks persist and run without an LLM, giving a real regression suite.
- Works in any repo using tmux-opsx; product-specific setup lives in that repo.
- The implementer cannot weaken the checks.

**Non-Goals:**
- Replacing ops-reviewer (kept unchanged) or ops-qa.
- Evaluating markdown-only changes (SKIP, by user decision).
- Running in repos without OpenSpec specs.
- CI integration beyond the runner being CI-friendly.

## Decisions

### 1. Two parts: an agent that writes and judges, a script that runs

```
 ops-eval (LLM)                          opsx-eval.sh (no LLM)
 ─────────────                           ─────────────────────
 read change delta specs + eval.yaml     run *.check in scope
 diff scenarios ↔ existing checks        eval.yaml setup/teardown
 write / update / delete checks          collect exit codes + stdout
 run opsx-eval.sh ─────────────────────▶ coverage + scorecard (text/json)
 judge each FAIL  ◀──────────────────────
 commit evals/ on the change branch
 VERDICT + FINDINGS keyed by scenario
```

The runner is the source of truth for results; the agent never reports a PASS the runner did not produce.

### 2. Suite layout mirrors capabilities

```
evals/
├── eval.yaml
└── <capability>/                 # same name as openspec/specs/<capability>/
    └── <scenario-slug>.check     # slug of the scenario title
```

Checks live with capabilities, not changes, so they survive archive. A change's delta for capability X adds/updates/removes files in `evals/X/`.

### 3. Check contract

```
#!/usr/bin/env <any>
# scenario: <capability> / <Scenario title exactly as in spec>
# level: L1 | L2 | L3
# requirement: <Requirement title>          (optional)
```

- exit `0` → PASS, `77` → UNVERIFIABLE, anything else → FAIL (timeout counts as FAIL)
- stdout/stderr → evidence, truncated in the scorecard, full text in the JSON output
- environment from the runner: `EVAL_ROOT` (repo root), `EVAL_TMP` (fresh temp dir per check), plus `eval.yaml` `env`
- checks must be side-effect free outside `EVAL_TMP` and whatever `setup` provisions

Language-agnostic by design: bash here, `npx vitest -t …`, `pytest -k …` or `curl` elsewhere.

### 4. `evals/eval.yaml`

```yaml
setup: ./evals/setup.sh        # optional, run once before checks; exports via $EVAL_ENV_FILE
teardown: ./evals/teardown.sh  # optional, always run
env: { KEY: value }            # optional
timeout: 60                    # seconds per check, default 60
agentic:
  trials: 3                    # L3 default trials
  cli: claude                  # headless CLI for L3 (claude -p, codex exec, …)
```

For this repo `setup` provides a scratch `HOME` and a private tmux socket (`tmux -L eval-$$`) so L2 checks never touch the user's session. If a repo has specs but no `eval.yaml`, ops-eval creates a minimal one and flags it in its report for the user to review.

### 5. Levels

| Level | What | Runs |
|---|---|---|
| L1 | script/API contracts, pure commands | always |
| L2 | environment behaviour (tmux, filesystem, services from `setup`) | always |
| L3 | an agent CLI following a skill/prompt, run headless | only `--agentic`; N trials; result = pass rate; PASS needs ≥ `threshold` (default all trials) |

Without `--agentic`, L3 checks are reported as `NOT RUN` and do not affect the verdict.

### 6. Blind generation

ops-eval derives **expected results only from specs**. It may read `design.md`, usage/`--help` output and public entry points to learn *how to invoke* the product, but not the applier's report, commit messages or the applier's own tests. The dispatcher does not pass the applier's output to ops-eval.

### 7. Ownership of `evals/`

- ops-eval is the only agent that writes under `evals/`; it commits those files on the change branch in a separate commit (`eval: <change>`). It never edits product code or tasks.md.
- ops-applier's rules gain: never modify `evals/`; if a finding looks like a broken check, fix nothing for it and report `DISPUTE <id>: <reason>`.
- On the next eval round, the dispatcher passes disputes to ops-eval, which re-checks the scenario text and either fixes the check (and says so) or keeps it with a justification.

### 8. Judging failures

For each FAIL, ops-eval reads the evidence and decides:
- **defect** → finding `[P0|P1] <capability>/<scenario-slug>: …` (P0 when a requirement's core behaviour fails, P1 otherwise);
- **broken check** → fixes the check, re-runs, and notes it in the report;
- UNVERIFIABLE results are listed as P2 (do not fail the gate) with what would be needed to verify them.

MISSING coverage (a scenario in the change with no check after generation) is a P1 on ops-eval's own output — it must write the check or mark it UNVERIFIABLE with a reason.

### 9. SKIP rules

`VERDICT: SKIP` with a one-line reason when:
- the repo has no `openspec/specs/` and the change has no delta specs; or
- the change's delta specs contain no scenarios; or
- the change diff is markdown-only (same rule as ops-reviewer).

In SKIP, no checks are written or run for that change.

### 10. Pipeline

```
apply --validate:  apply → eval → review → security → qa
                     eval FAIL → applier fixes (never evals/) → eval again
/opsx-run <c> eval [--agentic]   one-shot, no auto-fix
land:              opsx-eval.sh on target  → baseline
                   opsx-eval.sh on merged  → current
                   baseline PASS & current FAIL → BLOCK (regression)
                   other FAIL / UNVERIFIABLE / MISSING → warn only
                   no evals/ dir → skip silently
```

The regression baseline is computed by running the suite on the target branch, not stored — no result files to keep in sync. `land --skip-eval` bypasses it explicitly. L3 never runs during land.

### 11. Runner interface

```
opsx-eval.sh [--change <c>] [--capability <cap>]... [--all]
             [--agentic] [--trials N] [--json] [--root <dir>]
```

- `--change <c>`: checks for capabilities touched by that change's delta specs, plus coverage against its scenarios
- `--all` (default when no scope): every check in `evals/`
- exit 0 if no FAIL, 1 if any FAIL, 2 on runner/config error
- human scorecard to stdout; `--json` for machine use (used by `land` and ops-eval)

### 12. Placement and install

- `agents/opsx-eval.md` installed exactly like the other ops agents (Claude, Cursor, Codex toml, OpenCode, Gemini), and linked into project dirs by `opsx-window.sh ensure`.
- `opsx-eval.sh` lives in `skills/opsx-run/` and is installed with that skill.

## Risks / Trade-offs

- **LLM-written checks can be wrong** → judging step, disputes, and checks are reviewable plain files in git.
- **Slow suites at land** → two runs (target + merged); L3 never runs at land; `timeout` per check; `--skip-eval` escape hatch.
- **Flaky L2 checks** (tmux timing) → contract encourages polling with timeouts over sleeps; flakiness shows up as regression only if it passed on target and fails on merged, which is still a signal worth a look.
- **Markdown-only changes are unchecked** → accepted by user decision; `--agentic` can still be run explicitly.
- **Target-branch baseline needs a clean checkout** → runner uses a temporary worktree of the target, removed afterwards.

## Open Questions


- Default L3 pass threshold: all trials, or a majority?
- Should ops-eval also back-fill checks for existing capabilities when it first runs in a repo, or only for scenarios in the current change? (Proposal: only the current change; a separate `eval --backfill` later.)
