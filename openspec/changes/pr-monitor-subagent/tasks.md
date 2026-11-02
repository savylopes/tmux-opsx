# Tasks

## 1. Wait generation and liveness

- [ ] 1.1 `pr.sh`: parse `--gen <n>`; `wait --gen` exits 4 with a `superseded` line on stderr once the state's `monitor_gen` differs (checked on every poll); without `--gen` behaviour is unchanged; each poll writes `last_wait_at`; verify in `tests/test-pr.sh`: gen bumped mid-wait → exit 4 within one poll; no `--gen` → exit 3 as before
- [ ] 1.2 `start` (including a refresh), `restart-input` and `stop` increase `monitor_gen`, and `write_prompt_files` puts it in the wait command; verify each with the state file
- [ ] 1.3 `list` prints a 5th column `watch=<age>s|stale|-`; verify fresh, stale (old `last_wait_at`) and never-waited states

## 2. Monitor agent and install

- [ ] 2.1 Add `agents/opsx-pr-monitor.md` (name `ops-pr-monitor`, tools `[Bash]`, the loop and four-line return contract of design decision 1) and `claude.pr-monitor = haiku` in `agents/models.conf` (Claude only: no `agent.`/`opencode.` key and no `--pr-monitor-model` flag; make sure the models.conf parser and `agent_model_for` accept the key and `tests/test-agent-models.sh` still passes)
- [ ] 2.2 `install.sh` installs it to `~/.claude/agents/opsx-pr-monitor.md` with the model written in, removes it on `--uninstall`, checks it in verify; verify with a scratch HOME

## 3. Prompt and docs

- [ ] 3.1 `prompt_text`: resolve the window CLI; for `claude` write the background-monitor Loop (spawn, end turn, handle `event=`/`idle`/`superseded`/`error:`, never wait in the window, no second monitor), the self-caused-event rule and the updated user-message rule; others keep the foreground loop with `--gen`; `goal_text` on `claude` names the `idle` monitor result as the expected step instead of an exit-3 wait; verify `pr.sh prompt 42` for `--agent-cli claude` and `--agent-cli codex`
- [ ] 3.2 `skills/opsx-pr/SKILL.md` ("What the window does", "Goals per CLI", the refresh note), `skills/opsx-run/SKILL.md` (the PR monitor is the one sanctioned background subagent), README PR maintainer section

## 4. Checks

- [ ] 4.1 Run `tests/test-pr.sh`, the install tests, shellcheck and `openspec validate pr-monitor-subagent --strict`, all passing
- [ ] 4.2 Manual check in a scratch tmux window on Claude Code: after `/opsx-pr <pr>` the pane is idle at the prompt while `/tasks` shows the monitor; a typed message is answered at once; a pushed comment on the PR reaches the window as a new turn
