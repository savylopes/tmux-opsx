# Design

## Context

See proposal.md "Why". Current state that shapes the approach:

- `~/.tmux.conf` loads tpm, tmux-resurrect (`@resurrect-capture-pane-contents on`) and tmux-continuum (`@continuum-save-interval 5`, `@continuum-restore on`). Saves go to `~/.local/share/tmux/resurrect/` (731 files). The `last` link points to the newest save. The pane lines there have the session, window index, pane index, cwd, `pane_current_command` and full command fields.
- `claude` is not in resurrect's default process list, so restored agent panes come back as the default shell. That is good: nothing else is racing to start a bare `claude` in them.
- In the pre-reboot save, `pane_current_command` was `claude` even when the captured full command was the `uvx … browser-use` MCP child. So `pane_current_command = claude` is a reliable "Claude runs here" test. The full command is not.
- One window can hold two Claude panes (`FZTD-72:0` appears twice in the save). So records are per pane, not per window.
- tmux user options (`@opsx_change`, `@opsx_agent_cli`, `@opsx_model`, `@opsx_model_<agent>`, `@opsx_status`, `@opsx_task`, `@opsx_task_repo`, `@opsx_pr_repo`, `@opsx_explain`, `@opsx_preview*`) are not saved by resurrect. `opsx-window.sh` and `pr.sh` find windows only by these tags.
- `opsx-window.sh` `tag_window` sets the tags *after* `new-window` starts the agent, so the `SessionStart` hook can fire before the tags exist.
- Claude Code passes `session_id`, `cwd`, `permission_mode`, `hook_event_name` and `source` (`startup|resume|clear|compact`) on stdin to `SessionStart` hooks. `claude --resume <id>` keeps the same id (unless `--fork-session`) and looks the transcript up under the cwd's project folder.
- `fork.sh`/`explain.sh` already recover a stripped `TMUX`/`TMUX_PANE` from `/proc/<pid>/environ` of ancestors (`recover_env_var`).

## Goals / Non-Goals

**Goals:**
- After an automatic continuum restore, every Claude pane is running its old conversation again, and harness windows have their tags back, with no user action.
- Works the same when resurrect is missing or failed: `opsx sessions restore` rebuilds the missing sessions and windows itself.
- The hook adds no noticeable delay to Claude startup (a few `tmux` calls and one file write).

**Non-Goals:**
- Cursor CLI, Codex CLI, OpenCode, Gemini CLI. None has a session-start hook that this installer already manages. `/opsx-task` keeps resuming them by id. A later change can add a writer per CLI that feeds the same registry.
- Changing launch commands (`-n <change> --session-id` in `build_launch_cmd`). The hook makes that unnecessary for restore. Naming conversations is a possible follow-up.
- Telling idle, done, failed or asking windows to do anything, and continuing `/opsx-task` or hand-started sessions. They are only resumed.
- Restoring pane scrollback beyond what resurrect already does.

## Decisions

### 1. Claude's own `SessionStart` hook is the source of truth, not resurrect's command capture

Resurrect's captured command cannot hold an id that was never on the command line. Parsing `~/.claude/projects/*/*.jsonl` by cwd and mtime would guess wrong when several conversations share a cwd, which is the normal case here: every FACIS window runs in `/home/ubuntu/BSLL/FACIS`. The hook gets the exact id from Claude. It fires again on `/clear`, which mints a new id, so it follows the conversation the user actually sees. `compact` keeps the id, so the hook matcher is `startup|resume|clear`.

Alternative: pass `--session-id` in every harness launch. Rejected as the main mechanism because it misses sessions the user starts by hand, and `/clear`.

### 2. Two layers of state: live records per server, one snapshot

```
~/.local/state/tmux-opsx/sessions/
  live/<server-key>/<pane-id>      written by `hook`  (key=value lines)
  snapshot.tsv                     written by `save`, read and marked by `restore`
```

- `server-key` = `<tmux socket path hash>-<#{start_time}>`. Pane ids (`%12`) restart from zero on a new server. Keying by server means a fresh Claude in `%3` after a reboot can never overwrite the pre-reboot `%3` record before it is restored.
- `save` lists the running server's panes (`list-panes -a -F` with pane id, session, window index and name, pane index, `pane_current_command`). It keeps live records whose pane still runs `claude`, adds the window's `@opsx_*` options (`show-options -w` filtered by prefix), and writes `snapshot.tsv` atomically (temp file + `mv`). Entries from other servers that are not yet marked restored are carried over unchanged. Live directories of dead servers are pruned once none of their entries are pending.
- `restore` marks an entry restored by its `(server-key, pane-id)`. It is idempotent because a marked entry is skipped. Also, a pane that now runs `claude` is never a shell, so a second run has nothing to type into.
- TSV with escaped tabs and newlines, flat like the other harness state files. No `jq` dependency in the hook. The hook JSON is parsed with `python3`, which install already requires for settings merges. If `python3` is missing, a tolerant `sed` fallback pulls only the three string fields and checks the id against the UUID regex.

### 3. Finding the pane from inside the hook

Order: `$TMUX_PANE`, then `recover_env_var TMUX_PANE` (copied verbatim from fork.sh, as explain.sh already does), then walk `$PPID` ancestors and match a pid against `list-panes -a -F '#{pane_id} #{pane_pid}'`. The same walk finds the `claude` ancestor. Its `/proc/<pid>/cmdline` is checked for `-p`/`--print` to skip print mode. Not in tmux, or no pane found → exit 0 silently. The hook never fails Claude startup.

### 4. Restore types into the pane; it does not respawn it

`restore` sends `cd -- <cwd> && claude --resume <id> [--permission-mode <m>] [--model <m>]` as literal text plus Enter, through a new `opsx-window.sh type <pane-target> --text-file <f>`. That keeps the project rule that only opsx-window.sh calls `send-keys`. Typing, rather than `respawn-pane -k`, keeps the restored shell and its scrollback, and leaves a normal shell behind when the user later exits Claude, the same as a window the user opened by hand.

- Shell test: `pane_current_command` is in `bash|zsh|sh|fish|dash|ksh`. Anything else is reported as skipped. Tags are still applied, because a busy pane in the right window still needs its window found by tag.
- `--permission-mode` is passed only when it is not `default`, so harness windows come back as `bypassPermissions` and hand-started sessions keep what they had.
- `--model` comes only from the window's `@opsx_model` (what the harness launched with). The hook's per-session model is not used: `/model` changes after start are invisible to it, and pinning a stale model is worse than the user's default.
- Ordering: entries are processed by session, window index, pane index. A missing session is created with `new-session -d -s <name> -c <cwd>`, a missing window with `new-window -d -t <sess>:<idx> -n <name> -c <cwd>`. Missing panes in an existing window are not recreated (layout is resurrect's job). The entry is reported as skipped.
- Before writing, session and window names are checked against the same safe-name rules the harness uses, and ids against the UUID regex, so snapshot content cannot inject shell text into the typed command. cwd is `printf %q`-quoted.

### 5. Wiring into resurrect through its hooks, installed into `~/.tmux.conf`

```
# >>> tmux-opsx session restore >>>
set -g @resurrect-hook-post-save-all 'opsx sessions save'
set -g @resurrect-hook-post-restore-all 'opsx sessions restore'
# <<< tmux-opsx session restore <<<
```

The block goes immediately above the tpm `run` line (or at the end if there is none), with a `.bak` per the install convention. This is the first time install.sh edits `~/.tmux.conf`. It is opt-out via `--skip-restore`, never clobbers an existing value of either option, and only touches a file that already loads tmux-resurrect. Continuum's auto-restore goes through resurrect's restore, so the post-restore hook covers boot. The hook runs `opsx` through the user's shell, so the installer uses the absolute path of the installed `opsx` in the block to avoid depending on tmux's `PATH`.

Alternative: a tmux `session-created`/`client-attached` hook running `restore`. Rejected: it fires for every new session and could race resurrect's own restore.

### 6. Claude settings merge reuses the existing Python merge pattern

Same shape as the gemini `BeforeTool` merge in install.sh: load the JSON, drop entries whose command names `opsx-sessions.sh`, append ours under `hooks.SessionStart` with matcher `startup|resume|clear`, write with `.bak`. Uninstall drops only our entries and removes empty containers. The command is `bash <prefix>/skills/opsx-run/opsx-sessions.sh hook`, honouring `--prefix`/`CLAUDE_CONFIG_DIR`.

### 7. Continuing unfinished work: the message rides on the resume command

- **Delivery.** `claude [options] [prompt]` takes a first prompt with `--resume`, so restore types `… claude --resume <id> [flags] "<message>"` (message `printf %q`-quoted). There is no wait for the TUI to be ready and no second send into the pane. `ensure` already launches new Claude windows with `/goal …` as that argument, so this is the same path.
- **Change windows decide by `@opsx_status`, captured at save.** `busy` means the agent was working: Claude's spinner keeps the pane from going silent, so the 40 s silence fallback does not flip a working window to idle. `ask` waits for the user, and `idle/done/fail` are finished, so none of those get a message. After sending, restore runs `opsx-window.sh mark <change> busy`, so the badge and silence watch come back.
- **PR windows decide by the PR, not the badge.** A maintain window sits in `pr.sh wait` for up to 540 s, so its status falls back to idle while its job goes on. Restore therefore asks `pr.sh restart-input <n> --repo <cwd>`. It reuses `start`'s refusal checks (open, not a fork) and prompt and goal writers, but never touches tmux, and prints the first input. `restart-input` is not a flag on `start`, because `start` always types into or creates the window, and restore must own the pane. Exit 0 → that output is the prompt; non-zero → resume with no prompt and report why. Only `done` windows (PR merged or closed, marked by the window) skip the call.
- **Goal text lives on the window.** `ensure --goal-file` stores the condition in `@opsx_goal`. The goal file and the `.goal` wrapper sit next to the caller's prompt file, often a `/tmp` scratchpad that a reboot wipes. A window option rides along with the generic `@opsx_*` capture at save, with no new state file. The re-armed prompt is `/goal <goal> <resume message>`, kept under the 4000-character cap by the same check `goal_prompt_file` uses (if it would go over, the goal is dropped and the plain message is sent).
- `--no-nudge` resumes everything bare, for a reboot where the user wants to look first.

### 8. Start at boot through continuum, opt-in

The restore runs when a tmux server starts. Today that is the first `tmux` after login. `--restore-at-boot` adds `set -g @continuum-boot 'on'` to the marked block: continuum then installs its own systemd user unit that starts a tmux server, whose auto-restore runs our post-restore hook. Without lingering, user units start only at login, so the installer checks `loginctl show-user $USER -p Linger` and prints `sudo loginctl enable-linger $USER` when it is off. It never runs sudo, the same as expose-install's privileged steps. Continuum writes its unit the next time tmux loads the config, so the installer tells the user to run `tmux source ~/.tmux.conf`.

- Opt-in: at boot, every busy window resumes and continues by itself (about 30 here). The default nudge stays on; the README shows how to pass `--no-nudge` in the hook line for users who want to look first.
- Alternative: a tmux-opsx systemd unit of our own. Rejected because continuum already ships one and is already configured here; two would race to start the server.

## Risks / Trade-offs

- [`/goal` given as the first prompt of a *resumed* session may behave differently from a fresh launch] → The stub tests only prove the argument is passed. Task 7.1 checks it against the real `claude` on a private tmux server before archive. If it is not honoured, fall back to the plain message, which still carries the goal text.
- [A continued agent repeats a side effect it had half done (a push, a PR comment)] → The message tells it to check where it stopped first. `/opsx-pr` pushes are lease-protected and its handled events are recorded with `seen`.

- [The hook fires before the window gets its `@opsx_*` tags] → Tags are read at `save`, not at hook time (Decision 2).
- [A crash between continuum saves loses the newest windows] → Same guarantee as resurrect itself (≤5 min). `opsx sessions save` can also be run by hand.
- [Restore types into a shell that is not ready yet, right after resurrect starts it] → Text queued on the pty is read when the shell starts. The tests cover a freshly created window.
- [`claude --resume` for a transcript that was deleted] → Claude prints an error in that pane and leaves the shell. The entry is still marked restored, so it is not retried forever. `list` shows it.
- [Many panes resuming at once (≈30 here) load the machine and the API at boot] → Acceptable for a personal box. Restore sends with no delay. If this proves noisy, a small stagger can be added without spec changes.
- [Resurrect is later configured to restore `claude` itself] → That pane then runs `claude` and restore skips it as busy. The README says to keep `claude` out of `@resurrect-processes`.
- [Hook errors could block Claude startup] → It always exits 0, writes nothing to stdout, and has a short timeout in the settings entry.

## Migration Plan

Run `./install.sh`. The current conversations get recorded the next time they start, resume or clear, so the first reboot after install restores only sessions started or resumed since then. To cover today's restored-but-empty panes, resume each once by hand (or with `/opsx-task`, which already knows its ids). For start at boot: `./install.sh --restore-at-boot`, then the printed `sudo loginctl enable-linger` command if any, then `tmux source ~/.tmux.conf`. Rollback: `./install.sh --uninstall`, or delete the marked block and the `SessionStart` entry. The state directory can simply be removed.
