# Design

## Context

See proposal.md (Why). The pieces this builds on already exist:

- `opsx-window.sh ensure <name> --prompt-file <f> --goal-file <f>` starts or reuses a tmux window keyed by `@opsx_change=<name>`. On Claude Code its first input becomes `/goal <condition> Dispatcher steps: read <prompt> …` (capped at 4000 characters); other CLIs get the prompt only. `ensure` never checks that `<name>` is an OpenSpec change, so `pr-<n>` works as a window name.
- `opsx-window.sh mark` knows `busy|done|fail|idle`. Busy windows fall back to idle after pane silence through `mark … idle --if-busy`, which already leaves non-busy states alone.
- `opsx-review.sh` shows the house style for a `gh`-backed helper: `key=value` output, distinct exit codes, `--repo`, scratch-repo tests with a fake `gh` (`tests/test-review.sh`).
- `install.sh` installs `/opsx-review` into six skill folders with `install_review_skill`, `--skip-review`, uninstall and verify. `/opsx-pr` copies that pattern.

## Goals / Non-Goals

**Goals:**
- All deterministic work (resolve, open, state, waiting, worktree, restack, list, stop) lives in `pr.sh`, so it is testable without an LLM. The agent only does the judgement work: conflict resolution, comment fixes, replies, deciding when to ask.
- No LLM work while a PR is quiet.

**Non-Goals:**
- Merging the PR, or approving it.
- Maintaining a whole stack from one window. Each PR gets its own window.
- Notifications outside tmux, and any scheduler (cron, `/loop`).
- Writing PR titles and descriptions to a repo's conventions. `open` takes the title and body as given; the skill tells the agent to use a repo's own PR skill (e.g. `ztd-pr`) to write them when one exists.

## Decisions

Decisions on the proposal's open points, then the main mechanics.

1. **Asking inside a goal → wait in slices.** After asking, the agent marks the window `ask` and keeps calling `pr.sh wait` in the foreground with a slice under the CLI's tool timeout (default `--slice 540`, `--poll 60`). Exit 3 (timeout) means "call wait again". The user's typed answer arrives between slices (or the user presses Esc). When the goal evaluator sees "not merged" at a stop, the agent's next step is another wait, so the goal never spins. *Alternative*: a background wait that wakes the agent on exit. That is Claude-only and races the goal evaluator at every stop, so it was rejected for the default. The first task is a spike that confirms the slice pattern in a scratch Claude window before the prompt is finalised.
2. **Gates → tests always, reviewer for fixes.** Tests before any push that changes code (found from the repo's README, AGENTS.md, Makefile or package scripts; run through `opsx-dev.sh` when `.opsx/dev.yaml` exists). An ops-reviewer pass before pushing a comment or CI fix. A clean rebase or restack needs only tests. `opsx-eval.sh` is not run; it judges OpenSpec scenarios, not a PR's review feedback.
3. **Merge style → no question needed.** `restack` always runs `git rebase --onto <new base> <recorded parent tip>`. That drops the parent's commits whether the parent was squashed, merge-committed or rebase-merged, so the helper never needs to know the repo's merge style. The parent tip is recorded at `start`, and again on every `parent-moved` event (`pr.sh seen`).
4. **Thread resolution → reply and resolve.** The user asked for maximum autonomy: on a thread it fixed, the agent replies (what changed, with the commit SHA) and resolves the thread (GraphQL `resolveReviewThread`). Threads it asked the user about stay open until the user answers.
5. **Which comments count → PR author, reviewers, write access.** Comments from the PR author, requested or submitted reviewers and users with write permission are acted on. Anyone else triggers an ask. Bot comments (linters) are acted on only when clear-cut. CI failures come from checks (`ci-failed`), not comments.
6. **Wait mechanics.** `pr.sh wait` polls `gh pr view --json state,headRefOid,baseRefName,…`, the base tip from `git ls-remote`, review comments through `gh api` (highest id), and `gh pr checks`. One event per call, in priority order `merged > closed > parent-merged > parent-moved > base-moved > head-moved > ci-failed > comments`, so one wake handles the most important change first. `head-moved` covers pushes by someone else. The agent runs `pr.sh seen` after handling an event so the next wait starts from the new state.
7. **Worktree → reuse the branch's worktree, else `../wt-pr-<n>`.** `git worktree list --porcelain` finds a worktree already on the head branch (e.g. the change's `../wt-<change>`). Otherwise `pr.sh` adds `../wt-pr-<n>` on that branch (tracking `origin/<head>`). The main checkout is never switched.
8. **Resume after reboot → re-run `/opsx-pr <pr>`.** The state file holds everything a new window needs (SHAs, parent tip, last comment id, last event, open questions as `ask=` lines). `start` on an existing state file keeps it and refreshes nothing until the first `wait`, so events that happened while nothing was watching are still reported.
9. **PR creation → `pr.sh open`, maintenance → `pr.sh start`.** `/opsx-pr open [<branch>]` pushes and creates the PR (title and body written by the agent, from the OpenSpec change when the branch is `opsx/<change>`), then starts maintaining it. `/opsx-pr <pr>` maintains an existing PR.
10. **Stacks → one window per PR.** A child PR's window notices `parent-moved`/`parent-merged` by itself. After a parent merge it restacks, retargets its base to the parent's base (`gh pr edit --base`), records the new state and pushes. No cross-window coordination is needed.

Other mechanics:

- **Window name `pr-<n>`.** Window names are per tmux session, and the session is per project, so two repos with the same PR number in one session would clash. `start` refuses when a `pr-<n>` window belongs to another repo (`@opsx_pr_repo` tag).
- **Goal text.** `PR <owner>/<name>#<n> is MERGED by someone else, or CLOSED, or the user said stop in this window. Never merge it yourself.` The prompt carries the loop, the allowed actions, the ask list and the gates. It is generated from a heredoc in `pr.sh` so tests can grep it.
- **`ask` mark.** A new status in `apply_window_status`: badge `?`, a violet colour pair, never touched by `--if-busy`. The agent marks `busy` when it starts handling an event, `ask` after asking, and `idle` while waiting with no question open.
- **Pushing exception.** `openspec/config.yaml` context says "never push to a remote". The change adds one sentence: `/opsx-pr` windows push the PR branch with `--force-with-lease` and post to the PR, because the user started them for that.

## Risks / Trade-offs

- [The goal evaluator may not accept "waiting" as progress and stop the window early] → spike first (task 1). Fallback: the goal says that a wait returning 3 is the expected idle step.
- [Prompt injection through review comments, now that the agent pushes] → author allowlist, the ask list, comments treated as data, `--force-with-lease` only, never merge.
- [A long-lived window keeps paying tokens for slice timeouts] → poll in bash, ~6 short turns an hour at the default slice. `--slice` can be raised on CLIs with longer tool timeouts.
- [Force-push over a reviewer's pushed commit] → `head-moved` is detected before any work, and overwriting others' commits is an ask case. `--force-with-lease` is the backstop.
- [Window dies on reboot or CLI exit] → state file plus re-running `/opsx-pr <pr>`. `pr.sh list` shows PRs whose window is `none`.
- [CLIs without goals (Gemini) or with weaker tool timeouts] → the prompt keeps the objective as text; documented in the README.

## Migration Plan

Additive: a new skill and one new mark state. Rollback is `install.sh --uninstall` or `--skip-pr`, and existing windows and marks are unaffected.

## Open Questions

- The exact violet colours for the `ask` state. They are cosmetic and can be picked during apply.
