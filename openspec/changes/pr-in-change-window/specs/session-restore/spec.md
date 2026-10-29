## ADDED Requirements

### Requirement: Restore a change window maintaining a PR
A restored change window that was tagged `@opsx_pr=<n>` with `@opsx_pr_repo` SHALL get the tags back and SHALL resume the maintain loop with `pr.sh restart-input <n>` as its first input while the PR is open; when `restart-input` refuses (PR merged or closed), the window SHALL be restored as a plain change window without the PR tags.

#### Scenario: Open PR resumes in the change window
- **WHEN** session restore runs for a saved window `add-thing` with `@opsx_pr=42` and PR 42 is open
- **THEN** the restored window has `@opsx_pr=42` and its first input is the line printed by `pr.sh restart-input 42`

#### Scenario: Merged PR restores a plain change window
- **WHEN** PR 42 is merged at restore time
- **THEN** window `add-thing` is restored without `@opsx_pr` and with the normal change-window resume
