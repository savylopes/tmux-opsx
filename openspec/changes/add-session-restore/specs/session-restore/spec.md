# Spec Delta

## Purpose

Brings every Claude Code conversation back into the tmux session, window and pane it ran in after the tmux server restarts or the machine reboots. Also puts back the harness window tags, so follow-up commands land in the restored windows.

## ADDED Requirements

### Requirement: Record the conversation running in a pane
On Claude Code `SessionStart` (startup, resume, clear), `opsx-sessions.sh hook` SHALL read the hook JSON from stdin and write a record for the tmux pane that runs that Claude process. The record SHALL hold the tmux server identity, pane id, session name, window index and name, pane index, cwd, session id and permission mode. A new record for the same pane SHALL replace the old one. The hook SHALL always exit 0 and print nothing to stdout.

#### Scenario: Hook records the pane
- **WHEN** `opsx-sessions.sh hook` runs inside pane `work:2.0` of a private tmux server with stdin `{"session_id":"11111111-1111-4111-8111-111111111111","cwd":"/r","permission_mode":"bypassPermissions","hook_event_name":"SessionStart","source":"startup"}`
- **THEN** it exits 0 with empty stdout, and `opsx-sessions.sh list --live` shows `work:2.0` with id `11111111-1111-4111-8111-111111111111`, cwd `/r` and mode `bypassPermissions`

#### Scenario: Clear replaces the id
- **WHEN** the same pane already has a record and the hook runs again with `source` `clear` and a new session id
- **THEN** the pane has one record, holding the new id

#### Scenario: Mode from the command line
- **WHEN** the hook runs with stdin that has no `permission_mode`, started by `claude --permission-mode bypassPermissions` in pane `work:2.0`
- **THEN** `opsx-sessions.sh list --live` shows `work:2.0` with mode `bypassPermissions`

#### Scenario: Stripped TMUX_PANE
- **WHEN** the hook runs inside a tmux pane with `TMUX_PANE` unset
- **THEN** it still records that pane, which it finds through its process ancestry

### Requirement: Record only interactive tmux sessions
The hook SHALL write nothing, and still exit 0, when it is not inside a tmux pane, when the Claude process that started it runs in print mode (`-p`/`--print`), or when the input has no valid session id (a UUID).

#### Scenario: Outside tmux
- **WHEN** the hook runs with no tmux client or pane in its ancestry
- **THEN** it exits 0 and writes no record

#### Scenario: Print mode
- **WHEN** the hook's Claude ancestor was started with `-p`
- **THEN** it exits 0 and writes no record

#### Scenario: Malformed id
- **WHEN** the input's `session_id` is `../x`
- **THEN** it exits 0 and writes no record

### Requirement: Snapshot in step with the layout
`opsx-sessions.sh save` SHALL write a snapshot with one entry per recorded pane of the running server whose current command is still `claude`. Each entry SHALL use the pane's position and window name at save time and SHALL hold the window's `@opsx_*` options as they are at save time. Panes that are gone or no longer run Claude SHALL be left out. Records from earlier servers that have not been restored yet SHALL stay in the snapshot.

#### Scenario: Moved window
- **WHEN** a recorded pane's window was moved from index 2 to index 5 and renamed `ox ·add-auth`, and `save` runs
- **THEN** the snapshot entry is `work:5.0` with window name `ox ·add-auth`

#### Scenario: Exited conversation dropped
- **WHEN** a recorded pane now runs `bash` because Claude exited, and `save` runs
- **THEN** the snapshot has no entry for that pane

#### Scenario: Tags captured at save
- **WHEN** a recorded pane's window got `@opsx_change=add-auth` after the hook ran, and `save` runs
- **THEN** the snapshot entry holds `@opsx_change=add-auth`

#### Scenario: Unrestored entries survive a save on a new server
- **WHEN** the snapshot has an unrestored entry from an earlier tmux server and `save` runs on a new server before any `restore`
- **THEN** the entry is still in the snapshot and still unrestored

### Requirement: Resume each conversation in its pane
`opsx-sessions.sh restore` SHALL, for each snapshot entry not yet restored, find `session:window_index.pane_index`. It SHALL create a missing session or window, using the recorded cwd and window name. When the target pane's current command is a shell, it SHALL type in a command that changes to the recorded cwd and runs `claude --resume <id>`, with `--permission-mode <mode>` unless the mode is `default` and `--model <m>` when the entry has `@opsx_model`. It SHALL then mark the entry restored.

#### Scenario: Pane resumed
- **WHEN** the snapshot has `work:2.0` with id `<uuid>`, mode `bypassPermissions`, cwd `/r`, and on a new server pane `work:2.0` runs `bash` with a stub `claude` on PATH
- **THEN** the stub runs in `/r` with arguments `--resume <uuid> --permission-mode bypassPermissions`

#### Scenario: Missing window created
- **WHEN** the snapshot has `work:3.0` and session `work` has no window 3
- **THEN** window 3 is created in session `work` with the recorded name and cwd, and the stub `claude` runs there with `--resume`

#### Scenario: Busy pane left alone
- **WHEN** the target pane runs `nvim` or `claude`
- **THEN** nothing is typed into it, the entry stays unrestored, and the output names the pane as skipped

#### Scenario: Run twice
- **WHEN** `restore` runs a second time after a successful restore
- **THEN** no pane receives any input

### Requirement: Put back harness window tags
For each restored or skipped-busy entry, `restore` SHALL set every `@opsx_*` option recorded in the entry on the target window, so harness lookups by tag find the restored window.

#### Scenario: Change window found after restore
- **WHEN** an entry recorded `@opsx_change=add-auth` and `@opsx_agent_cli=claude`, and `restore` runs
- **THEN** `tmux show-options -w` on the target window prints `@opsx_change add-auth` and `@opsx_agent_cli claude`

### Requirement: Remember a window's goal
When `opsx-window.sh ensure` is given `--goal-file`, it SHALL also store the goal text, with newlines turned into spaces, as the window option `@opsx_goal`. A later `ensure` without `--goal-file` SHALL leave the option as it is.

#### Scenario: Goal stored on the window
- **WHEN** `opsx-window.sh ensure add-auth --prompt-file p.md --goal-file g.txt --agent-cli <stub>` runs on a private tmux server and `g.txt` holds `all gates PASS`
- **THEN** the `add-auth` window has `@opsx_goal` set to `all gates PASS`

### Requirement: Continue an unfinished change window
When an entry's window has `@opsx_change`, no `@opsx_pr_repo`, and `@opsx_status` `busy` at save time, `restore` SHALL pass a resume message as the first prompt of `claude --resume <id>`. The message SHALL say that tmux restarted and that the window's last task was not finished, and tell the agent to check where it stopped, continue the same steps and mark the window as before. With `@opsx_goal`, the prompt SHALL start with `/goal <goal>`. The window SHALL then be marked busy.

#### Scenario: Busy change window continued
- **WHEN** the snapshot has an entry for a window with `@opsx_change=add-auth` and `@opsx_status=busy`, and `restore` runs with a stub `claude`
- **THEN** the stub's last argument after `--resume <uuid>` is a message naming the restart and saying to continue, and the window's `@opsx_status` is `busy`

#### Scenario: Goal re-armed
- **WHEN** that entry also has `@opsx_goal=all gates PASS`
- **THEN** the stub's prompt argument starts with `/goal all gates PASS`

#### Scenario: Finished or waiting windows only resumed
- **WHEN** the entry's `@opsx_status` is `idle`, `done`, `fail` or `ask`, or the window has no `@opsx_change`
- **THEN** the stub receives `--resume <uuid>` and no prompt argument

### Requirement: Continue an open PR window
When an entry's window has `@opsx_pr_repo` and `@opsx_change=pr-<n>`, and `@opsx_status` is not `done`, `restore` SHALL run `pr.sh restart-input <n> --repo <recorded cwd>`. When that exits 0, its output SHALL be the first prompt of `claude --resume <id>`. Otherwise the pane SHALL be resumed with no prompt, and the output SHALL name the PR and the reason.

#### Scenario: Open PR continued
- **WHEN** the entry is window `pr-16` with `@opsx_status=idle`, and a stub `pr.sh restart-input 16` prints `/goal keep PR 16 mergeable`
- **THEN** the stub `claude` receives `--resume <uuid>` followed by the prompt `/goal keep PR 16 mergeable`

#### Scenario: Merged PR only resumed
- **WHEN** the stub `pr.sh restart-input 16` exits non-zero saying the PR is `MERGED`
- **THEN** the stub `claude` receives no prompt argument and the restore output names `pr-16` and `MERGED`

### Requirement: Restore without messages
`opsx-sessions.sh restore --no-nudge` SHALL resume every entry with no prompt argument and SHALL not run `pr.sh`.

#### Scenario: No nudge
- **WHEN** `restore --no-nudge` runs for a busy change window and an open PR window
- **THEN** both stubs receive `--resume <uuid>` with no prompt argument, and `pr.sh` is not called

### Requirement: Show the snapshot
`opsx-sessions.sh list` SHALL print one line per snapshot entry with its `session:window.pane`, window name, cwd, session id and whether it is restored. `list --live` SHALL print the hook records of the running server instead.

#### Scenario: Empty snapshot
- **WHEN** no snapshot exists and `list` runs
- **THEN** it exits 0 and says there are no recorded sessions

### Requirement: opsx command entry point
`opsx sessions <hook|save|restore|list> [args]` SHALL run the installed `opsx-sessions.sh` with the same arguments.

#### Scenario: Dispatch
- **WHEN** `opsx sessions list` runs after install in a scratch HOME
- **THEN** it prints the same output as `opsx-sessions.sh list`

### Requirement: Install the hook and the tmux wiring
`install.sh` SHALL add to `~/.claude/settings.json` a `SessionStart` hook that runs the installed `opsx-sessions.sh hook`. It SHALL keep the other hooks and SHALL not add a duplicate on re-install.

#### Scenario: Hook installed
- **WHEN** `install.sh` runs in a scratch HOME
- **THEN** `~/.claude/settings.json` has one `SessionStart` hook naming `opsx-sessions.sh hook`

#### Scenario: Re-install is idempotent
- **WHEN** `install.sh` runs twice
- **THEN** there is still exactly one such `SessionStart` hook and one marked block

### Requirement: Wire the restore into tmux-resurrect
When `~/.tmux.conf` loads tmux-resurrect, `install.sh` SHALL add a marked block, placed before the tpm `run` line, that sets `@resurrect-hook-post-save-all` to `opsx sessions save` and `@resurrect-hook-post-restore-all` to `opsx sessions restore`. If either option is already set outside the block, it SHALL leave the file unchanged and print the lines to add. Without resurrect it SHALL only print them.

#### Scenario: Installed with resurrect
- **WHEN** `install.sh` runs in a scratch HOME whose `~/.tmux.conf` has `set -g @plugin 'tmux-plugins/tmux-resurrect'` and a final `run '~/.tmux/plugins/tpm/tpm'`
- **THEN** `~/.tmux.conf` has the marked block above the `run` line with both hook options

#### Scenario: User hook kept
- **WHEN** `~/.tmux.conf` already sets `@resurrect-hook-post-restore-all` outside the block
- **THEN** `~/.tmux.conf` is unchanged and the output shows the lines to add by hand

### Requirement: Skip and uninstall
`install.sh --skip-restore` SHALL add neither the hook nor the block. `install.sh --uninstall` SHALL remove the `SessionStart` hook entry and the marked block and leave other hooks and lines untouched. The verify step SHALL report whether the hook and the block are in place.

#### Scenario: Skipped
- **WHEN** `install.sh --skip-restore` runs in a scratch HOME
- **THEN** `~/.claude/settings.json` names no `opsx-sessions.sh` and `~/.tmux.conf` has no marked block

#### Scenario: Uninstalled
- **WHEN** `install.sh --uninstall` runs after an install, and `settings.json` also holds an unrelated hook
- **THEN** the unrelated hook remains, no `opsx-sessions.sh` hook remains, and the marked block is gone

### Requirement: Restore at system start
`install.sh --restore-at-boot` SHALL add `set -g @continuum-boot 'on'` to the marked `~/.tmux.conf` block, so a tmux server, and with it the restore, starts with the user's systemd instance. It SHALL check `loginctl show-user <user> -p Linger`. When lingering is off, it SHALL print the `sudo loginctl enable-linger <user>` command and SHALL never run sudo itself. Without the flag, it SHALL add no `@continuum-boot` line. `--uninstall` SHALL remove the line with the block.

#### Scenario: Boot line added
- **WHEN** `install.sh --restore-at-boot` runs in a scratch HOME whose `~/.tmux.conf` loads tmux-resurrect and tmux-continuum, with a stub `loginctl` reporting `Linger=no`
- **THEN** the marked block contains `@continuum-boot 'on'`, the output contains `sudo loginctl enable-linger`, and no `sudo` was invoked

#### Scenario: Linger already on
- **WHEN** the stub `loginctl` reports `Linger=yes`
- **THEN** the output does not contain `enable-linger`

#### Scenario: Not requested
- **WHEN** `install.sh` runs without `--restore-at-boot`
- **THEN** `~/.tmux.conf` has no `@continuum-boot` line written by the installer

### Requirement: Documentation
`README.md` SHALL have a section on restoring sessions after a reboot. It SHALL cover what is restored, the tmux-resurrect requirement, `opsx sessions list|save|restore`, how to restore at system start (`--restore-at-boot`, lingering), and the limits: Claude Code only, which windows are told to continue (and `--no-nudge`), and the last-save window. The component overview SHALL list the feature.

#### Scenario: README documents restore
- **WHEN** `README.md` is read
- **THEN** it names `opsx sessions restore`, `@resurrect-hook-post-restore-all`, `--restore-at-boot`, `enable-linger`, and states that other CLIs are not restored
