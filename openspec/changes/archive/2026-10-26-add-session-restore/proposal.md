# Proposal

## Why

After a reboot or a tmux server restart, tmux-resurrect + continuum bring back every session, window, pane and cwd, but every Claude Code pane comes back as a bare shell: the conversation that was running there is gone from view, and the harness's `@opsx_*` window tags are gone with the old server. Resurrect cannot fix this by itself. Its saved command line for an agent pane is a bare `claude`, a child process (`uvx … browser-use --cli-mcp`), or `claude --resume <id>` only when the user resumed by hand. Harness windows start Claude with a prompt and no id, so there is never an id to resume. (Observed on 2026-10-25: 19 sessions and 48 windows restored, with nothing running in any agent pane and every `@opsx_change` empty.) Because the tags are lost, a follow-up `/opsx-run <change> …` cannot find the restored window and opens a duplicate.

## What Changes

- **Session registry, written by Claude Code itself.** A `SessionStart` hook (fired on startup, resume and `/clear`) records, for the tmux pane it runs in: the tmux server, pane, session name, window index and name, pane index, cwd, the Claude session id and the permission mode. This covers every interactive Claude session in tmux: harness windows (`/opsx-run`, `/opsx-pr`, `/opsx-review`, `/opsx-task`, `/fork`) and sessions the user started by hand. Print-mode (`claude -p`) sessions and panes outside tmux are not recorded.
- **Snapshot on save.** `opsx sessions save` re-reads where each recorded pane is now (windows move and get renamed) and the window's current `@opsx_*` options. It drops panes that no longer run Claude, then writes one snapshot. The installer runs it from resurrect's post-save hook, so the snapshot always matches the layout resurrect will restore.
- **Replay on restore.** `opsx sessions restore` takes each snapshot entry, finds `session:window.pane`, and creates the session or window when it is missing. Only in a pane that sits at an idle shell does it type `cd <cwd> && claude --resume <id>`, with the recorded permission mode and the window's `@opsx_model` when it has one. It then puts back the window's `@opsx_*` options. It never touches a pane that is already running something, and running it twice resumes nothing twice. The installer runs it from resurrect's post-restore hook, which continuum's auto-restore also triggers.
- **Continue unfinished work.** On restore, a harness window whose work was not done gets a resume message as the first prompt of `claude --resume <id> "<message>"`. That covers an `/opsx-run` change window marked busy at the last save (re-arming its `/goal`, which `ensure` now stores on the window as `@opsx_goal`) and an `/opsx-pr` window whose PR is still open (the maintain input from a new `pr.sh restart-input`). Idle, done, failed and asking windows, `/opsx-task` sessions and hand-started sessions are only resumed. `--no-nudge` turns the messages off.
- **`opsx sessions list`** shows the snapshot (session:window.pane, window name, cwd, id, restore state) so the user can see what would come back.
- **Install.** `install.sh` merges the hook into `~/.claude/settings.json` and adds the two resurrect hook options to `~/.tmux.conf` in a marked block, only when tmux-resurrect is configured there; otherwise it prints the lines. It never overwrites a hook option the user has already set. `--skip-restore` opts out, `--uninstall` removes both, and the verify step checks them. `--restore-at-boot` also sets `@continuum-boot 'on'` in that block, so tmux, and with it the restore, starts at system start. When lingering is off, it prints the `sudo loginctl enable-linger <user>` command needed to start without a login; it never runs sudo itself.
- **Docs.** A README section "Restoring sessions after a reboot", plus a line in the overview tree.
- Not changed: how windows launch agents (`build_launch_cmd`), resurrect's own process list, and the window prefix or naming.

## Capabilities

### New Capabilities
- `session-restore`: record which Claude Code conversation runs in which tmux pane, keep a snapshot in step with tmux-resurrect saves, and after a tmux restart resume each conversation in its pane and put back the harness window tags. Also covers the install wiring and docs.

### Modified Capabilities
- `pr-maintain`: adds `pr.sh restart-input <pr>`, which prints a maintain window's first input for an open PR without touching tmux, so restore can continue a PR window.

## Impact

- New `skills/opsx-run/opsx-sessions.sh` (subcommands `hook`, `save`, `restore`, `list`), installed with the `opsx-run` skill. `bin/opsx` gains `sessions`.
- `skills/opsx-run/opsx-window.sh`: one new subcommand that types literal text into a pane, so restore follows the "no hand-rolled send-keys" rule; `ensure --goal-file` also sets `@opsx_goal`.
- `skills/opsx-pr/pr.sh` + `SKILL.md`: `restart-input` subcommand; `tests/test-pr.sh` cases.
- `install.sh`: Claude `SessionStart` hook merge/unmerge, the `~/.tmux.conf` block, `--skip-restore`, verify step.
- New `tests/test-restore.sh` (private tmux server, stub `claude`). README section and overview line.
- State lives in `~/.local/state/tmux-opsx/sessions/`.
- Limits: Claude Code only. Cursor CLI, Codex CLI, OpenCode and Gemini CLI panes still come back as shells; `/opsx-task` keeps resuming those by id, and the README notes the gap. Only change windows marked busy at the last save and PR windows with an open PR are told to continue. A change window that was mid-task but had fallen back to idle (after ~40 s of silence) is only resumed; `/opsx-run <change> …` sets it going again. Conversation from the last ≤5 minutes before a crash is still in the transcript, but a window opened after continuum's last save is not in the snapshot.
