## ADDED Requirements

### Requirement: Background PR monitor on Claude Code
When the window's agent CLI is Claude Code, the maintain prompt SHALL tell the window never to run `pr.sh wait` itself, but to start `ops-pr-monitor` as a background subagent with the exact `pr.sh wait … --gen <n>` command and end its turn, so the window reads user input at once. On `event=` it SHALL handle the event, run `pr.sh seen` and spawn the next monitor; on `idle` spawn the next; on `superseded` spawn none; never two at once. Other CLIs SHALL keep the foreground `pr.sh wait` loop.

#### Scenario: Claude prompt uses the background monitor
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt names `ops-pr-monitor`, says to run it in the background and end the turn, says not to run `pr.sh wait` in the window, passes `--gen` to the wait command, and names the `idle`, `superseded` and `error:` results

#### Scenario: Other CLIs keep the foreground wait
- **WHEN** `pr.sh prompt 42 --agent-cli codex` runs
- **THEN** the prompt tells the window to run `pr.sh wait` in the foreground, does not name `ops-pr-monitor`, and passes `--gen`

### Requirement: PR monitor agent
`agents/opsx-pr-monitor.md` SHALL define the `ops-pr-monitor` agent with the Bash tool only. It SHALL run the given wait command in the foreground, run it again after exit 3 at most three times in a row, and return exactly one line: `event=<kind>`, `idle`, `superseded` (exit 4) or `error: <message>`. It SHALL do no other work. `install.sh` SHALL install it for Claude Code, remove it on `--uninstall` and check it in verify.

#### Scenario: Monitor agent installed
- **WHEN** `install.sh` runs with a scratch HOME
- **THEN** `~/.claude/agents/opsx-pr-monitor.md` exists, names `ops-pr-monitor`, lists only the Bash tool, and is removed again by `install.sh --uninstall`

### Requirement: One live monitor per PR
The state file SHALL hold `monitor_gen=<n>`. `pr.sh start` (including a refresh of a running window), `pr.sh restart-input` and `pr.sh stop` SHALL each increase it, and the prompt's wait command SHALL carry the current value as `--gen <n>`. `pr.sh wait --gen <n>` SHALL compare `<n>` with the state on every poll and exit 4, printing a line that contains `superseded`, when the two differ. Without `--gen`, `wait` SHALL behave as before.

#### Scenario: Refresh supersedes a running wait
- **WHEN** `pr.sh wait 42 --gen 1 --slice 30 --poll 1` runs and `monitor_gen` in the state file becomes 2 while it waits
- **THEN** it exits 4 within a few seconds, prints `superseded`, and prints no `event=` line

#### Scenario: Start and stop advance the generation
- **WHEN** `pr.sh start 42` runs on a state file with `monitor_gen=3`, and then `pr.sh stop 42` runs
- **THEN** the state file holds `monitor_gen=4` after start and `monitor_gen=5` after stop

#### Scenario: Wait without gen is unchanged
- **WHEN** `pr.sh wait 42 --slice 2 --poll 1` runs with no `--gen` and the fake `gh` reports no change
- **THEN** it exits 3

### Requirement: Watcher liveness in list
Each poll of `pr.sh wait` SHALL record `last_wait_at=<epoch seconds>` in the state file. `pr.sh list` SHALL print a fifth column: `watch=<age>s` with the seconds since `last_wait_at`, `watch=stale` when that age is greater than the slice plus the poll interval plus 30 seconds, and `watch=-` when no wait has run yet.

#### Scenario: Stale watcher shown
- **WHEN** the state file for PR 42 has a `last_wait_at` from one hour ago and `pr.sh list` runs
- **THEN** the line for PR 42 ends with `watch=stale`

#### Scenario: Fresh watcher shown
- **WHEN** `pr.sh wait 42 --slice 2 --poll 1` has just run and `pr.sh list` runs
- **THEN** the line for PR 42 has a `watch=<n>s` column with `<n>` under 60

## MODIFIED Requirements

### Requirement: User feedback in the window overrides the loop
The maintain prompt SHALL tell the agent that messages the user types in the window take precedence over the PR loop: it acts on them first, then returns to the loop (on Claude Code: it makes sure one `ops-pr-monitor` is running and ends its turn; on other CLIs: it runs `pr.sh wait` again). The prompt SHALL also say that a `head-moved` or `comments` event caused only by the window's own push or replies is acknowledged with `pr.sh seen` and not acted on further.

#### Scenario: Prompt names user messages
- **WHEN** `pr.sh prompt 42` runs
- **THEN** the prompt says the user's messages in this window come before the PR loop

#### Scenario: Prompt names self-caused events
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt says that a `head-moved` from the window's own push, or `comments` that are only its own replies, are acknowledged with `pr.sh seen`
