---
name: memory
description: "Read, save, update, and forget entries in the shared cross-agent memory store at ~/.agents/memory/. Use before a task when past preferences or project context might matter, after every user turn to decide whether something is worth remembering, whenever the user explicitly asks to remember or forget something, and whenever writing a memory file or MEMORY.md so concurrent writes from other agent sessions aren't lost."
---

# memory

Shared, portable memory used by every coding agent (Claude Code, Cursor CLI, Codex CLI, OpenCode, Gemini CLI) through the plain folder `~/.agents/memory/`. Codebase and architecture knowledge already lives in the repo (specs, `CLAUDE.md`, git history) — this store is only for the user, their preferences, and cross-session project facts that aren't derivable from the code.

## Store layout

```
~/.agents/memory/
├── MEMORY.md
├── user/
├── feedback/
├── project/
└── reference/
```

- `MEMORY.md` is the index — small, always cheap to read, one line per memory.
- Each memory is one Markdown file inside the folder named after its `type`.

## File format

```yaml
---
name: kebab-case-name          # equals the filename without .md
description: one line used to judge relevance
type: user | feedback | project | reference
project: org/repo              # omit entirely for a global memory
source: claude:<sessionId>     # only present on entries imported from Claude Code
---
```

Bodies of `feedback` and `project` memories state the rule or fact, then a `**Why:**` line, then a `**How to apply:**` line. `user` and `reference` memories can be plain prose. Link related memories with `[[other-name]]` (the other file's `name`, no `.md`).

Use `templates/memory.md` when creating a new memory file, and `templates/MEMORY.md` when creating the index for a fresh store.

## Index line format

Each `MEMORY.md` line looks like:

```
- [Title](<type>/<name>.md) · <type> · <project-or-global> — <hook>
```

Kept under 200 characters. Use `global` when the memory has no `project` tag. Every memory file has exactly one index line — if you find a file with no line, add one; if you find a line with no file, remove it.

## Reading

Don't read every memory file by default. When past preferences or project context might matter for the current task:

1. Read `~/.agents/memory/MEMORY.md`.
2. Keep only the lines marked `global` or tagged with the current project (see "Project tag" below).
3. Open only the files among those that look relevant to the task at hand.

## Project tag

A memory is global unless it carries a `project:` tag. To compute the tag for the current working directory:

1. Run `git remote get-url origin` in the repo. If it succeeds, strip the URL down to `org/repo`: drop the scheme (`https://`), the `git@host:` / `https://host/` prefix, and a trailing `.git`.
2. If there is no `origin` remote, use the basename of `git rev-parse --show-toplevel`.
3. Outside a git repo, use the basename of the current working directory.

Tag a memory with the project when the user asks to save it "for this project" or it only makes sense in this codebase. Otherwise leave `project` out — it's global.

## Save check — after every user turn

Ask whether the exchange contained any of:

- an explicit request to remember (or forget) something,
- a correction to how you approached the task,
- a confirmation of a non-obvious choice you made,
- a new lasting fact about the user, a project, or an external resource.

If yes, save it (see "Writing safely" below), following "Updating instead of duplicating" first. If not, save nothing.

**Never save:** temporary debugging details, one-off command errors and their fixes, task/todo progress, conversation transcripts, generic language or framework knowledge, or anything already recorded in the store or derivable from the repository itself (code, git history, specs, `CLAUDE.md`).

## Updating instead of duplicating

Before creating a new file, search `MEMORY.md` for an existing entry on the same subject. If one exists, edit that file (and its index line) instead of creating a second one. If two entries contradict each other, keep the one supported by the newest information and correct or delete the other — never leave both in the store.

## Forgetting

When the user asks to forget something: delete or edit the matching memory file, remove or update its `MEMORY.md` line, and check the rest of the store for other files that still state the same thing.

## Writing safely (concurrent agents)

Plain files, no locks — the last writer silently wins, so re-check right before writing:

1. Read the target file (the memory file and/or `MEMORY.md`) and note its modification time or a content hash.
2. Build the new content in memory.
3. Right before writing, re-read the file. If it changed since step 1, redo the read-merge-write — up to 3 attempts total.
4. If all 3 attempts still collide, append your change instead of dropping it (a new index line, or your addition appended to the file) and tell the user a collision happened.

This applies to every write in the store, including `MEMORY.md` itself.
