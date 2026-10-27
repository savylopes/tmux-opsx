## ADDED Requirements

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

## MODIFIED Requirements

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

### Requirement: Push with an explicit lease
`pr.sh push <pr>` SHALL push the worktree's head branch to the PR's head remote (`origin` for same-repository PRs in a plain checkout and for PRs from the user's fork) with `--force-with-lease=<head>:<head SHA recorded in the state file>`, exit 5 when that lease fails, and record the pushed SHA as `head_sha` on success.

#### Scenario: Push never overwrites someone else's commit
- **WHEN** someone pushes to the PR branch after the last `pr.sh seen`, the worktree has fetched it, and `pr.sh push 42` runs with a rewritten local branch
- **THEN** it exits 5 and the branch on `origin` still holds their commit

### Requirement: Restart input after a restore
`pr.sh restart-input <pr> [--repo <dir>]` SHALL refuse, like `start`, a PR that is not open or whose head is in a fork other than the user's own, exiting non-zero and naming the state or the fork. For an open PR it SHALL rewrite the prompt and goal files, keep the state file (open `ask=` questions included), and print the maintain window's first input (`/goal …` with the dispatcher steps on Claude Code). It SHALL not create, type into or retag any tmux window.

#### Scenario: Open PR prints the first input
- **WHEN** `pr.sh restart-input 42` runs for open PR 42 with no tmux server
- **THEN** it exits 0, prints a line starting with `/goal` that names PR 42, and the state file still holds its earlier `last_comment_id=`

#### Scenario: Merged PR refused
- **WHEN** `pr.sh restart-input 41` runs for a PR whose state is `MERGED`
- **THEN** it exits non-zero, names `MERGED`, and prints no input
