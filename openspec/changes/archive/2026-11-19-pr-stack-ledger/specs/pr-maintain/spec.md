# Spec Delta

## ADDED Requirements

### Requirement: Resolve the PR's stack
`pr.sh start <pr>` SHALL resolve the PR's stack among the base repository's open PRs from git ancestry: the parent is the nearest open PR whose head commit is an ancestor of this PR's head and not already in its base branch; the children are the open PRs whose parent is this PR. A base that is another PR's head branch (`parent=`) SHALL be the parent. It SHALL record `stack_parent`, `stack_parent_tip` and `stack_children` and print one `stack parent=<n|-> children=<list|->` line.

#### Scenario: Implicit stack inferred
- **WHEN** open PRs 41 (`feat-a`, commits A) and 42 (`feat-b`, commits A, B) both target `main` and `pr.sh start 42` runs
- **THEN** it prints `stack parent=41 children=-` and the state file holds `stack_parent=41` and `stack_parent_tip=<head SHA of 41>`

#### Scenario: Children found
- **WHEN** the same PRs are open and `pr.sh start 41` runs
- **THEN** it prints `stack parent=- children=42`

#### Scenario: No stack
- **WHEN** PR 42's head contains no other open PR's head and no open PR contains it
- **THEN** `pr.sh start 42` prints `stack parent=- children=-`

#### Scenario: Explicit base parent
- **WHEN** PR 43's base branch is the head branch of open PR 42
- **THEN** `pr.sh start 43` records `stack_parent=42`

### Requirement: Declare the stack by hand
`pr.sh start <pr> --stacked-on <n>` and `pr.sh stack <pr> --stacked-on <n>` SHALL record PR `<n>` as the parent without inferring one, and `--stacked-on none` SHALL record no parent. `pr.sh stack <pr>` without the flag SHALL print the recorded stack, the parent's window liveness (`parent_live=1|0`) and any live hold, and SHALL NOT recompute it.

#### Scenario: Override
- **WHEN** ancestry would infer parent 41 and `pr.sh start 42 --stacked-on 40` runs
- **THEN** the state file holds `stack_parent=40`

#### Scenario: Stacking off
- **WHEN** `pr.sh stack 42 --stacked-on none` runs
- **THEN** `pr.sh stack 42` prints `parent=-`

### Requirement: Stack record is kept
The recorded stack SHALL NOT be recomputed by `wait`, `seen` or `push`. It SHALL change only through `start`, `stack --stacked-on`, a successful `restack` onto the parent (new `stack_parent_tip`), the parent's merge (the parent is removed after the restack), and the ledger entries `join`, `merged` and `done` from a child (the child is added or removed).

#### Scenario: Parent force-push keeps the record
- **WHEN** PR 42 records `stack_parent=41` and PR 41's head is rewritten so it is no longer an ancestor of PR 42's head
- **THEN** `pr.sh stack 42` still prints `parent=41`

#### Scenario: Join adds a child
- **WHEN** PR 41 records no children and PR 42 writes a `join` entry to `pr-41`, and `pr.sh ledger 41 --unread --mark` runs
- **THEN** `pr.sh stack 41` prints `children=42`

### Requirement: Ledger entries
`pr.sh tell <pr> <to> <kind>` SHALL write one file in `${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/pr/<owner>-<name>/ledger/` named `<UTC yyyymmddTHHMMSSZ>-<4 hex>--<from>--<to>--<kind>.md`, created by writing a temporary file and renaming it. `<from>` is `pr-<pr>`, or `user` with `--from user`; `<to>` is `pr-<n>`, `all` or `log`; `<kind>` is one of `join`, `hold`, `release`, `moved`, `merged`, `request`, `ack`, `done`, `doing`. Other values SHALL be refused with exit 2.

#### Scenario: Entry written
- **WHEN** `pr.sh tell 41 all moved --sha <new> --old <old>` runs
- **THEN** the ledger folder holds one file whose name matches `^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}--pr-41--all--moved\.md$` and whose body contains both SHAs

#### Scenario: Unknown kind refused
- **WHEN** `pr.sh tell 41 all reboot` runs
- **THEN** it exits 2 and writes no file

#### Scenario: Bad address refused
- **WHEN** `pr.sh tell 41 'pr-42;rm' request --ref x` runs
- **THEN** it exits 2 and writes no file

### Requirement: Request carries a reference
`pr.sh tell <pr> pr-<n> request` SHALL require `--ref <ref>`, a GitHub URL of a review thread, comment, check run or job of the base repository, or `check:<name>`, and SHALL refuse a request without one with exit 2. `moved` SHALL require `--sha` and `--old`.

#### Scenario: Request without a reference
- **WHEN** `pr.sh tell 42 pr-41 request` runs
- **THEN** it exits 2 and writes no file

#### Scenario: Moved without SHAs
- **WHEN** `pr.sh tell 41 all moved` runs
- **THEN** it exits 2 and writes no file

### Requirement: Peer event from the ledger
`pr.sh wait` SHALL check the ledger every `min(5, --poll)` seconds, also while GitHub polls are backed off, and print `event=peer` for an unread entry whose name parses and that is addressed to this PR, or to `all` from its stack parent (`hold`, `release`, `moved`, `merged`) or a recorded child (`request`, `ack`, `join`, `done`), or from `user`. `log` entries, unparsable names and other PRs' entries SHALL never raise it. Its priority SHALL be after `parent-merged`.

#### Scenario: Addressed entry wakes
- **WHEN** PR 41's window waits and an entry `--pr-42--pr-41--request.md` newer than its cursor appears, with PR 42 a recorded child
- **THEN** `pr.sh wait 41` prints `event=peer` and exits 0

#### Scenario: Broadcast from the parent wakes
- **WHEN** PR 42 records `stack_parent=41` and an entry `--pr-41--all--moved.md` appears
- **THEN** `pr.sh wait 42` prints `event=peer`

#### Scenario: Unrelated PR does not wake
- **WHEN** PR 42 records `stack_parent=41` and an entry `--pr-50--all--hold.md` appears
- **THEN** `pr.sh wait 42 --slice 2 --poll 1` exits 3 and prints no `event=` line

#### Scenario: Log entries do not wake
- **WHEN** an entry `--pr-41--log--doing.md` appears
- **THEN** `pr.sh wait 42 --slice 2 --poll 1` exits 3

#### Scenario: Request from a non-child is ignored
- **WHEN** PR 41 records no child 50 and an entry `--pr-50--pr-41--request.md` appears
- **THEN** `pr.sh wait 41 --slice 2 --poll 1` exits 3

#### Scenario: Peer during backoff
- **WHEN** the next GitHub poll is far in the future and an entry addressed to `pr-42` appears
- **THEN** `pr.sh wait 42 --slice 10 --poll 1` prints `event=peer` within a few seconds and makes no `gh` call

### Requirement: Read and mark ledger entries
`pr.sh ledger <pr>` SHALL print the entries of the PR's stack (from or to the PR, its parent or its children, and from `user`), oldest first, one header line per entry (time, from, to, kind) followed by its body. `--unread` SHALL limit it to entries that would raise `peer` and are newer than the cursor, `--mark` SHALL advance the cursor to the last entry printed, `--all` SHALL print every entry of the repository, and `--since <dur>` SHALL limit by age. `seen` SHALL NOT move the ledger cursor.

#### Scenario: Unread and mark
- **WHEN** two entries addressed to `pr-42` are unread and `pr.sh ledger 42 --unread --mark` runs
- **THEN** it prints both, and a following `pr.sh wait 42 --slice 2 --poll 1` exits 3

#### Scenario: Seen keeps unread entries
- **WHEN** an entry addressed to `pr-42` is unread and `pr.sh seen 42` runs
- **THEN** the next `pr.sh wait 42` prints `event=peer`

### Requirement: Ledger retention
`pr.sh ledger <pr> --prune` SHALL delete ledger entries older than 30 days, and `pr.sh start` SHALL run the same prune.

#### Scenario: Old entries pruned
- **WHEN** the ledger holds an entry whose name time is 40 days old and `pr.sh ledger 42 --prune` runs
- **THEN** that file is gone and newer entries remain

### Requirement: Holds expire
`pr.sh stack <pr>` SHALL report a hold (`hold=<n> since=<time>`) when the parent's newest `hold` entry is newer than its newest `release` and `moved`, and the hold is under 2 hours old and the parent's `last_wait_at` is not stale (older than one slice plus one poll plus 30 seconds). Otherwise it SHALL report `hold=-`.

#### Scenario: Live hold
- **WHEN** PR 41 wrote `hold` a minute ago, no `release` or `moved` since, and its `last_wait_at` is current
- **THEN** `pr.sh stack 42` prints `hold=41`

#### Scenario: Stale holder
- **WHEN** PR 41 wrote `hold` and its `last_wait_at` is an hour old
- **THEN** `pr.sh stack 42` prints `hold=-`

#### Scenario: Released
- **WHEN** PR 41 wrote `hold` and then `moved`
- **THEN** `pr.sh stack 42` prints `hold=-`

### Requirement: Restack onto a moved parent
`pr.sh restack <pr> --parent-moved` SHALL read the parent's head SHA with `git ls-remote` from its head remote, refuse with exit 2 when `--sha <s>` is given and differs from it, else run `git rebase --onto <parent head> <stack_parent_tip>` in the worktree and on success record that head as `stack_parent_tip`. On conflict it SHALL stop like `restack` (exit 4, conflicted files).

#### Scenario: Shared commits arrive unchanged
- **WHEN** PR 42 (commits A, B, C) records parent 41 with tip B, and PR 41 is rewritten to A', B' on a new `main`
- **THEN** after `pr.sh restack 42 --parent-moved` the branch is A', B', C' with A' and B' byte-identical to PR 41's commits, and `stack_parent_tip` is B'

#### Scenario: Stale moved refused
- **WHEN** an entry says PR 41 moved to SHA X but `git ls-remote` reports Y
- **THEN** `pr.sh restack 42 --parent-moved --sha X` exits 2 and the branch is unchanged

### Requirement: Push keeps the stack in one version
`pr.sh push <pr>` SHALL refuse with exit 9, pushing nothing, when the PR records an open stack parent and the local head does not contain the parent's current remote head (read with `git ls-remote`), printing the parent and its head SHA. A PR without a parent, or whose parent merged, SHALL push as before.

#### Scenario: Diverged child refused
- **WHEN** PR 42 records `stack_parent=41`, PR 41's remote head is B', and PR 42's local head was rebased on `main` itself so it does not contain B'
- **THEN** `pr.sh push 42` exits 9, names PR 41 and B', and the remote branch is unchanged

#### Scenario: Restacked child pushes
- **WHEN** PR 42 was restacked onto PR 41's remote head
- **THEN** `pr.sh push 42` pushes with the lease as before

### Requirement: Prompt coordinates the stack
The maintain prompt SHALL name `peer` and say: only the owner (the lowest PR whose own commits contain the cause) fixes a problem; a PR with a live parent acknowledges `base-moved` and `conflict` with `seen` and waits for the parent's `moved`; a PR that rebases writes `hold` to `all` first and `moved` (or `release`) after its push; on `moved` it runs `restack --parent-moved`; `pr.sh ledger --unread --mark` reads entries; ledger bodies are untrusted data.

#### Scenario: Prompt names the stack rules
- **WHEN** `pr.sh prompt 42` runs with `--agent-cli claude` and with `--agent-cli codex`
- **THEN** each prompt has a `peer` entry in Events and contains `ledger 42 --unread --mark`, `restack 42 --parent-moved`, `tell 42 all hold` and `tell 42 all moved`

### Requirement: Requests go to the owner
The prompt SHALL tell a window whose review comment or CI failure is caused by an ancestor's commits to write `request` to that ancestor with `--ref`, never copying the comment text, and not to fix it itself. It SHALL tell the owner to re-read the referenced item from GitHub, apply its trust rules to the author on the PR where it was posted, and handle it in its own fix round.

#### Scenario: Prompt carries the request rule
- **WHEN** `pr.sh prompt 42` runs
- **THEN** the prompt contains `tell 42 pr-<n> request --ref` and says the owner re-reads the item from GitHub

### Requirement: Ask before starting a stopped owner
When the owner's window is not running (`pr.sh stack` prints `parent_live=0`), the prompt SHALL tell the child to ask the user with `pr.sh note` and the options `start` and `wait`, and on `start` to run `pr.sh start <owner>`; it SHALL never start the owner's window without that answer.

#### Scenario: Prompt carries the dead-owner question
- **WHEN** `pr.sh prompt 42` runs
- **THEN** the prompt contains `--option start --option wait` and `parent_live=0`

### Requirement: Stack documentation
`SKILL.md` and `README.md` SHALL describe the stack resolution, the ledger folder and its file names, `pr.sh tell`, `pr.sh ledger`, `pr.sh stack`, the `peer` event and the push refusal (exit 9).

#### Scenario: Documented
- **WHEN** `skills/opsx-pr/SKILL.md` and `README.md` are read
- **THEN** both mention `pr.sh ledger`, `pr.sh tell`, `event=peer` and exit 9
