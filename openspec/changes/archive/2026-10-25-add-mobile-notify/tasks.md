# Tasks

## 1. Push helper and config

- [x] 1.1 Add `skills/opsx-run/opsx-notify.sh send <kind> <window-label> <title> [body]`: read only `KEY=value` lines from `~/.config/tmux-opsx/notify.env`, exit 0 silently when it is missing or incomplete, POST with `curl -fsS --max-time 5`, Bearer token, `Title`/`Tags`/`Priority` headers per kind, body on stdin cut to 500 characters, title stripped of newlines, never print the token, always exit 0; verify with a new `tests/test-notify.sh` (fake `curl` on PATH logging argv, headers and stdin to a file) covering: not configured → no call, curl exit 7 → exit 0, 2000-character body → at most 500 characters and no `Markdown: yes`, token absent from stdout and stderr
- [x] 1.2 Add the pane scope check to `opsx-notify.sh`: resolve the pane from `$TMUX_PANE` or the `/proc` recovery shared with `opsx-window.sh`, and allow only `@fork_dir` panes, `@opsx_change` windows and `@opsx_task` sessions; verify with test cases on a private tmux server (`tmux -L`): untagged window → no call and exit 0, each of the three tags → one call, `$TMUX_PANE` unset in an opsx pane → still one call
- [x] 1.3 Add `opsx notify test` (sends a push, exits non-zero with the HTTP status on failure) and `opsx notify info [--show-password]` (URL, user, topic; password only with the flag; never the token) to `bin/opsx`; verify with test cases for test-ok, test-fail (fake curl fails → non-zero, "push failed"), and info hiding the password and token

## 2. Decision pushes

- [x] 2.1 Make `opsx-window.sh mark <w> ask` start a detached sender that waits 5 s and sends a `decision` push naming the window, unless the window recorded a texted decision push (`@opsx_notify_last_decision`) in the last 30 s; verify with test cases: `mark pr-42 ask` → one push whose title contains `pr-42`; `mark ask` then a texted push 2 s later → exactly one push, with the text
- [x] 2.2 Make `pr.sh note <pr> "<question>"` send a `decision` push with the question as body right away and record `@opsx_notify_last_decision` on the PR window; verify with test cases in `tests/test-pr.sh` or `tests/test-notify.sh`: body contains the question, and `note` still exits 0 and writes `ask=` when notify is not configured; `bash tests/test-pr.sh` still passes
- [x] 2.3 Add "run `opsx-window.sh mark <w> ask` before you ask the user a question" to the dispatcher prompt templates in `skills/opsx-run/SKILL.md`, and to the prompts written by `skills/opsx-task/` and `skills/fork/`; verify with test cases that a validate dispatcher prompt, an `opsx-task` brief prompt and a fork protocol contain the `mark … ask` line, and that `tests/test-fork.sh` still passes

## 3. Finished pushes

- [x] 3.1 Make `mark <w> done|fail` set `@opsx_notify_pending=<status>:<epoch>` and start a detached `opsx-notify.sh flush <win> <stamp> --after 60` that claims the stamp (lock dir + unchanged stamp + unset) and sends a `finished` push without the final message; make `OPSX_NOTIFY_FLUSH_AFTER` override the 60 s for tests; verify with test cases: `mark fix-x fail` and no hook → exactly one push with `fix-x` and `fail` in the title
- [x] 3.2 Add `opsx-notify.sh hook claude-stop`: read the hook JSON on stdin, check scope, claim a pending stamp if there is one, and send one `finished` push with `last_assistant_message`, or the last assistant text from `transcript_path`, as body; send nothing when no stamp is pending; print nothing on stdout; verify with test cases: `mark fix-x done` then the hook with final message "all gates passed" → exactly one push containing it (and the flusher sends nothing later), hook without pending → no push, hook with only `transcript_path` → body from the transcript
- [x] 3.3 Make the silence fallback (`mark <w> idle --if-busy` turning a busy window idle) send a `finished` push saying the window stopped without marking, and send nothing when `--if-busy` skips; verify with test cases for both

## 4. Claude Code question and permission hooks

- [x] 4.1 Add `opsx-notify.sh hook claude-pretool` (only for `AskUserQuestion`: first question plus its option labels as body, records `@opsx_notify_last_decision`) and `hook claude-notification` (only `permission_prompt` → "waiting for permission"; `idle_prompt` and other types → nothing); verify with test cases using sample hook JSON: AskUserQuestion in a fork pane → one `decision` push with the question, `idle_prompt` → no push, other tool names → no push

## 5. Self-hosted ntfy in install.sh

- [x] 5.1 Add ntfy fetching to `install.sh`: `$OPSX_NTFY_BIN` override, else a pinned release tarball from GitHub verified against a sha256 per arch pinned in `install.sh` (taken from the release's `checksums.txt`), put in the Caddy bin dir; `--skip-notify` flag and usage text; verify in a scratch HOME with a fake `ntfy` through `$OPSX_NTFY_BIN` that the install step reports it, and that a checksum mismatch aborts without leaving a binary
- [x] 5.2 Write the ntfy `server.yml` (`base-url: https://ntfy.<d>`, `listen-http: 127.0.0.1:2586`, `behind-proxy: true`, `auth-default-access: deny-all`, cache and auth DB under `~/.local/state/tmux-opsx/ntfy/`) and the `tmux-opsx-ntfy` unit, installed through the same sudo-or-print path as `tmux-opsx-caddy`; verify in a scratch HOME with fake `systemctl` that both files have the expected content and the unit's `ExecStart` points at the installed binary and config
- [x] 5.3 Add the static `opsx-ntfy` route (host `ntfy.<d>` → `127.0.0.1:2586`, `flush_interval: -1`) to `expose_write_caddy_config` unless `--skip-notify`; verify that `caddy.json` has it, that `--skip-notify` leaves it out, and that an `expose.sh up`/`down` round-trip against a fake admin API keeps it (the "Expose routes are untouched" scenario)
- [x] 5.4 Create the ntfy user `opsx` (random password), the read-write grant on a random `opsx-<12 hex>` topic and a token, and write `notify.env` with mode 600; on a re-run keep the existing values while they still work; print the Android setup lines (server, user, topic) at the end, never the password (the lines name `opsx notify info --show-password` to read it); verify with a fake `ntfy` that logs its calls: first run creates the user once and `notify.env` has mode `600`, a second run makes no `user add` and keeps `NTFY_TOKEN` and `NTFY_TOPIC`
- [x] 5.5 Merge the `PreToolUse` (`AskUserQuestion`), `Notification` (`permission_prompt`) and `Stop` hooks into `~/.claude/settings.json` (jq, else python3), with `.bak` unless `--no-backup`, replacing earlier tmux-opsx entries by the `opsx-notify.sh hook` substring; remove them on `--skip-notify`; verify with a `settings.json` that already has a `PreToolUse` hook: after two runs it is unchanged and the tmux-opsx `Stop` hook appears once
- [x] 5.6 Extend `--uninstall` to remove the `tmux-opsx-ntfy` unit, the `opsx-ntfy` route, the hooks and `opsx-notify.sh`, keeping the ntfy state dir; add `opsx-notify.sh` to every skills dir `install.sh` copies `opsx-run` into, plus a parse check; verify in a scratch HOME that uninstall leaves no unit, no route and no `opsx-notify` hook command, and that `bash tests/test-eval.sh` still passes

## 6. Docs

- [x] 6.1 Update `README.md`: component overview row for `opsx-notify.sh` and the ntfy service, a Notifications section (what pushes and when, which windows, Android setup with `opsx notify info`, `opsx notify test`, password rotation with `ntfy user change-pass`, `--skip-notify`, which CLIs lack question and turn-end pushes), and replace "There are no notifications" in the `/opsx-pr` section; add the notify helper to the component list in `openspec/config.yaml` context; verify the documented commands match `opsx notify --help` and `install.sh --help`

## 7. Integration

- [x] 7.1 Run `bash tests/test-notify.sh`, `bash tests/test-pr.sh`, `bash tests/test-fork.sh`, `bash tests/test-eval.sh`, and `shellcheck` on every changed script; run `./install.sh --expose-domain dev.example.com` in a scratch HOME with fake `caddy`, `ntfy` and `systemctl` and check `opsx notify info`; verify all pass

## Workflow follow-up

- ops-eval writes the checks under `evals/mobile-notify/`.
- After landing, re-run `./install.sh` on the real machine, set up the ntfy Android app with `opsx notify info --show-password`, and run `opsx notify test`.
- Follow-up change `add-notify-answers`: ntfy action buttons that answer a question through a signed, single-use answer endpoint.
