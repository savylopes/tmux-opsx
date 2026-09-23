## ADDED Requirements

### Requirement: README presents the repo as a development harness
`README.md` SHALL open with a short statement that tmux-opsx is the user's personal development harness for agent CLIs, followed by an overview of its components grouped as workflow, gates, context and portability. Only shipped components SHALL be listed. All existing usage documentation SHALL be preserved.

#### Scenario: First screen
- **WHEN** someone opens `README.md`
- **THEN** the first section names the repo as a development harness and shows the component overview before any command reference

#### Scenario: No lost documentation
- **WHEN** the README is compared with the previous version
- **THEN** every command, flag and install option documented before is still documented

### Requirement: OpenSpec project context
The repo SHALL contain `openspec/config.yaml` with `schema: spec-driven` and a `context:` section describing the harness purpose, the product surface (installer, skills, agent definitions, tmux behaviour), the five supported CLIs, and the repo conventions. `openspec validate --strict` SHALL still pass for existing specs and changes.

#### Scenario: Context reaches planning
- **WHEN** an agent runs `openspec instructions proposal --change <any>`
- **THEN** the output includes the project context from `openspec/config.yaml`

### Requirement: No behaviour change
This capability SHALL NOT change names, install paths, skill names, window prefixes or any agent's rules.

#### Scenario: Install unchanged
- **WHEN** `install.sh` runs before and after this change in a scratch `HOME`
- **THEN** the installed files are identical
