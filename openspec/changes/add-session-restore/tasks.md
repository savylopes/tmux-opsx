# Tasks

## 1. Registry writer (hook)

- [x] 1.1 Create `skills/opsx-run/opsx-sessions.sh` with usage header, state dir `~/.local/state/tmux-opsx/sessions/` (overridable by `OPSX_SESSIONS_DIR` for tests), the server key (`socket hash-#{start_time}`), and `recover_env_var` copied from `skills/fork/fork.sh`; verify `shellcheck skills/opsx-run/opsx-sessions.sh` is clean
- [x] 1.2 Implement `hook`: parse stdin JSON (python3, sed fallback), validate the UUID, find the pane (`TMUX_PANE` → recovered env → ancestor pid ↔ `pane_pid`), skip print mode via the claude ancestor's cmdline, write `live/<server-key>/<pane-id>` atomically, always exit 0 with empty stdout; implement `list --live`
- [x] 1.3 Create `tests/test-restore.sh` (private `tmux -L` server, scratch HOME, stub `claude` that records argv and cwd) with cases: hook records the pane, clear replaces the id, stripped `TMUX_PANE`, outside tmux, print mode, malformed id; verify `bash tests/test-restore.sh` passes

## 2. Snapshot (save)

- [x] 2.1 Implement `save`: list panes, keep live records whose pane runs `claude`, take position/window name and the window's `@opsx_*` options at save time, carry over unrestored entries of other servers, prune dead servers' live dirs with nothing pending, write `snapshot.tsv` atomically with escaped fields
- [x] 2.2 Implement `list` (snapshot view, "no recorded sessions" when empty)
- [x] 2.3 Add test cases: moved/renamed window, exited conversation dropped, tags captured at save, unrestored entries survive a save on a new server, empty snapshot; verify `bash tests/test-restore.sh` passes

## 3. Replay (restore)

- [x] 3.1 Add `opsx-window.sh type <pane-target> --text-file <f>` (literal send + Enter, refuses a missing target) and document it in the usage header; verify `bash tests/test-fork.sh` and `tests/test-agent-models.sh` still pass
- [x] 3.2 Implement `restore`: ordered by session/window/pane, validate names/ids, create missing session/window with recorded name and cwd, type `cd -- <cwd> && claude --resume <id> [--permission-mode m] [--model @opsx_model]` into shell panes via `opsx-window.sh type`, skip and report busy panes and missing panes, re-apply `@opsx_*` options, mark entries restored
- [x] 3.3 Add test cases: pane resumed (stub argv/cwd), missing window created, busy pane left alone, run twice sends nothing, tags put back; verify `bash tests/test-restore.sh` passes

## 4. Continue unfinished work

- [x] 4.1 In `opsx-window.sh ensure`, store the `--goal-file` text (newlines → spaces) as `@opsx_goal`; add a case to `tests/test-agent-models.sh` or `tests/test-restore.sh` checking the option, and verify `bash tests/test-fork.sh` still passes
- [x] 4.2 Add `pr.sh restart-input <pr> [--repo <dir>]` (reuse `start`'s open/fork refusal and prompt/goal writers, keep the state file, print the first input, no tmux) and document it in `skills/opsx-pr/SKILL.md`; add open-PR and merged-PR cases to `tests/test-pr.sh` and verify it passes
- [x] 4.3 In `restore`, build the prompt argument: busy change window → resume message (prefixed by `/goal <@opsx_goal>` when set, within 4000 chars), then `opsx-window.sh mark <change> busy`; PR window not done → `pr.sh restart-input` output, or no prompt plus a reported reason; everything else and `--no-nudge` → no prompt
- [x] 4.4 Add stub-argv cases to `tests/test-restore.sh`: busy change window continued, goal re-armed, idle/done/fail/ask only resumed, open PR continued, merged PR only resumed, `--no-nudge`; verify the test passes

## 5. Entry point and install

- [x] 5.1 Add `sessions` to `bin/opsx` (dispatch to `opsx-run/opsx-sessions.sh`, usage line); verify `opsx sessions list` matches `opsx-sessions.sh list` in a scratch HOME
- [x] 5.2 In `install.sh`: install `opsx-sessions.sh` with the opsx-run skill files, merge/unmerge the Claude `SessionStart` hook (matcher `startup|resume|clear`, short timeout, `.bak`), add/remove the marked `~/.tmux.conf` block above the tpm `run` line only when resurrect is loaded and neither hook option is set elsewhere (else print the lines), use the absolute installed `opsx` path, add `--skip-restore`, extend the verify step
- [x] 5.3 Add install cases to `tests/test-restore.sh` (scratch HOME): installed with resurrect, re-install idempotent, user hook kept, `--skip-restore`, `--uninstall` keeps an unrelated hook; verify the test passes and `shellcheck install.sh` is clean
- [x] 5.4 Add `--restore-at-boot` to `install.sh`: `@continuum-boot 'on'` in the marked block, Linger check through `loginctl` with the `sudo loginctl enable-linger` hint (never run sudo), `tmux source` reminder, removed on `--uninstall`; add boot-line, linger-on and not-requested cases (stub `loginctl`) to `tests/test-restore.sh` and verify it passes

## 6. Documentation

- [x] 6.1 Add README section "Restoring sessions after a reboot" (what comes back, tmux-resurrect requirement, keep `claude` out of `@resurrect-processes`, `opsx sessions list|save|restore`, `--no-nudge` (and how to put it in the hook line), start at boot with `--restore-at-boot` + `enable-linger`, limits: Claude only, which windows are told to continue and `--no-nudge`, last-save window, first reboot after install), add `--skip-restore` and `--restore-at-boot` to the install flags, the components table and a line in the overview tree; update the `openspec/config.yaml` context product-surface list; verify `grep -n "opsx sessions restore\|@resurrect-hook-post-restore-all" README.md` finds both

## 7. Integration check

- [ ] 7.1 On a private tmux server with resurrect-style restore simulated (kill server, recreate sessions/windows as shells, run `opsx sessions restore`), confirm two split Claude panes in one window and a hand-started session each resume their own id, that `opsx-window.sh` finds a restored change window by `@opsx_change` instead of opening a duplicate, and, with the real `claude`, that a busy `--validate` window resumed with `/goal <goal> <message>` has its goal active and continues
