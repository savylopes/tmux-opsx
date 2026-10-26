# Design

## Context

`opsx-notify.sh` is the only push sender. `post()` writes the headers to a temporary file that `curl -H @file` reads (`Title`, `Tags`, `Priority`, `Authorization`), so the token never appears in argv. Decision pushes come from `hook_claude_pretool` (an `AskUserQuestion`, whose options `question_text()` already reads), `hook_claude_notification` (permission prompts), `notify_ask_later` (a bare `mark ask`) and `pr.sh notify_question` (`pr.sh note`). Finished pushes come from `mark done|fail` through the Stop hook or the flusher.

The ntfy server is self-hosted behind the static Caddy route `opsx-ntfy`, with deny-all access, one user `opsx`, one token and one topic in `notify.env`. `opsx-window.sh type <pane> --text-file` types a literal line followed by Enter. The project conventions say never to hand-roll `tmux send-keys`.

## Goals / Non-Goals

**Goals:**
- Answer a fixed-choice question from the phone, without opening a new internet-facing service.
- A tap that arrives late, twice, or forged can never type anything except an offered option into the pane that asked.

**Non-Goals:**
- Free-text answers, multi-question or multi-select Claude menus, and permission prompts (windows run with bypass, so these are rare).
- Answer buttons for Cursor, Codex, OpenCode and Gemini. Their pushes come only from `mark` and `pr.sh note`, so they get PR answers and links but no question-menu answers.
- Buttons that run opsx actions (land, retry, close).

## Decisions

1. **Reply through ntfy instead of an own endpoint.** The answer button is an ntfy `http` action that POSTs to `<NTFY_URL>/<topic>-reply`. A local listener subscribes to that topic with the main `opsx` token, which gets read access to it. The reply token belongs to a separate user `opsx-reply` with only `wo` access to the reply topic, so leaking it from a notification payload lets someone post replies but not read pushes or publish to the main topic. *Alternative:* an `act.<d>` service with HMAC-signed URLs keeps the token out of the payload, but it would be a new public service to write and secure. The user chose ntfy.

2. **`Actions` header as a JSON array.** ntfy accepts the `Actions` header as JSON. It is built with `jq`, falling back to `python3 -I`, the same pattern as `question_text()`, so commas, semicolons and quotes in labels need no escaping rules of our own. Labels are cut to 40 characters and stripped of newlines. The header goes into the same header file as the token, never into argv. If neither `jq` nor `python3` is available, the push is sent without actions.

3. **Nonce record on the tmux window.** `@opsx_notify_reply` holds `<nonce> <epoch> <kind> <pane-id>`. `@opsx_notify_reply_opts` holds the option labels, one per line. `@opsx_notify_reply_q` holds the question text: for `claude`, the first 60 characters of the question; for `pr`, the exact `ask=` value plus the PR number and repo. The nonce is 16 bytes from `/dev/urandom` as hex. Window options are not saved by session restore, so a nonce never outlives the tmux server. *Alternative:* a state file under `~/.local/state`. Rejected, because it would need its own cleanup and locking, and a window option dies with the window.

4. **Listener = `opsx-notify.sh listen`.** It loops on `curl -sN --max-time 0 -H @<auth-file> "<NTFY_URL>/<reply-topic>/json?since=<x>"`:
   - The first connection uses no `since` (only new messages). Later connections use `since=<last id>`.
   - It reads one JSON line per event and handles `event == "message"` only.
   - After a disconnect it sleeps 1, 2, 4 … 60 seconds, and resets the delay after a message.

   For each message it:
   - matches the body against `^[0-9a-f]{32}:[1-3]$`, otherwise drops it;
   - finds the window whose `@opsx_notify_reply` nonce equals it, across `tmux list-windows -a`;
   - takes the existing per-window lock (`claim()`'s lock-dir pattern);
   - re-checks the nonce, its age (≤ 3600 s) and that the window still shows the question (`claude`: `capture-pane -p` of the recorded pane contains the stored question text; `pr`: the PR state file still has that `ask=` line);
   - unsets the record, then delivers the answer.

   A well-formed reply with a missing or invalid nonce sends one `info` push titled "already answered or expired". To keep forged spam bounded, that push is sent at most once per nonce value within an hour (an in-memory set).

5. **Delivery.**
   - **pr:** the n-th recorded label is written to a mode-600 temp file and sent with `opsx-window.sh type <pane> --text-file`.
   - **claude:** a new `opsx-window.sh keys <pane> <key>...` sends named keys (tmux key names, never literal text from the reply). `opsx-notify.sh menu-keys <n>` prints the sequence for option n.

   Task 1 is a spike on a private tmux server with a real `claude` pane. It finds the reliable sequence (candidates: the digit alone, the digit plus Enter, or Down × (n-1) plus Enter) and pins it in `menu_keys`, with the Claude Code version it was checked against recorded in a comment. If no sequence is reliable, `menu_keys` prints nothing and `AskUserQuestion` pushes get no answer buttons. The spec allows that outcome.

   **Spike result (Claude Code 2.1.310, tmux 3.4, private `tmux -L` server, one single-select question with 3 options, 3 runs per option and candidate, checked against the tool results in the session transcript):**
   - the digit alone (`1`, `2`, `3`): selected exactly option n in 9/9 runs per pass (two passes, 18/18). The digit submits at once; no Enter is needed.
   - Down × (n-1) + Enter: selected exactly option n in 9/9 runs, but depends on the highlight starting on option 1.
   - the digit + Enter: selected option n in 9/9 runs, but the digit already submits, so the trailing Enter lands in whatever comes next (the next question's menu, where it would pick option 1, or the prompt). Rejected.

   Pinned: `menu_keys n` prints the digit `n` alone (one tmux key name).

6. **Links.** A `push_links <win> <pane>` helper returns up to 3 `view` actions:
   - **PR:** the window name is `pr-<n>` and `@opsx_pr_repo` is set.
   - **Preview:** `@opsx_change` is set and `opsx-preview.sh url <change>` exits 0. It reads local state only; a 2-second timeout keeps the push fast.
   - **Page:** a `@fork_dir` pane whose fork state records a `page_dir` whose `.meta` has `url=`.

   Answer buttons are added first, then links, up to 3 in total.

7. **`pr.sh note --option`.** It is repeatable, takes 1 to 3 values, and is validated before the `ask=` line is written. The options are passed to `opsx-notify.sh send` as `--option` arguments together with `--pr <n> --repo <slug>`, so the nonce record can point at the state's `ask=` line. The PR prompt gets one line with an example.

8. **Install.**
   - **Credentials:** `notify_credentials` gains the reply topic (`<topic>-reply`), the `opsx-reply` user with a random password that is never stored, `access opsx-reply <reply> wo`, `access opsx <reply> ro`, and a token for `opsx-reply`. They are written to `notify.env` as `NTFY_REPLY_TOPIC` and `NTFY_REPLY_TOKEN`, and kept on a re-run when the token still lists.
   - **Listener unit:** `~/.config/systemd/user/tmux-opsx-notify-listen.service` with `ExecStart=<skills>/opsx-run/opsx-notify.sh listen` and `Restart=always`, then `systemctl --user daemon-reload && systemctl --user enable --now`. No sudo is needed, because the unit runs as the user and so reaches the user's default tmux socket.
   - **Removal:** uninstall and `--skip-notify` run `systemctl --user disable --now` and delete the file.

## Risks / Trade-offs

- [A tap types into an agent that runs with bypassed permissions] → The token is write-only, nonces are single-use and live for at most an hour, the still-asking check runs before typing, only offered labels or fixed keys are sent, and the reply body is never typed.
- [Claude Code changes its menu keys] → The sequence is pinned in one function, together with the version it was checked against. A wrong sequence selects nothing or the wrong option, so the README says to check the pane after a tap. Re-running the spike procedure fixes it.
- [The still-asking check reads the pane, and the question text could scroll out of view] → `capture-pane` uses `-S -200` lines of history. A miss only makes the tap report "already answered", which is safe.
- [The listener runs only while the user's systemd manager runs] → Without lingering it stops at logout. That is acceptable because the tmux server it types into is the user's too; the README mentions `loginctl enable-linger` as an option.
- [A notify.env written by hand without the reply keys] → No answer buttons; link buttons still work.

## Migration Plan

Re-run `./install.sh --expose-domain <d>`. Existing `opsx` credentials are kept, and the reply user, topic and token are added. Rollback: `--skip-notify` removes the listener, and old pushes without actions keep working.
