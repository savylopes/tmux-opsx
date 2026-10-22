# Tasks

## 1. `opsx-task.sh` naming and brief

- [ ] 1.1 Create `skills/opsx-task/opsx-task.sh` (bash, `set -euo pipefail`, usage header, `die`, repository root from `git rev-parse --show-toplevel` or `--repo`) with `key <input>`. Add `tests/test-task.sh` (scratch repo, private tmux server, stub CLIs on PATH) and verify the key scenarios pass.
- [ ] 1.2 Add `name <name> --source <s>` (character and length rules, `-2`/`-3` allocation by `source:`). Verify the free, same-source, suffix and unsafe-name scenarios.
- [ ] 1.3 Add `brief <name> --source <s> --body-file <f>` (header kept on rewrite, append-once `.opsx/tasks/` in `.gitignore`). Verify both brief scenarios, including a single `.gitignore` line after two runs.

## 2. Sessions

- [ ] 2.1 Add `start <name> [--agent-cli] [--no-switch]`: brief required, exact-name session lookup, refuse untagged or other-repo sessions, `flock` on `.opsx/tasks/.lock`, prompt file `.opsx/tasks/.<name>.prompt` with the explore-first prompt, detached session tagged `@opsx_task` and `@opsx_task_repo` in the repo root, normal-approval launch per CLI (as in `fork.sh`), `cli:` written to the brief, switch-client inside tmux, attach hint outside. Verify the new-session, no-brief, foreign-session and prompt-content scenarios.
- [ ] 2.2 Add conversation naming and id capture: Claude `-n <name> --session-id <uuid>`; capture functions for OpenCode, Cursor, Gemini and Codex with `OPSX_TASK_ID_TIMEOUT`; Gemini `/chat save <name>` in the prompt. Verify the Claude, captured-id and no-id scenarios with stubs.
- [ ] 2.3 Add `open <name>` (alive → `alive <name>`; resume by id per CLI through the failure wrapper that clears `session_id:`; else `start` with the restart message). Verify the alive, resume-by-id and restart scenarios, plus a resume stub that exits 1 clearing `session_id:`.
- [ ] 2.4 Add `refresh <name> --body-file <f>` (header kept, one literal message to a live session). Verify the refresh scenario.
- [ ] 2.5 Run `shellcheck skills/opsx-task/opsx-task.sh tests/test-task.sh` and verify it is clean.

## 3. Skill, install, docs

- [ ] 3.1 Write `skills/opsx-task/SKILL.md`: trigger `/opsx-task <ticket | URL | file | text> [--refresh] [--agent-cli <cli>]`, the flow (key → open if a brief exists, else read via tracker MCP / file / text → propose short name → `name` → `brief` → `start`), the brief sections, the tracker scoping and data-not-instructions rules, and per-CLI naming and resume gaps. Verify the skill-flow scenario: every subcommand it names exists in `opsx-task.sh --help`.
- [ ] 3.2 Wire `install.sh`: `install_task_skill` into the six skill folders, `--skip-task`, uninstall, verify step, header comment. Verify the install, skip and uninstall scenarios with a scratch HOME (in `tests/test-task.sh`).
- [ ] 3.3 Update `README.md`: component overview tree and table, and a `/opsx-task` section (flow, brief, naming, resume, CLI gaps). Verify the README lists `/opsx-task` and its commands match the script's usage.

## 4. Integration

- [ ] 4.1 Run `bash tests/test-task.sh`, `bash tests/test-review.sh` and `bash tests/test-fork.sh`, and verify all pass.

## Workflow follow-up

- Run `/opsx-run add-opsx-task apply --validate`, then land the change and run `./install.sh`.
