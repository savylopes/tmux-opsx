# pr-maintain Specification

## Purpose
Lets the user hand one open pull request to a goal-driven agent window that keeps it mergeable (rebase, restack, conflicts, review comments, CI) until someone else merges or closes it, asking the user only for important or ambiguous decisions.

## Requirements

### Requirement: Resolve the PR to maintain
`pr.sh resolve <pr> [--repo <dir>]` SHALL accept a PR number, `#<n>` or a PR URL and print `pr url repo head base state author head_repo base_remote head_remote` as `key=value` lines, where `repo` is the base repository `<owner>/<name>`, `head_repo` is the repository holding the head branch, and `head_remote` is empty when no remote may push it. It SHALL exit 2 when no PR matches and fail with a message for any other argument or outside a git repository without `--repo`.

#### Scenario: PR number resolves
- **WHEN** `pr.sh resolve 42` runs in a repository where `gh` knows open PR 42 on branch `feat-a` against `main`
- **THEN** it exits 0 and prints `pr=42`, `head=feat-a`, `base=main` and `state=OPEN` lines

#### Scenario: Unknown PR
- **WHEN** `pr.sh resolve 999` runs and `gh` finds no PR 999
- **THEN** it exits 2

#### Scenario: Bad argument
- **WHEN** `pr.sh resolve not-a-pr` runs
- **THEN** it exits non-zero with a message and prints no `pr=` line

### Requirement: Open a PR for a branch
`pr.sh open [<branch>] --title <t> --body-file <f> [--base <b>] [--repo <dir>]` SHALL push the branch to `origin` and create the PR on the base repository with `gh pr create`, defaulting to the current branch and the base repository's default branch, with head `<fork owner>:<branch>` when `origin` is the user's fork, then print `pr=<n>` and `url=<url>`. When the branch already has an open PR from that head repository it SHALL print that PR and create nothing. It SHALL refuse, pushing nothing, a branch that is the base repository's default branch or equal to `--base`.

#### Scenario: New PR
- **WHEN** `pr.sh open feat-a --title T --body-file b.md` runs and `feat-a` has no PR
- **THEN** the fake `gh` records one `pr create` call with head `feat-a` and the output has a `pr=` line

#### Scenario: Existing PR
- **WHEN** `feat-a` already has open PR 42
- **THEN** `pr.sh open feat-a --title T --body-file b.md` prints `pr=42` and records no `pr create` call

#### Scenario: Default branch refused
- **WHEN** `pr.sh open main --title T --body-file b.md` runs and `main` is the default branch
- **THEN** it exits non-zero and records no `pr create` call

#### Scenario: New PR from the user's fork
- **WHEN** `origin` is `me/app`, `upstream` is `acme/app`, and `pr.sh open feat-f --title T --body-file b.md` runs
- **THEN** `feat-f` is pushed to `origin` only, and the fake `gh` records one `pr create` call with `-R acme/app` and head `me:feat-f`

### Requirement: Start a maintain window
`pr.sh start <pr> [--repo <dir>] [--agent-cli <cmd>]` SHALL refuse a PR that is not open or whose head is in a fork other than the user's own (see Only the user's own fork is maintained), record the PR's state, and call `opsx-window.sh ensure pr-<n>` with a prompt file and a goal file, reusing the window when it already exists. The goal SHALL say the PR is merged by someone else, closed, or the user said stop.

#### Scenario: Open PR starts a window
- **WHEN** `pr.sh start 42` runs inside a private tmux server for open PR 42
- **THEN** a window tagged `@opsx_change=pr-42` exists and the goal file passed to `ensure` names PR 42 and the merged, closed and stop exits

#### Scenario: Second start reuses the window
- **WHEN** `pr.sh start 42` runs again while window `pr-42` exists
- **THEN** no second `pr-42` window is created and the output starts with `reused`

#### Scenario: Merged PR is refused
- **WHEN** `pr.sh start 41` runs for a PR whose state is `MERGED`
- **THEN** it exits non-zero naming the state and no window is created

#### Scenario: Fork PR is refused
- **WHEN** `pr.sh start 45` runs for an open PR whose head is `main` of a fork that is not `origin` (`isCrossRepository=true`)
- **THEN** it exits non-zero naming the fork, and no window and no state file are created; `pr.sh worktree 45`, `restack 45` and `push 45` refuse it too

### Requirement: PR state file
`pr.sh` SHALL keep per-PR state in `${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/pr/<owner>-<name>-<n>/state` as `key=value` lines holding at least the head SHA, base branch and SHA, the parent PR and its tip SHA when the base is another PR's head branch, and the newest review comment id seen. `pr.sh seen <pr>` SHALL update it to the PR's current values.

#### Scenario: Start writes state
- **WHEN** `pr.sh start 42` runs
- **THEN** the state file exists and contains `head_sha=`, `base=` and `last_comment_id=` lines

#### Scenario: Stacked PR records its parent
- **WHEN** `pr.sh start 43` runs for PR 43 whose base `feat-a` is the head branch of open PR 42
- **THEN** the state file contains `parent=42` and a `parent_tip=` line with PR 42's head SHA

### Requirement: Wait for a PR event
`pr.sh wait <pr> [--slice <seconds>] [--poll <seconds>]` SHALL compare GitHub and git state with the state file every poll interval without starting any agent. On a change it SHALL print one `event=<kind>` line and exit 0. Kinds: `merged`, `closed`, `parent-merged`, `parent-moved`, `base-moved`, `head-moved`, `comments`, `ci-failed`. When the slice ends with no change it SHALL exit 3.

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

### Requirement: Maintenance worktree
`pr.sh worktree <pr>` SHALL print the path of a worktree on the PR's head branch: an existing worktree of that branch when there is one, else a new `../wt-pr-<n>` beside the repository. It SHALL never check out the branch in the main checkout and SHALL refuse when that worktree has uncommitted changes.

#### Scenario: New worktree
- **WHEN** `pr.sh worktree 42` runs and no worktree holds `feat-a`
- **THEN** `../wt-pr-42` exists on branch `feat-a` and the main checkout's branch is unchanged

#### Scenario: Existing worktree reused
- **WHEN** `../wt-add-thing` already holds `feat-a`
- **THEN** `pr.sh worktree 42` prints that path and creates no `../wt-pr-42`

### Requirement: Restack after the parent merges
`pr.sh restack <pr>` SHALL, in the PR's worktree, rebase the PR's own commits onto its new base with `git rebase --onto <base> <parent_tip>` using the recorded parent tip, so commits of a squash-merged parent are dropped. On conflict it SHALL stop with the rebase in progress, exit 4 and list the conflicted files.

#### Scenario: Squash-merged parent
- **WHEN** parent PR 42 (commits A, B) was squash-merged into `main` and PR 43 has commits A, B, C, D on top
- **THEN** after `pr.sh restack 43` the branch holds only C and D on top of `main`

#### Scenario: Conflict stops
- **WHEN** C conflicts with `main`
- **THEN** `pr.sh restack 43` exits 4 and prints the conflicted file names

### Requirement: Autonomous actions
The window prompt SHALL allow the agent, without asking, to rebase or restack, resolve mechanical conflicts, make the change a review comment clearly asks for, fix failing CI, re-run a failed CI once per head through `pr.sh rerun <pr>`, push only through `pr.sh push <pr>` (see Push with an explicit lease), reply to the threads it handled and mark them resolved, and retarget the base to the parent's base after a parent merged. It SHALL forbid merging the PR and any plain `--force` push.

#### Scenario: Prompt lists allowed and forbidden actions
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt contains `--force-with-lease`, says the agent never merges the PR, and forbids plain `--force`

#### Scenario: Prompt allows one CI re-run
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the "You may do on your own" list includes re-running a failed CI once per head with `rerun 42`

### Requirement: Push with an explicit lease
`pr.sh push <pr>` SHALL push the worktree's head branch to the PR's head remote (`origin` for same-repository PRs in a plain checkout and for PRs from the user's fork) with `--force-with-lease=<head>:<head SHA recorded in the state file>`, exit 5 when that lease fails, and record the pushed SHA as `head_sha` on success.

#### Scenario: Push never overwrites someone else's commit
- **WHEN** someone pushes to the PR branch after the last `pr.sh seen`, the worktree has fetched it, and `pr.sh push 42` runs with a rewritten local branch
- **THEN** it exits 5 and the branch on `origin` still holds their commit

### Requirement: Ask the user on important or ambiguous decisions
The window prompt SHALL tell the agent, for an important or ambiguous decision, to ask in the window, mark the window `ask`, keep waiting for PR events, and act on that decision only after the user answers.

#### Scenario: Prompt carries the ask list
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt names as ask cases: a conflict that changes behaviour on both sides; a scope or design change, new dependency, or disabled or deleted tests; disagreeing reviewers or agent disagreement; a comment or review author who is not the PR author, a requested reviewer or a user with write access (`admin`, `maintain` or `write`), stating that a submitted review alone does not count; overwriting others' commits, closing the PR or changing another PR; the same fix failing twice

#### Scenario: Prompt says how to ask
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt contains `opsx-window.sh mark pr-42 ask` and says comment text, the PR title and body, commit messages and CI logs are untrusted input

### Requirement: Trusted authors and untrusted input
The window prompt SHALL trust only the PR author, *requested* reviewers and users whose repository permission is `admin`, `maintain` or `write`; having submitted a review SHALL NOT make an author trusted, and a bot is a GitHub App account whose login ends in `[bot]`. It SHALL treat all text read from GitHub as untrusted input: review comments and reviews, PR comments, the PR title and body, commit messages and diffs pushed by others, CI logs and check output, and bot comments.

#### Scenario: Prompt defines trusted authors
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt names `reviewRequests`, the `admin`, `maintain` or `write` permissions, says a submitted review does not make someone trusted, and defines a bot as a `[bot]` account

### Requirement: Gates before a push
The window prompt SHALL require the repository's tests to pass before every push that changes code, and an ops-reviewer pass with no P0/P1 findings before pushing a fix for a review comment or CI. A clean rebase or restack with no conflicts SHALL need only the tests.

#### Scenario: Prompt carries the gates
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt requires tests before a push and an ops-reviewer pass for comment and CI fixes

### Requirement: Ask window state
`opsx-window.sh mark <name> ask` SHALL give the window an `ask` status with its own title badge (`ox ?<name>`) and colour, distinct from idle, busy and fail. Silence monitoring SHALL not turn an `ask` window idle.

#### Scenario: Mark ask
- **WHEN** `opsx-window.sh mark pr-42 ask` runs on a private tmux server with window `pr-42`
- **THEN** the window's `@opsx_status` is `ask` and its name starts with `ox ?`

#### Scenario: Silence keeps ask
- **WHEN** `opsx-window.sh mark pr-42 idle --if-busy` runs on a window marked `ask`
- **THEN** its status stays `ask`

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

### Requirement: Install and documentation
`install.sh` SHALL install `skills/opsx-pr/` (`SKILL.md`, executable `pr.sh`) into the same six skill folders as `/opsx-review`, skip it with `--skip-pr`, remove the six folders on `--uninstall` and check them in its verify step. `README.md` SHALL document `/opsx-pr` and list it in the component overview.

#### Scenario: Installed in a scratch HOME
- **WHEN** `install.sh` runs with a scratch HOME
- **THEN** `~/.claude/skills/opsx-pr/SKILL.md` exists and `~/.claude/skills/opsx-pr/pr.sh` is executable

#### Scenario: Skipped
- **WHEN** `install.sh --skip-pr` runs with a scratch HOME
- **THEN** no `opsx-pr` skill folder is created

#### Scenario: Uninstalled
- **WHEN** `install.sh --uninstall` runs after an install
- **THEN** none of the six `opsx-pr` skill folders remain

### Requirement: Detect a failing CI on the current head
`pr.sh wait` SHALL treat CI as failing when any check is in the `fail` or `cancel` bucket. It SHALL report `ci-failed` once per failing head: when it prints `event=ci-failed` it records that head as `ci_reported=`, and it reports again only for another head or once CI on that head left the fail state (pending or pass) and failed again. `pr.sh seen` SHALL NOT mark a failure as reported. `pr.sh rerun` SHALL record the current head as `ci_reported`, so the stale failed checks are not a repeat.

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
- **WHEN** a failure on the current head was reported, `pr.sh rerun 42` ran, CI on the same head went pending, and it fails again
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

### Requirement: Restart input after a restore
`pr.sh restart-input <pr> [--repo <dir>]` SHALL refuse, like `start`, a PR that is not open or whose head is in a fork other than the user's own, exiting non-zero and naming the state or the fork. For an open PR it SHALL rewrite the prompt and goal files, keep the state file (open `ask=` questions included), and print the maintain window's first input (`/goal …` with the dispatcher steps on Claude Code). It SHALL not create, type into or retag any tmux window.

#### Scenario: Open PR prints the first input
- **WHEN** `pr.sh restart-input 42` runs for open PR 42 with no tmux server
- **THEN** it exits 0, prints a line starting with `/goal` that names PR 42, and the state file still holds its earlier `last_comment_id=`

#### Scenario: Merged PR refused
- **WHEN** `pr.sh restart-input 41` runs for a PR whose state is `MERGED`
- **THEN** it exits non-zero, names `MERGED`, and prints no input

### Requirement: Fixed-choice questions carry options
The window prompt SHALL tell the agent that when a question has 2 or 3 fixed answers it records it with `pr.sh note <pr> "<question>" --option <label>` for each answer, so the push gets answer buttons, and that an answer typed into the window from a button is the chosen option's label.

#### Scenario: Prompt shows note with options
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt contains `--option` in a `pr.sh note` example and says a typed option label is the user's answer

### Requirement: Base repository and user's fork
`pr.sh` SHALL take the base repository, where PRs are looked up and created, from the `upstream` remote when it exists, else from `origin`'s GitHub parent when `origin` is a fork, else from `origin`. The user's fork SHALL be the `origin` repository when it differs from the base repository. Base branches SHALL be fetched from a remote whose URL names the base repository; commands that need a base branch and find no such remote SHALL fail naming `git remote add`.

#### Scenario: Upstream remote names the base repository
- **WHEN** `origin` is `me/app`, `upstream` is `acme/app`, and `pr.sh resolve 50` runs for PR 50 of `acme/app`
- **THEN** it prints `repo=acme/app` and `base_remote=upstream`, and the fake `gh` saw `-R acme/app`

#### Scenario: Origin's parent without an upstream remote
- **WHEN** `origin` is `me/app`, a fork of `acme/app`, and no `upstream` remote exists
- **THEN** `pr.sh resolve 50` prints `repo=acme/app` and an empty `base_remote=`, and `pr.sh restack 50` exits non-zero naming `git remote add`

#### Scenario: Plain checkout unchanged
- **WHEN** `origin` is `o/app` and is not a fork, and there is no `upstream` remote
- **THEN** `pr.sh resolve 42` prints `repo=o/app`, `base_remote=origin` and `head_remote=origin`

### Requirement: Only the user's own fork is maintained
A PR whose head is in a fork SHALL be accepted by `start`, `restart-input`, `worktree`, `restack` and `push` only when the head repository is the `origin` repository; `head_remote` is then `origin`. A PR from any other fork SHALL be refused naming the fork and `origin`, and so SHALL a fork PR whose head branch is the base repository's default branch or its own base branch.

#### Scenario: PR from the user's fork starts a window
- **WHEN** `pr.sh start 50` runs for open PR 50 of `acme/app` whose head is `me:feat-f` and `origin` is `me/app`
- **THEN** a `pr-50` window exists, the state file is written, and `pr.sh resolve 50` prints `head_repo=me/app` and `head_remote=origin`

#### Scenario: Teammate's fork refused
- **WHEN** `pr.sh start 51` runs for an open PR whose head is `dany:feat-d` while a `dany` remote exists
- **THEN** it exits non-zero naming `dany` and `origin`, creates no window and no state file, and `worktree 51`, `restack 51` and `push 51` refuse it too

#### Scenario: Fork main refused
- **WHEN** `pr.sh start 52` runs for an open PR whose head is `me:main` from the user's fork
- **THEN** it exits non-zero naming the branch and no window is created

### Requirement: Fork PR worktree, restack and push
For a PR from the user's fork, `worktree` SHALL create the head branch tracking `origin/<head>`, `restack` SHALL rebase onto `<base remote>/<base>`, and `push` SHALL push to `origin` with the recorded lease. A local branch of the same name tracking another remote SHALL be refused, not reused.

#### Scenario: Restack onto upstream
- **WHEN** `upstream/main` moved and `pr.sh restack 50` runs
- **THEN** it prints `onto=upstream/main` and the worktree's branch contains `upstream/main`

#### Scenario: Push goes to the fork
- **WHEN** the worktree of PR 50 has a new commit and `pr.sh push 50` runs
- **THEN** the fork's `feat-f` holds that commit, the upstream repository has no `feat-f` branch, and `head_sha` is updated

#### Scenario: Lease protects the fork branch
- **WHEN** someone pushed to `me:feat-f` after the last `seen` and `pr.sh push 50` runs with a rewritten branch
- **THEN** it exits 5 and the fork's `feat-f` still holds their commit

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
The maintain prompt SHALL tell the agent that messages the user types in the window take precedence over the PR loop: it acts on them first, then returns to the loop (on Claude Code: it makes sure one `ops-pr-monitor` is running and ends its turn; on other CLIs: it runs `pr.sh wait` again). The prompt SHALL also say that a `head-moved` or `comments` event caused only by the window's own push or replies is acknowledged with `pr.sh seen` and not acted on further.

#### Scenario: Prompt names user messages
- **WHEN** `pr.sh prompt 42` runs
- **THEN** the prompt says the user's messages in this window come before the PR loop

#### Scenario: Prompt names self-caused events
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt says that a `head-moved` from the window's own push, or `comments` that are only its own replies, are acknowledged with `pr.sh seen`

### Requirement: Background PR monitor on Claude Code
When the window's agent CLI is Claude Code, the maintain prompt SHALL tell the window never to run `pr.sh wait` itself, but to start `ops-pr-monitor` in the background with the exact wait command and a `max-calls:` line, then end its turn. Only a monitor started with the current `--gen` counts as running. On `event=` it SHALL handle it, run `pr.sh seen` and ensure a monitor; on `idle` or `superseded` ensure one; on `stopped` start none. The prompt SHALL say that `waiting`, or any monitor result that is not one of the five results, is not a reason to start a monitor. Other CLIs SHALL keep the foreground loop.

#### Scenario: Claude prompt uses the background monitor
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt names `ops-pr-monitor`, says to run it in the background and end the turn, says not to run `pr.sh wait` in the window, passes `--gen` to the wait command, and names the `idle`, `superseded`, `stopped` and `error:` results

#### Scenario: Only current-gen monitors count
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt says a monitor counts as running only when started with the current `--gen`, says to start one on `superseded` when none counts, and does not contain "When unsure, start one"

#### Scenario: Interim monitor result starts nothing
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt names the `waiting` line and says that an interim or non-matching monitor result is not a reason to start a monitor

#### Scenario: Other CLIs keep the foreground wait
- **WHEN** `pr.sh prompt 42 --agent-cli codex` runs
- **THEN** the prompt tells the window to run `pr.sh wait` in the foreground, does not name `ops-pr-monitor`, and passes `--gen`

### Requirement: PR monitor agent
`agents/opsx-pr-monitor.md` SHALL define `ops-pr-monitor` with the Bash tool only, guarded by a PreToolUse hook that runs `monitor-guard.sh`. It SHALL rerun the wait after exit 3 up to the `max-calls:` value (default 3, at most 30) and return one line: `event=<kind>`, `idle`, `superseded`, `stopped` or `error: <message>`. It SHALL never end its turn before that line with other text; if a call is moved to the background it SHALL take the exit code from the completion notification, read the task output file it names when it needs the result line, and continue the loop, and a turn it must end to wait for that notification SHALL say only `waiting`. A completion notification SHALL NOT be treated as a new prompt. `install.sh` SHALL install it and the guard unless `--skip-pr`, verify them, and always remove them on `--uninstall`.

#### Scenario: Monitor never replies early
- **WHEN** `agents/opsx-pr-monitor.md` is read
- **THEN** it says never to end the turn before the one final line, names the `moved to the background` case, the `<task-notification>` with its exit code and output file, the `waiting` line, and says a notification is not a new prompt and never yields `error: not a pr.sh wait command`

#### Scenario: Monitor agent installed
- **WHEN** `install.sh` runs with a scratch HOME
- **THEN** `~/.claude/agents/opsx-pr-monitor.md` exists, names `ops-pr-monitor`, lists only the Bash tool, has a PreToolUse hook naming `monitor-guard.sh`, and is removed again by `install.sh --uninstall`

#### Scenario: Skipped with --skip-pr
- **WHEN** `install.sh --skip-pr` runs with a scratch HOME
- **THEN** no `opsx-pr-monitor.md` and no `monitor-guard.sh` are installed

### Requirement: One live monitor per PR
The state file SHALL hold `monitor_gen=<n>`; `start`, `restart-input` and `stop` SHALL increase it, and the prompt's wait command SHALL carry it as `--gen <n>`. `wait --gen <n>` SHALL exit 4 on a mismatch, printing `stopped` when the bump came from `pr.sh stop` and `superseded` otherwise. Without `--gen`, `wait` SHALL behave as before.

#### Scenario: Refresh supersedes a running wait
- **WHEN** `pr.sh wait 42 --gen 1 --slice 30 --poll 1` runs and `monitor_gen` in the state file becomes 2 while it waits
- **THEN** it exits 4 within a few seconds, prints `superseded`, and prints no `event=` line

#### Scenario: Stop is reported as stopped
- **WHEN** `pr.sh wait 42 --gen 1 --slice 30 --poll 1` runs and `pr.sh stop 42` runs while it waits
- **THEN** the wait exits 4 within a few seconds and prints `stopped`, not `superseded`

#### Scenario: Start and stop advance the generation
- **WHEN** `pr.sh start 42` runs on a state file with `monitor_gen=3`, and then `pr.sh stop 42` runs
- **THEN** the state file holds `monitor_gen=4` after start and `monitor_gen=5` after stop

#### Scenario: Wait without gen is unchanged
- **WHEN** `pr.sh wait 42 --slice 2 --poll 1` runs with no `--gen` and the fake `gh` reports no change
- **THEN** it exits 3

### Requirement: Watcher liveness in list
Each poll of `pr.sh wait` SHALL record `last_wait_at=<epoch seconds>`. `pr.sh list` SHALL print a fifth column: `watch=off` when the last event is `merged` or `closed`, or when it is `stopped` and no `start` or `restart-input` ran since the stop (`stopped_gen` equals `monitor_gen`); else `watch=<age>s` since `last_wait_at`, `watch=stale` when the age exceeds slice plus poll plus 30 seconds, and `watch=-` when no wait has run yet.

#### Scenario: Stale watcher shown
- **WHEN** the state file for PR 42 has a `last_wait_at` from one hour ago, `last_event=comments`, and `pr.sh list` runs
- **THEN** the line for PR 42 ends with `watch=stale`

#### Scenario: Finished PR shows off
- **WHEN** the state file for PR 42 has a `last_wait_at` from one hour ago and `last_event=merged` (or `closed`), or `pr.sh stop 42` ran after that wait
- **THEN** the line for PR 42 ends with `watch=off`

#### Scenario: Restart after stop shows the new watcher
- **WHEN** `pr.sh stop 42` runs, then `pr.sh start 42` (or `pr.sh restart-input 42`), then a wait polls, and `pr.sh list` runs
- **THEN** the line for PR 42 ends with `watch=<n>s`, and with `watch=stale` once that `last_wait_at` is an hour old

#### Scenario: Fresh watcher shown
- **WHEN** `pr.sh wait 42 --slice 2 --poll 1` has just run and `pr.sh list` runs
- **THEN** the line for PR 42 has a `watch=<n>s` column with `<n>` under 60

### Requirement: Slice fits the monitor
On Claude Code the prompt's wait command SHALL use a slice of at most 170 seconds, so one call ends before Claude Code's 180-second auto-background limit for a subagent's Bash call. The monitor prompt SHALL carry `max-calls: <n>` with n = max(1, 1620 / slice), at most 30, and the prompt's `idle` line SHALL name the effective run (n × slice). `pr.sh wait` SHALL count its slice from its start and SHALL not start a poll round that it expects to end after the slice.

#### Scenario: Long slice clamped
- **WHEN** `pr.sh prompt 42 --agent-cli claude --slice 900` runs
- **THEN** the wait command has `--slice 170`, the prompt has `max-calls: 9`, and the `idle` line says about 25 minutes

#### Scenario: Short slice capped
- **WHEN** `pr.sh prompt 42 --agent-cli claude --slice 30` runs
- **THEN** the prompt has `max-calls: 30` and the `idle` line says about 15 minutes

#### Scenario: Wait stays within its slice
- **WHEN** `pr.sh wait 42 --slice 5 --poll 3` runs and each poll round takes about one second
- **THEN** it exits 3 within 6 seconds of its start

### Requirement: Quoted wait command
The prompt's wait command SHALL quote the `pr.sh` path and the repository path so a path with spaces or shell characters is one argument.

#### Scenario: Repo path with a space
- **WHEN** `pr.sh prompt 42` runs with `--repo "/tmp/my repo"`
- **THEN** the wait command contains `--repo /tmp/my\ repo`

### Requirement: State writes are locked
State writes SHALL hold a lock on the state file: `flock` when available, else a `mkdir` lock directory (broken after 120 s by renaming it first, so only one process breaks it). The lock SHALL be re-entrant within one process, `write_seen` SHALL hold it for its whole update, and a lock not obtained within 30 s SHALL print a `state lock busy` warning on stderr before writing.

#### Scenario: Concurrent writes without flock
- **WHEN** two processes each set 50 distinct keys at once with no `flock` on PATH
- **THEN** the state file holds all 100 keys afterwards

#### Scenario: Stale lock broken once
- **WHEN** a `mkdir` lock directory older than 120 s exists and two processes without `flock` each set 20 distinct keys at once
- **THEN** the state file holds all 40 keys and no lock directory is left

#### Scenario: Busy lock warns
- **WHEN** another process holds the lock for longer than 30 s and `pr.sh seen 42` runs
- **THEN** it prints `state lock busy` on stderr and still updates the state

### Requirement: Monitor command guard
`skills/opsx-pr/monitor-guard.sh` SHALL read a PreToolUse payload on stdin and allow only two command shapes: a single `<pr.sh> wait <n> --repo <arg> --slice <n> --poll <n> --gen <n>` with no unescaped shell metacharacters or newlines, where `<pr.sh>` is absolute and resolves to the `pr.sh` next to the guard; and `cat` or `tail -n <n>` of one Claude Code task output file. Anything else SHALL be denied with exit 2 and a reason on stderr.

#### Scenario: Prompt command allowed
- **WHEN** the guard gets the exact wait command from `pr.sh prompt 42 --agent-cli claude`, including a repo path with a space
- **THEN** it exits 0

#### Scenario: Other commands denied
- **WHEN** the guard gets `pr.sh wait 42 --repo /r --slice 5 --poll 1 --gen 1; rm -rf x`, `gh pr view 42`, `cat ~/.ssh/id_rsa`, or a command with `$(id)`
- **THEN** it exits 2 for each

#### Scenario: Only the installed pr.sh
- **WHEN** the guard gets the wait command with a relative path (`env/pr.sh wait …`), with an assignment prefix (`PATH=/x/pr.sh wait …`), or with the absolute path of another `pr.sh`
- **THEN** it exits 2 for each

#### Scenario: Task output read allowed, nothing else
- **WHEN** the guard gets `tail -n 5 /tmp/claude-1000/-home-u-p/0a1b-2c/tasks/bq7x.output` and `cat` of the same file
- **THEN** it exits 0, and it exits 2 for `cat /etc/passwd`, `tail -f` of that file, and a path with a `..` segment
