# Tasks

## 1. Spike: Claude question menu keys

- [ ] 1.1 On a private tmux server (`tmux -L`), start a real `claude` pane in a scratch dir, make it ask one single-select `AskUserQuestion` with 3 options, and try the candidate key sequences (digit alone, digit + Enter, Down × (n-1) + Enter) for options 1-3 through `tmux send-keys` with named keys; record which sequence selects exactly option n every time across 3 runs each, plus the `claude --version`, in design.md Decision 5. If none is reliable, record that and make `menu_keys` print nothing (no Claude answer buttons)

## 2. Key sending and the Actions header

- [ ] 2.1 Add `opsx-window.sh keys <pane-target> <key>...` (same exact pane resolution as `type`, keys limited to tmux key names matching `^[A-Za-z0-9-]+$`, no `-l` literal text); verify with test cases on a private tmux server that a pane running a key logger receives the keys and that a missing pane or a key with spaces fails
- [ ] 2.2 Add `opsx-notify.sh menu-keys <n>` printing the sequence from task 1.1 (empty when unknown); verify with a test case for n=1..3 and for out-of-range n (non-zero exit)
- [ ] 2.3 Build the `Actions` header as a JSON array (jq, else `python3 -I`, else no actions) in the header file, at most 3 actions, labels cut to 40 characters without newlines, and leave the header out when there are no actions; verify with fake `curl` test cases that a push with no actions has no `Actions` header, that a 3-option push has exactly 3 `http` actions in order, and that `NTFY_TOKEN` never appears in the `Actions` header

## 3. Answer buttons and nonce records

- [ ] 3.1 Mint a 32-hex nonce per answer push and record `@opsx_notify_reply`, `@opsx_notify_reply_opts` and `@opsx_notify_reply_q` on the window (a newer push replaces them); each `http` action POSTs `<nonce>:<n>` to `<NTFY_URL>/<NTFY_REPLY_TOPIC>` with `Authorization: Bearer <NTFY_REPLY_TOKEN>`; no answer buttons without both reply keys; verify with test cases for the action URL/body/headers, the window options, replacement by a second push, and the no-reply-config case
- [ ] 3.2 In `hook_claude_pretool`, add answer buttons only for exactly one question, not multi-select, 1-3 options, and only when `menu-keys` is non-empty; verify with sample hook JSON test cases: 2 options → 2 buttons labelled with the options, `multiSelect: true` → none, 4 options → none, two questions → none
- [ ] 3.3 Add `pr.sh note <pr> "<q>" --option <label>` (repeatable, 1-3, more fails before the `ask=` line is written or a push is sent) passing the options plus PR number and repo to `opsx-notify.sh send`; add the `--option` line and example to the PR window prompt; verify in `tests/test-pr.sh`: 2 options → 2 buttons and the `ask=` line, 4 options → non-zero and nothing recorded or sent, no options → unchanged behaviour, the prompt contains `--option`

## 4. Link buttons

- [ ] 4.1 Add the link builder: Open PR for `pr-<n>` + `@opsx_pr_repo` (`https://github.com/<repo>/pull/<n>`), Open preview when `opsx-preview.sh url <change>` exits 0 within 2 s, Open page for a `@fork_dir` page pane whose page `.meta` has `url=`; add links after answer buttons on decision and finished pushes up to 3 total; verify with test cases: `mark pr-42 done` with `@opsx_pr_repo acme/api` → `Open PR` view action with that URL, no preview running → no `Open preview`, 3 answer options → no links

## 5. Listener

- [ ] 5.1 Add `opsx-notify.sh listen`: subscribe to `<NTFY_URL>/<NTFY_REPLY_TOPIC>/json` with the main token from a header file (first connect without `since`, later `since=<last id>`), handle `message` events only, back off 1→60 s on disconnect and reset after a message; exit 0 with a message when notify.env or the reply keys are missing; verify with a fake `curl` that streams canned JSON lines and then fails: reconnect uses `since=<last id>`, a message published before start is not acted on
- [ ] 5.2 Implement reply handling: body must match `^[0-9a-f]{32}:[1-3]$` and n ≤ recorded options, else drop silently; find the window by nonce, take the per-window lock, re-check age ≤ 3600 s and still-asking (claude: question text in `capture-pane -p -S -200` of the recorded pane; pr: the `ask=` line still in the PR state), unset the record, then deliver (pr: `opsx-window.sh type` of the label via a mode-600 temp file; claude: `opsx-window.sh keys` with `menu-keys <n>`); verify on a private tmux server with a fake pane: PR reply `:2` types `develop` + Enter exactly once even when sent twice, Claude reply sends exactly the `menu-keys 1` sequence, body `rm -rf ~` types nothing, `:3` with 2 options types nothing, expired nonce types nothing
- [ ] 5.3 Send one "already answered or expired" `info` push for a well-formed reply whose nonce is not live (at most once per nonce value per hour), and no push for a delivered reply; verify: `pr.sh note 42 --clear` then the reply → nothing typed and exactly one such push; delivered reply → no push

## 6. Install

- [ ] 6.1 Extend `notify_credentials`: reply topic `<topic>-reply`, user `opsx-reply` (random password, not stored), `access opsx-reply <reply> wo`, `access opsx <reply> ro`, a token for `opsx-reply`; write `NTFY_REPLY_TOPIC`/`NTFY_REPLY_TOKEN` to `notify.env` and keep them on a re-run while the token still lists; `opsx notify info` prints the reply topic but never the reply token; verify with the fake `ntfy` call log in a scratch HOME: `wo` grant for `opsx-reply` only, `ro` for `opsx`, second run keeps both values and adds no user
- [ ] 6.2 Install the `tmux-opsx-notify-listen` systemd user unit (`ExecStart` = installed `opsx-notify.sh listen`, `Restart=always`), `systemctl --user daemon-reload` + `enable --now`; print the command on macOS; remove it (`disable --now` + delete) on `--skip-notify` and `--uninstall`; verify with fake `systemctl` in a scratch HOME for install and uninstall

## 7. Docs and checks

- [ ] 7.1 Update README: Notifications section (answer and link buttons, which pushes get them, the reply topic/user/token trust model, the listener unit and `loginctl enable-linger`, that preview and page links need the expose owner login once on the phone, check the pane after a Claude answer tap), the component overview rows, and the `opsx-notify.sh` line in `openspec/config.yaml` context
- [ ] 7.2 Run `bash tests/test-notify.sh`, `bash tests/test-pr.sh`, `bash tests/test-restore.sh`, `bash tests/test-fork.sh`, `bash tests/test-eval.sh`, `shellcheck` on every changed script, and `openspec validate add-notify-actions --strict`; verify all pass
