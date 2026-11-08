# Spec Delta

## MODIFIED Requirements

### Requirement: Wait for a PR event
`pr.sh wait <pr> [--slice <seconds>] [--poll <seconds>]` SHALL compare GitHub and git state with the state file at each due poll (see "Back off between polls") without starting any agent. On a change it SHALL print one `event=<kind>` line and exit 0. Kinds: `merged`, `closed`, `parent-merged`, `parent-moved`, `base-moved`, `head-moved`, `conflict`, `comments`, `ci-failed`. When the slice ends with no change it SHALL exit 3.

#### Scenario: Nothing changes
- **WHEN** `pr.sh wait 42 --slice 2 --poll 1` runs and the fake `gh` reports the same state as the state file
- **THEN** it exits 3 within a few seconds and prints no `event=` line

#### Scenario: New review comment
- **WHEN** the fake `gh` reports a review comment with an id above `last_comment_id`
- **THEN** `pr.sh wait 42` prints `event=comments` and exits 0

#### Scenario: Base moved
- **WHEN** the base branch tip differs from the recorded base SHA
- **THEN** `pr.sh wait 42` prints `event=base-moved` and exits 0

#### Scenario: Merged wins
- **WHEN** the PR state is `MERGED` and new comments also exist
- **THEN** `pr.sh wait 42` prints `event=merged` only

#### Scenario: Parent merged
- **WHEN** the state file has `parent=42` and the fake `gh` reports PR 42 as `MERGED`
- **THEN** `pr.sh wait 43` prints `event=parent-merged`

## ADDED Requirements

### Requirement: Detect a conflicting PR
`pr.sh wait` SHALL print `event=conflict` when GitHub reports the PR's `mergeable` as `CONFLICTING`, once per pair of head SHA and base tip SHA. When it prints the event it SHALL record the pair as `conflict_reported=<head>:<base>`. `pr.sh seen` SHALL NOT record it. `UNKNOWN` and `MERGEABLE` SHALL NOT raise the event. Without a base tip SHA it SHALL NOT raise the event.

#### Scenario: Conflict reported
- **WHEN** the state matches GitHub and the fake `gh` reports `mergeable` as `CONFLICTING`
- **THEN** `pr.sh wait 42` prints `event=conflict`, exits 0 and records `conflict_reported=<head>:<base>`

#### Scenario: Reported once
- **WHEN** `pr.sh wait 42` printed `event=conflict`, then `pr.sh seen 42` ran, and the head and base are unchanged
- **THEN** `pr.sh wait 42 --slice 2 --poll 1` exits 3 and prints no `event=` line

#### Scenario: Seen does not hide a conflict
- **WHEN** the PR is `CONFLICTING`, no `conflict` was reported for its head and base, and `pr.sh seen 42` runs
- **THEN** the next `pr.sh wait 42` prints `event=conflict`

#### Scenario: A new base tip reports again
- **WHEN** `conflict` was reported, the base tip moves, `pr.sh seen 42` runs and the PR is still `CONFLICTING`
- **THEN** the next `pr.sh wait 42` prints `event=conflict`

#### Scenario: Still computing
- **WHEN** the fake `gh` reports `mergeable` as `UNKNOWN`
- **THEN** `pr.sh wait 42 --slice 2 --poll 1` exits 3 and prints no `event=` line

#### Scenario: Base moved wins
- **WHEN** the base tip differs from the recorded base SHA and the PR is `CONFLICTING`
- **THEN** `pr.sh wait 42` prints `event=base-moved`, and `conflict` is reported by a later wait if the PR is still conflicting

### Requirement: Back off between polls
`pr.sh wait` SHALL double the gap between its polls of GitHub and git, starting from `--poll` (1, 2, 4, 8, ... times `--poll`), at most 3600 seconds unless `--poll` is longer, and SHALL keep the position in the state file across wait calls. An event, `seen`, `push`, `rerun`, `start` and `restart-input` SHALL start the progression over. A failed poll SHALL NOT advance it. A wait SHALL still check its generation and record `last_wait_at` every `--poll` seconds.

#### Scenario: Gaps grow
- **WHEN** repeated `pr.sh wait 42 --poll 60` calls find no change
- **THEN** the gaps between polls grow as 60, 120, 240 seconds, across wait calls

#### Scenario: Capped at one hour
- **WHEN** the progression passes 3600 seconds with `--poll 60`
- **THEN** the gap stays 3600 seconds

#### Scenario: Seen starts over
- **WHEN** the next poll is far in the future and `pr.sh seen 42` runs
- **THEN** the next `pr.sh wait 42` polls at once

#### Scenario: Backoff does not delay a stop
- **WHEN** the next poll is far in the future, `pr.sh wait 42 --gen 1 --slice 30 --poll 1` runs and `monitor_gen` becomes 2
- **THEN** the wait exits 4 within a few seconds

#### Scenario: Liveness during backoff
- **WHEN** the next poll is far in the future and `pr.sh wait 42 --slice 2 --poll 1` runs
- **THEN** it makes no `gh` call, exits 3 and records a current `last_wait_at`

### Requirement: Prompt handles the conflict event
The maintain prompt SHALL describe `conflict`: when an open question or a rebase in progress already covers it, the window SHALL acknowledge with `pr.sh seen` and return to the loop. Otherwise it SHALL rebase as for `base-moved`, sending a stopped rebase to a fix round or asking the user.

#### Scenario: Prompt names the event
- **WHEN** `pr.sh prompt 42` runs with `--agent-cli claude` and with `--agent-cli codex`
- **THEN** the Events section of each prompt has a `conflict` entry naming the acknowledge path and the rebase path
