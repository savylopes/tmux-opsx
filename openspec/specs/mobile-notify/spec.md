# mobile-notify Specification

## Purpose
TBD - created by archiving change add-mobile-notify. Update Purpose after archive.

## Requirements

### Requirement: Self-hosted ntfy installed by install.sh
`install.sh --expose-domain <d>` SHALL install, without calling `expose.sh`, a pinned checksum-verified ntfy binary, a config that listens only on `127.0.0.1` with base URL `https://ntfy.<d>` and denies all access by default, a `tmux-opsx-ntfy` systemd unit installed like `tmux-opsx-caddy`, and a static `opsx-ntfy` route in `caddy.json` for host `ntfy.<d>`. `--skip-notify` SHALL install none of it.

#### Scenario: Route in the base config
- **WHEN** `install.sh --expose-domain dev.example.com` runs in a scratch HOME with fake `caddy`, `ntfy` and `systemctl`
- **THEN** `caddy.json` has a route with `@id` `opsx-ntfy` matching host `ntfy.dev.example.com` and proxying to `127.0.0.1:2586`, and the ntfy config has `base-url: https://ntfy.dev.example.com` and `auth-default-access: deny-all`

#### Scenario: Expose routes are untouched
- **WHEN** `expose.sh` adds and removes a route after the install
- **THEN** the `opsx-ntfy` route is still in the proxy config

#### Scenario: Skipped
- **WHEN** `install.sh --expose-domain dev.example.com --skip-notify` runs in a fresh scratch HOME
- **THEN** there is no `opsx-ntfy` route, no `tmux-opsx-ntfy` unit and no `notify.env`

#### Scenario: Uninstalled
- **WHEN** `install.sh --uninstall` runs after an install with ntfy
- **THEN** the `tmux-opsx-ntfy` unit file and the `opsx-ntfy` route are gone

### Requirement: ntfy credentials
`install.sh` SHALL create one ntfy user `opsx` with a generated password, a random topic the user may read and write, and a publish token, and SHALL keep them on a re-run while they still work.

#### Scenario: Re-run keeps the credentials
- **WHEN** `install.sh --expose-domain dev.example.com` runs a second time
- **THEN** `notify.env` has the same `NTFY_TOKEN` and `NTFY_TOPIC`, and no second ntfy user is created

### Requirement: Notification config
The push helper SHALL read its settings only from `~/.config/tmux-opsx/notify.env` (`NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`), which `install.sh` writes with mode 600. The file SHALL also work when written by hand for any ntfy server. The token and the ntfy password SHALL never be written to the repository, to a window prompt, or to stdout, except `opsx notify info --show-password` prints the password.

#### Scenario: Private file
- **WHEN** `install.sh --expose-domain dev.example.com` writes `notify.env`
- **THEN** the file's mode is `600`

#### Scenario: Info hides the password
- **WHEN** `opsx notify info` runs
- **THEN** it prints the ntfy URL, the user `opsx` and the topic, and does not print the password or the token

### Requirement: Send a push without breaking the caller
The push helper SHALL send one ntfy message to the configured topic, authenticated with the token, with a timeout of at most 5 seconds. The body SHALL be plain text (no Markdown rendering), cut to at most 500 characters, and the helper SHALL never print the token.

#### Scenario: Long body is capped
- **WHEN** the body is 2000 characters
- **THEN** the fake `curl` receives a body of at most 500 characters and no `Markdown: yes` header

### Requirement: Push failures never break the caller
The push helper SHALL exit 0 when `notify.env` is missing or incomplete, and when the server cannot be reached or rejects the message. `opsx notify test` SHALL send a test message and report a failure with a non-zero exit.

#### Scenario: Not configured
- **WHEN** `notify.env` does not exist and `opsx-notify.sh finished "t" "b"` runs
- **THEN** it exits 0 and the fake `curl` is not called

#### Scenario: Server down
- **WHEN** the fake `curl` fails with exit 7
- **THEN** `opsx-notify.sh finished "t" "b"` exits 0

#### Scenario: Test reports failure
- **WHEN** the fake `curl` fails and `opsx notify test` runs
- **THEN** it exits non-zero and says the push failed

### Requirement: Pushes only from opsx windows
A push SHALL be sent only for a pane in a window tagged `@opsx_change` or `@opsx_task`, or a pane tagged `@fork_dir`. Hooks running in any other pane, or outside tmux, SHALL send nothing and exit 0. When `$TMUX_PANE` is stripped from the environment, the pane SHALL be recovered the same way `opsx-window.sh` recovers it.

#### Scenario: Plain window stays quiet
- **WHEN** the Claude Code `Stop` hook runs in a pane of an untagged window
- **THEN** the fake `curl` is not called and the hook exits 0

#### Scenario: Fork pane sends
- **WHEN** a Claude Code question prompt fires in a pane tagged `@fork_dir`
- **THEN** one push of kind `decision` is sent

### Requirement: Push when a decision is needed
A `decision` push naming the window SHALL be sent when `opsx-window.sh mark <w> ask` runs, when `pr.sh note <pr> "<question>"` records a question (with the question as its body), and when Claude Code shows a question or a permission prompt in an opsx pane. The Claude Code idle prompt SHALL NOT send a push.

#### Scenario: Mark ask
- **WHEN** `opsx-window.sh mark pr-42 ask` runs on a private tmux server
- **THEN** the fake `curl` receives one message whose title contains `pr-42`

#### Scenario: PR question
- **WHEN** `pr.sh note 42 "keep theirs or ours in api.ts?"` runs
- **THEN** the pushed body contains `keep theirs or ours in api.ts?`

#### Scenario: Idle prompt is ignored
- **WHEN** the Claude Code `Notification` hook fires with type `idle_prompt` in an opsx pane
- **THEN** no push is sent

### Requirement: One decision push per question
When a push carrying the question text is sent for a window up to 30 seconds before `mark ask`, or up to 5 seconds after it, only the push with the text SHALL be sent.

#### Scenario: Mark ask and note collapse
- **WHEN** `opsx-window.sh mark pr-42 ask` runs and `pr.sh note 42 "rebase onto main or develop?"` runs two seconds later
- **THEN** the fake `curl` receives exactly one message, and its body contains `rebase onto main or develop?`

### Requirement: Prompts mark ask before asking
The dispatcher prompts written by `/opsx-run`, and the `/opsx-task` and `/fork` prompts, SHALL tell the agent to mark its window `ask` before asking the user a question.

#### Scenario: Dispatcher prompt says to mark ask
- **WHEN** `/opsx-run` writes a validate dispatcher prompt
- **THEN** the prompt tells the agent to run `opsx-window.sh mark <change> ask` before asking the user

### Requirement: One push when a window finishes
When `mark <w> done` or `fail` runs, exactly one `finished` push SHALL be sent. On Claude Code it SHALL be sent at the turn end with the agent's final message as body; when no turn end follows within 60 seconds, or the CLI has no turn-end hook, it SHALL be sent without it. A turn end without a preceding `done` or `fail` SHALL send nothing.

#### Scenario: Done and turn end collapse
- **WHEN** `mark fix-x done` runs and the Claude Code `Stop` hook then fires in that window with final message "all gates passed"
- **THEN** the fake `curl` receives exactly one message, its title contains `fix-x` and `done`, and its body contains `all gates passed`

#### Scenario: No hook follows
- **WHEN** `mark fix-x fail` runs and no `Stop` hook fires within 60 seconds
- **THEN** one message is sent whose title contains `fix-x` and `fail`

#### Scenario: Ordinary turn end
- **WHEN** the `Stop` hook fires in an opsx window that was not marked `done` or `fail`
- **THEN** no push is sent

### Requirement: Push when a window goes silent
When a busy window falls back to idle on silence, a `finished` push saying the window stopped without marking SHALL be sent.

#### Scenario: Silence fallback
- **WHEN** a busy window falls back to idle through `mark <w> idle --if-busy`
- **THEN** one message is sent saying the window stopped without marking

### Requirement: Claude Code hooks installed safely
`install.sh` SHALL add the `Stop` hook and a `Notification` hook for question and permission prompts to `~/.claude/settings.json`, keeping every other setting and hook, writing a `.bak` copy first (unless `--no-backup`), and not adding them twice on a re-run. `--skip-notify` and `--uninstall` SHALL leave no tmux-opsx notify hooks there. The README SHALL say which CLIs send only script events (`mark`, `pr.sh note`) and lack question and turn-end pushes.

#### Scenario: Existing hooks kept
- **WHEN** `settings.json` already has a `PreToolUse` hook and `install.sh` runs twice
- **THEN** the `PreToolUse` hook is unchanged and the tmux-opsx `Stop` hook appears exactly once

#### Scenario: Hooks removed on uninstall
- **WHEN** `install.sh --uninstall` runs
- **THEN** `settings.json` has no hook command pointing at `opsx-notify`
