## Why

The `ops-pr-monitor` subagent only detects PR events, but the maintain window then makes code changes itself: it fixes review comments, CI failures and conflicts on its own model. Only the tests and one ops-reviewer pass run before the push. Every other code change in this harness goes through the validation loop of `/opsx-run apply --validate`:
- ops-applier implements;
- ops-eval, ops-reviewer, ops-security (and ops-qa) verify, with fix rounds until each gate passes.

A PR fix should get the same treatment before it is pushed to a branch other people review.

Two monitor defects found in live windows feed this loop false wake-ups:
- **Haiku misreads results.** The haiku monitor sometimes misreads a plain exit 3 (`event=unknown` on PR 29, `event=timeout` on PR 36).
- **Missing `max-calls:`.** A window that drops the `max-calls:` line gets the default of 3 calls, so it wakes every 8 min (PR 20).

## What Changes

- **Detection vs. fixing.** The monitor stays detection-only. The maintain window becomes a dispatcher for code changes: it never edits code itself on Claude Code, Cursor CLI or OpenCode.
- **Mechanical steps stay in the window.** These change no code by hand: a clean rebase or restack, `pr.sh rerun`, `pr.sh seen`, the base retarget after a parent merged, thread replies, and `pr.sh note` questions. A clean rebase or restack still needs only the repository's tests before `pr.sh push`.
- **Fix rounds go through the validation loop.** A fix round is any code change: a review comment the rules allow acting on, a CI failure caused by the PR, or a conflict the rules allow resolving. In the PR's worktree:
  1. **ops-applier** implements, receiving the event's material (comment text, failing check and log excerpt, conflicting paths) as quoted untrusted data. It commits without pushing.
  2. **ops-eval** runs when the branch belongs to an OpenSpec change (head `opsx/<change>`, or the window is that change's window). Otherwise it is `SKIP`.
  3. **ops-reviewer** runs, then **ops-security**.
  4. **ops-qa** runs only when the repository has `.opsx/preview.yaml`. Otherwise it is `SKIP`.
  5. Any `FAIL` sends that gate's FINDINGS verbatim back to ops-applier and re-runs from that gate, at most 3 fix rounds per event. After that the window asks the user (`mark ask`, `pr.sh note`).
  6. When all gates are PASS or SKIP with no P0/P1 findings and the tests pass, the window pushes with `pr.sh push`, replies on the handled threads with the commit SHA, and runs `pr.sh seen`.
- **The window prints each gate's VERDICT.** On Codex CLI and Gemini CLI, which have no reliable subagents, the window applies the fix itself on the worktree and runs each gate itself from the agent files, in the same order.
- **Ask-first rules unchanged.** Untrusted authors, scope or design changes, new dependencies, disabled tests, the same fix failing twice, and a both-sides conflict are still asked about before any fix round.
- **Monitor reliability.**
  - `agents/models.conf` ships `claude.pr-monitor = sonnet`.
  - `agents/opsx-pr-monitor.md` uses `max-calls` 9 when the line is missing (not 3).
  - The prompt says to copy the two-line monitor prompt verbatim.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `pr-maintain`: Autonomous actions (window does only mechanical steps), Gates before a push (validation loop for fix rounds), monitor model and `max-calls` default.

## Impact

- `skills/opsx-pr/pr.sh` (`prompt_text`: "You may do on your own", Events, Gates; models block for the gates), `skills/opsx-pr/SKILL.md`, README PR maintainer section.
- `agents/models.conf`, `agents/opsx-pr-monitor.md`.
- `tests/test-pr.sh`, `evals/pr-maintain/`.
