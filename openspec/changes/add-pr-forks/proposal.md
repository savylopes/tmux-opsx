## Why

In fork-based projects (e.g. FACIS: `origin` = the user's fork `blopes-atals/…`, `upstream` = `eclipse-xfsc/…`, plus teammates' fork remotes) every PR the user opens lives on the upstream repository with its head on the user's fork (`isCrossRepository=true`). `/opsx-pr` refuses all of those today, so it cannot maintain any of the user's PRs there, and `pr.sh open` pushes to `origin` but creates the PR on whatever `gh` resolves, which fails or targets the fork.

## What Changes

- `pr.sh` resolves two repositories per checkout: the **base repository** where PRs live (the `upstream` remote when present, else `origin`'s GitHub parent when `origin` is a fork, else `origin`) and the **user's fork** (`origin`, when it differs from the base repository). All `gh` calls use the base repository; base branches are fetched and rebased from the base repository's remote.
- A PR whose head is in a fork is maintained **only when that fork is the `origin` repository** (the user's own fork). PRs from any other fork (teammates' remotes such as `dany`, `luis`, or strangers) stay refused, with a message naming the fork and `origin`.
- For a fork PR, `worktree`, `restack`, `push` and the `head-moved` handling use the `origin` remote for the head branch, and the base remote (`upstream/<base>`) for the base. Same-repository PRs keep using one remote, as today.
- A fork PR whose head branch name is the base repository's default branch or equal to its base branch is refused (a fork's `main` must still never map onto a local `main`).
- `pr.sh resolve` adds `head_repo=`, `base_remote=` and `head_remote=` lines; the window prompt names the two remotes so the agent fetches and rebases from the right one.
- `pr.sh open` in a fork checkout pushes the branch to `origin` and creates the PR on the base repository with `--head <fork owner>:<branch>`; it finds an existing PR by head owner and branch.
- README and the `/opsx-pr` skill describe fork checkouts.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `pr-maintain`: resolving the base and fork repositories, opening a PR from the user's fork, starting/restart-input/worktree/restack/push accepting PRs from the user's own fork and still refusing other forks, push to the fork remote with the lease.

## Impact

- `skills/opsx-pr/pr.sh` (repo/remote resolution, `refuse_fork`, `ensure_worktree`, `cmd_restack`, `cmd_push`, `cmd_open`, `cmd_resolve`, `remote_tip`, window prompt), `skills/opsx-pr/SKILL.md`, `README.md` (PR maintainer section).
- `tests/test-pr.sh`: a second bare repo as `upstream`, fork PR fixtures in the fake `gh`.
- `evals/pr-maintain/` checks for the new scenarios.
- No change to state file location (still keyed by the base repository `<owner>-<name>-<n>`), so existing same-repo state stays valid.
- Comments and thread replies are posted with `gh`'s active account; the fork push uses the git credentials of `origin`. Making those the same account is left to the user (README note).
