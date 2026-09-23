## ADDED Requirements

### Requirement: ops-eval agent exists and is installable
The system SHALL provide an `ops-eval` agent definition at `agents/opsx-eval.md`, installed by `install.sh` to the same agent locations as `ops-applier`, `ops-reviewer`, `ops-security` and `ops-qa` for Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI, linked into project agent dirs by `opsx-window.sh ensure` where applicable, and removed by `install.sh --uninstall`.

#### Scenario: Install copies eval agent
- **WHEN** the user runs `./install.sh`
- **THEN** an `ops-eval` agent file is present in each supported CLI's global agents directory

#### Scenario: Uninstall removes eval agent
- **WHEN** the user runs `./install.sh --uninstall`
- **THEN** every installed `ops-eval` agent file is removed

### Requirement: Checks are generated from spec scenarios
For each `#### Scenario` in the change's delta specs, ops-eval SHALL ensure exactly one check exists at `evals/<capability>/<scenario-slug>.check` whose header names that capability and scenario. For modified scenarios it SHALL update the check; for removed scenarios or requirements it SHALL delete the matching checks.

#### Scenario: New scenario gets a check
- **WHEN** a change adds scenario "Concurrent forks" to capability `tmux-fork`
- **THEN** after ops-eval runs, `evals/tmux-fork/concurrent-forks.check` exists with header `# scenario: tmux-fork / Concurrent forks`

#### Scenario: Removed scenario loses its check
- **WHEN** a change removes a requirement whose scenarios have checks
- **THEN** ops-eval deletes those check files

### Requirement: Blind generation
ops-eval SHALL derive expected outcomes only from the spec scenarios. It MAY read `design.md`, usage output and public entry points to learn how to invoke the product. It SHALL NOT use the applier's report, commit messages or the applier's tests as a source of expected behaviour, and the dispatcher SHALL NOT pass them to it.

#### Scenario: Dispatcher prompt
- **WHEN** the dispatcher delegates to ops-eval
- **THEN** the prompt contains the change name, branch/worktree and any disputes, and does not contain the applier's report

### Requirement: ops-eval owns evals/ and nothing else
ops-eval SHALL write only under `evals/` and SHALL commit those files on the change branch in a separate commit. It SHALL NOT edit product code, specs or `tasks.md`. ops-applier SHALL NOT modify anything under `evals/`; when it believes a finding comes from a broken check it SHALL report `DISPUTE <id>: <reason>` instead of changing code or checks for it.

#### Scenario: Applier respects evals
- **WHEN** ops-applier fixes eval findings
- **THEN** its commits contain no changes under `evals/`

#### Scenario: Dispute resolved by ops-eval
- **WHEN** the applier reports `DISPUTE F2: check expects exit 1 but spec says exit 0`
- **THEN** the next ops-eval round re-examines that check against the spec and either fixes it and says so, or keeps it with a justification

### Requirement: Failures are judged
ops-eval SHALL run checks only through `opsx-eval.sh` and SHALL NOT report a result the runner did not produce. For each FAIL it SHALL decide whether it is a product defect (reported as a finding) or a broken check (fixed, re-run, and noted). UNVERIFIABLE results SHALL be reported as P2 with what would be needed to verify them. A scenario left without a check SHALL be reported as P1.

#### Scenario: Broken check fixed
- **WHEN** a check fails because of a bug in the check itself
- **THEN** ops-eval fixes the check, re-runs it, and lists the fix in its report instead of a product finding

### Requirement: SKIP rules
ops-eval SHALL return `VERDICT: SKIP` with a one-line reason, writing and running no checks for the change, when the repo has no OpenSpec specs and the change has no delta specs, when the change's delta specs contain no scenarios, or when the change diff is markdown-only.

#### Scenario: Markdown-only change
- **WHEN** a change only edits `.md` files
- **THEN** ops-eval returns `VERDICT: SKIP` and `evals/` is unchanged

#### Scenario: Repo without specs
- **WHEN** ops-eval runs in a repo with no `openspec/specs/` and a change with no delta specs
- **THEN** it returns `VERDICT: SKIP`

### Requirement: Structured verdict
ops-eval SHALL end with a block the dispatcher can parse:

```
VERDICT: PASS | FAIL | SKIP
CHANGE: <change>
SCORE: <pass>/<total> pass · <fail> fail · <unverifiable> unverifiable · <not run> not run
FINDINGS:
- [P0|P1|P2] F<n> <capability>/<scenario-slug>: <one line> — evidence: <short> — expected: <x> — actual: <y>
CHECKS_CHANGED: <added/updated/deleted files, or none>
SUMMARY: <two sentences max>
```

PASS means no P0/P1 findings; FAIL means at least one.

#### Scenario: Failing scenario reported
- **WHEN** one check for the change fails because of a product defect
- **THEN** the verdict is FAIL and the finding names the capability and scenario slug

### Requirement: One-shot eval action
`/opsx-run <change> eval` SHALL ensure the change window and dispatch ops-eval once without auto-fix, like `review`. `/opsx-run <change> eval --agentic` SHALL also run L3 checks. `/opsx-run eval` without a change SHALL ask the user to pick one.

#### Scenario: Eval once
- **WHEN** the user runs `/opsx-run add-auth eval`
- **THEN** ops-eval runs once in the `add-auth` window and ops-applier is not dispatched

