## Why

A maintain window runs `pr.sh wait` as a foreground tool call that lasts up to 540 s, over and over. While it runs the window is busy. A message the user types is only read once that call returns, and Esc is the only way to cut in. In a change window (`pr-in-change-window`) this matters most, because that is where the user talks to the orchestrator about the change. The window should sit idle and take input at once, with the waiting done somewhere else.

## What Changes

- **Background monitor (Claude Code).** The window no longer calls `pr.sh wait` itself. It spawns a new `ops-pr-monitor` subagent in the background and ends its turn. The window is then idle and takes the user's input at once. The monitor runs `pr.sh wait` in a loop with no LLM work between calls. It returns the first `event=` line, or `idle` after three empty slices (about 27 minutes), or `superseded`. The completion arrives in the window as a new turn. The window handles the event under the same rules as today, runs `pr.sh seen`, spawns the next monitor and ends its turn again.
- **`/goal` stays.** Its text changes on Claude Code: an `idle` result from the monitor is now the expected idle step, not a wait that exits 3. Claude Code does not evaluate a goal while a background subagent runs, and delivers the subagent's result as a new turn, so the maintain goal still keeps the loop alive. (Documented in code.claude.com/docs/en/goal.md, "Background work defers evaluation".)
- **One live monitor per PR.** The state file holds `monitor_gen=<n>`. `start` (and a refresh), `restart-input` and `stop` increase it. The prompt passes `--gen <n>` to `wait`. `wait` exits 4 (`superseded`) on the next poll once the state's gen differs, so a monitor left over from a refresh, a stop or a restore ends by itself, and the window does not spawn a new one on exit 4.
- **Liveness.** `wait` records `last_wait_at`. `pr.sh list` adds a column with the watcher's age, or `stale` when no wait ran for longer than one slice plus one poll, so a loop that died quietly shows up.
- **Concurrent work.** The window can act on a user message while a monitor is waiting. An event that the window itself caused (its own push, or its own reply) is acknowledged with `seen`, and nothing else is done.
- **Other CLIs unchanged.** Cursor CLI, Codex CLI, OpenCode and Gemini CLI keep the foreground `pr.sh wait`. Their background-subagent completion does not reliably start a new turn, and the gap is documented. `pr.sh` picks the loop by the window's agent CLI (`--agent-cli`, else the window's `@opsx_agent_cli`, else `claude`).

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `pr-maintain`: background monitor loop on Claude Code, `--gen` and exit 4 on `wait`, `monitor_gen` and `last_wait_at` in the state, the watcher column in `list`, the prompt's loop and user-message rules, install of the monitor agent.

## Impact

- `agents/opsx-pr-monitor.md` (new; Bash only, cheapest model), `agents/models.conf` (`claude.pr-monitor`), `install.sh` (install, uninstall and verify it for Claude Code).
- `skills/opsx-pr/pr.sh` (`prompt_text`, `cmd_wait`, `cmd_start`, `cmd_restart_input`, `cmd_stop`, `cmd_list`, option parsing), `skills/opsx-pr/SKILL.md` ("What the window does", "Goals per CLI"), `skills/opsx-run/SKILL.md` (the PR monitor is the one background subagent a window may start), README.
- `tests/test-pr.sh`, `evals/pr-maintain/`.
