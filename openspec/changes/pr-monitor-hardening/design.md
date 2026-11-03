# Design

## Context

Follow-up to `pr-monitor-subagent` (archived). Code: `skills/opsx-pr/pr.sh` (`with_state_lock` ~l.350, `write_seen` ~l.445, `loop_text` ~l.640, `watch_col` ~l.1345), `agents/opsx-pr-monitor.md`. Findings: reviewer F1–F6, security F1–F4, QA F1–F3 (all P2).

## Decisions

1. **`stopped` vs `superseded`.** `cmd_stop` writes `stopped_gen=<new gen>` together with the bump. `wait --gen <n>` on a gen mismatch exits 4 and prints `pr: stopped` when the state's `stopped_gen` equals its current `monitor_gen`, and `pr: superseded` otherwise. `start` and `restart-input` clear `stopped_gen`. The monitor maps exit 4 + `stopped` → `stopped`, and exit 4 otherwise → `superseded`.
2. **Gen-scoped monitor count.** Prompt step 1: "A monitor counts as running only if you started it with `--gen <current>` (the gen in the command below) and it has not returned. Start one when none counts." `superseded` → go to step 1 (it starts one only if none for the current gen is running). `stopped` → start none and say the loop stopped. The old "when unsure, start one" sentence goes.
3. **Slice and calls.** In `loop_text` for Claude, `s=$(( SLICE > 570 ? 570 : SLICE ))` and `calls=$(( 1620 / s ))` (min 1). The monitor's prompt becomes two lines: the command, then `max-calls: <n>`. The agent file reads `max-calls` (default 3 when missing, capped at 30), and the guard ignores it because it is not a command. Foreground CLIs keep `--slice` as given.
4. **Lock.** `with_state_lock`: if `$OPSX_PR_LOCKED` equals the state file, run directly (re-entrant). Else take the lock for 30 s. With `flock(1)`, use `flock -w 30` on fd 9 of `<state>.lock`. Without it, loop on `mkdir <state>.lockd` every 0.2 s up to 30 s, removing it on exit with `trap`, and break a lock directory older than 120 s. On a timeout, print `pr: state lock busy after 30s; writing unlocked` to stderr and proceed. While the lock is held, export `OPSX_PR_LOCKED=<state>`. `write_seen` wraps its body as `with_state_lock write_seen_unlocked`.
5. **Quoting.** `WAITCMD=$(printf '%q wait %s --repo %q --slice %s --poll %s --gen %s' "$SELF" "$PR" "$REPO" …)`, used for both CLIs.
6. **Guard.** `monitor-guard.sh` reads the PreToolUse JSON from stdin (`jq -r .tool_input.command`). It allows only `^<path>/pr\.sh wait [0-9]+ --repo <arg> --slice [0-9]+ --poll [0-9]+ --gen [0-9]+$`, where `<path>` and `<arg>` are `%q`-style tokens with no unescaped `;|&$\`()<>` and no newline. It denies everything else with exit 2 and a reason on stderr. The agent frontmatter gets `hooks: PreToolUse: [{matcher: Bash, hooks: [{type: command, command: <installed path>/monitor-guard.sh}]}]`, and `install.sh` writes the absolute installed path into it. The applier first checks code.claude.com/docs/en/sub-agents.md for frontmatter `hooks` support. If it is unsupported, it reports BLOCKED for 3.1 with the doc quote instead of falling back to something else.
7. **`watch=off`.** In `watch_col`, a `last_event` of `merged`, `closed` or `stopped` prints `watch=off` before the age check.
8. **Install.** The `ops-pr-monitor` install, verify and guard lines move under the existing `--skip-pr` condition. Uninstall removes them without that condition.

## Risks / Trade-offs

- [The guard regex is too strict for a path with spaces] `%q` escapes spaces as `\ `, and the regex allows backslash-escaped characters. The tests cover a repo path with a space.
- [A `mkdir` lock left behind by a killed process] It is broken after 120 s, and the 30 s wait then warns.
