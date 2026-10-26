# Proposal

## Why

Pushes from opsx windows tell the user that an agent needs a decision, but answering still means walking to a terminal, and the push has no way to open the PR, preview or page it is about. Most questions the agents ask are a choice between two or three fixed options, so a tap on the phone could answer them, and the links the user would open next are already known to the scripts that send the push.

## What Changes

- Pushes get ntfy action buttons (at most 3 per message):
  - **Answer buttons** (ntfy `http` actions) on a Claude Code `AskUserQuestion` push that has exactly one single-select question with 1-3 options, and on a `pr.sh note` push that has 1-3 options.
  - **Link buttons** (ntfy `view` actions) on decision and finished pushes: Open PR (a `pr-<n>` window with `@opsx_pr_repo`), Open preview (a running preview of the window's change), Open page (a `/fork` page pane whose page has a URL), each only when it exists. Answer buttons take the slots first.
- Replies go back through the user's own ntfy: an answer button POSTs `<nonce>:<n>` to a private reply topic with a write-only reply token. No new public endpoint.
- New `opsx-notify.sh listen`, run by a `tmux-opsx-notify-listen` systemd user unit, subscribes to the reply topic and delivers a valid reply into the asking pane:
  - `AskUserQuestion`: the key sequence that selects option n in Claude Code's question menu (found by a spike against a real Claude pane; if no sequence is reliable, Claude questions get link buttons only).
  - `pr.sh note`: the chosen option's label typed as a line through `opsx-window.sh type`.
- A reply acts only with a live nonce: single use, at most 1 hour old, and only while the window still shows that question. Any other tap sends one "already answered" push and does nothing else. A reply can only pick an offered option, never send free text.
- `pr.sh note <pr> "<question>" --option <label>` (repeatable, 1-3) and the PR window prompt tells the agent to pass options when the decision has 2-3 fixed choices.
- `install.sh --expose-domain` creates the reply topic, an `opsx-reply` ntfy user with write-only access to it, its token, read access for `opsx`, writes `NTFY_REPLY_TOPIC` / `NTFY_REPLY_TOKEN` to `notify.env`, and installs the listener unit; `--skip-notify` and `--uninstall` remove the unit.
- README: buttons, the reply path and its trust model, and that preview/page links need the expose owner login once on the phone.

## Capabilities

### New Capabilities
- `notify-actions`: action buttons on pushes — which pushes get answer or link buttons, the reply topic and token, the listener and its delivery and validity rules.

### Modified Capabilities
- `mobile-notify`: the ntfy credentials and `notify.env` gain the reply topic and reply token, and install/uninstall cover the listener unit.
- `pr-maintain`: the PR window asks fixed-choice questions with `pr.sh note --option`.

## Impact

- `skills/opsx-run/opsx-notify.sh`: `Actions` header, nonce records on tmux windows, `listen`, `menu-keys`.
- `skills/opsx-run/opsx-window.sh`: a `keys` subcommand for sending a fixed key sequence to a pane (no hand-rolled `send-keys`).
- `skills/opsx-pr/pr.sh` and the PR window prompt: `note --option`.
- `install.sh`: reply user/topic/token, `notify.env` keys, listener user unit, uninstall.
- `tests/test-notify.sh`, `tests/test-pr.sh` (fake curl/ntfy, private tmux server), README, `openspec/config.yaml` context.
- Security surface: a phone tap can now type into an agent pane running with bypassed permissions; bounded by the write-only token, live single-use nonces, the still-asking check and options-only replies.
