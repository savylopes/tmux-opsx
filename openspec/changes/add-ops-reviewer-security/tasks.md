## 1. Agent definitions

- [x] 1.1 Create `agents/opsx-reviewer.md` — read-only persona, full implementation review checklist, SKIP rules, structured VERDICT/FINDINGS output (mirror ops-qa format)
- [x] 1.2 Create `agents/opsx-security.md` — read-only persona, security-focused checklist, SKIP rules, same verdict format
- [x] 1.3 Update `agents/opsx-applier.md` — add review-fix and security-fix rounds (fix F1..Fn by id, same worktree, same pattern as qa-fix)

## 2. Installer

- [x] 2.1 Extend `install.sh` to install `opsx-reviewer.md` and `opsx-security.md` to Claude, Cursor, Codex, OpenCode, and Gemini agent paths (same transforms as applier/qa)
- [x] 2.2 Update `install.sh` uninstall/cleanup paths for the new agents if applicable
- [x] 2.3 Ensure `opsx-window.sh ensure` symlinks reviewer and security into `.cursor/agents/` and `.gemini/agents/` alongside applier/qa

## 3. opsx-run skill — new actions

- [x] 3.1 Add `review` and `review "..."` to SKILL.md usage, preconditions, and actions table
- [x] 3.2 Add `security` and `security "..."` to SKILL.md usage, preconditions, and actions table
- [x] 3.3 Add **review** dispatcher window prompt (ops-reviewer once, no auto-fix, mark done/fail)
- [x] 3.4 Add **security** dispatcher window prompt (ops-security once, no auto-fix, mark done/fail)
- [x] 3.5 Add **review-fix** and **security-fix** dispatcher prompts (delegate to ops-applier with pasted findings)
- [x] 3.6 Document host-specific delegation table rows for ops-reviewer and ops-security (Claude/Cursor/OpenCode Task/Agent; Codex/Gemini in-window)

## 4. opsx-run skill — validate pipeline

- [x] 4.1 Update **validate** dispatcher prompt: goal includes review + security PASS/SKIP; loop order apply → review → security → qa with per-gate fix retries
- [x] 4.2 Confirm plain **apply** prompt still excludes review, security, and qa
- [x] 4.3 Confirm **land** / **merge** docs explicitly state review and security do not gate landing

## 5. Documentation

- [x] 5.1 Update `README.md` — architecture diagram, contents table, usage examples for `review` and `security`, validate loop description
- [x] 5.2 Update README validate section to show review → security → qa ordering

## 6. Verification

- [x] 6.1 Run `./install.sh` and confirm new agents appear in global agent dirs
- [x] 6.2 Run `openspec validate add-ops-reviewer-security --strict` and fix any issues
- [x] 6.3 Smoke-test: `/opsx-run add-ops-reviewer-security review` dispatches (manual or dry-run prompt review)
