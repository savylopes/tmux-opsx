## MODIFIED Requirements

### Requirement: Background PR monitor on Claude Code
When the window's agent CLI is Claude Code, the maintain prompt SHALL tell the window never to run `pr.sh wait` itself, but to start `ops-pr-monitor` in the background with the exact wait command and a `max-calls:` line, then end its turn. Only a monitor started with the current `--gen` counts as running. On `event=` it SHALL handle it, run `pr.sh seen` and ensure a monitor; on `idle` or `superseded` ensure one; on `stopped` start none. The prompt SHALL say that `waiting`, or any monitor result that is not one of the five results, is not a reason to start a monitor. Other CLIs SHALL keep the foreground loop.

#### Scenario: Claude prompt uses the background monitor
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt names `ops-pr-monitor`, says to run it in the background and end the turn, says not to run `pr.sh wait` in the window, passes `--gen` to the wait command, and names the `idle`, `superseded`, `stopped` and `error:` results

#### Scenario: Only current-gen monitors count
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt says a monitor counts as running only when started with the current `--gen`, says to start one on `superseded` when none counts, and does not contain "When unsure, start one"

#### Scenario: Interim monitor result starts nothing
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt names the `waiting` line and says that an interim or non-matching monitor result is not a reason to start a monitor

#### Scenario: Other CLIs keep the foreground wait
- **WHEN** `pr.sh prompt 42 --agent-cli codex` runs
- **THEN** the prompt tells the window to run `pr.sh wait` in the foreground, does not name `ops-pr-monitor`, and passes `--gen`

### Requirement: PR monitor agent
`agents/opsx-pr-monitor.md` SHALL define `ops-pr-monitor` with the Bash tool only, guarded by a PreToolUse hook that runs `monitor-guard.sh`. It SHALL rerun the wait after exit 3 up to the `max-calls:` value (default 3, at most 30) and return one line: `event=<kind>`, `idle`, `superseded`, `stopped` or `error: <message>`. It SHALL never end its turn before that line with other text; if a call is moved to the background it SHALL take the exit code from the completion notification, read the task output file it names when it needs the result line, and continue the loop, and a turn it must end to wait for that notification SHALL say only `waiting`. A completion notification SHALL NOT be treated as a new prompt. `install.sh` SHALL install it and the guard unless `--skip-pr`, verify them, and always remove them on `--uninstall`.

#### Scenario: Monitor never replies early
- **WHEN** `agents/opsx-pr-monitor.md` is read
- **THEN** it says never to end the turn before the one final line, names the `moved to the background` case, the `<task-notification>` with its exit code and output file, the `waiting` line, and says a notification is not a new prompt and never yields `error: not a pr.sh wait command`

#### Scenario: Monitor agent installed
- **WHEN** `install.sh` runs with a scratch HOME
- **THEN** `~/.claude/agents/opsx-pr-monitor.md` exists, names `ops-pr-monitor`, lists only the Bash tool, has a PreToolUse hook naming `monitor-guard.sh`, and is removed again by `install.sh --uninstall`

#### Scenario: Skipped with --skip-pr
- **WHEN** `install.sh --skip-pr` runs with a scratch HOME
- **THEN** no `opsx-pr-monitor.md` and no `monitor-guard.sh` are installed

### Requirement: One live monitor per PR
The state file SHALL hold `monitor_gen=<n>`; `start`, `restart-input` and `stop` SHALL increase it, and the prompt's wait command SHALL carry it as `--gen <n>`. `wait --gen <n>` SHALL exit 4 on a mismatch, printing `stopped` when the bump came from `pr.sh stop` and `superseded` otherwise. Without `--gen`, `wait` SHALL behave as before.

#### Scenario: Refresh supersedes a running wait
- **WHEN** `pr.sh wait 42 --gen 1 --slice 30 --poll 1` runs and `monitor_gen` in the state file becomes 2 while it waits
- **THEN** it exits 4 within a few seconds, prints `superseded`, and prints no `event=` line

#### Scenario: Stop is reported as stopped
- **WHEN** `pr.sh wait 42 --gen 1 --slice 30 --poll 1` runs and `pr.sh stop 42` runs while it waits
- **THEN** the wait exits 4 within a few seconds and prints `stopped`, not `superseded`

#### Scenario: Start and stop advance the generation
- **WHEN** `pr.sh start 42` runs on a state file with `monitor_gen=3`, and then `pr.sh stop 42` runs
- **THEN** the state file holds `monitor_gen=4` after start and `monitor_gen=5` after stop

#### Scenario: Wait without gen is unchanged
- **WHEN** `pr.sh wait 42 --slice 2 --poll 1` runs with no `--gen` and the fake `gh` reports no change
- **THEN** it exits 3

### Requirement: Watcher liveness in list
Each poll of `pr.sh wait` SHALL record `last_wait_at=<epoch seconds>`. `pr.sh list` SHALL print a fifth column: `watch=off` when the last event is `merged` or `closed`, or when it is `stopped` and no `start` or `restart-input` ran since the stop (`stopped_gen` equals `monitor_gen`); else `watch=<age>s` since `last_wait_at`, `watch=stale` when the age exceeds slice plus poll plus 30 seconds, and `watch=-` when no wait has run yet.

#### Scenario: Stale watcher shown
- **WHEN** the state file for PR 42 has a `last_wait_at` from one hour ago, `last_event=comments`, and `pr.sh list` runs
- **THEN** the line for PR 42 ends with `watch=stale`

#### Scenario: Finished PR shows off
- **WHEN** the state file for PR 42 has a `last_wait_at` from one hour ago and `last_event=merged` (or `closed`), or `pr.sh stop 42` ran after that wait
- **THEN** the line for PR 42 ends with `watch=off`

#### Scenario: Restart after stop shows the new watcher
- **WHEN** `pr.sh stop 42` runs, then `pr.sh start 42` (or `pr.sh restart-input 42`), then a wait polls, and `pr.sh list` runs
- **THEN** the line for PR 42 ends with `watch=<n>s`, and with `watch=stale` once that `last_wait_at` is an hour old

#### Scenario: Fresh watcher shown
- **WHEN** `pr.sh wait 42 --slice 2 --poll 1` has just run and `pr.sh list` runs
- **THEN** the line for PR 42 has a `watch=<n>s` column with `<n>` under 60

## ADDED Requirements

### Requirement: Slice fits the monitor
On Claude Code the prompt's wait command SHALL use a slice of at most 170 seconds, so one call ends before Claude Code's 180-second auto-background limit for a subagent's Bash call. The monitor prompt SHALL carry `max-calls: <n>` with n = max(1, 1620 / slice), at most 30, and the prompt's `idle` line SHALL name the effective run (n × slice). `pr.sh wait` SHALL count its slice from its start and SHALL not start a poll round that it expects to end after the slice.

#### Scenario: Long slice clamped
- **WHEN** `pr.sh prompt 42 --agent-cli claude --slice 900` runs
- **THEN** the wait command has `--slice 170`, the prompt has `max-calls: 9`, and the `idle` line says about 25 minutes

#### Scenario: Short slice capped
- **WHEN** `pr.sh prompt 42 --agent-cli claude --slice 30` runs
- **THEN** the prompt has `max-calls: 30` and the `idle` line says about 15 minutes

#### Scenario: Wait stays within its slice
- **WHEN** `pr.sh wait 42 --slice 5 --poll 3` runs and each poll round takes about one second
- **THEN** it exits 3 within 6 seconds of its start

### Requirement: Quoted wait command
The prompt's wait command SHALL quote the `pr.sh` path and the repository path so a path with spaces or shell characters is one argument.

#### Scenario: Repo path with a space
- **WHEN** `pr.sh prompt 42` runs with `--repo "/tmp/my repo"`
- **THEN** the wait command contains `--repo /tmp/my\ repo`

### Requirement: State writes are locked
State writes SHALL hold a lock on the state file: `flock` when available, else a `mkdir` lock directory (broken after 120 s by renaming it first, so only one process breaks it). The lock SHALL be re-entrant within one process, `write_seen` SHALL hold it for its whole update, and a lock not obtained within 30 s SHALL print a `state lock busy` warning on stderr before writing.

#### Scenario: Concurrent writes without flock
- **WHEN** two processes each set 50 distinct keys at once with no `flock` on PATH
- **THEN** the state file holds all 100 keys afterwards

#### Scenario: Stale lock broken once
- **WHEN** a `mkdir` lock directory older than 120 s exists and two processes without `flock` each set 20 distinct keys at once
- **THEN** the state file holds all 40 keys and no lock directory is left

#### Scenario: Busy lock warns
- **WHEN** another process holds the lock for longer than 30 s and `pr.sh seen 42` runs
- **THEN** it prints `state lock busy` on stderr and still updates the state

### Requirement: Monitor command guard
`skills/opsx-pr/monitor-guard.sh` SHALL read a PreToolUse payload on stdin and allow only two command shapes: a single `<pr.sh> wait <n> --repo <arg> --slice <n> --poll <n> --gen <n>` with no unescaped shell metacharacters or newlines, where `<pr.sh>` is absolute and resolves to the `pr.sh` next to the guard; and `cat` or `tail -n <n>` of one Claude Code task output file. Anything else SHALL be denied with exit 2 and a reason on stderr.

#### Scenario: Prompt command allowed
- **WHEN** the guard gets the exact wait command from `pr.sh prompt 42 --agent-cli claude`, including a repo path with a space
- **THEN** it exits 0

#### Scenario: Other commands denied
- **WHEN** the guard gets `pr.sh wait 42 --repo /r --slice 5 --poll 1 --gen 1; rm -rf x`, `gh pr view 42`, `cat ~/.ssh/id_rsa`, or a command with `$(id)`
- **THEN** it exits 2 for each

#### Scenario: Only the installed pr.sh
- **WHEN** the guard gets the wait command with a relative path (`env/pr.sh wait …`), with an assignment prefix (`PATH=/x/pr.sh wait …`), or with the absolute path of another `pr.sh`
- **THEN** it exits 2 for each

#### Scenario: Task output read allowed, nothing else
- **WHEN** the guard gets `tail -n 5 /tmp/claude-1000/-home-u-p/0a1b-2c/tasks/bq7x.output` and `cat` of the same file
- **THEN** it exits 0, and it exits 2 for `cat /etc/passwd`, `tail -f` of that file, and a path with a `..` segment
