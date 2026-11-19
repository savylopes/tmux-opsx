# Proposal

## Why

`/opsx-pr` windows are islands: each one polls GitHub for its own PR and nothing else. In a stack of PRs this makes every window fix the same problem on its own. When `main` moves, every PR of the stack rebases the shared commits separately, resolves the same conflict in its own fix round and can resolve it differently, so the stack diverges and the PRs start to conflict with each other. Stacks from the user's fork are worse off: GitHub refuses a fork branch as the base of an upstream PR, so every PR of the FACIS stack (20 -> 29 -> 32 -> 34 -> 36) targets `main`, `pr.sh` records no `parent`, and it does not see a stack at all.

## What Changes

- **One problem, one resolution.** A problem is fixed only by its owner: the lowest PR of the stack whose own commits contain the cause. Every PR above it takes the fix by replaying only its own commits on top of its parent's new head (`git rebase --onto <parent new> <parent old>`), so shared commits exist in exactly one version.
- **Stack resolution per window.** `pr.sh start` resolves the PR's whole stack (ancestors and descendants among the repository's open PRs) from git ancestry, also for implicit stacks whose PRs all target the same base, records it in the state file and prints it. The record is kept, not recomputed each poll; ledger events and `start --stacked-on <n>|none` change it.
- **Ledger folder.** A per-repository folder in the state directory where windows write one file per entry, named `<UTC time>-<random>--<from>--<to>--<kind>.md`. `to` is `pr-<n>`, `all` or `log`. Kinds: `join`, `hold`, `release`, `moved`, `merged`, `request`, `ack`, `done`, `doing`. Entries are created atomically (temp file and rename), need no lock, and give the user one readable timeline of the stack.
- **New commands.** `pr.sh tell <pr> <to> <kind> [--sha ..] [--old ..] [--ref ..] [--body-file ..]` writes an entry, `pr.sh ledger <pr> [--since ..] [--all] [--prune]` shows the entries of the PR's stack, `pr.sh stack <pr>` prints (and with `--stacked-on` sets) the recorded stack.
- **`peer` event.** `pr.sh wait` checks the ledger every few seconds, also while GitHub polling is backed off, and prints `event=peer` for a new entry addressed to this PR, or to `all` from a PR in its stack with a kind that fits the direction (`hold`, `release`, `moved`, `merged` from ancestors; `request`, `ack`, `join` from descendants; anything from `user`). `log` entries and other stacks never wake a window.
- **Children defer.** A PR with a live ancestor does not rebase on `base-moved` or `conflict` caused by shared commits; it acknowledges and waits for the ancestor's `moved`. A `hold` expires once its writer's watch is stale or after 2 hours.
- **Requests go straight to the owner.** A window that finds a review comment or a CI failure caused by an ancestor's commits writes `request` to that ancestor with a reference (thread URL, check name), never the text. The owner re-reads it from GitHub, applies its own trust rules and handles it in its own fix round; each window pushes only its own PR.
- **Dead owner.** When the owner's window is not running, the child asks the user with `start` / `wait` answer buttons; on `start` it runs `pr.sh start <owner>`, which reads the pending entries on its first turn.
- **Push invariant.** `pr.sh push` refuses (exit 9) to push a PR whose recorded parent is open when the local head does not contain the parent's current remote head, so a window that resolved shared commits itself cannot publish a diverged stack.
- **The ledger notifies, git decides.** Routing comes only from strictly parsed file names; the body is untrusted data. A `moved` is checked against `git ls-remote` before a restack.
- The maintain prompt, `SKILL.md` and `README.md` describe the stack rules, the new event and commands.

## Capabilities

### New Capabilities
<!-- None: the ledger and stack coordination are part of maintaining a PR. -->

### Modified Capabilities
- `pr-maintain`: adds stack resolution, the ledger, the `peer` event, stack-aware handling of base moves and conflicts, requests to the owner, the dead-owner question and the push invariant.

## Impact

- `skills/opsx-pr/pr.sh`: new `tell`, `ledger`, `stack` commands; stack fields in the state file; ledger scan and `peer` event in `wait`; invariant check in `push`; prompt text; `start --stacked-on`.
- `skills/opsx-pr/SKILL.md`, `README.md`: usage and rules.
- `skills/opsx-pr/monitor-guard.sh` and `agents/opsx-pr-monitor.md`: unchanged command shape; the monitor returns `event=peer` like any other event.
- `tests/test-pr.sh`: fake `gh`/git fixtures for stacks and the ledger.
- New state: `${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/pr/<owner>-<name>/ledger/`. No new dependencies.
- Builds on the `pr-conflict-event` change (the `conflict` event and poll backoff), which must be landed first.
