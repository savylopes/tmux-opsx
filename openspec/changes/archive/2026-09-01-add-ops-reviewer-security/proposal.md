## Why

tmux-opsx today has **ops-applier** (implements) and **ops-qa** (UI/UX only). There is no automated gate for code correctness, spec fidelity, architecture, or security before a change is considered done. `apply --validate` only loops through UI QA, so API-only and backend changes ship without implementation review. Adding native **ops-reviewer** and **ops-security** subagents closes that gap without depending on Cursor-specific tools like bugbot.

## What Changes

- Add **`ops-reviewer`** subagent: read-only, full implementation review (spec vs code, logic, tests, maintainability) with structured `VERDICT` / `FINDINGS` output matching ops-qa.
- Add **`ops-security`** subagent: read-only, security-focused review (auth, injection, secrets, unsafe defaults) with the same verdict format.
- Add **`/opsx-run <change> review`** and **`/opsx-run <change> security`** actions (one-shot, advisory).
- Extend **`apply --validate`** gated loop: apply → review → security → qa → fix rounds until all gates PASS or SKIP.
- **`land` is not blocked** by review or security — only existing OpenSpec validate/tasks gates apply.
- SKIP rules on both new agents (e.g. docs-only / no relevant surface), same spirit as ops-qa.
- Native agents installed for all supported CLIs (Claude, Cursor, Codex, OpenCode, Gemini) — no bugbot delegation.
- Update **ops-applier** to handle review-fix and security-fix rounds by finding id (F1, F2, …).

## Capabilities

### New Capabilities

- `ops-reviewer`: Implementation review subagent, `/opsx-run review` action, SKIP rules, applier fix-round integration.
- `ops-security`: Security review subagent, `/opsx-run security` action, SKIP rules, applier fix-round integration.
- `opsx-validate-pipeline`: Extended `apply --validate` dispatcher loop ordering review → security → qa with fix retries.

### Modified Capabilities

<!-- No existing specs in openspec/specs/ — all behavior is new capability specs. -->

## Impact

- **New files**: `agents/opsx-reviewer.md`, `agents/opsx-security.md`
- **Modified files**: `agents/opsx-applier.md`, `skills/opsx-run/SKILL.md`, `install.sh`, `README.md`
- **Install targets**: Same agent/skill paths as ops-applier and ops-qa across Claude, Cursor, Codex, OpenCode, Gemini
- **User-facing**: New CLI actions; `apply --validate` takes longer but catches more issues before UI QA
- **Non-breaking**: Plain `apply`, `qa`, and `land` behavior unchanged except `apply --validate` gains two new gates
