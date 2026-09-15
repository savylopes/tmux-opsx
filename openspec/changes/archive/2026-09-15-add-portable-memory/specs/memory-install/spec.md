## ADDED Requirements

### Requirement: Install the memory skill
`install.sh` SHALL install `skills/memory/` (including its templates and import script) to the same skill folders as `opsx-run`: `<claude-config>/skills/memory/`, `~/.cursor/skills/memory/`, `~/.agents/skills/memory/`, `~/.codex/skills/memory/`, `~/.config/opencode/skills/memory/` and `~/.gemini/skills/memory/`. Replaced files SHALL get timestamped backups, as other skills do.

#### Scenario: Fresh install
- **WHEN** the user runs `./install.sh` on a machine without the memory skill
- **THEN** `SKILL.md` exists in all six `memory` skill folders

### Requirement: Always-loaded instruction block
`install.sh` SHALL write a memory instruction block between `<!-- tmux-opsx:memory:start -->` and `<!-- tmux-opsx:memory:end -->` into `<claude-config>/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md` and `~/.gemini/GEMINI.md`. The block SHALL say:
- the store lives at `~/.agents/memory/`;
- read `MEMORY.md` when relevant and open only global or current-project entries;
- check after each user turn whether something should be saved, using the `memory` skill;
- use this store instead of any built-in memory.

`<claude-config>` SHALL follow `--prefix` and `CLAUDE_CONFIG_DIR`, as the rest of `install.sh` does.

#### Scenario: File does not exist
- **WHEN** `~/.codex/AGENTS.md` is missing
- **THEN** `install.sh` creates it containing only the marked block

#### Scenario: File has other content
- **WHEN** `~/.claude/CLAUDE.md` contains a graphify section and no memory markers
- **THEN** the block is appended after it, and the graphify section is unchanged

#### Scenario: Re-run
- **WHEN** `install.sh` runs again and the markers already exist
- **THEN** only the text between the markers is replaced, the file contains exactly one memory block, and content outside the markers is unchanged

#### Scenario: Backup on change
- **WHEN** the block changes an existing file and `--no-backup` was not given
- **THEN** a `.bak.<timestamp>` copy of the previous file is kept

### Requirement: Cursor note
Because Cursor has no known global instructions file, `install.sh` SHALL print the instruction block with a note to add it to Cursor's user rules.

#### Scenario: Install prints Cursor instructions
- **WHEN** installation finishes without `--skip-memory`
- **THEN** the output includes the block text and the Cursor rules location

### Requirement: Create the store skeleton without overwriting
`install.sh` SHALL create `~/.agents/memory/`, its four type folders and an empty `MEMORY.md` index, but only for the parts that are missing. It SHALL NOT modify or delete existing memory files or index lines. It SHALL NOT run `git init`.

#### Scenario: Existing store
- **WHEN** `~/.agents/memory/` already holds memories and `install.sh` runs
- **THEN** every existing file in the store is byte-for-byte unchanged

### Requirement: Skip flag
`install.sh` SHALL accept `--skip-memory`, which skips the skill install, the instruction blocks, the Cursor note, the skeleton and the import. `--help` and the header comment SHALL document the flag and the new install step.

#### Scenario: Skipping memory
- **WHEN** the user runs `./install.sh --skip-memory`
- **THEN** no memory skill folder, instruction block or `~/.agents/memory/` path is created or changed

### Requirement: Uninstall keeps memories
`./install.sh --uninstall` SHALL remove the six `memory` skill folders and remove the marked block (markers included) from each instruction file. It SHALL leave all other content in those files, and SHALL NOT delete or modify anything in `~/.agents/memory/`.

#### Scenario: Uninstall
- **WHEN** the user runs `./install.sh --uninstall`
- **THEN** the skill folders and marked blocks are gone, the graphify section in `CLAUDE.md` remains, and `~/.agents/memory/` is untouched

### Requirement: README documents memory
`README.md` SHALL describe the memory store, what `install.sh` sets up for each CLI, the manual Cursor step, the `--skip-memory` flag, and that uninstall keeps the store.

#### Scenario: Reader looks up memory
- **WHEN** a user reads the README install section
- **THEN** it lists the memory step, its install locations and the Cursor manual step
