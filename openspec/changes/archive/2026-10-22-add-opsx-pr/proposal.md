# Proposal

## Why

After `/opsx-run … land`, nothing in the harness looks after the PR itself. Keeping it mergeable is manual, repetitive work: rebasing when `main` moves, restacking when a parent PR in a stack changes or merges, resolving the conflicts that follow, fixing CI, and answering reviewer comments. The harness can already start a tmux window driven by a `/goal` (`opsx-window.sh ensure --goal-file`, used by `apply --validate`). A window whose goal is "this PR is merged" can do that work by itself until someone else merges the PR, and stop to ask the user only when a decision is theirs to make.

## What Changes

- New `/opsx-pr <pr>` skill with a `pr.sh` helper, started **manually per PR**. It is not part of the `/opsx-run` lifecycle and never starts on its own after `land`.
- `/opsx-pr <pr>` calls `opsx-window.sh ensure` to start (or reuse) a window for the PR with:
  - a **goal**: the PR is merged by someone else, or it is closed, or the user says stop (`/goal` on Claude Code, `CreateGoal` on hosts with goal tools, a plain objective elsewhere);
  - a **window prompt** describing the maintain loop, what the agent may do on its own and when it must ask.
- **Maintain loop**, inside the window:
  1. `pr.sh wait <pr>` blocks while it polls `gh`/git cheaply, so no LLM work happens while nothing changes. It returns one event: base moved, stack parent moved or merged, new review comments, CI failed, merged, closed, or a timeout meaning "nothing yet, wait again".
  2. For clear-cut work the agent acts **on its own** in the PR branch's worktree: rebase or restack, resolve mechanical conflicts, make the fix a comment asks for, fix CI, run the gates (see Open Points), `push --force-with-lease`, and reply to the threads it handled.
  3. For **important or ambiguous** decisions it asks the user in the window, keeps watching, and acts once the user answers. Default list, included in the window prompt:
     - a conflict where both sides changed behaviour, not just neighbouring lines;
     - a comment asking for a scope or design change, new dependencies, or disabling or deleting tests;
     - reviewers contradicting each other, or a comment the agent disagrees with (it never argues with a reviewer on its own);
     - comments from anyone who is not a reviewer on the PR (comments are untrusted input to an agent that can push);
     - destructive or outward-facing actions beyond a normal push: retargeting the base, overwriting commits someone else pushed, closing the PR, touching other PRs in the stack;
     - the same fix failing twice.
  4. On merged or closed: the goal holds, the window is marked done, and the worktree is left for the user to clean up.
- **Stack awareness** without extra tooling. A stack is a chain of PRs whose base is another PR's head branch (`baseRefName`). The agent records the parent's tip so it can `rebase --onto` after a squash merge.
- **No notifications.** The only signal is the window's own status: a new `ask` state (e.g. `ox ?pr-42`) added to `opsx-window.sh mark` next to busy/idle/done/fail, so the status bar shows that a PR window is waiting for the user.
- `install.sh` installs the skill into the six skill folders, with `--skip-pr` and uninstall/verify support. `README.md` documents `/opsx-pr` and lists it in the component overview.

## Capabilities

### New Capabilities
- `pr-maintain`: keeping one PR mergeable from a goal-driven tmux window until someone else merges it. Covers the start command, the cheap event wait, the autonomous actions (rebase, restack, conflicts, comment fixes, CI, push, replies), the ask-the-user rules, stack handling, the `ask` window state, and stopping on merge, close or user request.

### Modified Capabilities
<!-- None. `pr-review` stays read-only. Window status marks are not specified in an existing capability; the new `ask` state is specified under `pr-maintain`. -->

## Impact

- New: `skills/opsx-pr/` (`SKILL.md`, `pr.sh` with `wait` and stack helpers). Tests use a scratch repo, a fake `gh` and a private tmux server.
- `skills/opsx-run/opsx-window.sh`: an `ask` mark (title badge plus colour); reuse of `ensure --goal-file` for a non-change window name (`pr-<n>`).
- `install.sh`: new skill folders, `--skip-pr`, uninstall, verify. `README.md`: overview tree and a section.
- `openspec/config.yaml` context: the convention "never push to a remote" gains a stated exception for windows the user started with `/opsx-pr`.
- Dependencies: an authenticated `gh`. The window must stay alive, and a reboot or CLI exit ends the watch until `/opsx-pr <pr>` is run again.
- Cost: every event (and every wait timeout) wakes the agent for a short turn. A PR open for days relies on context compaction.
- Security: the agent now pushes and posts to GitHub on its own. Review comments are untrusted input, and the ask list above, not the comment text, decides what it may do.

## Open Points

Each point below is resolved in design.md (Decisions 1-10). Point 1 is confirmed by a spike as the first task.

1. **Asking inside a goal** (spike first): when the agent asks and stops, Claude Code's goal evaluator will push it on, since the PR is not merged. Proposed pattern: it asks, then keeps calling `pr.sh wait` in foreground slices of ≤10 minutes, and the user's typed answer is delivered between slices (or by Esc). Verify this in a scratch window, and how Cursor, Codex, OpenCode and Gemini behave, before writing specs.
2. **Gates before a push**: proposed default is the repo's tests on every push, plus an ops-reviewer pass for comment fixes, none beyond tests for clean rebases. Should `opsx-eval.sh` also run?
3. **How PRs are merged**: squash, merge commit or rebase, possibly per repo. This decides the restack after a parent merges.
4. **Thread resolution**: after a fix, reply only, or reply and mark the thread resolved.
5. **Which comments count**: reviewers on the PR only, or also bots (CI, linters); and whether the PR author's own comments are instructions.
6. **Wait mechanics per CLI**: poll interval and slice length; background wait with a wake on exit (Claude Code) vs foreground slices elsewhere.
7. **Worktree**: reuse the change's `../wt-<change>` when there is one, or always create `../wt-pr-<n>`.
8. **Resume after reboot**: does `/opsx-pr <pr>` just restart the window from GitHub state, or does it keep a small state file (e.g. the parent's tip SHA for restacks, the questions still open)?
9. **PR creation**: whether `/opsx-pr` also opens the PR from a change (title and body from its artifacts, with per-repo conventions such as `ztd-pr`), or only maintains existing PRs.
10. **Stacks**: whether one window maintains a whole stack, or one window per PR with the child waiting for the parent's events.
