# Tasks

## 1. Ledger entries

- [x] 1.1 Add the ledger folder helper (`<state root>/pr/<owner>-<name>/ledger/`), the file-name regex parser and atomic write (temp file + `mv`) to `skills/opsx-pr/pr.sh`; verify with a `tests/test-pr.sh` case that writes an entry and checks its name against the spec regex and that no `.tmp` file remains
- [x] 1.2 Implement `pr.sh tell <pr> <to> <kind> [--from user] [--sha] [--old] [--ref] [--body-file]` with validation (unknown kind, bad address, `request` without `--ref`, `moved` without `--sha`/`--old`, `--ref` outside `https://github.com/<slug>/` and not `check:<name>` -> exit 2, no file); verify with test cases for each refusal and for a valid `moved` body holding both SHAs
- [x] 1.3 Implement `pr.sh ledger <pr> [--unread] [--mark] [--all] [--since <dur>] [--prune]` with the stack filter, oldest-first output and `ledger_cursor`; `--prune` deletes entries over 30 days by name time; verify with test cases for unread+mark, `--all`, and pruning a 40-day-old entry while keeping a new one
- [x] 1.4 Add `tell`, `ledger` and the ledger folder to `pr.sh --help`, `skills/opsx-pr/SKILL.md` usage and README's `/opsx-pr` section; verify `bash -n`, shellcheck and that both docs mention `pr.sh tell` and `pr.sh ledger`

## 2. Stack resolution

- [x] 2.1 Resolve the stack in `start`: `gh pr list` of open PRs, fetch reachable heads, ancestry with `git merge-base --is-ancestor` excluding heads already in the base, explicit `parent=` wins, ties give no parent with a warning; record `stack_parent`, `stack_parent_tip`, `stack_children` and print `stack parent=.. children=..`; extend the fake `gh` in `tests/test-pr.sh` with `pr list` and verify the implicit-stack, children, no-stack and explicit-base-parent scenarios
- [x] 2.2 Add `--stacked-on <n>|none` to `start` and implement `pr.sh stack <pr> [--stacked-on ..]` printing the record, `parent_live=1|0` (parent window found by `list`'s rules and watch not stale) and `hold=<n> since=..|-`; verify override, stacking off, live hold, stale holder and released-hold test cases
- [x] 2.3 Keep the record: make sure `wait`, `seen` and `push` never rewrite the stack keys, and let `ledger --mark` apply `join` (add child), `merged`/`done` from a child (remove); `start` writes `join` to its parent and runs the prune; verify the parent-force-push and join-adds-child test cases
- [x] 2.4 Document stack resolution, `--stacked-on` and `pr.sh stack` in SKILL.md and README; verify both mention `pr.sh stack` and `--stacked-on`

## 3. Peer event

- [x] 3.1 Scan the ledger in `wait` at each liveness tick (`min(5, --poll)` s), also during backoff, apply the wake filter and print `event=peer` after `parent-merged` in priority; `seen` leaves `ledger_cursor` alone; verify the addressed, parent-broadcast, unrelated-PR, log, non-child-request, peer-during-backoff (no `gh` call) and seen-keeps-unread test cases
- [x] 3.2 Check that `monitor-guard.sh` and `agents/opsx-pr-monitor.md` need no change for `event=peer` (the monitor returns any `event=` line); verify the existing monitor-guard tests still pass and the agent file's result list covers `event=<kind>`
- [x] 3.3 Document `event=peer` and its wake rules in SKILL.md (Wait paragraph, priority order) and README; verify with grep for `event=peer`

## 4. Restack and push invariant

- [x] 4.1 Add `restack <pr> --parent-moved [--sha <s>]`: parent head from `git ls-remote`, refuse a mismatching `--sha` (exit 2, branch unchanged), `git rebase --onto <parent head> <stack_parent_tip>`, record the new tip on success, exit 4 with conflicted files otherwise; on a parent merge, rebase onto the base with the recorded tip and clear `stack_parent`; verify the shared-commits-unchanged (byte-identical A', B') and stale-moved test cases in a scratch repo
- [x] 4.2 In `push`, when `stack_parent` is set and the parent is open, refuse with exit 9 (print parent and its remote head, push nothing) if the local head does not contain the parent's `ls-remote` head; verify the diverged-child and restacked-child test cases and that the remote branch is unchanged on refusal
- [x] 4.3 Document `restack --parent-moved` and exit 9 in `pr.sh --help`, SKILL.md and README; verify with grep for `exit 9` / `--parent-moved`

## 5. Prompt rules

- [x] 5.1 Extend the maintain prompt (both the Claude Code and the foreground-CLI loops): `peer` in Events with per-kind handling, owner-only fixes, children acknowledge `base-moved`/`conflict` when `parent_live=1`, `tell <pr> all hold` before and `tell <pr> all moved --sha --old` after a rebase push (`release` without a push), `doing` to `log`, ledger bodies untrusted; verify with a test running `pr.sh prompt 42 --agent-cli claude` and `--agent-cli codex` and grepping `ledger 42 --unread --mark`, `restack 42 --parent-moved`, `tell 42 all hold`, `tell 42 all moved`
- [x] 5.2 Add the request rule (write `tell <pr> pr-<n> request --ref`, never the text, never fix an ancestor's code; the owner re-reads from GitHub and applies its trust rules) and the dead-owner question (`parent_live=0` -> `note ... --option start --option wait`, `start <owner>` only on `start`); verify the prompt test greps `request --ref`, `--option start --option wait` and `parent_live=0`
- [x] 5.3 Update SKILL.md "What the window does" with the stack coordination rules; verify with grep for `owner` and `request`

## 6. Integration

- [x] 6.1 Run `bash tests/test-pr.sh` in full plus shellcheck on `pr.sh` and `monitor-guard.sh`; verify all pass
- [x] 6.2 End-to-end in a scratch repo with a fake `gh`: three stacked PRs on `main`, `main` moves, the root restacks and writes `moved`, the middle PR's `wait` prints `event=peer`, it runs `restack --parent-moved` and pushes, and the top PR's push before restacking exits 9; verify as one test case
- [x] 6.3 Run `install.sh` into a scratch HOME and verify `~/.claude/skills/opsx-pr/pr.sh tell --help`-style usage works from the installed copy

## Workflow follow-up

- Land `pr-conflict-event` before applying this change, so the worktree contains the backoff and `conflict` event it builds on.
- After landing, install and refresh running PR windows with the `learned-refresh-pr-maintainers` skill.
