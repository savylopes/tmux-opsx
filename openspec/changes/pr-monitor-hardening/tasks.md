# Tasks

## 1. Loop correctness

- [x] 1.1 `stopped_gen` in `cmd_stop`, cleared by `start`/`restart-input`; `wait --gen` prints `stopped` vs `superseded` on exit 4; verify both in `tests/test-pr.sh`
- [x] 1.2 `loop_text` (Claude): gen-scoped running rule, `superseded` → step 1, `stopped` → none, the "when unsure" sentence removed; slice clamp 570 and `max-calls: <n>` line; `%q`-quoted wait command for both CLIs; verify `pr.sh prompt 42 --agent-cli claude --slice 900` shows `--slice 570` and `max-calls: 2`, and a repo path with a space is quoted
- [x] 1.3 `agents/opsx-pr-monitor.md`: read `max-calls` (default 3, cap 30), return `stopped` on exit 4 with `stopped`; `SKILL.md` text for both
- [x] 1.4 Review round 2 (F1, F3, F4, F5, F6 and the user's PR 48 follow-up): clamp the Claude slice to 170 s (the 180 s auto-background limit), `max-calls` = max(1, 1620 / slice) capped at 30, `idle` wording from calls × slice; `cmd_wait` deadline from its start and no poll round past it (timing test); agent file: never end the turn before the final line, background fallback from the real `<task-notification>` shape (`waiting` line, exit code from the summary, `tail` of the output file), notification is not a new prompt; prompt: an interim or non-matching result starts no monitor; guard: only the installed absolute `pr.sh`, plus `cat`/`tail -n` of a task output file; `mkdir` stale lock broken by rename; `watch=off` after stop only while no start/restart-input ran since (F2); race-free mid-wait gen-bump test (F3); SKILL.md, README; verify `pr.sh prompt 42 --agent-cli claude --slice 900` → `--slice 170`, `max-calls: 9`

## 2. State locking

- [x] 2.1 `with_state_lock`: re-entrant via `OPSX_PR_LOCKED`, `flock -w 30`, `mkdir` fallback with 120 s stale break, stderr warning on timeout; `write_seen` takes one lock; verify: no-flock PATH still serializes two concurrent `sset` loops (no lost key), a held lock yields the warning, `write_seen` under a held lock from the same process does not deadlock

## 3. Monitor guard

- [x] 3.1 Confirm subagent frontmatter `hooks` support in the Claude Code docs; add `skills/opsx-pr/monitor-guard.sh` and the agent's PreToolUse hook (installed absolute path); verify the guard allows the exact prompt command (incl. a quoted path with a space) and denies `pr.sh wait 42 ...; rm -rf x`, `gh pr view 42`, `cat ~/.ssh/id_rsa`, a command with `$(...)`, and a newline-joined second command

## 4. list, install, docs

- [x] 4.1 `watch_col`: `watch=off` for `merged|closed|stopped`; verify with state files
- [x] 4.2 `install.sh`: monitor agent and guard under `--skip-pr`, always removed on `--uninstall`, verified; README manual-install block and models excerpt; `openspec/config.yaml` agents list; verify with a scratch HOME (`--skip-pr` → no `opsx-pr-monitor.md`). The live Claude Code check of `pr-monitor-subagent` stays for the user: say so in the report

## 5. Checks

- [x] 5.1 `tests/test-pr.sh`, install tests, `tests/test-agent-models.sh`, shellcheck, `openspec validate pr-monitor-hardening --strict`, all passing
