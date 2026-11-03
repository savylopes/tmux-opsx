## Why

`pr-monitor-subagent` landed with 13 non-blocking P2 findings from ops-reviewer, ops-security and ops-qa. Two of them can quietly stop the loop:
- After a refresh, the old monitor is still running for up to one poll. So the window starts no new monitor, and when the old one returns `superseded` it starts none either. The loop then waits for the next goal turn.
- A long wait call in the monitor is moved to the background. Claude Code moves a subagent's Bash call to the background after 180 s, whatever its `timeout`. The monitor then replies early with prose, and each such reply wakes the window (about every 3-9 minutes instead of once per ~27-minute run). In a live PR 48 window it also took the completion notification for a new prompt and returned `error: not a pr.sh wait command`. An idle hour cost about 2-2.5 times the foreground loop's tokens.

The others are about locking, quoting, enforcement, accuracy and the docs.

## What Changes

- **Stop and refresh are told apart** (reviewer F5, QA F1). On a stop, `pr.sh wait --gen` exits 4 and prints `stopped`. On a refresh or restart it prints `superseded`. The monitor returns `stopped` or `superseded`. In the prompt, only a monitor started with the current prompt's `--gen` counts as running. On `superseded` the window starts a monitor for the current gen unless one is already running. On `stopped` it starts none. This replaces the "start only one / when unsure, start one" wording.
- **The slice fits the monitor** (reviewer F6, review round 2 F1, F6). The Claude Code loop clamps the wait slice to 170 s, so one call ends before Claude Code's 180 s auto-background limit for a subagent's Bash call. `pr.sh wait` keeps its wall time within the slice: its deadline counts from its start, and it starts no poll round that would end after the deadline. The monitor's prompt carries `max-calls: <n>`, where n = max(1, 1620 / slice) capped at 30 (170 s → 9), and the `idle` line of the prompt names the effective run (calls × slice, about 25 minutes at 170 s).
- **The monitor never replies early** (round 2 F1). The agent file says to return nothing before the one final line. If a call is still moved to the background, the monitor waits for its completion notification, takes the exit code from it, reads the output file it names when it needs the `event=` or `stopped` line, and goes on with the loop. The notification is not a new prompt. The window's prompt says that an interim or non-matching monitor result is not a reason to start a monitor.
- **State locking** (security F1, F2).
  - `with_state_lock` uses `flock` when it is available, else a `mkdir` lock directory. Either way it waits up to 30 s, and on a timeout it prints a `pr: state lock busy` warning on stderr before writing. It is never silent.
  - A stale `mkdir` lock (older than 120 s) is renamed before it is removed, so only one process breaks it (round 2 F5).
  - The lock is re-entrant within one process, and `write_seen` takes it once for its whole update.
- **Quoted wait command** (security F3). The wait command in the prompt quotes the `pr.sh` path and the repository path with `printf %q`.
- **Monitor enforcement** (security F4, QA F3, round 2 F4). A PreToolUse hook in the `ops-pr-monitor` agent's frontmatter runs `skills/opsx-pr/monitor-guard.sh`. It denies every Bash command except two: one `<installed pr.sh> wait <n> … --gen <n>` call with no shell metacharacters, where the path must be the `pr.sh` next to the guard (absolute, no relative path, no assignment prefix), and `cat` or `tail -n <n>` of one Claude Code task output file (`/tmp/claude-<uid>/<project>/<session>/tasks/<id>.output`) for the background fallback.
- **`list` accuracy** (QA F2, round 2 F2). `watch=off` replaces `watch=stale` when the last event is `merged` or `closed`, or when the PR is stopped: the last event is `stopped` and no `start` or `restart-input` ran since (`stopped_gen` still equals `monitor_gen`). After a stop and a new start, `list` shows the new monitor's age again, and `stale` once it dies.
- **Install and docs** (reviewer F2, F3, F4).
  - `install.sh --skip-pr` skips installing and verifying `ops-pr-monitor` and its guard, and `--uninstall` always removes them.
  - The README's manual-install block and models excerpt list the agent and `claude.pr-monitor`.
  - `openspec/config.yaml` lists `ops-pr-monitor`.
- Reviewer F1 (task 4.2 of `pr-monitor-subagent` was ticked with script coverage only) gets no code change. The live check stays with the user, and task 4.2 here keeps it listed.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `pr-maintain`: stop and refresh results, gen-scoped monitor count, slice clamp (170 s) and `max-calls`, the wait's wall-time bound, no early monitor reply, locking, quoting, the monitor guard, `watch=off`, `--skip-pr` for the monitor.

## Impact

- `skills/opsx-pr/pr.sh` (`with_state_lock`, `write_seen`, `cmd_wait`, `cmd_stop`, `loop_text`, `watch_col`), new `skills/opsx-pr/monitor-guard.sh`, `agents/opsx-pr-monitor.md`, `install.sh`, `README.md`, `openspec/config.yaml`, `skills/opsx-pr/SKILL.md`.
- `tests/test-pr.sh`, install tests, `evals/pr-maintain/`.
