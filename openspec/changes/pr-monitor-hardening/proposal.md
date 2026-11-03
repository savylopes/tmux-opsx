## Why

`pr-monitor-subagent` landed with 13 non-blocking P2 findings from ops-reviewer, ops-security and ops-qa. Two of them can quietly stop the loop:
- After a refresh, the old monitor is still running for up to one poll. So the window starts no new monitor, and when the old one returns `superseded` it starts none either. The loop then waits for the next goal turn.
- A `--slice` near 600 s exceeds the monitor's Bash timeout.

The others are about locking, quoting, enforcement, accuracy and the docs.

## What Changes

- **Stop and refresh are told apart** (reviewer F5, QA F1). On a stop, `pr.sh wait --gen` exits 4 and prints `stopped`. On a refresh or restart it prints `superseded`. The monitor returns `stopped` or `superseded`. In the prompt, only a monitor started with the current prompt's `--gen` counts as running. On `superseded` the window starts a monitor for the current gen unless one is already running. On `stopped` it starts none. This replaces the "start only one / when unsure, start one" wording.
- **The slice fits the monitor** (reviewer F6). The Claude Code loop clamps the wait slice to 570 s, so a call always fits the 600 s Bash timeout. The monitor's prompt carries `max-calls: <n>`, where n = max(1, 1620 / slice), so a monitor's run stays at about 27 minutes whatever the slice.
- **State locking** (security F1, F2).
  - `with_state_lock` uses `flock` when it is available, else a `mkdir` lock directory. Either way it waits up to 30 s, and on a timeout it prints a `pr: state lock busy` warning on stderr before writing. It is never silent.
  - The lock is re-entrant within one process, and `write_seen` takes it once for its whole update.
- **Quoted wait command** (security F3). The wait command in the prompt quotes the `pr.sh` path and the repository path with `printf %q`.
- **Monitor enforcement** (security F4, QA F3). A PreToolUse hook in the `ops-pr-monitor` agent's frontmatter runs `skills/opsx-pr/monitor-guard.sh`, which denies every Bash command except one `pr.sh wait <n> … --gen <n>` call with no shell metacharacters.
- **`list` accuracy** (QA F2). `watch=off` replaces `watch=stale` when the last event is `merged`, `closed` or `stopped`.
- **Install and docs** (reviewer F2, F3, F4).
  - `install.sh --skip-pr` skips installing and verifying `ops-pr-monitor` and its guard, and `--uninstall` always removes them.
  - The README's manual-install block and models excerpt list the agent and `claude.pr-monitor`.
  - `openspec/config.yaml` lists `ops-pr-monitor`.
- Reviewer F1 (task 4.2 of `pr-monitor-subagent` was ticked with script coverage only) gets no code change. The live check stays with the user, and task 4.2 here keeps it listed.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `pr-maintain`: stop and refresh results, gen-scoped monitor count, slice clamp and `max-calls`, locking, quoting, the monitor guard, `watch=off`, `--skip-pr` for the monitor.

## Impact

- `skills/opsx-pr/pr.sh` (`with_state_lock`, `write_seen`, `cmd_wait`, `cmd_stop`, `loop_text`, `watch_col`), new `skills/opsx-pr/monitor-guard.sh`, `agents/opsx-pr-monitor.md`, `install.sh`, `README.md`, `openspec/config.yaml`, `skills/opsx-pr/SKILL.md`.
- `tests/test-pr.sh`, install tests, `evals/pr-maintain/`.
