## MODIFIED Requirements

### Requirement: Autonomous actions
The window prompt SHALL allow the window, without asking, only mechanical steps that edit no code: rebase or restack without conflicts, re-run a failed CI once per head through `pr.sh rerun <pr>`, push only through `pr.sh push <pr>`, reply to handled threads and resolve them, retarget the base after a parent merged, and `pr.sh seen`/`note`. Every code change SHALL go through a fix round. It SHALL forbid merging the PR and any plain `--force` push.

#### Scenario: Prompt lists allowed and forbidden actions
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt contains `--force-with-lease`, says the agent never merges the PR, and forbids plain `--force`

#### Scenario: Prompt allows one CI re-run
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the list of steps the window may do on its own includes re-running a failed CI once per head with `rerun 42`

#### Scenario: Window does not edit code itself
- **WHEN** `pr.sh prompt 42 --agent-cli claude` runs
- **THEN** the prompt says the window never edits code or commits content changes itself and routes review-comment fixes, CI fixes and conflict resolution to a fix round

### Requirement: Gates before a push
A clean rebase or restack with no conflicts SHALL need only the repository's tests before `pr.sh push`. Any other push SHALL follow a passed fix round: ops-applier, then ops-eval (OpenSpec branch, else SKIP), ops-reviewer, ops-security, ops-qa (`.opsx/preview.yaml`, else SKIP), each PASS or SKIP with no P0/P1, findings sent back verbatim, at most 3 rounds per event before asking the user, then the tests.

#### Scenario: Prompt carries the gates
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt requires tests before every push, names ops-applier, ops-eval, ops-reviewer, ops-security and ops-qa in that order for a fix round, and says to ask the user after 3 rounds

#### Scenario: Eval skipped for a non-OpenSpec branch
- **WHEN** `pr.sh prompt 42` runs for a PR whose head branch is not `opsx/<change>` and the window is not a change window
- **THEN** the prompt says ops-eval is SKIP for this PR

#### Scenario: Foreground CLIs run the gates themselves
- **WHEN** `pr.sh prompt 42 --agent-cli codex` runs
- **THEN** the prompt tells the window to apply the fix itself in the worktree and run each gate itself in the same order

### Requirement: PR monitor agent
`agents/opsx-pr-monitor.md` SHALL define `ops-pr-monitor` with the Bash tool only, guarded by a PreToolUse hook that runs `monitor-guard.sh`. It SHALL rerun the wait after exit 3 up to the `max-calls:` value (default 9 when missing, at most 30) and return one line: `event=<kind>`, `idle`, `superseded`, `stopped` or `error: <message>`. It SHALL never end its turn before that line with other text; if a call is moved to the background it SHALL take the exit code from the completion notification, read the task output file it names when it needs the result line, and continue the loop, and a turn it must end to wait for that notification SHALL say only `waiting`. A completion notification SHALL NOT be treated as a new prompt. `agents/models.conf` SHALL ship `claude.pr-monitor = sonnet`. `install.sh` SHALL install it and the guard unless `--skip-pr`, verify them, and always remove them on `--uninstall`.

#### Scenario: Monitor never replies early
- **WHEN** `agents/opsx-pr-monitor.md` is read
- **THEN** it says never to end the turn before the one final line, names the `moved to the background` case, the `<task-notification>` with its exit code and output file, the `waiting` line, and says a notification is not a new prompt and never yields `error: not a pr.sh wait command`

#### Scenario: Monitor agent installed
- **WHEN** `install.sh` runs with a scratch HOME
- **THEN** `~/.claude/agents/opsx-pr-monitor.md` exists, names `ops-pr-monitor`, lists only the Bash tool, has `model: sonnet` and a PreToolUse hook naming `monitor-guard.sh`, and is removed again by `install.sh --uninstall`

#### Scenario: Skipped with --skip-pr
- **WHEN** `install.sh --skip-pr` runs with a scratch HOME
- **THEN** no `opsx-pr-monitor.md` and no `monitor-guard.sh` are installed

#### Scenario: Missing max-calls defaults to nine
- **WHEN** the installed agent file is read
- **THEN** it says to use 9 calls when the `max-calls:` line is missing
