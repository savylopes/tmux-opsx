# Proposal

## Why

The `/opsx-pr` window misses or mishandles some CI failures. `pr.sh wait` sums up checks as fail/pending/pass and ignores `cancel`, so a cancelled required check never wakes the window. The `ci-failed` event fires only when the recorded summary was not already `fail`, and `pr.sh seen` records whatever CI is at that moment, so a failure that appears while the agent handles another event (for example CI on its own rebase push) is absorbed by `seen` and never reported. (A PR that is already red when the window starts is reported, because `start` leaves CI unrecorded.) And the prompt tells the agent to fix the code for every failure, with no step to re-run a job that failed by chance, so a flaky test or an infrastructure error leads to code changes and review rounds nobody needed.

## What Changes

- `pr.sh` counts a `cancel` check as failing, the same as `fail`.
- `wait` reports `ci-failed` once per failing head, recorded as `ci_reported=<sha>` when it prints the event. `seen` no longer hides a failure the agent never looked at; it clears `ci_reported` when CI is not failing.
- New `pr.sh rerun <pr>`: re-runs the failed and cancelled GitHub Actions runs of the current head with `gh run rerun <run-id> --failed`, at most once per head SHA (recorded as `rerun_head=`), and clears `ci_reported` so a repeat failure is reported. A second call on the same head exits 6 without re-running. When no failing check is a GitHub Actions run it exits 7.
- The window prompt's `ci-failed` step: when the failure is not clearly caused by this PR's change (an unrelated or known-flaky test, a timeout, a network or runner error, a cancelled run), run `pr.sh rerun` first, then `seen` and wait. If CI fails again on the same head, treat it as real: fix it with the gates, or ask the user when the cause is unclear.

## Capabilities

### New Capabilities

### Modified Capabilities
- `pr-maintain`: the `ci-failed` event (cancelled checks count, the failure is tied to the head), a new requirement for re-running a failed CI once per head, and the autonomous actions now include that re-run.

## Impact

- `skills/opsx-pr/pr.sh`: `ci_state`, `detect_event`, `cmd_wait` and `write_seen` (`ci_reported`, `rerun_head`), a new `rerun` command, the `ci-failed` step of the prompt, usage text.
- `skills/opsx-pr/SKILL.md` and README: document `rerun` and the cancelled-check rule.
- `tests/test-pr.sh`: the fake `gh` learns `pr checks --json bucket,link` and `run rerun`; new cases.
- `evals/pr-maintain/`: new checks are written by ops-eval.
- PR windows already running keep their old prompt until `pr.sh start <pr>` is run again for them, which rewrites the prompt and goal files and types the new goal into the reused window.
