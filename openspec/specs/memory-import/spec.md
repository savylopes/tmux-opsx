# memory-import Specification

## Purpose
TBD - created by archiving change add-portable-memory. Update Purpose after archive.
## Requirements
### Requirement: One-time import of Claude Code memories
`install.sh` SHALL run `skills/memory/import-claude-memory.sh` after the store skeleton exists. The script SHALL import every `*.md` file except `MEMORY.md` from `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/memory/`. When it finishes, it SHALL write `~/.agents/memory/.claude-import-done` recording the date and the number of entries imported. If that marker exists, the script SHALL exit without changes.

#### Scenario: First install
- **WHEN** `install.sh` runs, no marker exists, and Claude has 14 memory files across its project folders
- **THEN** all 14 are imported into the store and the marker records 14

#### Scenario: Later install
- **WHEN** `install.sh` runs again and the marker exists
- **THEN** no memory is imported and the store is unchanged

### Requirement: Convert Claude frontmatter
For each imported file, the script SHALL:
- move `metadata.type` to a top-level `type`;
- drop `node_type`;
- turn `originSessionId` into `source: claude:<id>`;
- add a `project` tag;
- keep `name`, `description` and the body unchanged.

If a file has no type, the script SHALL use `project` and print a warning.

#### Scenario: Feedback memory converted
- **WHEN** a Claude file has `metadata.type: feedback` and `metadata.originSessionId: 35ceecef-6f4a-48eb-affd-8a904840b6ef`
- **THEN** the imported file has `type: feedback`, `source: claude:35ceecef-6f4a-48eb-affd-8a904840b6ef`, a `project` field, no `metadata` or `node_type` keys, and the original body

### Requirement: Tag imports with their source project
The script SHALL work out the source project path from Claude's encoded folder name. Starting at `/`, it picks at each level the longest run of dash-separated tokens that exists as a subfolder.
- If the full path resolves, the tag SHALL follow the project tag rule in `agent-memory`: the `origin` remote's `org/repo`, otherwise the folder name.
- If it does not resolve, the tag SHALL be the leftover tokens joined with `-`.

#### Scenario: Existing folder with a remote
- **WHEN** the source folder is `-home-boris-Documents-ToStudy-Crawlers-bocv-crawler` and its origin is `git@github.com:savylopes/bo-cv.git`
- **THEN** its memories are tagged `project: savylopes/bo-cv`

#### Scenario: Existing folder without a remote
- **WHEN** the source folder is `-home-boris-Documents-Projects-cha-marinha-site` and that repo has no `origin`
- **THEN** its memories are tagged `project: cha-marinha-site`

#### Scenario: Deleted project folder
- **WHEN** the source folder is `-home-boris-Documents-Projects-ship-mantianance` and `/home/boris/Documents/Projects` exists but no matching subfolder does
- **THEN** its memories are tagged `project: ship-mantianance`

### Requirement: Place and index imported memories
Each imported memory SHALL be written to `~/.agents/memory/<type>/<name>.md` and get one `MEMORY.md` index line.
- If a different file with the same name already exists in that folder, the new file SHALL be named `<project-slug>--<name>.md`, with `/` in the tag turned into `-`.
- A file whose `source` value already exists in the store SHALL be skipped.
- Claude's original files SHALL NOT be modified or deleted.

#### Scenario: Links keep working
- **WHEN** `cha-marinha-project.md` links to `[[user-prefers-bilingual-pt-en]]` and both are imported without collisions
- **THEN** both files keep their names, so the link still resolves

#### Scenario: Already imported
- **WHEN** a memory with `source: claude:<id>` is already in the store
- **THEN** the matching Claude file is not imported again

#### Scenario: Originals untouched
- **WHEN** the import finishes
- **THEN** every file under `~/.claude/projects/*/memory/` is unchanged

### Requirement: Import summary
The import SHALL print how many memories were imported, skipped and warned about, and the project tag given to each source folder.

#### Scenario: Summary shown
- **WHEN** the import finishes
- **THEN** `install.sh` output lists each source folder with its project tag and the imported, skipped and warning counts

