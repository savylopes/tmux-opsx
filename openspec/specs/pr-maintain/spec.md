# pr-maintain Specification

## Purpose
Lets the user hand one open pull request to a goal-driven agent window that keeps it mergeable (rebase, restack, conflicts, review comments, CI) until someone else merges or closes it, asking the user only for important or ambiguous decisions.

## Requirements

### Requirement: Resolve the PR to maintain
`pr.sh resolve <pr> [--repo <dir>]` SHALL accept a PR number, `#<n>` or a PR URL and print `pr url repo head base state author` as `key=value` lines, where `repo` is `<owner>/<name>`. It SHALL exit 2 when no PR matches and fail with a message for any other argument or outside a git repository without `--repo`.

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
`pr.sh open [<branch>] --title <t> --body-file <f> [--base <b>] [--repo <dir>]` SHALL push the branch to `origin` and create the PR with `gh pr create`, defaulting to the current branch and the repository's default base, then print `pr=<n>` and `url=<url>`. When the branch already has an open PR it SHALL print that PR and create nothing. It SHALL refuse, pushing nothing, a branch that is the repository's default branch or equal to `--base`.

#### Scenario: New PR
- **WHEN** `pr.sh open feat-a --title T --body-file b.md` runs and `feat-a` has no PR
- **THEN** the fake `gh` records one `pr create` call with head `feat-a` and the output has a `pr=` line

#### Scenario: Existing PR
- **WHEN** `feat-a` already has open PR 42
- **THEN** `pr.sh open feat-a --title T --body-file b.md` prints `pr=42` and records no `pr create` call

#### Scenario: Default branch refused
- **WHEN** `pr.sh open main --title T --body-file b.md` runs and `main` is the default branch
- **THEN** it exits non-zero and records no `pr create` call

### Requirement: Start a maintain window
`pr.sh start <pr> [--repo <dir>] [--agent-cli <cmd>]` SHALL refuse a PR that is not open or whose head is in a fork (`isCrossRepository`), record the PR's state, and call `opsx-window.sh ensure pr-<n>` with a prompt file and a goal file, reusing the window when it already exists. The goal SHALL say the PR is merged by someone else, closed, or the user said stop.

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
- **WHEN** `pr.sh start 45` runs for an open PR whose head is `main` of a fork (`isCrossRepository=true`)
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
The window prompt SHALL allow the agent, without asking, to rebase or restack, resolve mechanical conflicts, make the change a review comment clearly asks for, fix failing CI, push only through `pr.sh push <pr>` (see Push with an explicit lease), reply to the threads it handled and mark them resolved, and retarget the base to the parent's base after a parent merged. It SHALL forbid merging the PR and any plain `--force` push.

#### Scenario: Prompt lists allowed and forbidden actions
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt contains `--force-with-lease`, says the agent never merges the PR, and forbids plain `--force`

### Requirement: Push with an explicit lease
`pr.sh push <pr>` SHALL push the worktree's head branch to `origin` with `--force-with-lease=<head>:<head SHA recorded in the state file>`, exit 5 when that lease fails, and record the pushed SHA as `head_sha` on success.

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
`pr.sh list` SHALL print one line per PR with a state file: repo, PR, window status (or `none`) and the last event. `pr.sh stop <pr>` SHALL close window `pr-<n>` and keep the state file and worktree.

#### Scenario: List shows a running PR
- **WHEN** PR 42 was started and its window exists
- **THEN** `pr.sh list` prints a line containing `42` and the window status

#### Scenario: Stop closes the window
- **WHEN** `pr.sh stop 42` runs
- **THEN** no `pr-42` window remains and the state file still exists

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
