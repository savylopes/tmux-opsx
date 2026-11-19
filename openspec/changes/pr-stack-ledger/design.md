# Design

## Context

`skills/opsx-pr/pr.sh` (about 1750 lines of bash) runs one maintain window per PR. Each window learns about the world only from `pr.sh wait`, which polls `gh` and `git ls-remote` with a doubling backoff (up to 1 h, from `pr-conflict-event`) and prints one `event=` line. On Claude Code the wait runs inside the `ops-pr-monitor` subagent, whose `monitor-guard.sh` hook only allows the exact `pr.sh wait <n> --repo .. --slice .. --poll .. --gen ..` shape.

Stack knowledge today is one level deep and only explicit: `parent=` is set when the PR's base branch is another open PR's head branch (`refresh_current` in `pr.sh`). Fork stacks target `main` (GitHub refuses a fork branch as an upstream base), so they record no parent. Per-PR state lives in `${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/pr/<owner>-<name>-<n>/state` and its writes are locked.

This change builds on `pr-conflict-event` (uncommitted in the main checkout when this was written): the `conflict` event, the backoff fields and the liveness tick. That change must be committed and landed before this one is applied, so the worktree branches from a `main` that contains it.

## Goals / Non-Goals

**Goals:**
- One version of every shared commit across a stack, enforced by `pr.sh push`, not only by prompt rules.
- Windows of one stack notify each other within seconds without extra `gh` calls.
- A plain-file, cross-CLI channel the user can read with `ls`.

**Non-Goals:**
- No new transport (sockets, daemons, tmux typing into other windows).
- No merge ordering or merging of stacks; windows still never merge.
- No sharing of `git rerere` caches. Restack-only makes them unnecessary for shared commits.
- No cross-repository stacks.

## Decisions

### D1 Divergence is prevented structurally, then enforced at push
Children never rebase shared commits; they replay only their own commits with `git rebase --onto <parent remote head> <stack_parent_tip>`. `pr.sh push` then refuses (exit 9) a head that does not contain the parent's remote head. Alternative: let every window rebase and share resolutions through `rerere` or the ledger. Rejected: identical resolutions are not guaranteed (different hunks, different agents), and the failure would only show later as sibling conflicts. Exit 9 is new and unused by `pr.sh`.

### D2 Stack resolution at `start`, recorded and kept
`start` runs `gh pr list -R <slug> --state open --json number,headRefName,headRefOid,baseRefName`, fetches the heads it can reach (`git fetch <head remote> <branch>` for same-repo PRs and PRs on `origin`; heads it cannot fetch are skipped), and checks `git merge-base --is-ancestor`. Candidate ancestors are PRs whose head is an ancestor of this head and not an ancestor of `<base remote>/<base>`. The parent is the candidate that descends from all other candidates; ties (equal heads) resolve to no parent and print a warning to use `--stacked-on`. Children are PRs whose own nearest candidate is this PR. An explicit GitHub parent (`parent=`) wins over ancestry. Recomputing on every poll was rejected: a parent's force-push breaks ancestry exactly when the stack needs it. New state keys: `stack_parent`, `stack_parent_tip`, `stack_children` (comma list), `ledger_cursor`.

### D3 The ledger is a folder of immutable entry files
`<state root>/pr/<owner>-<name>/ledger/<UTC>-<4 hex>--<from>--<to>--<kind>.md`. One file per entry: write `.<name>.tmp` in the same folder, then `mv` (atomic on one filesystem), so writers need no lock and readers never see partial files. Time first makes `ls` chronological; the random suffix avoids same-second collisions. Name grammar (regex, anything else ignored): `^([0-9]{8}T[0-9]{6}Z)-([0-9a-f]{4})--(pr-[0-9]+|user)--(pr-[0-9]+|all|log)--(join|hold|release|moved|merged|request|ack|done|doing)\.md$`. The body is `key: value` lines (`sha`, `old`, `ref`, `pr`) followed by free text from `--body-file`. Alternatives: one append-only log file (needs locking, harder to filter) and per-PR inbox files (no shared timeline). The per-repo folder sits beside the per-PR state folders so it outlives any one PR.

### D4 Wake rules live in `pr.sh`, not in the prompt
`wait` scans the ledger at each liveness tick (`min(5, --poll)` s), compares names with `ledger_cursor` (names sort by time), and applies the filter: `to` is `pr-<me>`, or `to=all` and `from` is the parent with kind in {hold, release, moved, merged} or a recorded child with kind in {request, ack, join, done}, or `from=user`. Addressed entries from PRs outside the stack are ignored except `join` (a new child announcing itself). Doing the filter in bash keeps LLM turns for real work and gives every CLI the same behaviour. The scan is a directory listing; no `gh` call. `peer` sits after `parent-merged` in the priority order, so a merge seen on GitHub is handled first.

### D5 Cursor moves only when the agent reads
`seen` does not touch `ledger_cursor`; only `ledger --unread --mark` does, and only up to the last entry it printed. This avoids losing an entry written between reading and acknowledging. `--mark` also applies record updates: `join` from a PR whose `--stacked-on`/inferred parent is this PR adds it to `stack_children`; `merged`/`done` from a child removes it.

### D6 Holds are advisory and expire
A hold is only a hint for the child to wait; correctness comes from D1. `stack` reports a hold only while the holder's window is live (`last_wait_at` fresh, same staleness rule as `list`) and under 2 hours. A dead holder therefore never blocks a child for long.

### D7 The ledger notifies, git decides
Any local process can write the folder, so routing comes only from the parsed file name, never the body, and every action is re-checked: `restack --parent-moved` reads the parent head from `git ls-remote` (and refuses a mismatching `--sha`), `push` checks ancestry against `ls-remote`, the owner re-reads a `request`'s `--ref` from GitHub and applies its trust rules to that item's author on the PR where it was posted. `--ref` is validated as a URL under `https://github.com/<slug>/` or `check:<name>`, so a request cannot point the owner at another site. Bodies are untrusted data, like GitHub comments.

### D8 Prompt rules for coordination
The Events section gets `peer`: run `ledger <pr> --unread --mark` and act per kind (`moved` from the parent: `restack --parent-moved --sha <sha>`, tests, push, then `tell all moved`; `hold`: wait; `request` from a child: handle as own comment/CI event; `join`: nothing more). `base-moved` and `conflict` with a live parent (`stack` prints `parent_live=1`) are acknowledged with `seen`; with `parent_live=0` the window asks `start`/`wait` via `note --option`. A window that rebases writes `tell all hold` before and `tell all moved --sha --old` after its push (`release` when it ends without pushing). `doing` entries go to `log` at fix-round boundaries. `start` writes `join` to the parent when it records one.

### D9 Monitor unchanged
`ops-pr-monitor` and `monitor-guard.sh` keep their command shape; `event=peer` is just another result line. The guard needs no change.

## Risks / Trade-offs

- [Ancestry needs local copies of other PRs' heads] -> `start` fetches reachable heads; unreachable ones (other forks) are skipped, and `--stacked-on` covers the rest.
- [A parent that never writes `moved` (old prompt, crash)] -> the child's GitHub poll still sees `base-moved`; with `parent_live=0` it asks the user; the push invariant still prevents divergence.
- [Many children wake on every `hold`] -> holds are rare (one per rebase); `doing` goes to `log` and wakes nobody.
- [Clock skew between writers] -> one machine, one clock; the random suffix covers same-second entries.
- [Ledger growth] -> 30-day prune on `start` and `ledger --prune`.
- [A child's own commits conflict with the new main after restack] -> normal conflict fix round in the child; the parent's `moved` body carries its range-diff as context so the resolution stays consistent.

## Migration Plan

Existing state files lack the stack keys: they behave as "no stack" until the next `pr.sh start` (a refresh), which resolves the stack. Refresh running windows with the `learned-refresh-pr-maintainers` procedure after install. Rollback: reinstall the previous `pr.sh`; the ledger folder is ignored by it.
