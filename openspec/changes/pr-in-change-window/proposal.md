## Why

`/opsx-pr <pr>` always opens (or reuses) a separate `pr-<n>` window with a fresh agent. When the PR's branch is an OpenSpec change that already has an `/opsx-run` window, that window's agent knows the change (design, specs, tasks, what it already tried) and is where the user talks about it; a second window splits the context and the feedback.

## What Changes

- **Inside a change window:** `/opsx-pr <pr>` run from an `/opsx-run` change window (tagged `@opsx_change=<change>`, not `pr-<n>`) opens no new window: the maintain loop runs in that window and conversation. The user gives feedback by typing there; the prompt says the user's messages override the PR loop.
- **Outside a change window:** when the PR's head branch is `opsx/<change>`, or is the branch of the worktree of a change whose window is open in the session, `/opsx-pr` asks the user whether to reuse that window or open `pr-<n>`. `pr.sh start` reports the candidate and exits without starting; the skill asks and re-runs with `--window <change>` or `--new-window`.
- A reused change window must be idle (not busy, not asking) unless it is the caller's own window, and must not already maintain another PR.
- A change window maintaining a PR is tagged `@opsx_pr=<n>` and `@opsx_pr_repo=<repo>`; every lookup of a PR window (`pr.sh list`, `note`, `stop`, `start` reuse, the Open PR button, PR answer delivery, session restore) also finds it.
- `pr.sh stop <pr>` on a change window ends the maintain goal and removes the PR tags, and never closes the change window.
- With no related change window, behaviour is unchanged.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `pr-maintain`: start in the caller's change window, ask before reusing a related change window, the `@opsx_pr` tag, stop without closing a change window.
- `notify-actions`: Open PR link and PR answer delivery for a change window tagged `@opsx_pr`.
- `session-restore`: a restored change window tagged `@opsx_pr` resumes the maintain loop.

## Impact

- `skills/opsx-pr/pr.sh` (`start`, `stop`, `list`, `note`, window lookups, prompt), `skills/opsx-pr/SKILL.md` (the ask step), `skills/opsx-run/opsx-notify.sh` (link and PR reply target), `skills/opsx-run/opsx-sessions.sh` (restore), README.
- `tests/test-pr.sh`, `tests/test-notify.sh`, `tests/test-sessions.sh` (or the existing restore suite), `evals/`.
