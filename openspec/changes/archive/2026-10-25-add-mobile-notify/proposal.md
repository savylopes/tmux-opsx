# Proposal

## Why

opsx windows (changes, `/opsx-pr`, `/opsx-task`, `/fork`) run unattended, and the only signal that one needs a decision or has finished is its tmux title. Away from the terminal the user doesn't see it, so an `ask` window can wait for hours and a finished change sits unnoticed. The user wants those two moments pushed to their Android phone, from a server they host themselves, without noise from their own interactive sessions.

## What Changes

- `install.sh --expose-domain <d>` also installs a self-hosted ntfy server, the same way it installs the Caddy proxy: a pinned, checksum-verified binary, a `tmux-opsx-ntfy` systemd unit, and a static Caddy route in `caddy.json` for the stable URL `https://ntfy.<d>`. It does not use `expose.sh`. ntfy listens only on `127.0.0.1`, denies all access by default, and gets one user (`opsx`, generated password) and one publish token. `--skip-notify` leaves it out, and `--uninstall` removes the unit and the route.
- New `~/.config/tmux-opsx/notify.env` (mode 600) holds `NTFY_URL`, `NTFY_TOPIC` and `NTFY_TOKEN`. Without a domain, the user can point it at any ntfy server.
- New helper `skills/opsx-run/opsx-notify.sh` sends one push. It reads only `notify.env`, sends untrusted text as plain text capped in length, and always exits 0, so it never breaks a caller. `opsx notify test` and `opsx notify info` (URL, user, topic; the password only with `--show-password`) are added to the `opsx` command.
- Pushes are sent only from opsx windows (tagged `@opsx_change`, `@opsx_task` or `@fork_dir`), for two kinds of moments:
  - **decision needed**: `opsx-window.sh mark <w> ask`, `pr.sh note <pr> "<question>"`, and a Claude Code question or permission prompt in an opsx window;
  - **finished**: `mark <w> done` or `fail`, sent as one push together with the agent's final message when the turn ends, and the busy-to-idle silence fallback ("stopped without marking").
- Claude Code gets a `Stop` hook and a `Notification` hook (only the question and permission prompts, never the idle prompt) merged into `~/.claude/settings.json`. They do nothing outside opsx windows. Other CLIs get the script events only, and the README documents the gap.
- The dispatcher prompts written by `/opsx-run`, and the `/opsx-task` and `/fork` prompts, tell the agent to `mark <w> ask` before asking the user something.
- README: the component overview and a Notifications section. The "There are no notifications" line in the `/opsx-pr` section is replaced.

Not in this change: action buttons that answer a question from the phone (follow-up `add-notify-answers`), and a push for every agent turn.

## Capabilities

### New Capabilities
- `mobile-notify`: self-hosted ntfy installed by `install.sh`, the push helper and its config, which events send a push and from which windows, and the Claude Code hooks.

### Modified Capabilities

## Impact

- `install.sh`: ntfy download, config, systemd unit, static Caddy route, user and token, `notify.env`, Claude hooks in `settings.json` (merged, `.bak`), `--skip-notify`, uninstall.
- `skills/opsx-run/opsx-notify.sh` (new), `skills/opsx-run/opsx-window.sh` (`mark`, silence fallback), `skills/opsx-pr/pr.sh` (`note`), `bin/opsx` (`notify` subcommand), the prompt templates in `skills/opsx-run/SKILL.md`, `skills/opsx-task/`, `skills/fork/`.
- `tests/test-notify.sh` (new, fake `curl` and `ntfy`, private tmux server).
- `README.md`, `openspec/config.yaml` context (component list).
- Runtime: a new `127.0.0.1:2586` listener and a public `ntfy.<domain>` hostname guarded by ntfy's own auth. Message text leaves the machine only to the user's own server.
