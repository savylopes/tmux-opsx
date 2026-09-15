## ADDED Requirements

### Requirement: Global memory store layout
The memory store SHALL live at `~/.agents/memory/` as a plain folder containing a `MEMORY.md` index and the folders `user/`, `feedback/`, `project/` and `reference/`. Each memory SHALL be one Markdown file inside the folder that matches its type.

#### Scenario: Store structure
- **WHEN** an agent lists `~/.agents/memory/`
- **THEN** it finds `MEMORY.md` and the four type folders, and every memory file sits in the folder named after its `type`

### Requirement: Memory file format
Each memory file SHALL start with YAML frontmatter containing `name` (kebab-case, equal to the filename without `.md`), `description` (one line), and `type` (`user`, `feedback`, `project` or `reference`). It MAY contain `project` and `source`. Bodies of `feedback` and `project` memories SHALL state the rule or fact, followed by a `**Why:**` line and a `**How to apply:**` line. Related memories SHALL be linked with `[[name]]`.

#### Scenario: Valid feedback memory
- **WHEN** an agent saves a correction from the user
- **THEN** the file has `name`, `description` and `type: feedback` in its frontmatter, and a body with the rule, a `**Why:**` line and a `**How to apply:**` line

### Requirement: Index lists every memory
`MEMORY.md` SHALL contain exactly one line per memory file, in the form `- [Title](<type>/<name>.md) · <type> · <project-or-global> — <hook>`, each under 200 characters. No memory file SHALL exist without an index line, and no index line SHALL point to a missing file.

#### Scenario: New memory indexed
- **WHEN** an agent creates a memory file
- **THEN** it adds that file's line to `MEMORY.md` in the same save

#### Scenario: Orphan found
- **WHEN** an agent finds a memory file with no index line, or an index line with no file
- **THEN** it adds the missing line or removes the dead line

### Requirement: Project scoping by tag
Memories SHALL be global unless they carry a `project` tag. The tag SHALL be the `org/repo` of the working repo's `origin` remote (host, `.git` and URL scheme stripped). When there is no remote, it SHALL be the basename of the repo root, or of the working directory outside git. An agent SHALL tag a memory with a project when the user asks to save it for this project, or when it only applies to this project.

#### Scenario: Repo with a remote
- **WHEN** the user says "remember this for this project" in a repo whose origin is `git@github.com:savylopes/tmux-opsx.git`
- **THEN** the memory is saved with `project: savylopes/tmux-opsx`

#### Scenario: Repo without a remote
- **WHEN** the same request is made in `~/Documents/Projects/voice-recognitions` with no `origin` remote
- **THEN** the memory is saved with `project: voice-recognitions`

#### Scenario: General preference
- **WHEN** the user states a preference that is not tied to the current codebase
- **THEN** the memory is saved without a `project` field and indexed as `global`

### Requirement: Read only what is relevant
Agents SHALL NOT read every memory file by default. When past preferences or project context may matter, an agent SHALL read `MEMORY.md`, keep lines marked `global` or tagged with the current project, and open only the files among those that are relevant to the task.

#### Scenario: Task in a tagged project
- **WHEN** an agent starts a task in `savylopes/tmux-opsx` and the index has global entries, `savylopes/tmux-opsx` entries and `cha-marinha-site` entries
- **THEN** it considers only the global and `savylopes/tmux-opsx` entries and does not open `cha-marinha-site` files

### Requirement: Save check after every user turn
After every user turn, an agent SHALL check whether the exchange contained an explicit request to remember something, a correction, a confirmation of a non-obvious choice, or a new lasting fact about the user, a project, or an external resource. When it did, the agent SHALL save it. The agent SHALL NOT save temporary debugging details, one-off errors, task progress, conversation transcripts, generic language or framework knowledge, or anything already recorded in the store or the repository.

#### Scenario: Correction received
- **WHEN** the user says "don't mock the database in these tests"
- **THEN** the agent saves or updates a `feedback` memory, including the reason if the user gave one

#### Scenario: Nothing worth saving
- **WHEN** the turn only contained a failing command and its fix
- **THEN** the agent saves nothing

### Requirement: Update instead of duplicating
Before creating a memory, an agent SHALL search the index for an existing entry on the same subject and update that entry instead. When two entries contradict each other, the agent SHALL keep the one supported by the newest information, correct or delete the other, and not leave both in place.

#### Scenario: Existing entry covers the subject
- **WHEN** a new preference refines an existing `feedback` memory
- **THEN** the agent edits that file and its index line, and does not create a second file

### Requirement: Forget on request
When the user asks to forget something, the agent SHALL delete or edit the matching memory file, remove or update its index line, and check the rest of the store for other copies of the same information.

#### Scenario: Forget a memory
- **WHEN** the user says "forget that I prefer bilingual content"
- **THEN** the matching file and its `MEMORY.md` line are removed, and no other memory file still states that preference

### Requirement: Safe writes when agents collide
When writing a memory file or `MEMORY.md`, an agent SHALL read the file, note its modification time or content hash, and re-read it right before writing. If the file changed in between, the agent SHALL redo the read-merge-write, up to 3 attempts. If all attempts fail, it SHALL append its change without removing other content and tell the user.

#### Scenario: Another agent wrote first
- **WHEN** two agent sessions save different memories at the same moment
- **THEN** both index lines end up in `MEMORY.md` and neither memory is lost

### Requirement: Memory skill
The repository SHALL provide a `memory` skill (`skills/memory/SKILL.md`, with `name` and `description` frontmatter) that documents every requirement in this spec, and templates for a memory file and for `MEMORY.md`.

#### Scenario: Agent needs the save procedure
- **WHEN** an agent decides to save a memory
- **THEN** the `memory` skill gives it the format, where the file goes, the index line, the project tag rule and the write-and-retry steps
