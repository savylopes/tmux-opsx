## Context

tmux-opsx orchestrates OpenSpec changes in per-change tmux windows. **ops-applier** implements in an `opsx/<change>` worktree; **ops-qa** is a read-only UI/UX gate with `VERDICT: PASS|FAIL|SKIP` and numbered findings. The dispatcher pattern (Claude/Cursor/OpenCode delegate; Codex/Gemini work in-window) is established in `skills/opsx-run/SKILL.md`.

`apply --validate` currently loops: apply → ops-qa → applier fix → repeat. There is no code-level or security review. Users can run `/review-bugbot` in Cursor ad hoc, but that is outside the opsx lifecycle and not portable.

## Goals / Non-Goals

**Goals:**

- Add **ops-reviewer** and **ops-security** as first-class subagents, installed and symlinked like ops-applier/ops-qa.
- Expose `/opsx-run <change> review` and `/opsx-run <change> security` as one-shot advisory actions.
- Extend `apply --validate` to gate on review → security → qa sequentially, with applier fix rounds between failures.
- Use identical verdict/findings format across reviewer, security, and qa so the applier can fix by id.
- Support SKIP when the change has no relevant surface for that gate.
- Native prompts on all CLIs — no delegation to bugbot or security-review.

**Non-Goals:**

- Blocking `land` or `merge` on review/security PASS.
- Parallel execution of review + security + qa in one pass.
- Replacing or wrapping Cursor bugbot/security-review skills.
- Changing plain `apply` (no validate) behavior.
- Adding new MCP dependencies for review (read/grep/bash/diff only).

## Decisions

### 1. Two separate agents, not one combined reviewer

**Choice:** `ops-reviewer` (implementation) and `ops-security` (security) as distinct agents and CLI actions.

**Rationale:** Security review benefits from a focused prompt and can be run independently. Users may want `security` without full implementation review. Separate SKIP rules per domain.

**Alternative considered:** Single `ops-reviewer` with a security section — rejected; harder to tune and to skip independently.

### 2. Verdict format mirrors ops-qa

**Choice:** Reuse the same output block shape:

```
VERDICT: PASS | FAIL | SKIP
CHANGE: <change>
ROUNDS_HINT: ...
FINDINGS:
- [P0|P1|P2] F<n>: ...
SUMMARY: ...
```

**Rationale:** Dispatcher and applier already understand F1, F2 fix rounds from qa. Minimal new parsing logic.

### 3. Validate loop order: review → security → qa

**Choice:** Sequential gates after apply; on any FAIL, applier fixes that gate's findings only, then retry that gate before advancing.

**Rationale:** Code issues are cheaper to fix before browser QA. Security between review and qa catches auth/data issues before UI polish.

**Alternative considered:** Parallel review + qa — rejected for dispatcher complexity and conflicting fix batches.

### 4. Advisory standalone, gated only on `--validate`

**Choice:** `review` and `security` actions are one-shot and do not auto-fix. Only `apply --validate` runs the full loop with applier fix rounds. `land` unchanged.

**Rationale:** User decision (option B) — try agents without making merge scary.

### 5. Native agents everywhere

**Choice:** New markdown/toml agent files installed to the same paths as existing agents; Codex/Gemini run review in the dispatcher window.

**Rationale:** Consistent behavior across CLIs; no Cursor-only dependency.

### 6. SKIP rules

**ops-reviewer SKIP when:**

- Change is docs/spec-only (no product code diff), or
- Diff touches only non-executable artifacts (markdown, yaml config with no logic, `.openspec` metadata).

**ops-security SKIP when:**

- Same as reviewer for pure docs/copy, or
- Diff has no security-relevant surface (typo, comment-only, pure formatting) — agent judges with one-line reason.

**Not SKIP:** API changes, auth, user input, network, file I/O, dependencies, env/secrets patterns — must run.

### 7. Applier fix-round extensions

**Choice:** Add sections to `opsx-applier.md` for review-fix and security-fix mirroring existing qa-fix: fix only listed F ids, same worktree, report which ids addressed.

### 8. Installer and project symlinks

**Choice:** Extend `install.sh` with the same transforms used for ops-qa (Cursor frontmatter, Codex toml, Gemini/OpenCode paths). `opsx-window.sh ensure` symlinks new agents into `.cursor/agents/` and `.gemini/agents/` like applier/qa.

## Risks / Trade-offs

- **[Risk] Longer validate cycles** → Mitigation: SKIP rules; standalone review/security for quick checks without full loop.
- **[Risk] False positives block validate** → Mitigation: P2 nits do not fail; user can use plain `apply` + manual `land` if needed.
- **[Risk] Agent inconsistency across CLIs** → Mitigation: Shared agent markdown as source of truth; install.sh normalizes per CLI.
- **[Risk] Reviewer duplicates qa for UI bugs** → Mitigation: Reviewer focuses code/spec/tests; qa owns browser/regression. Reviewer may note obvious UI code issues but does not drive browser.

## Migration Plan

1. Ship new agent files and `install.sh` updates.
2. Users re-run `./install.sh` and restart agent CLIs.
3. Existing `apply --validate` windows pick up new loop on next validate invocation (prompt change in SKILL.md).
4. No data migration; no breaking CLI renames.

## Open Questions

- Should `apply --validate` accept `--no-security` or `--no-review` flags for faster iteration? (Defer unless requested during implementation.)
- Exact SKIP heuristics for "typo-only" security — leave to agent judgment with mandatory one-line SKIP reason.
