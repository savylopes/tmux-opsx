# Spec Delta

## ADDED Requirements

### Requirement: Restart input after a restore
`pr.sh restart-input <pr> [--repo <dir>]` SHALL refuse, like `start`, a PR that is not open or whose head is in a fork, exiting non-zero and naming the state or the fork. For an open PR it SHALL rewrite the prompt and goal files, keep the state file (open `ask=` questions included), and print the maintain window's first input (`/goal …` with the dispatcher steps on Claude Code). It SHALL not create, type into or retag any tmux window.

#### Scenario: Open PR prints the first input
- **WHEN** `pr.sh restart-input 42` runs for open PR 42 with no tmux server
- **THEN** it exits 0, prints a line starting with `/goal` that names PR 42, and the state file still holds its earlier `last_comment_id=`

#### Scenario: Merged PR refused
- **WHEN** `pr.sh restart-input 41` runs for a PR whose state is `MERGED`
- **THEN** it exits non-zero, names `MERGED`, and prints no input
