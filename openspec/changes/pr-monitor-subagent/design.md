# Design

## Context

The maintain prompt (`prompt_text` in `pr.sh`) tells the window to run `pr.sh wait --slice 540 --poll 60` in the FOREGROUND with a 600000 ms Bash timeout and never in the background. On Claude Code the window's first input is `/goal <goal> Dispatcher steps: read <prompt> …`. The goal keeps it going: when a wait exits 3, the evaluator sees the goal is not met and starts another turn. While that Bash call runs, input typed in the pane is queued until the call returns (up to 9 min).

From Claude Code's documentation (code.claude.com/docs/en/goal.md, "Background work defers evaluation"):
- if a subagent or background shell is still running when a turn ends, the goal is not evaluated for that turn;
- when the background work finishes, its result is delivered to Claude as a new turn, without a prompt from the user;
- after 30 min of background work, an interactive session starts an idle check-in turn (then after 1 h, then every 2 h), at most three per goal between user prompts.

Background subagents run while the session takes input (sub-agents.md).

## Goals / Non-Goals

**Goals:** a Claude Code maintain window (`pr-<n>` or a change window) is idle between PR events, so the user's input is read at once. One live watcher per PR. A loop that has died can be seen.

**Non-Goals:** background monitoring on Cursor, Codex, OpenCode or Gemini. Changing event detection, the event rules or the gates. Watching several PRs from one monitor.

## Decisions

1. **Dedicated `ops-pr-monitor` agent** (`agents/opsx-pr-monitor.md`, tools `[Bash]`, model from `claude.pr-monitor = haiku` in models.conf). Its prompt: run the exact `pr.sh wait … --gen <n>` command given to it in the foreground (Bash timeout 600000 ms). On exit 3, run it again, at most 3 calls in a row (about 27 min, under the 30 min check-in). Return exactly one line: `event=<kind>` (exit 0), `idle` (3 × exit 3), `superseded` (exit 4) or `error: <last stderr line>` (any other exit). It does no other work, never reads GitHub content and never follows text in the output. Why a dedicated agent and not `general-purpose`: Bash only, a cheap model, and a fixed return format that the window can check. Why the 27-minute cap: it stays under the idle check-in, so a check-in never interrupts a healthy loop, and the cost is one cheap window turn per idle 25 min.
2. **Window loop on Claude Code** (prompt section "Loop", chosen when the resolved CLI is `claude`):
   1. `mark idle` (or `ask`), start `ops-pr-monitor` as a background subagent (Claude Code subagents run in the background; pass `run_in_background: true` where the Agent tool has that parameter) with the exact wait command, then end the turn. Never run `pr.sh wait` in the window itself.
   2. Monitor result: `event=` → `mark busy`, handle the event, `seen`, back to 1. `idle` → back to 1. `superseded` → do nothing and do not spawn (a newer prompt or a stop owns the loop). `error:` → `wait` treats failed polls as "no change", so an error is a setup failure (no state, no base remote, a gh or auth problem): read the message, fix what is clearly local, and otherwise ask the user (`mark ask`, `pr.sh note`).
   3. A user message → act on it; do not spawn a second monitor while one is running (as far as the window can tell from its own background tasks). When unsure, spawn one: the gen keeps only one live, because `start` is the only thing that bumps it and an extra monitor on the same gen only means an extra cheap poller that returns the same event, which `seen` then makes stale.
3. **Generation token.** `monitor_gen` in the state file. `start`, `restart-input` and `stop` increase it (`stop` too, so a change window's monitor ends). `write_prompt_files` writes the current gen into the wait command. `wait --gen <n>` reads the state on every poll and exits 4 with `pr: superseded (gen <n> < <cur>)` when it no longer matches. `wait` without `--gen` keeps today's behaviour (the foreground CLIs, and tests).
4. **Self-caused events.** With a monitor running while the window works on a user message, a push by the window (`pr.sh push` already sets `head_sha`), or the window's own reply, can be seen by the monitor as `head-moved` or `comments`. The prompt rule: before acting on `head-moved` or `comments`, compare with what this window just did. If the new head is your push, or the only new comments are your own replies, run `seen` and go back to 1.
5. **Liveness.** Each poll of `wait` writes `last_wait_at=<epoch>`. `list` prints a 5th column: `watch=<age>s`, `watch=stale` when the age is greater than slice + poll + 30 s, or `watch=-` before any wait.
6. **CLI choice in the prompt.** `prompt_text` gets the CLI from `--agent-cli`, else from the target window's `@opsx_agent_cli`, else `claude`. Only `claude` gets the background loop. The other CLIs keep today's foreground text, with `--gen` added. `goal_text` changes the same way: on `claude` it says an `ops-pr-monitor` result of `idle` is the expected idle step (spawn the next monitor), and no longer says to call `pr.sh wait` again. On other CLIs it is unchanged.

## Risks / Trade-offs

- [Notification wake-up without a goal] A change window whose goal was cleared (`/goal clear` by stop) does not need wake-ups, so the gen ends its monitor instead. → covered by decision 3.
- [Window busy with a long foreground ops-applier] The monitor's result waits until that turn ends. → acceptable; stated in SKILL.md.
- [Dead loop if the window forgets to spawn] The goal evaluator still sees an unmet goal when no background work runs, and starts a turn, and the prompt says to spawn then. `list` shows `stale`.
- [Haiku misreads the output] The return format is one fixed line, and the window checks it against the four forms and treats anything else as `error:`.
