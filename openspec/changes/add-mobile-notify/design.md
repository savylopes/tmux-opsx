# Design

## Context

- `install.sh --expose-domain <d>` already downloads Caddy into `~/.local/share/tmux-opsx/bin` (with `$OPSX_CADDY_BIN` as an override), writes `~/.config/tmux-opsx/caddy.json` (one `:443` server, a wildcard certificate for `*.<d>` through DNS-01, `"routes": []`, autosave off), and installs the `tmux-opsx-caddy` systemd unit. `expose.sh` adds and deletes only routes whose `@id` is `expose-<label>`, and its labels always contain `--`. A route that `install.sh` writes into `caddy.json` is therefore reloaded on every start and `/load`, and `expose.sh` never touches it.
- `opsx-window.sh mark` already supports `busy|done|fail|idle|ask`. The silence fallback is a tmux hook that runs `mark <w> idle --if-busy`.
- Window tags: change and PR windows `@opsx_change`, task sessions `@opsx_task` (session option), fork child panes `@fork_dir` (pane option).
- Only Claude Code is installed on the dev machine, so hooks for the other CLIs can't be verified here.
- The user's phone runs Android, so the ntfy app connects straight to the server and no `upstream-base-url` is needed.

## Goals / Non-Goals

**Goals:**
- A stable push URL that survives proxy restarts and `expose.sh` changes, and needs no step outside `install.sh`.
- No push path can make `mark`, `pr.sh` or a Claude hook fail or hang for more than about 5 seconds.

**Non-Goals:**
- Pushes for every turn, iOS instant delivery, and answering from the phone (follow-up `add-notify-answers`).
- Turn-end and question hooks for Codex, Gemini, Cursor and OpenCode. Script events still push on those CLIs.

## Decisions

1. **ntfy as a downloaded binary plus a systemd unit, not Docker.** This mirrors Caddy: a pinned release tarball from GitHub, verified against the release's `checksums.txt`, put in the same bin dir, with an `$OPSX_NTFY_BIN` override for tests and air-gapped hosts. The unit `tmux-opsx-ntfy` is installed through the same sudo-or-print path as `tmux-opsx-caddy`. Docker was rejected because the tmux server isn't in the `docker` group, and a system service shouldn't depend on the Docker daemon.

2. **Static route `opsx-ntfy` in `caddy.json`.** It matches host `ntfy.<d>` and reverse-proxies to `127.0.0.1:2586` with streaming (`flush_interval: -1`), so the app's long-lived JSON or WebSocket stream works. It sits before the expose routes, though host matching keeps the two apart either way. `expose_write_caddy_config` writes it only when notify isn't skipped. A changed config reaches a running proxy through the existing `/load` path. Using `expose.sh up --public` was rejected because the URL would carry the project name and depend on the skill.

3. **ntfy does its own auth.** ntfy can't sit behind the expose login, because the app can't carry the cookie. The config sets `auth-default-access: deny-all`, `behind-proxy: true`, `listen-http: 127.0.0.1:2586`, `base-url: https://ntfy.<d>`, and keeps the cache and auth DB under `~/.local/state/tmux-opsx/ntfy/`. `install.sh` creates user `opsx` with a random 24-character password (`ntfy user add`, password via env), grants it read-write on the topic, and creates a token (`ntfy token add`). The topic is a random `opsx-<12 hex>`, so a mistake in the ACL still doesn't expose a guessable name. A re-run reads `notify.env` and creates nothing new while the user and token still work.

4. **`opsx-notify.sh` is the only sender.** Its form is `send <kind> <window-label> <title> [body]`. It sources only `KEY=value` lines from `notify.env`, never executing the file. It POSTs with `curl -fsS --max-time 5 -H "Authorization: Bearer …" -H "Title: …" -H "Tags: …" --data-binary @-`, sends the body on stdin so it never appears in `ps`, cuts it to 500 characters, and passes the title through `tr -d '\r\n'`. Errors are swallowed and the exit is always 0. Kinds map to priority and tags: `decision` is priority 4, tag `question`; `finished` with done is priority 3, `white_check_mark`; with fail it's priority 4, `x`; silence is priority 3, `zzz`.

5. **Collapsing `done`/`fail` with the turn end.** `mark <w> done|fail` sets a window option `@opsx_notify_pending=<status>:<epoch>` and starts a detached flusher (`opsx-notify.sh flush <win> <stamp> --after 60`). The Claude `Stop` hook calls `opsx-notify.sh hook claude-stop`. If the pane's window has a pending stamp, the hook claims it and sends one `finished` push with the final message. The flusher claims it after 60 seconds if it's still there and sends without the message. Claiming means `mkdir` of a per-window lock dir under `$XDG_RUNTIME_DIR` (else `~/.local/state`), then checking that the stamp is unchanged, then unsetting it, so exactly one of the two sends. The final message comes from the hook input's `last_assistant_message` when present, otherwise from the last assistant text entry in `transcript_path`.

6. **Collapsing a bare `mark ask`.** `mark <w> ask` starts a detached sender that waits 5 seconds, then sends "needs a decision" unless that window had a decision push carrying text in the last 30 seconds. `pr.sh note` and the Claude question hook send their text right away and record the time in `@opsx_notify_last_decision`. So a texted push up to 30 seconds before `mark ask` collapses it, and one sent after `mark ask` collapses it only within the 5-second delay; a later texted push arrives as a second push. ntfy cannot recall a message once it is sent, and holding the bare push for 30 seconds would make `mark ask` alone too slow to notice.

7. **Claude hooks.** `PreToolUse` with matcher `AskUserQuestion` sends a `decision` push with the first question and its options as the body. `Notification` with matcher `permission_prompt` sends "waiting for permission". `idle_prompt` is never matched, because windows run with permissions bypassed and an idle prompt follows every finished turn. `Stop` is handled as in decision 5. Every hook command is `<prefix>/skills/opsx-run/opsx-notify.sh hook <event>`, always exits 0, and prints nothing on stdout, so Claude doesn't treat the output as hook feedback. `install.sh` merges these hooks into `settings.json` with `jq` (or `python3` when `jq` is missing), finds its own entries by the `opsx-notify.sh hook` substring, replaces them on a re-run, removes them on `--skip-notify` and `--uninstall`, and writes `.bak` first.

8. **Scope check in one place.** `opsx-notify.sh` resolves the pane from `$TMUX_PANE`, or from `/proc` with the same recovery code `opsx-window.sh` uses (sourced, not copied). It then checks `@fork_dir` on the pane, `@opsx_change` on the window, and `@opsx_task` on the session. The script events (`mark`, `pr.sh note`) pass the window id explicitly and skip pane recovery.

9. **`opsx notify` subcommands** in `bin/opsx`: `test`, which sends a push and exits non-zero with the HTTP status on failure, and `info`, which prints the URL, user and topic, plus the password only with `--show-password`. At the end of `install.sh` it prints the server, user and topic, with "Android: install ntfy, add server https://ntfy.<d>, log in as opsx, subscribe to <topic>", and points at `opsx notify info --show-password` for the password. It never prints the password itself.

## Risks / Trade-offs

- [The `ntfy.<d>` hostname is public] → ntfy denies everything without credentials, and the topic is random. The README says to rotate the password with `ntfy user change-pass` if the phone is lost.
- [Message text leaves the machine] → It goes only to the user's own server, is capped at 500 characters and is sent as plain text. The cache lives on the user's disk.
- [A pending `done` push is lost if the machine sleeps or tmux dies during the 60 seconds] → Accepted. The window title still shows the state.
- [`last_assistant_message` may not exist in every Claude Code version] → Fall back to reading the transcript, and when that fails, send without a body.
- [Hooks are global in `settings.json`] → They return within milliseconds outside opsx panes (one tmux query), and nothing is sent.
- [Pinned ntfy version goes stale] → Bump the version and checksum together in `install.sh`. `$OPSX_NTFY_BIN` lets the user use their own build.

## Migration Plan

Re-run `./install.sh --expose-domain <d>` (the domain is remembered in `expose.env`). Running windows pick up `mark` pushes at once. Claude windows started before the install get the hooks only after a restart, and newly dispatched windows have them. Rollback: `./install.sh --skip-notify`, which removes the route, the unit and the hooks, keeps the ntfy state dir, and restores the earlier behaviour.

## Open Questions

- Which ntfy release to pin. Pick the latest stable at implementation time.
