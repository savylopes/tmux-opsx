## ADDED Requirements

### Requirement: PR buttons for a change window maintaining a PR
A change window tagged `@opsx_pr=<n>` and `@opsx_pr_repo=<repo>` SHALL get the same Open PR link as a `pr-<n>` window, and a tapped answer to its `pr.sh note` question SHALL be typed into that change window.

#### Scenario: Open PR link from a change window
- **WHEN** `opsx-window.sh mark add-thing done` runs for a window with `@opsx_pr=42` and `@opsx_pr_repo=acme/api`
- **THEN** the fake `curl` receives an `Open PR` view action with `https://github.com/acme/api/pull/42`

#### Scenario: Answer typed into the change window
- **WHEN** `pr.sh note 42 "q" --option main --option develop` ran for PR 42 maintained in window `add-thing` and the listener gets a valid reply `:2`
- **THEN** `develop` and Enter are typed into window `add-thing` exactly once
