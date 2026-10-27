# Tasks

## 1. Test fixtures

- [x] 1.1 In `tests/test-pr.sh`, add a fork block: a second bare repo `upstream.git` (`acme/app`) and a fork bare repo (`me/app`) cloned into a checkout with `origin` = fork URL and `upstream` = upstream URL, plus a `dany` remote; remote URLs must parse to `owner/name` (e.g. `file:///…/github.com/me/app.git` style or a URL-to-slug override env read only by tests); extend the fake `gh` to serve PR 50 (head `me:feat-f`), 51 (head `dany:feat-d`), 52 (head `me:main`) from `acme/app` with `headRepository`/`headRepositoryOwner`, `repos/me/app` with `parent.full_name=acme/app`, and to log `-R` and `--head` of `pr create`; the existing same-repo block stays untouched

## 2. Repository resolution

- [x] 2.1 Replace `repo_slug` with `resolve_repos` setting `SLUG` (base), `BASE_REMOTE`, `FORK_SLUG` per design Decision 1-2 (URL parsing for https/ssh, `upstream` first, `origin`'s parent via `gh api`, fallback `gh repo view`); verify: plain checkout → `repo=o/app base_remote=origin head_remote=origin` (existing tests still pass), fork checkout → `repo=acme/app base_remote=upstream`, no `upstream` remote → `repo=acme/app` and empty `base_remote=`
- [x] 2.2 `cmd_resolve` prints `head_repo=`, `base_remote=`, `head_remote=` (head remote empty for a refused fork); verify with PR 42, 50 and 51

## 3. Fork acceptance

- [x] 3.1 Rewrite `refuse_fork` to accept a cross-repository PR only when its head repo equals `FORK_SLUG`, set `HEAD_REMOTE` (base remote for same-repo, `origin` for the user's fork), and refuse a fork head named like the base repo's default branch or the PR's base; messages name the fork and `origin`; apply it in `start`, `restart-input`, `worktree`, `restack`, `push`; verify: PR 50 starts a window and writes state, PR 51 and 52 are refused by all five with no window/state/worktree, existing PR 45 test still refused

## 4. Git operations on the right remote

- [x] 4.1 `remote_tip` and `restack` use `BASE_REMOTE` (fail naming `git remote add upstream …` when empty); `ensure_worktree` fetches/tracks `HEAD_REMOTE/<head>` and refuses a local `<head>` branch tracking another remote; `push` pushes to `HEAD_REMOTE` with the existing lease; verify: restack 50 after `upstream/main` moved prints `onto=upstream/main`; push 50 updates the fork's `feat-f` and creates nothing on upstream; a third-party commit on the fork's `feat-f` makes push exit 5 and stays; a local `feat-f` tracking `upstream` is refused by `worktree 50`
- [x] 4.2 Window prompt: base-moved/head-moved/restack lines use the resolved remotes (`git fetch <base remote>`, `git rebase <base remote>/<base>`, reset to `<head remote>/<head>`); verify `pr.sh prompt 50` contains `upstream/` for the base and `origin/feat-f` for the head, and `pr.sh prompt 42` still says `origin`

## 5. Open from the fork

- [x] 5.1 `cmd_open` in a fork checkout: push to `origin`, `gh pr create -R <base> --head <fork owner>:<branch>`, default base from the base repo, existing PR found by head branch filtered to the fork owner; verify: `open feat-f` records one `pr create` with `-R acme/app` and `--head me:feat-f` and the upstream bare repo has no `feat-f`; an existing PR 50 is printed without a create; `open main` refused

## 6. Docs and checks

- [x] 6.1 Update the `pr.sh` header comment, `skills/opsx-pr/SKILL.md` (fork refusal wording, fork checkouts) and README "Forks are refused" paragraph → fork checkouts: base from `upstream`, only `origin` forks maintained, other forks refused, gh active account vs fork push credentials note
- [x] 6.2 Add `evals/pr-maintain/` checks for the new and modified scenarios; run `tests/test-pr.sh`, `opsx-eval.sh --change add-pr-forks` and `openspec validate add-pr-forks --strict`, all passing
