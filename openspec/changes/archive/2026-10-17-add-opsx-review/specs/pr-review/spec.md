# Spec Delta

## Purpose

Lets the user review a pull request against its ticket and the project's requirements as an OpenSpec change driven by `/opsx-run`, producing a report, a conformance matrix, evidence and a draft comment without ever posting or changing the PR.

## ADDED Requirements

### Requirement: Resolve a PR and its ticket
`opsx-review.sh resolve <arg> [--repo <dir>]` SHALL accept a PR number, `#<n>`, a PR URL or a ticket key (`ABC-123`, any case) and print `pr url title author head head_sha base state ticket change` as `key=value` lines. The ticket SHALL come from the branch, else the title, else the body, matched as a whole key. A key SHALL match open PRs first, then PRs in any state.

#### Scenario: PR number
- **WHEN** `resolve 8` runs and PR 8 has branch `feat/MED-35-db-foundation`
- **THEN** it prints `pr=8`, `ticket=MED-35` and `change=review-med-35-db-foundation`

#### Scenario: Ticket from the body
- **WHEN** a PR's branch and title name no ticket and its body says `Refs ABC-4`
- **THEN** `ticket=ABC-4`

#### Scenario: Ticket key, closed PR fallback
- **WHEN** `resolve med-60` runs and the only PR naming MED-60 is merged
- **THEN** that PR is printed

### Requirement: Resolve failures are distinct
`resolve` SHALL exit 2 when no PR matches, exit 3 and print one `pr=` line per candidate when several PRs match a ticket key, and fail with a message for an argument that is no PR number, URL or key, or when it is run outside a git repository without `--repo`.

#### Scenario: Several candidates
- **WHEN** two open PRs name MED-50 and `resolve MED-50` runs
- **THEN** it exits 3 and prints both as `pr=` lines

#### Scenario: Nothing found
- **WHEN** `resolve 999` or `resolve XYZ-1` matches no PR
- **THEN** it exits 2

### Requirement: Read-only GitHub access
`opsx-review.sh` SHALL only read from GitHub (`gh pr view`, `gh pr list`) and SHALL never comment, review, label, push or check out a PR branch.

#### Scenario: Only reads
- **WHEN** every `opsx-review.sh` subcommand has run against a fake `gh` that logs its arguments
- **THEN** the log holds only `pr view` and `pr list` calls

### Requirement: Session naming
`opsx-review.sh session <name>` SHALL rename the tmux session that owns `$TMUX_PANE` to `<name>` with `.`, `:` and whitespace folded to `-`, report `unchanged` when it already has that name, refuse a name another session uses, do nothing outside tmux, and print `claude: type /rename <name>` when run under Claude Code.

#### Scenario: Renamed
- **WHEN** `session MED-35-review` runs in a pane of session `work`
- **THEN** the session is named `MED-35-review` and the output says `session renamed work -> MED-35-review`

#### Scenario: Taken name
- **WHEN** a session `MED-35-review` already exists and another session runs `session MED-35-review`
- **THEN** it fails and no session is renamed

#### Scenario: Claude Code hint
- **WHEN** it runs with `CLAUDECODE` set
- **THEN** the output includes `claude: type /rename <name>`

### Requirement: Detached review worktree
`opsx-review.sh worktree <change> <sha> [--repo <dir>]` SHALL create `../wt-<change>` beside the repository as a detached worktree at `<sha>`, reuse it when it is already at that commit, and refuse when it is at another commit. It SHALL leave the shared checkout's branch unchanged.

#### Scenario: Created and reused
- **WHEN** `worktree review-x <sha>` runs twice
- **THEN** the first prints `worktree created`, the second `worktree reused`, `../wt-review-x` is at `<sha>` with a detached HEAD, and the repository's branch is unchanged

#### Scenario: Other commit refused
- **WHEN** `../wt-review-x` exists at another commit
- **THEN** `worktree review-x <sha>` fails naming the remove command

### Requirement: Review change and launch
The `/opsx-review` skill SHALL write the review change through the propose workflow (proposal, a baseline spec from the ticket's acceptance criteria and the project's requirement sources, design, tasks), validate it with `--strict`, and, unless `--no-run`, launch `/opsx-run <change> --validate`.

#### Scenario: Skill text
- **WHEN** the installed `opsx-review/SKILL.md` is read
- **THEN** it names `opsx-review.sh resolve`, `session` and `worktree`, `openspec validate`, `/opsx-run <change> --validate`, `--no-run`, `--no-session`, the `review/` deliverables `report.md`, `pr-comment.md` and `questions.md`, and the rule that nothing is posted unless the user asks

### Requirement: Review constraints in the launch prompt
The launch prompt SHALL tell every subagent that the change produces review documents only under `openspec/changes/<change>/review/`, works in the detached worktree, and never commits, pushes, posts to the PR or touches the ticket, and that the gates judge the review deliverables.

#### Scenario: Constraints in the skill
- **WHEN** the installed `opsx-review/SKILL.md` is read
- **THEN** its launch block says review documents only, the detached worktree, no commit, push or post, and no ticket change

### Requirement: Install and documentation
`install.sh` SHALL install `skills/opsx-review/` (`SKILL.md`, executable `opsx-review.sh`) into the same six skill folders as `/fork`, SHALL skip it with `--skip-review`, SHALL remove the six folders on `--uninstall`, and SHALL check them in its verify step. `README.md` SHALL document `/opsx-review` and list it in the component overview.

#### Scenario: Installed
- **WHEN** `install.sh` runs in a scratch HOME
- **THEN** `~/.claude/skills/opsx-review/SKILL.md` and an executable `opsx-review.sh` exist, and `--help` mentions `--skip-review`

#### Scenario: Skipped and uninstalled
- **WHEN** `install.sh --skip-review` runs in a fresh scratch HOME, and `install.sh --uninstall` runs in one where it was installed
- **THEN** no `opsx-review` folder exists afterwards in either

#### Scenario: README
- **WHEN** `README.md` is read
- **THEN** it mentions `/opsx-review`, `opsx-review.sh`, `--skip-review` and `pr-comment.md`
