## ADDED Requirements

### Requirement: Maintain inside the caller's change window
When `pr.sh start <pr>` runs from a pane whose window is an `/opsx-run` change window (`@opsx_change=<change>` that is not `pr-<n>`), it SHALL open no new window: it SHALL tag that window `@opsx_pr=<n>` and `@opsx_pr_repo=<repo>`, write the state, prompt and goal files as usual, and give that window the maintain goal and prompt as its next input.

#### Scenario: Start from a change window
- **WHEN** `pr.sh start 42` runs with `$TMUX_PANE` in window `add-thing` (`@opsx_change=add-thing`) on a private tmux server
- **THEN** no `pr-42` window exists, window `add-thing` has `@opsx_pr=42` and `@opsx_pr_repo=o/app`, the output names that window, and the state file is written

#### Scenario: Change window already maintaining another PR
- **WHEN** window `add-thing` has `@opsx_pr=41` and `pr.sh start 42` runs from it
- **THEN** it exits non-zero naming PR 41 and the window keeps `@opsx_pr=41`

### Requirement: Ask before reusing a related change window
When `pr.sh start <pr>` runs outside a change window without `--window` or `--new-window`, and the PR's head is `opsx/<change>` or the branch of a worktree whose change has an open window in the session, it SHALL start nothing, print `candidate window=<id> change=<change>` and exit 8. `--window <change>` SHALL maintain the PR in that window and `--new-window` SHALL use `pr-<n>` as before. The skill SHALL ask the user which one to use.

#### Scenario: Candidate reported
- **WHEN** window `add-thing` is open, PR 42's head is `opsx/add-thing`, and `pr.sh start 42` runs from another window
- **THEN** it exits 8, prints `candidate window=` with that window's id and `change=add-thing`, and creates no window and no state file

#### Scenario: User chose the change window
- **WHEN** `pr.sh start 42 --window add-thing` runs and that window is idle
- **THEN** window `add-thing` gets `@opsx_pr=42`, its pane receives the maintain `/goal` input, and no `pr-42` window exists

#### Scenario: User chose a new window
- **WHEN** `pr.sh start 42 --new-window` runs
- **THEN** a `pr-42` window is created as before and window `add-thing` has no `@opsx_pr`

#### Scenario: Busy change window refused
- **WHEN** window `add-thing` is `busy` and `pr.sh start 42 --window add-thing` runs from another window
- **THEN** it exits non-zero saying the window is busy, and nothing is typed into it

#### Scenario: No related window
- **WHEN** no change window is open for PR 42's head branch and `pr.sh start 42` runs
- **THEN** it creates or reuses `pr-42` as before and does not exit 8

### Requirement: User feedback in the window overrides the loop
The maintain prompt SHALL tell the agent that messages the user types in the window take precedence over the PR loop: it acts on them first, then returns to `pr.sh wait`.

#### Scenario: Prompt names user messages
- **WHEN** `pr.sh prompt 42` runs
- **THEN** the prompt says the user's messages in this window come before the PR loop

## MODIFIED Requirements

### Requirement: List and stop
`pr.sh list` SHALL print one line per PR with a state file: repo, PR, window status (or `none`) and the last event, finding the window as `pr-<n>` or as a change window tagged `@opsx_pr=<n>` with the same `@opsx_pr_repo`. `pr.sh stop <pr>` SHALL close window `pr-<n>` and keep the state file and worktree; for a change window it SHALL end the maintain goal and remove `@opsx_pr` and `@opsx_pr_repo`, and SHALL never close that window.

#### Scenario: List shows a running PR
- **WHEN** PR 42 was started and its window exists
- **THEN** `pr.sh list` prints a line containing `42` and the window status

#### Scenario: Stop closes the window
- **WHEN** `pr.sh stop 42` runs
- **THEN** no `pr-42` window remains and the state file still exists

#### Scenario: List finds a change window
- **WHEN** PR 42 is maintained in change window `add-thing`
- **THEN** `pr.sh list` prints a line containing `42` and that window's status, not `none`

#### Scenario: Stop keeps the change window
- **WHEN** PR 42 is maintained in change window `add-thing` and `pr.sh stop 42` runs
- **THEN** window `add-thing` still exists, has no `@opsx_pr` and no `@opsx_pr_repo`, and the state file still exists
