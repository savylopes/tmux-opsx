## ADDED Requirements

### Requirement: Detect a failing CI on the current head
`pr.sh wait` SHALL treat CI as failing when any check of the PR is in the `fail` or `cancel` bucket. It SHALL report `ci-failed` once per failing head: when it prints `event=ci-failed` it records that head as `ci_reported=`, and it reports again only for another head or after CI on that head stopped failing. `pr.sh seen` SHALL NOT mark a failure as reported, and `pr.sh rerun` SHALL clear `ci_reported`.

#### Scenario: Cancelled check
- **WHEN** the fake `gh` reports checks in the buckets `pass` and `cancel` for PR 42
- **THEN** `pr.sh wait 42` prints `event=ci-failed` and exits 0

#### Scenario: Reported failure stays quiet
- **WHEN** `pr.sh wait 42` printed `event=ci-failed`, then `pr.sh seen 42` ran, and CI and the head are unchanged
- **THEN** `pr.sh wait 42 --slice 2 --poll 1` exits 3 and prints no `event=` line

#### Scenario: Failure absorbed by seen is still reported
- **WHEN** CI of PR 42 starts failing after the last wait and before `pr.sh seen 42` runs, so `seen` records `ci=fail`
- **THEN** the next `pr.sh wait 42` prints `event=ci-failed`

#### Scenario: Failure on a new head
- **WHEN** a failure on head `aaa` was reported, the head moved to `bbb` and CI on `bbb` fails
- **THEN** `pr.sh wait 42` prints `event=ci-failed`

#### Scenario: Failure again after a re-run
- **WHEN** a failure on the current head was reported, `pr.sh rerun 42` ran, and CI on the same head fails again
- **THEN** `pr.sh wait 42` prints `event=ci-failed`

### Requirement: Re-run a failed CI once per head
`pr.sh rerun <pr>` SHALL re-run, with `gh run rerun <run-id> --failed`, each distinct GitHub Actions run behind a `fail` or `cancel` check of the PR's current head, and record that head as `rerun_head=` in the state file. When `rerun_head` already equals the current head it SHALL re-run nothing and exit 6. When no failing check links to a GitHub Actions run it SHALL re-run nothing and exit 7.

#### Scenario: First re-run
- **WHEN** PR 42 has a `fail` check whose link is `https://github.com/o/app/actions/runs/77/job/1` and a `cancel` check of run 78
- **THEN** `pr.sh rerun 42` runs `gh run rerun 77 --failed` and `gh run rerun 78 --failed`, exits 0, and the state file has `rerun_head=` the current head SHA

#### Scenario: Second re-run on the same head
- **WHEN** `pr.sh rerun 42` already ran for the current head
- **THEN** a second `pr.sh rerun 42` exits 6 and calls no `gh run rerun`

#### Scenario: New head allows a new re-run
- **WHEN** `rerun_head` is an older SHA and the head has moved
- **THEN** `pr.sh rerun 42` re-runs the failing runs and exits 0

#### Scenario: Not a GitHub Actions check
- **WHEN** the only failing check links to an external CI service
- **THEN** `pr.sh rerun 42` exits 7 and calls no `gh run rerun`

### Requirement: Triage a CI failure before fixing it
The window prompt's `ci-failed` step SHALL tell the agent to read the failing checks and logs, and, when the failure is not clearly caused by this PR's change (a test unrelated to the diff, a timeout, a network or runner error, a cancelled run), to run `pr.sh rerun <pr>` once and go back to waiting. When CI fails again on the same head, or `rerun` exits 6 or 7, the agent SHALL treat the failure as real: fix it with the gates, or ask the user when the cause is unclear.

#### Scenario: Prompt carries the CI triage
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the `ci-failed` step names `rerun 42`, says to re-run only when the failure is not caused by the PR's change, and says a repeated failure on the same head is fixed or asked about, not re-run again

## MODIFIED Requirements

### Requirement: Autonomous actions
The window prompt SHALL allow the agent, without asking, to rebase or restack, resolve mechanical conflicts, make the change a review comment clearly asks for, fix failing CI, re-run a failed CI once per head through `pr.sh rerun <pr>`, push only through `pr.sh push <pr>` (see Push with an explicit lease), reply to the threads it handled and mark them resolved, and retarget the base to the parent's base after a parent merged. It SHALL forbid merging the PR and any plain `--force` push.

#### Scenario: Prompt lists allowed and forbidden actions
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt contains `--force-with-lease`, says the agent never merges the PR, and forbids plain `--force`

#### Scenario: Prompt allows one CI re-run
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the "You may do on your own" list includes re-running a failed CI once per head with `rerun 42`
