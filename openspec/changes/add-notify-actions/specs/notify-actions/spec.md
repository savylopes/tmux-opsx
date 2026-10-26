## Purpose

Action buttons on the pushes sent from opsx windows: answer buttons that let the user pick an offered option from the phone, delivered back into the asking pane through the user's own ntfy, and link buttons that open the PR, preview or page the push is about.

## ADDED Requirements

### Requirement: At most three buttons per push
A push SHALL carry at most 3 ntfy actions. Answer buttons SHALL come first, in option order, and link buttons SHALL fill the remaining slots. A push with nothing to offer SHALL carry no `Actions` header, so it looks exactly as before.

#### Scenario: Three options leave no room for links
- **WHEN** a `pr.sh note` push with 3 options is sent for a `pr-42` window whose PR link exists
- **THEN** the `Actions` header sent to the fake `curl` has exactly 3 actions, all `http`, in option order

#### Scenario: Plain push unchanged
- **WHEN** `mark fix-x done` sends its push for a window with no PR, no preview and no page
- **THEN** the request has no `Actions` header

### Requirement: Answer buttons for a single Claude question
A Claude Code `AskUserQuestion` push SHALL get one `http` answer button per option, labelled with the option label, when the tool input has exactly one question, it is not multi-select, and it has 1 to 3 options. Any other `AskUserQuestion` SHALL get no answer buttons. When no reliable key sequence for the question menu is known, `AskUserQuestion` pushes SHALL get no answer buttons.

#### Scenario: Two options become two buttons
- **WHEN** the `PreToolUse` hook fires in an opsx pane for one single-select question with options `rebase` and `merge`
- **THEN** the push has two `http` actions labelled `rebase` and `merge`

#### Scenario: Multi-select gets no answer buttons
- **WHEN** the hook fires for one question with `multiSelect: true` and 2 options
- **THEN** the push has no `http` action

#### Scenario: Four options get no answer buttons
- **WHEN** the hook fires for one single-select question with 4 options
- **THEN** the push has no `http` action

### Requirement: Answer buttons for a PR question
`pr.sh note <pr> "<question>" --option <label>` SHALL accept the option 1 to 3 times, and its push SHALL get one `http` answer button per option. More than 3 options SHALL fail the command before anything is recorded or sent. Without options the note SHALL behave as before.

#### Scenario: Note with options
- **WHEN** `pr.sh note 42 "rebase onto main or develop?" --option main --option develop` runs with notifications configured
- **THEN** the push has two `http` actions labelled `main` and `develop`, and the state file has the `ask=` line

#### Scenario: Too many options
- **WHEN** `pr.sh note 42 "pick" --option a --option b --option c --option d` runs
- **THEN** it exits non-zero, no `ask=` line is added and no push is sent

### Requirement: Answer button posts a nonce to the reply topic
Each answer button SHALL POST to `<NTFY_URL>/<NTFY_REPLY_TOPIC>` with `Authorization: Bearer <NTFY_REPLY_TOKEN>` and the body `<nonce>:<n>`, where the nonce is 32 random hex characters minted for that push and n is the 1-based option. The main token SHALL never appear in an action. Without `NTFY_REPLY_TOPIC` and `NTFY_REPLY_TOKEN` in `notify.env` no answer buttons SHALL be sent.

#### Scenario: Action carries the reply token only
- **WHEN** a push with answer buttons is sent
- **THEN** every `http` action's URL ends with the reply topic, its body matches `^[0-9a-f]{32}:[1-3]$`, its headers carry the reply token, and the main `NTFY_TOKEN` appears nowhere in the `Actions` header

#### Scenario: No reply config, no answer buttons
- **WHEN** `notify.env` has no `NTFY_REPLY_TOKEN` and a `pr.sh note` with 2 options is sent
- **THEN** the push is sent with no `http` action

### Requirement: Live nonce
Each answer push SHALL record its nonce, kind, time and offered options on the asking window. A nonce SHALL be live only while it is recorded, at most 1 hour old, and the window still shows that question: for a Claude question the pane still shows the question text, for a PR question the PR state still has that `ask=` line. A newer answer push for the same window SHALL replace the older nonce.

#### Scenario: Newer question replaces the nonce
- **WHEN** two answer pushes are sent for the same window
- **THEN** a reply with the first push's nonce does not act

#### Scenario: Expired nonce
- **WHEN** a reply arrives for a nonce recorded more than 1 hour ago
- **THEN** nothing is typed into the pane

### Requirement: Listener delivers a valid reply once
`opsx-notify.sh listen` SHALL subscribe to the reply topic and, for a reply with a live nonce, deliver option n into the asking pane and then forget the nonce, so a second reply with it does nothing. A PR answer SHALL type the option's label as one line through `opsx-window.sh type`. A Claude answer SHALL send the key sequence printed by `opsx-notify.sh menu-keys <n>`.

#### Scenario: PR answer typed once
- **WHEN** a reply `<nonce>:2` arrives for a live PR nonce whose options are `main` and `develop`, then the same reply arrives again
- **THEN** the pane receives `develop` followed by Enter exactly once

#### Scenario: Claude answer sends the menu keys
- **WHEN** a reply `<nonce>:1` arrives for a live Claude nonce whose pane shows the question text
- **THEN** the pane receives exactly the key sequence of `opsx-notify.sh menu-keys 1`

### Requirement: Replies never carry free text
The listener SHALL drop any reply whose body does not match `^[0-9a-f]{32}:[1-3]$`, or whose n is larger than the number of recorded options, without typing anything. What is typed SHALL come only from the recorded option labels or the fixed menu key sequence, never from the reply body.

#### Scenario: Free text dropped
- **WHEN** a reply with body `rm -rf ~` arrives on the reply topic
- **THEN** nothing is typed into any pane and the listener keeps running

#### Scenario: Option out of range
- **WHEN** a reply `<nonce>:3` arrives for a live nonce with 2 options
- **THEN** nothing is typed into the pane

### Requirement: Stale tap reports already answered
A well-formed reply whose nonce is not live (used, replaced, expired, or the window no longer shows the question) SHALL send one push saying the question was already answered or has expired, and SHALL type nothing. A tap that is delivered SHALL send no confirmation push.

#### Scenario: Answered at the terminal first
- **WHEN** a PR question's `ask=` line was cleared with `pr.sh note 42 --clear` and then its answer button reply arrives
- **THEN** nothing is typed and exactly one push saying it was already answered is sent

### Requirement: Listener survives the server
The listener SHALL reconnect after the ntfy connection drops, waiting longer after each failed attempt up to 60 seconds. On its first connection it SHALL act only on replies published after it connected, and after a reconnect only on replies newer than the last one it saw.

#### Scenario: Old replies are not replayed
- **WHEN** a valid reply was published on the reply topic before the listener started
- **THEN** the listener types nothing for it

### Requirement: Link buttons
Decision and finished pushes SHALL get `view` buttons for links that exist: Open PR for a `pr-<n>` window with `@opsx_pr_repo` (`https://github.com/<repo>/pull/<n>`), Open preview when `opsx-preview.sh url <change>` prints a URL for the window's change, and Open page for a `/fork` page pane whose page has a recorded URL. A link that does not exist SHALL be left out.

#### Scenario: PR link
- **WHEN** `mark pr-42 done` sends its push for a window tagged `@opsx_pr_repo` `acme/api`
- **THEN** the push has a `view` action labelled `Open PR` with URL `https://github.com/acme/api/pull/42`

#### Scenario: No preview running
- **WHEN** `mark fix-x done` sends its push and no preview runs for `fix-x`
- **THEN** the push has no `Open preview` action
