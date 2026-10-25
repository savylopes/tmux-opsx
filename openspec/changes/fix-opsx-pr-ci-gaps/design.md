# Design

## Context

`pr.sh` keeps one state file per PR. `snapshot` reads the current values and `write_seen` stores them. `detect_event` compares the two in priority order. CI is a single summary (`ci_state`: `fail` > `pending` > `pass`, else `none`) from `gh pr checks --json bucket`. `ci-failed` fires when `CUR_ci=fail` and the stored `ci` is not `fail`. `start` already leaves `ci` empty on a fresh state, so a PR that is already red is reported by the first wait (tests `F3`). What's left:

- `gh` buckets are `pass`, `fail`, `pending`, `skipping`, `cancel`. A `cancel` check currently counts as passing.
- `seen` stores whatever CI is at that moment. A failure that appears while the agent handles another event is stored as `ci=fail` and never reported.
- The prompt has no re-run step, so every failure goes straight to a code fix.

## Goals / Non-Goals

**Goals:**
- `cancel` counts as failing.
- Each head's failure is reported exactly once, whenever `seen` happens to run.
- One automatic re-run per head for failures that don't look caused by the PR, through a helper that enforces the limit.

**Non-Goals:**
- Re-running external (non GitHub Actions) CI.
- Detecting flaky tests automatically. The agent judges from the log; the helper only caps the number of re-runs.
- Changing the event priority or any other event.

## Decisions

1. **`cancel` joins `fail` in `ci_state`.** A cancelled required check blocks a merge the same way a failure does. A run cancelled because a newer push superseded it belongs to an old head, and `gh pr checks` shows only the current head's checks, so this adds no noise for normal pushes.

2. **Report once per head with `ci_reported=<sha>`, set by `wait`.** Alternative considered: a `ci_head` next to `ci` in `write_seen`. It doesn't help, because `seen` writes both together, so a failure absorbed by `seen` still looks seen. Instead, `detect_event` fires `ci-failed` when `CUR_ci=fail` and `ci_reported != CUR_head_sha`. `cmd_wait` stores `ci_reported=$CUR_head_sha` when it prints that event. `write_seen` never sets it. `write_seen` and every `wait` poll clear it when the current CI is `pending` or `pass` (so a failure that comes back after CI on the same head left the fail state, for example a human re-run, is reported again). `none` does not clear it, because a failed `gh pr checks` fetch also gives `none`, and clearing on it would re-report the same failure after a network blip. The old `ci` key is still written for `list` and debugging, but no longer drives the event. Migration: an existing state file has no `ci_reported`, so a PR that is red right now is reported once after the upgrade. The agent then looks at it, which is the wanted behaviour.

3. **`pr.sh rerun <pr>`.** It reads `gh pr checks <pr> --json bucket,link`, keeps the `fail`/`cancel` rows whose `link` matches `/actions/runs/<id>`, and runs `gh run rerun <id> --failed` once per distinct id (`-R <slug>`). Before re-running, it compares `rerun_head` with the current head SHA (from `gh pr view --json headRefOid`). If they are equal, it exits 6 (`already re-ran CI for <sha>`). If no check is failing at all, it exits 7 with `no check of <pr> is failing`; if failing rows exist but none is an Actions run, it exits 7 with the external-CI message. After at least one successful `gh run rerun`, it stores `rerun_head=<sha>` and sets `ci_reported=<sha>` (it does not clear it). GitHub keeps showing the old failed checks for a few seconds until the new attempt is listed as pending, so clearing it here made the very next `wait` poll report the old failure as a repeat, and the agent treated an un-retried flake as real. With `ci_reported` kept, a failure on the same head counts as a repeat only once a poll saw CI leave `fail` (pending or pass) and it then failed again. Trade-off: if a re-run starts and fails again entirely between two polls, the repeat is missed until the next head or state change; with a 60 s poll and CI runs of minutes this is unlikely. If every `gh run rerun` fails (no permission), it exits 1 with gh's error, and the agent treats the failure as real. Exit codes 6 and 7 are new and not used elsewhere in `pr.sh` (2 unknown PR, 3 no event, 4 conflict, 5 lease).

4. **The triage lives in the prompt, the limit lives in the script.** The `ci-failed` step becomes: read `gh pr checks` and `gh run view --log-failed`. If the failure is clearly caused by this PR's change, fix it with the gates and push. Otherwise (unrelated test, timeout, network or runner error, cancelled run) run `pr.sh rerun`, then `seen`, and wait. If it fails again on the same head, or `rerun` exits 6 or 7, treat it as real: fix it, or ask when the cause is unclear. "The same fix failed twice" in the ask list stays. The CI log stays untrusted input, so a log telling the agent to re-run or change something is not a reason by itself.

5. **Running windows are updated with `pr.sh start <pr> --repo <dir>`.** The state file is kept (`state kept`), the prompt and goal files are rewritten, and `opsx-window.sh ensure` types the new `/goal` and "read the prompt" into the reused window. Typed input waits until the current `pr.sh wait` returns, at most one slice. Open `ask=` questions survive, because the first-turn step reads them from the state file.

## Risks / Trade-offs

- [A real failure costs one extra CI run before it is fixed] → Accepted. The agent re-runs only when the log doesn't point at the change, and only once per head.
- [`gh run rerun --failed` needs `actions: write`] → On a permission error `rerun` exits 1 and the agent falls back to treating the failure as real.
- [After the upgrade, every currently red PR is reported once] → Intended: those windows then look at the failure once under the new rules.
- [Re-running is outward-facing] → It only restarts this PR's own runs, never changes code or settings, and is capped at one per head. It is listed under "on its own" in the prompt and spec.
