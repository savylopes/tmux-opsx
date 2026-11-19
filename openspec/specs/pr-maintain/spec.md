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
The window prompt SHALL allow the window, without asking, only mechanical steps that edit no code: rebase or restack without conflicts, re-run a failed CI once per head through `pr.sh rerun <pr>`, push only through `pr.sh push <pr>`, reply to handled threads and resolve them, retarget the base after a parent merged, and `pr.sh seen`/`note`. Every code change SHALL go through a fix round. It SHALL forbid merging the PR and any plain `--force` push.

#### Scenario: Prompt lists allowed and forbidden actions
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt contains `--force-with-lease`, says the agent never merges the PR, and forbids plain `--force`

#### Scenario: Prompt allows one CI re-run
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the list of steps the window may do on its own includes re-running a failed CI once per head with `rerun 42`

#### Scenario: Window does not edit code itself
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt says the window never edits code or commits content changes itself and routes review-comment fixes, CI fixes and conflict resolution to a fix round

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
A clean rebase or restack with no conflicts SHALL need only the repository's tests before `pr.sh push`. Any other push SHALL follow a passed fix round: ops-applier, then ops-eval (OpenSpec branch, else SKIP), ops-reviewer, ops-security, ops-qa (`.opsx/preview.yaml`, else SKIP), each PASS or SKIP with no P0/P1, findings sent back verbatim, at most 3 rounds per event before asking the user (a conflict rebase is one ops-applier run however often it stops), then the tests.

#### Scenario: Prompt carries the gates
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt requires tests before every push, names ops-applier, ops-eval, ops-reviewer, ops-security and ops-qa in that order for a fix round, and says to ask the user after 3 rounds

#### Scenario: Eval skipped for a non-OpenSpec branch
- **WHEN** `pr.sh prompt 42` runs for a PR whose head branch is not `opsx/<change>` and the window is not a change window
- **THEN** the prompt says ops-eval is SKIP for this PR

#### Scenario: Foreground CLIs run the gates themselves
- **WHEN** `pr.sh prompt 42 --agent-cli codex` runs
- **THEN** the prompt tells the window to apply the fix itself in the worktree and run each gate itself in the same order

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
`agents/opsx-pr-monitor.md` SHALL define `ops-pr-monitor` with the Bash tool only, guarded by a PreToolUse hook that runs `monitor-guard.sh`. It SHALL rerun the wait after exit 3 up to the `max-calls:` value (default 9 when missing, at most 30) and return one line: `event=<kind>`, `idle`, `superseded`, `stopped` or `error: <message>`. It SHALL never end its turn before that line with other text; if a call is moved to the background it SHALL take the exit code from the completion notification, read the task output file it names when it needs the result line, and continue the loop, and a turn it must end to wait for that notification SHALL say only `waiting`. A completion notification SHALL NOT be treated as a new prompt. `agents/models.conf` SHALL ship `claude.pr-monitor = sonnet`. `install.sh` SHALL install it and the guard unless `--skip-pr`, verify them, and always remove them on `--uninstall`.

#### Scenario: Monitor never replies early
- **WHEN** `agents/opsx-pr-monitor.md` is read
- **THEN** it says never to end the turn before the one final line, names the `moved to the background` case, the `<task-notification>` with its exit code and output file, the `waiting` line, and says a notification is not a new prompt and never yields `error: not a pr.sh wait command`

#### Scenario: Monitor agent installed
- **WHEN** `install.sh` runs with a scratch HOME
- **THEN** `~/.claude/agents/opsx-pr-monitor.md` exists, names `ops-pr-monitor`, lists only the Bash tool, has `model: sonnet` and a PreToolUse hook naming `monitor-guard.sh`, and is removed again by `install.sh --uninstall`

#### Scenario: Skipped with --skip-pr
- **WHEN** `install.sh --skip-pr` runs with a scratch HOME
- **THEN** no `opsx-pr-monitor.md` and no `monitor-guard.sh` are installed

#### Scenario: Missing max-calls defaults to nine
- **WHEN** the installed agent file is read
- **THEN** it says to use 9 calls when the `max-calls:` line is missing

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

### Requirement: Resolve the PR's stack
`pr.sh start <pr>` SHALL resolve the PR's stack among the base repository's open PRs from git ancestry: the parent is the nearest open PR whose head commit is an ancestor of this PR's head and not already in its base branch; the children are the open PRs whose parent is this PR. A base that is another PR's head branch (`parent=`) SHALL be the parent. It SHALL record `stack_parent`, `stack_parent_tip` and `stack_children` and print one `stack parent=<n|-> children=<list|->` line.

#### Scenario: Implicit stack inferred
- **WHEN** open PRs 41 (`feat-a`, commits A) and 42 (`feat-b`, commits A, B) both target `main` and `pr.sh start 42` runs
- **THEN** it prints `stack parent=41 children=-` and the state file holds `stack_parent=41` and `stack_parent_tip=<head SHA of 41>`

#### Scenario: Children found
- **WHEN** the same PRs are open and `pr.sh start 41` runs
- **THEN** it prints `stack parent=- children=42`

#### Scenario: No stack
- **WHEN** PR 42's head contains no other open PR's head and no open PR contains it
- **THEN** `pr.sh start 42` prints `stack parent=- children=-`

#### Scenario: Explicit base parent
- **WHEN** PR 43's base branch is the head branch of open PR 42
- **THEN** `pr.sh start 43` records `stack_parent=42`

### Requirement: Declare the stack by hand
`pr.sh start <pr> --stacked-on <n>` and `pr.sh stack <pr> --stacked-on <n>` SHALL record PR `<n>` as the parent without inferring one, and `--stacked-on none` SHALL record no parent. `pr.sh stack <pr>` without the flag SHALL print the recorded stack, the parent's window liveness (`parent_live=1|0`) and any live hold, and SHALL NOT recompute it.

#### Scenario: Override
- **WHEN** ancestry would infer parent 41 and `pr.sh start 42 --stacked-on 40` runs
- **THEN** the state file holds `stack_parent=40`

#### Scenario: Stacking off
- **WHEN** `pr.sh stack 42 --stacked-on none` runs
- **THEN** `pr.sh stack 42` prints `parent=-`

### Requirement: Stack record is kept
The recorded stack SHALL NOT be recomputed by `wait`, `seen` or `push`. It SHALL change only through `start`, `stack --stacked-on`, a successful `restack` onto the parent (new `stack_parent_tip`), the parent's merge (the parent is removed after the restack), and the ledger entries `join`, `merged` and `done` from a child (the child is added or removed).

#### Scenario: Parent force-push keeps the record
- **WHEN** PR 42 records `stack_parent=41` and PR 41's head is rewritten so it is no longer an ancestor of PR 42's head
- **THEN** `pr.sh stack 42` still prints `parent=41`

#### Scenario: Join adds a child
- **WHEN** PR 41 records no children and PR 42 writes a `join` entry to `pr-41`, and `pr.sh ledger 41 --unread --mark` runs
- **THEN** `pr.sh stack 41` prints `children=42`

### Requirement: Ledger entries
`pr.sh tell <pr> <to> <kind>` SHALL write one file in `${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/pr/<owner>-<name>/ledger/` named `<UTC yyyymmddTHHMMSSZ>-<4 hex>--<from>--<to>--<kind>.md`, created by writing a temporary file and renaming it. `<from>` is `pr-<pr>`, or `user` with `--from user`; `<to>` is `pr-<n>`, `all` or `log`; `<kind>` is one of `join`, `hold`, `release`, `moved`, `merged`, `request`, `ack`, `done`, `doing`. Other values SHALL be refused with exit 2.

#### Scenario: Entry written
- **WHEN** `pr.sh tell 41 all moved --sha <new> --old <old>` runs
- **THEN** the ledger folder holds one file whose name matches `^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}--pr-41--all--moved\.md$` and whose body contains both SHAs

#### Scenario: Unknown kind refused
- **WHEN** `pr.sh tell 41 all reboot` runs
- **THEN** it exits 2 and writes no file

#### Scenario: Bad address refused
- **WHEN** `pr.sh tell 41 'pr-42;rm' request --ref x` runs
- **THEN** it exits 2 and writes no file

### Requirement: Request carries a reference
`pr.sh tell <pr> pr-<n> request` SHALL require `--ref <ref>`, a GitHub URL of a review thread, comment, check run or job of the base repository, or `check:<name>`, and SHALL refuse a request without one with exit 2. `moved` SHALL require `--sha` and `--old`.

#### Scenario: Request without a reference
- **WHEN** `pr.sh tell 42 pr-41 request` runs
- **THEN** it exits 2 and writes no file

#### Scenario: Moved without SHAs
- **WHEN** `pr.sh tell 41 all moved` runs
- **THEN** it exits 2 and writes no file

### Requirement: Peer event from the ledger
`pr.sh wait` SHALL check the ledger every `min(5, --poll)` seconds, also while GitHub polls are backed off, and print `event=peer` for an unread entry whose name parses and that is addressed to this PR, or to `all` from its stack parent (`hold`, `release`, `moved`, `merged`) or a recorded child (`request`, `ack`, `join`, `done`), or from `user`. `log` entries, unparsable names and other PRs' entries SHALL never raise it. Its priority SHALL be after `parent-merged`.

#### Scenario: Addressed entry wakes
- **WHEN** PR 41's window waits and an entry `--pr-42--pr-41--request.md` newer than its cursor appears, with PR 42 a recorded child
- **THEN** `pr.sh wait 41` prints `event=peer` and exits 0

#### Scenario: Broadcast from the parent wakes
- **WHEN** PR 42 records `stack_parent=41` and an entry `--pr-41--all--moved.md` appears
- **THEN** `pr.sh wait 42` prints `event=peer`

#### Scenario: Unrelated PR does not wake
- **WHEN** PR 42 records `stack_parent=41` and an entry `--pr-50--all--hold.md` appears
- **THEN** `pr.sh wait 42 --slice 2 --poll 1` exits 3 and prints no `event=` line

#### Scenario: Log entries do not wake
- **WHEN** an entry `--pr-41--log--doing.md` appears
- **THEN** `pr.sh wait 42 --slice 2 --poll 1` exits 3

#### Scenario: Request from a non-child is ignored
- **WHEN** PR 41 records no child 50 and an entry `--pr-50--pr-41--request.md` appears
- **THEN** `pr.sh wait 41 --slice 2 --poll 1` exits 3

#### Scenario: Peer during backoff
- **WHEN** the next GitHub poll is far in the future and an entry addressed to `pr-42` appears
- **THEN** `pr.sh wait 42 --slice 10 --poll 1` prints `event=peer` within a few seconds and makes no `gh` call

### Requirement: Read and mark ledger entries
`pr.sh ledger <pr>` SHALL print the entries of the PR's stack (from or to the PR, its parent or its children, and from `user`), oldest first, one header line per entry (time, from, to, kind) followed by its body. `--unread` SHALL limit it to entries that would raise `peer` and are newer than the cursor, `--mark` SHALL advance the cursor to the last entry printed, `--all` SHALL print every entry of the repository, and `--since <dur>` SHALL limit by age. `seen` SHALL NOT move the ledger cursor.

#### Scenario: Unread and mark
- **WHEN** two entries addressed to `pr-42` are unread and `pr.sh ledger 42 --unread --mark` runs
- **THEN** it prints both, and a following `pr.sh wait 42 --slice 2 --poll 1` exits 3

#### Scenario: Seen keeps unread entries
- **WHEN** an entry addressed to `pr-42` is unread and `pr.sh seen 42` runs
- **THEN** the next `pr.sh wait 42` prints `event=peer`

### Requirement: Ledger retention
`pr.sh ledger <pr> --prune` SHALL delete ledger entries older than 30 days, and `pr.sh start` SHALL run the same prune.

#### Scenario: Old entries pruned
- **WHEN** the ledger holds an entry whose name time is 40 days old and `pr.sh ledger 42 --prune` runs
- **THEN** that file is gone and newer entries remain

### Requirement: Holds expire
`pr.sh stack <pr>` SHALL report a hold (`hold=<n> since=<time>`) when the parent's newest `hold` entry is newer than its newest `release` and `moved`, and the hold is under 2 hours old and the parent's `last_wait_at` is not stale (older than one slice plus one poll plus 30 seconds). Otherwise it SHALL report `hold=-`.

#### Scenario: Live hold
- **WHEN** PR 41 wrote `hold` a minute ago, no `release` or `moved` since, and its `last_wait_at` is current
- **THEN** `pr.sh stack 42` prints `hold=41`

#### Scenario: Stale holder
- **WHEN** PR 41 wrote `hold` and its `last_wait_at` is an hour old
- **THEN** `pr.sh stack 42` prints `hold=-`

#### Scenario: Released
- **WHEN** PR 41 wrote `hold` and then `moved`
- **THEN** `pr.sh stack 42` prints `hold=-`

### Requirement: Restack onto a moved parent
`pr.sh restack <pr> --parent-moved` SHALL read the parent's head SHA with `git ls-remote` from its head remote, refuse with exit 2 when `--sha <s>` is given and differs from it, else run `git rebase --onto <parent head> <stack_parent_tip>` in the worktree and on success record that head as `stack_parent_tip`. On conflict it SHALL stop like `restack` (exit 4, conflicted files).

#### Scenario: Shared commits arrive unchanged
- **WHEN** PR 42 (commits A, B, C) records parent 41 with tip B, and PR 41 is rewritten to A', B' on a new `main`
- **THEN** after `pr.sh restack 42 --parent-moved` the branch is A', B', C' with A' and B' byte-identical to PR 41's commits, and `stack_parent_tip` is B'

#### Scenario: Stale moved refused
- **WHEN** an entry says PR 41 moved to SHA X but `git ls-remote` reports Y
- **THEN** `pr.sh restack 42 --parent-moved --sha X` exits 2 and the branch is unchanged

### Requirement: Push keeps the stack in one version
`pr.sh push <pr>` SHALL refuse with exit 9, pushing nothing, when the PR records an open stack parent and the local head does not contain the parent's current remote head (read with `git ls-remote`), printing the parent and its head SHA. A PR without a parent, or whose parent merged, SHALL push as before.

#### Scenario: Diverged child refused
- **WHEN** PR 42 records `stack_parent=41`, PR 41's remote head is B', and PR 42's local head was rebased on `main` itself so it does not contain B'
- **THEN** `pr.sh push 42` exits 9, names PR 41 and B', and the remote branch is unchanged

#### Scenario: Restacked child pushes
- **WHEN** PR 42 was restacked onto PR 41's remote head
- **THEN** `pr.sh push 42` pushes with the lease as before

### Requirement: Prompt coordinates the stack
The maintain prompt SHALL name `peer` and say: only the owner (the lowest PR whose own commits contain the cause) fixes a problem; a PR with a live parent acknowledges `base-moved` and `conflict` with `seen` and waits for the parent's `moved`; a PR that rebases writes `hold` to `all` first and `moved` (or `release`) after its push; on `moved` it runs `restack --parent-moved`; `pr.sh ledger --unread --mark` reads entries; ledger bodies are untrusted data.

#### Scenario: Prompt names the stack rules
- **WHEN** `pr.sh prompt 42` runs with `--agent-cli claude` and with `--agent-cli codex`
- **THEN** each prompt has a `peer` entry in Events and contains `ledger 42 --unread --mark`, `restack 42 --parent-moved`, `tell 42 all hold` and `tell 42 all moved`

### Requirement: Requests go to the owner
The prompt SHALL tell a window whose review comment or CI failure is caused by an ancestor's commits to write `request` to that ancestor with `--ref`, never copying the comment text, and not to fix it itself. It SHALL tell the owner to re-read the referenced item from GitHub, apply its trust rules to the author on the PR where it was posted, and handle it in its own fix round.

#### Scenario: Prompt carries the request rule
- **WHEN** `pr.sh prompt 42` runs
- **THEN** the prompt contains `tell 42 pr-<n> request --ref` and says the owner re-reads the item from GitHub

### Requirement: Ask before starting a stopped owner
When the owner's window is not running (`pr.sh stack` prints `parent_live=0`), the prompt SHALL tell the child to ask the user with `pr.sh note` and the options `start` and `wait`, and on `start` to run `pr.sh start <owner>`; it SHALL never start the owner's window without that answer.

#### Scenario: Prompt carries the dead-owner question
- **WHEN** `pr.sh prompt 42` runs
- **THEN** the prompt contains `--option start --option wait` and `parent_live=0`

### Requirement: Stack documentation
`SKILL.md` and `README.md` SHALL describe the stack resolution, the ledger folder and its file names, `pr.sh tell`, `pr.sh ledger`, `pr.sh stack`, the `peer` event and the push refusal (exit 9).

#### Scenario: Documented
- **WHEN** `skills/opsx-pr/SKILL.md` and `README.md` are read
- **THEN** both mention `pr.sh ledger`, `pr.sh tell`, `event=peer` and exit 9
