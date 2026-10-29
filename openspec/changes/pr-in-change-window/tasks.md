# Tasks

## 1. Window lookup and tags

- [ ] 1.1 Add `pr_window_ids <n> <repo>` in `pr.sh` matching `@opsx_change==pr-<n>` or `@opsx_pr==<n>` with the same `@opsx_pr_repo`; use it in `start` reuse, `list`, `stop`, `note`; verify in `tests/test-pr.sh` on a private tmux server: a change window tagged `@opsx_pr=42 @opsx_pr_repo=o/app` is listed with its status, and existing `pr-42` tests still pass

## 2. Start in a change window

- [ ] 2.1 `pr.sh start` detects the caller's change window from `$TMUX_PANE`, refuses one with `@opsx_pr` of another PR, tags it, and runs `ensure <change>` with the prompt and goal files; prints `inline window=<id>`; verify: start from window `add-thing` → no `pr-42`, tags set, its pane got the `/goal` line, state written; window already on PR 41 → non-zero naming 41
- [ ] 2.2 Add `--window <change>` and `--new-window`; outside a change window without a flag, detect a candidate (head `opsx/<change>` with an open change window, else a change worktree on the head branch) and exit 8 with `candidate window=<id> change=<change>`, starting nothing; `--window` refuses a `busy` or `ask` window; verify the five Ask-before-reusing scenarios
- [ ] 2.3 Prompt line: user messages in this window come first, then back to `pr.sh wait`; verify `pr.sh prompt 42` contains it

## 3. Stop

- [ ] 3.1 `pr.sh stop` on a change window unsets `@opsx_pr`/`@opsx_pr_repo`, types `/goal clear` (Claude) or a stop line (other CLIs) through `opsx-window.sh type`, never kills it; verify the window survives without tags and the state file stays

## 4. Notify and restore

- [ ] 4.1 opsx-notify: Open PR link and PR reply target for a window with `@opsx_pr`; verify with fake `curl` (Open PR URL) and a listener reply `:2` typed once into the change window
- [ ] 4.2 opsx-sessions: save and restore `@opsx_pr`/`@opsx_pr_repo`; restored window gets `pr.sh restart-input <n>` as first input while open, else plain change restore without tags; verify both scenarios with the existing restore test harness

## 5. Skill, docs, checks

- [ ] 5.1 `skills/opsx-pr/SKILL.md`: on exit 8 ask the user (reuse `<change>` (Recommended) / new `pr-<n>` window) and re-run with `--window`/`--new-window`; relay `inline window=` and that the loop starts when this turn ends; README PR maintainer section
- [ ] 5.2 Run `tests/test-pr.sh`, `tests/test-notify.sh`, the restore suite and `openspec validate pr-in-change-window --strict`, all passing
