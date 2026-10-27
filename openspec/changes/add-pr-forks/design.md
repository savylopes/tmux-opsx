# Design

## Context

`pr.sh` assumes one repository: `SLUG` comes from `gh repo view` in the checkout, every git operation uses `origin`, and `refuse_fork` rejects any PR with `isCrossRepository=true`. In a fork checkout (FACIS: `origin` = `blopes-atals/facis-zero-trust-demonstrator`, `upstream` = `eclipse-xfsc/…`, extra remotes `dany`, `luis`) `gh repo view` has no default repository set, and every PR the user owns is cross-repository, so nothing works. `gh` is logged in with two accounts (`savylopes` active, `blopes-atals` inactive); the fork belongs to `blopes-atals`.

## Goals / Non-Goals

**Goals:**
- Maintain and open PRs whose head is on the user's fork (`origin`), with the PR on the upstream repository.
- Keep same-repository checkouts behaving exactly as today (same state paths, same remote, same messages apart from the fork refusal wording).

**Non-Goals:**
- PRs from teammates' or strangers' forks, even with `maintainerCanModify` (the user asked for their own forks only).
- Auto-adding remotes, or switching the active `gh` account.
- Stacks across forks (GitHub needs the base branch in the base repository; parent detection stays same-repository only, as today).

## Decisions

1. **Base repository resolution** (replaces `repo_slug`'s `gh repo view`, which needs `gh repo set-default` in multi-remote checkouts). Each remote's `owner/name` is parsed from its URL (https and ssh forms). Base slug, in order: the `upstream` remote; else `origin`'s GitHub parent (`gh api repos/<origin> --jq .parent.full_name`) when `origin` is a fork; else `origin`. `BASE_REMOTE` is the first remote whose URL names the base slug (`upstream` first), empty when none. Commands that need base branches (`seen`/`wait` base tip, `restack`) fail with "add the base repository as a remote: git remote add upstream https://github.com/<base>.git" when it is empty; `resolve`, `start` and `push` do not need it. Falls back to `gh repo view` when `origin`'s URL is not a GitHub URL.
2. **My fork = `origin`.** `FORK_SLUG` is `origin`'s `owner/name` when it differs (case-insensitively) from the base slug. A cross-repository PR is accepted only when `headRepositoryOwner.login + "/" + headRepository.name` equals `FORK_SLUG`. Not tied to the `gh` login, because the active account (`savylopes`) differs from the fork owner (`blopes-atals`). `PR_FIELDS` adds `headRepository`.
3. **Head remote.** Same-repo PR → `BASE_REMOTE`. User's fork PR → `origin`. Every git call that touched `origin` is split into `$HEAD_REMOTE` (fetch/track/push the head branch, `head-moved`) and `$BASE_REMOTE` (`remote_tip`, `restack` target, `base-moved`). In a plain checkout both are `origin`, so behaviour is unchanged.
4. **Branch-name safety.** Refuse a fork PR whose head name equals the base repository's default branch or the PR's base branch. In `ensure_worktree`, when a local branch `<head>` exists, require its upstream to be `<HEAD_REMOTE>/<head>` (or no upstream and same SHA as the remote branch); otherwise refuse instead of reusing a branch that tracks another remote.
5. **`open` in a fork checkout.** Push to `origin`; `gh pr create -R <base> --head <fork owner>:<branch> --base <default of base>`; the existing-PR check uses `gh pr list -R <base> --head <branch> --json number,url,headRepositoryOwner` filtered to the fork owner.
6. **Prompt.** The maintain prompt names `BASE_REMOTE` and `HEAD_REMOTE`: base-moved becomes `git fetch <base remote>` + `git rebase <base remote>/<base>`; head-moved resets to `<head remote>/<head>`. `resolve` prints `head_repo`, `base_remote`, `head_remote`.
7. **State key** stays the base slug (`<owner>-<name>-<n>`), so PR numbers never collide and existing state survives.

## Risks / Trade-offs

- [Two gh accounts] Comments/replies go out as the active `gh` account, pushes as `origin`'s git credentials → README note; out of scope to switch.
- [Upstream remote that is not the parent] A remote named `upstream` pointing elsewhere would be taken as the base → the URL check in `setup_pr` still refuses a PR URL of another repo; documented.
- [Extra `gh api` call] One `repos/<origin>` lookup per command only when no `upstream` remote exists; cheap, and failure falls back to `origin` as base.
- [Test complexity] `tests/test-pr.sh` needs a second bare repo; keep the fork fixtures in their own block so the existing suite is untouched.
