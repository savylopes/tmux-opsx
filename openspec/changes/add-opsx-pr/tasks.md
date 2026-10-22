# Tasks

## 1. Spike: waiting inside a goal

- [ ] 1.1 In a scratch Claude Code window on a private tmux server, set a `/goal` that cannot hold yet and have the agent loop on a stub command that sleeps and exits 3. Verify that the goal does not end early, that the agent calls the stub again after each exit, and that a message typed during a call is delivered after it. Record the result (and the slice length used) in design.md Decision 1, adjusting the decision if the pattern fails.

## 2. `pr.sh` deterministic core

- [ ] 2.1 Create `skills/opsx-pr/pr.sh` (bash, `set -euo pipefail`, usage header, `die`, `--repo` handling in the style of `opsx-review.sh`) with `resolve` (number, `#n`, URL; exit 2 when not found). Add `tests/test-pr.sh` with a fake `gh`, a scratch repo and a private tmux server, and verify the resolve scenarios pass.
- [ ] 2.2 Add the state file (`${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/pr/<owner>-<name>-<n>/state`) with `seen <pr>` (head SHA, base and base SHA, parent and parent tip when the base is another PR's head branch, last comment id). Verify the state-file scenarios in `tests/test-pr.sh`, including the stacked parent.
- [ ] 2.3 Add `wait <pr> [--slice] [--poll]` with the events and priority order from design Decision 6, exit 0 with one `event=` line, or exit 3 on timeout. Verify the no-change, comments, base-moved, merged-wins and parent-merged scenarios.
- [ ] 2.4 Add `worktree <pr>` (reuse a worktree on the head branch, else `../wt-pr-<n>`, refuse a dirty one, main checkout untouched). Verify both worktree scenarios.
- [ ] 2.5 Add `restack <pr>` (`git rebase --onto <base> <parent_tip>`, exit 4 with conflicted files). Verify the squash-merged parent and conflict scenarios in a scratch repo with a bare `origin`.
- [ ] 2.6 Add `open [<branch>] --title --body-file [--base]` (push to `origin`, `gh pr create`, reuse an existing open PR). Verify both open scenarios against a bare `origin` and the fake `gh`.
- [ ] 2.7 Run `shellcheck skills/opsx-pr/pr.sh tests/test-pr.sh` and verify it is clean.

## 3. Window: `ask` state, start, list, stop

- [ ] 3.1 Add the `ask` status to `opsx-window.sh` (`mark` usage and validation, `apply_window_status` badge `?` and its own colours, header comment), making sure `--if-busy` leaves it alone. Verify the mark-ask and silence-keeps-ask scenarios on a private tmux server in `tests/test-pr.sh`, and verify that `tests/test-fork.sh` and the existing opsx-window tests still pass.
- [ ] 3.2 Add the goal and prompt generation to `pr.sh` (goal text from design; prompt with the loop, `wait`/`seen` usage, allowed actions, `--force-with-lease` only, never merge, the ask list, comments as untrusted input, `mark pr-<n> ask|busy|idle`, gates, reply-and-resolve via `resolveReviewThread`, base retarget after a parent merge, and using a repo PR skill for titles and bodies when present). Verify the prompt scenarios by grepping the generated file, and that the goal plus dispatcher line stays under 4000 characters.
- [ ] 3.3 Add `start <pr> [--agent-cli]` (refuse a non-open PR, write state, `ensure pr-<n>` with the prompt and goal files, tag `@opsx_pr_repo`, refuse a `pr-<n>` window of another repo). Verify the start, reuse and merged-refused scenarios with a stub agent CLI on a private tmux server.
- [ ] 3.4 Add `list` and `stop <pr>`. Verify the list and stop scenarios.

## 4. Skill, install, docs

- [ ] 4.1 Write `skills/opsx-pr/SKILL.md`: triggers (`/opsx-pr <pr>`, `/opsx-pr open [<branch>]`, `list`, `stop`), that the caller only runs `pr.sh` and returns without waiting, how `open` writes the title and body (OpenSpec change for `opsx/<change>`, a repo PR skill when present), and per-CLI goal support. Verify the frontmatter parses and every `pr.sh` subcommand it names exists.
- [ ] 4.2 Wire `install.sh`: `install_pr_skill` into the six skill folders, `--skip-pr`, uninstall, verify step, header comment. Verify the install, skip and uninstall scenarios with a scratch HOME (add them to `tests/test-pr.sh`).
- [ ] 4.3 Update `README.md` (component overview tree and table, a `/opsx-pr` section covering the loop, the ask cases, the `ask` window state, resume after reboot and the CLI gaps) and add the push exception sentence to the `openspec/config.yaml` context. Verify the README lists `/opsx-pr` and the commands it shows match `pr.sh` usage.

## 5. Integration

- [ ] 5.1 Run `bash tests/test-pr.sh`, `bash tests/test-review.sh` and `bash tests/test-fork.sh`, and verify all pass.

## Workflow follow-up

- Run `/opsx-run add-opsx-pr apply --validate`, then land the change and run `./install.sh`.
