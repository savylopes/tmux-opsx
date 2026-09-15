## Context

`install.sh` installs global skills and agents for Claude Code, Cursor, Codex, OpenCode and Gemini, and copies files with timestamped `.bak` backups. It never edits instruction files today. On the author's machine:

- `~/.claude/CLAUDE.md` exists and holds a graphify block.
- `~/.gemini/GEMINI.md` exists and is empty.
- `~/.codex/AGENTS.md` and `~/.config/opencode/AGENTS.md` don't exist.
- `~/.agents/` holds only `skills/`.
- Claude Code has 14 memories across 8 folders in `~/.claude/projects/*/memory/`. Three of the source project folders no longer exist and most projects have no git remote.

Claude's memory files use this frontmatter:

```yaml
name: avoid-loading-user-chrome-profile
description: ...
metadata:
  node_type: memory
  type: feedback
  originSessionId: 35ceecef-...
```

Codebase knowledge is already covered by OpenSpec specs and graphify, so this memory is only about the user.

## Goals / Non-Goals

**Goals:**
- One memory store that all five CLIs read and write the same way.
- Only a few lines always loaded; everything else read on demand.
- Fully automatic setup through `install.sh`, safe to re-run.
- Keep what Claude Code already remembers.

**Non-Goals:**
- Git-backed store or syncing across machines.
- Locks, daemons, MCP servers, databases or embeddings.
- Codebase or architecture knowledge (ADRs, specs).
- Deciding which imported memories should become global (a manual edit later).
- Fixing the `opsx-land` stash cleanup bug.

## Decisions

### 1. One global plain folder at `~/.agents/memory/`

It sits next to the existing `~/.agents/skills/` convention, so a person can `ls` it and every agent can be pointed at it with one line.

Alternatives considered:
- Per-project `.agent/memory/`: facts about the user would be repeated in every repo.
- Claude's native path: other CLIs can't work out its encoded folder names.
- A git repo: postponed.

### 2. Folders by type; project scope as a frontmatter tag

```
~/.agents/memory/
├── MEMORY.md
├── user/  feedback/  project/  reference/
```

```yaml
---
name: no-mock-db-in-tests          # kebab-case, equals filename without .md
description: one line used to judge relevance
type: feedback                     # user | feedback | project | reference
project: savylopes/tmux-opsx       # omit when the memory applies everywhere
source: claude:35ceecef-...        # only on imported entries
---
```

Each index line looks like `- [Title](feedback/no-mock-db-in-tests.md) · feedback · savylopes/tmux-opsx — hook`, using `global` when there is no project. Agents keep lines marked `global` or tagged with the current project.

Alternative considered: a folder per project. It is invisible to agents that don't know the naming rule, and a single memory's scope can't change without moving the file.

### 3. Project tag = git remote `org/repo`, else folder name

The tag comes from `git remote get-url origin`, with the host, `.git` and `git@host:` or `https://host/` stripped. With no remote, it is the basename of `git rev-parse --show-toplevel`, or of the working directory when outside git.

A remote is stable across clones and machines. The folder name is the only option for local-only repos.

### 4. Two layers: a short instruction block plus a `memory` skill

Skills only load when a task matches their description, so a skill alone would not trigger the check after every turn. Putting the full protocol in every instruction file would repeat it five times and cost context in every session.

The always-loaded block:

```markdown
<!-- tmux-opsx:memory:start -->
## Memory
Personal memory shared by all coding agents lives in `~/.agents/memory/`.
- When past preferences or project context may matter, read `~/.agents/memory/MEMORY.md` and open only entries marked `global` or tagged with the current project.
- After each user turn, check whether it contained something worth remembering (explicit request, correction, confirmed choice, lasting fact). If so, save it following the `memory` skill.
- Use this store instead of any built-in or tool-specific memory.
<!-- tmux-opsx:memory:end -->
```

The skill holds the full protocol and the templates, so updating it only needs a re-install.

### 5. Replace the marked block in place

`install.sh` gets an `upsert_marked_block <file>` helper:

- **File missing:** create it with just the block.
- **Markers present:** replace everything between them.
- **No markers:** append the block after a blank line.
- **Backup:** keep a `.bak.<timestamp>` copy when the file changes, unless `--no-backup` is given.
- **Uninstall:** delete the lines between the markers, including the markers.

Alternatives considered:
- Overwriting the file would destroy user content, such as the graphify block.
- Appending without markers would add a duplicate on every run.

### 6. Templates live in the skill, not in the store

The store holds only user data, so an upgraded template never leaves an outdated copy inside the memory folder.

### 7. Write by re-checking, not locking

Plain writes don't fail on collision; the last writer silently wins. The skill tells agents to:

1. Read the target file and note its mtime or content hash.
2. Build the new content.
3. Re-read right before writing. If the file changed, repeat from step 1, up to 3 times.
4. After 3 failures, append the new index line rather than drop the update, and tell the user.

This applies to `MEMORY.md` and to the memory file. Collisions are rare with one user, so no lock file is needed.

### 8. Claude uses only the portable store

The instruction block tells every agent to use `~/.agents/memory/` instead of its built-in memory. For Claude Code, `CLAUDE.md` instructions override default behavior, so this takes precedence over the built-in memory. The existing Claude memories are imported once (decision 9) so nothing is lost.

### 9. One-time Claude import

`skills/memory/import-claude-memory.sh <store>` is run by `install.sh` after the skeleton is created. It is idempotent:

- **Marker:** if `<store>/.claude-import-done` exists, the script exits. The marker records the date and the number of entries imported.
- **Which files:** every `*.md` except `MEMORY.md` in `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/memory/`.
- **Finding the project folder:** the folder name is the absolute path with `/` turned into `-`. Starting at `/`, the script consumes dash-separated tokens and at each level picks the longest run of tokens, re-joined with `-`, that exists as a subfolder.
  - If the whole name resolves, the tag follows decision 3.
  - Otherwise the tag is the leftover tokens joined with `-` (for example `ship-mantianance`).
- **Converting a file:**
  - `metadata.type` becomes top-level `type`. A missing type becomes `project`, with a warning.
  - `node_type` is dropped.
  - `originSessionId` becomes `source: claude:<id>`.
  - `project:` is added.
  - The body is kept as it is.
- **Where it goes:** `<store>/<type>/<name>.md`. On a name collision with different content, the filename gets `<project-slug>--` as a prefix.
  - Names are otherwise kept, so `[[name]]` links still work.
- **Duplicates:** an entry is skipped when a file in the store already has the same `source:`.
- **Index:** one `MEMORY.md` line is appended per imported entry.

Every import is tagged with its source project, even if its content looks global. Promoting an entry to global is a one-line edit the user can make later.

### 10. Cursor gets the skill and a printed note

No global Cursor instructions file on disk is known. `install.sh` installs the skill and prints the block with a pointer to Cursor Settings → Rules. Cursor still reads the project-level `AGENTS.md` where one exists.

## Risks / Trade-offs

- **An agent ignores its instruction block, so no automatic save happens.** → This is a best-effort limit accepted up front. Explicit "remember this" requests still work through the skill.
- **Claude's built-in memory keeps writing despite the block.** → Watch after install. If it persists, look for a Claude Code setting that turns built-in memory off (open question).
- **The folder-name decoding picks the wrong path** (dashes or dots in names). → The tag is best-effort and visible in the index; the user can fix it by editing one field.
- **Too many memories get saved, since every agent checks every turn.** → The skill's never-save list, and updating existing entries instead of creating new ones.
- **The index grows until reading it gets expensive.** → One line per entry, under 200 characters. The skill says to merge or remove stale entries once it passes about 200 lines.
- **The instruction block conflicts with content the user wrote.** → Markers limit edits to the block, and a `.bak` is kept on every change.
- **A stale entry contradicts newer information.** → The skill says to update or delete the stale entry when it is found, never to keep both.

## Migration Plan

1. Resolve the stash-pop conflict and the duplicate Gemini helper functions in `opsx-window.sh`.
2. Implement, then test against a scratch `HOME` holding a copy of the real `~/.claude/projects`.
3. Run `./install.sh`. The Claude memories are imported and the instruction blocks are added.
4. Rollback: `./install.sh --uninstall` removes the skill and the blocks, and `.bak` files restore the instruction files. `~/.agents/memory/` is kept on purpose. Claude's original memory files are never modified by the import.

## Open Questions

- Does Cursor or the Cursor CLI (`agent`) read any global rules file that could be written automatically?
- Does Claude Code have a setting that turns built-in memory off, as a backstop to the instruction block?
- Confirm that OpenCode loads `~/.config/opencode/AGENTS.md` and Codex loads `~/.codex/AGENTS.md` (or `$CODEX_HOME/AGENTS.md`) in the installed versions.
