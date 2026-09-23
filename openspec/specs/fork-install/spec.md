# fork-install Specification

## Purpose
TBD - created by archiving change add-tmux-fork. Update Purpose after archive.
## Requirements
### Requirement: Install the fork skill for every CLI
`install.sh` SHALL copy `skills/fork/` (`SKILL.md` and an executable `fork.sh`) to the same six skill folders used for the `memory` skill: the Claude Code skills dir, `~/.cursor/skills/`, `~/.agents/skills/`, `$CODEX_HOME/skills/` when it differs, `~/.config/opencode/skills/` and `~/.gemini/skills/`, each as a `fork/` subfolder, with the usual `.bak` backups on overwrite.

#### Scenario: Fresh install
- **WHEN** `install.sh` runs on a machine without the fork skill
- **THEN** each of the six skill folders contains `fork/SKILL.md` and an executable `fork/fork.sh`

#### Scenario: Re-run
- **WHEN** `install.sh` runs again with unchanged sources
- **THEN** the installed files are identical and no duplicates are created

### Requirement: Skip flag
`install.sh` SHALL accept `--skip-fork`, which leaves all fork skill folders untouched. The flag SHALL appear in the header comment and `--help`.

#### Scenario: Skipped
- **WHEN** `install.sh --skip-fork` runs
- **THEN** no `fork/` skill folder is created or modified

### Requirement: Uninstall
`install.sh --uninstall` SHALL remove the six `fork/` skill folders and SHALL NOT delete fork state under `agent-forks/`.

#### Scenario: Uninstall keeps state
- **WHEN** `install.sh --uninstall` runs and `~/.local/state/agent-forks/` holds past forks
- **THEN** the skill folders are removed and the state directory is unchanged

