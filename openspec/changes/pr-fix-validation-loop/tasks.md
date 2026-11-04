# Tasks

## 1. Maintain prompt

- [x] 1.1 `prompt_text`: replace "You may do on your own" with the mechanical list (no code edits by the window on Claude/Cursor/OpenCode); Events `ci-failed` (caused by the PR), `comments`, conflicts during base-moved/parent-moved/parent-merged route to a fix round
- [x] 1.2 Add a "Fix round (validation loop)" section: ops-applier → ops-eval (OpenSpec branch, else SKIP) → ops-reviewer → ops-security → ops-qa (`.opsx/preview.yaml`, else SKIP), verbatim FINDINGS re-rounds, max 3 per event then ask, print each VERDICT, then tests, `pr.sh push`, replies with SHA, `seen`; Codex/Gemini do the steps themselves; untrusted material passed as quoted data
- [x] 1.3 "Gates before a push": clean rebase/restack → tests only; anything else → the fix-round loop passed
- [x] 1.4 Verify with `pr.sh prompt 42 --agent-cli claude` and `--agent-cli codex` in `tests/test-pr.sh`

## 2. Monitor reliability

- [x] 2.1 `agents/models.conf`: `claude.pr-monitor = sonnet`; `agents/opsx-pr-monitor.md`: `max-calls` default 9; prompt: pass the two-line monitor prompt verbatim; verify install writes `model: sonnet` and the agent text says 9

## 3. Docs and checks

- [x] 3.1 `skills/opsx-pr/SKILL.md` ("What the window does", gates), README PR maintainer section
- [x] 3.2 `tests/test-pr.sh`, `tests/test-agent-models.sh`, install tests, shellcheck, `openspec validate pr-fix-validation-loop --strict`, all passing
