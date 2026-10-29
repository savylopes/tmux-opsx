# Design

## Context

`pr.sh start` calls `opsx-window.sh ensure pr-<n> --prompt-file --goal-file`; for a reused Claude window `ensure` types `/goal <goal> Dispatcher steps: read <prompt> first and follow it.`, and the input lands when the current turn ends. Every PR window lookup matches `@opsx_change == pr-<n>` (pr.sh `window_in_session`, `list`, `stop`; opsx-notify Open PR link and PR reply; opsx-sessions restore). Change windows are tagged `@opsx_change=<change>`, run in the main checkout, and their branch `opsx/<change>` lives in `../wt-<change>`, which `ensure_worktree` already reuses.

## Goals / Non-Goals

**Goals:** run the maintain loop in the change window the user is in; ask before taking over a change window from elsewhere; keep notify, list, stop and restore working.

**Non-Goals:** maintaining two PRs in one window; moving a running `pr-<n>` loop into a change window; changing the loop itself.

## Decisions

1. **Same input path for both cases.** `pr.sh start --window <change>` (explicit, or implied when `$TMUX_PANE`'s window is a change window) calls `opsx-window.sh ensure <change> --prompt-file --goal-file` on the existing change window instead of `ensure pr-<n>`. When the caller is inside that window, the typed `/goal` input is queued and runs once the caller's turn ends — the skill already ends its turn right after `start`, so no special in-conversation mode is needed. The skill relays `inline window=<id>` and tells the user the loop starts when this turn ends.
2. **Candidate detection** (outside a change window, no flag): head branch `opsx/<change>` with an open window `@opsx_change=<change>` in the session, else a change window whose `../wt-<change>` worktree is on the head branch (`git worktree list --porcelain`). First match wins; exit 8 with `candidate window=<id> change=<change>`. The skill asks with two options (reuse `<change>` (recommended) / new `pr-<n>` window) and re-runs `start` with the answer.
3. **Busy guard.** Taking over a change window from another pane requires `@opsx_status` in `idle|done|fail` (not `busy`, not `ask`); refused otherwise. Its own window is exempt (the caller is the agent there).
4. **Tags.** `@opsx_pr=<n>` and `@opsx_pr_repo=<repo>` on the change window; `@opsx_change` keeps the change name so `/opsx-run` keeps working. A shared helper `pr_window_ids <n> <repo>` matches `@opsx_change==pr-<n>` OR `@opsx_pr==<n>`, both with the same `@opsx_pr_repo`; used by `start`, `list`, `stop`, `note`. opsx-notify reads `#{@opsx_pr}` next to `#{@opsx_change}` for the Open PR link and the PR reply target label.
5. **Stop.** For a change window: unset both tags, and type `/goal clear` into it through `opsx-window.sh type` (Claude Code); other CLIs get a one-line "stop maintaining PR <n>" message. Never `kill-window`.
6. **Restore.** opsx-sessions saves `@opsx_pr`/`@opsx_pr_repo` with the window; on restore it runs `pr.sh restart-input <n>` and uses its output as the first input when it exits 0, else restores the change window without PR tags.
7. **Prompt addition:** "Messages the user types in this window come first: act on them, then go back to `pr.sh wait`." Added to both window kinds.

## Risks / Trade-offs

- [Change window's own goal replaced] A change window with an active `/goal` (e.g. `--validate`) gets the maintain goal instead → the busy guard refuses while it works; from inside, the user chose it.
- [Queued input timing] From inside, the `/goal` lands only after the current turn; if the user types first, their message runs first → acceptable, documented.
- [`land` closes the window] `/opsx-run <change> land` kills a window that may be maintaining a PR → land's close output already names the window; not changed here.
