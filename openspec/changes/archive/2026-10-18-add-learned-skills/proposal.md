# Proposal

> Captured from the `/opsx:explore` session of 2026-10-18. Decisions confirmed there: agents save a project skill automatically when they learn a new, repeatable procedure in a project, the way they already save memories; the one real copy lives in `<repo>/.opsx/skills/<name>/`, and each CLI sees it through a `learned-<name>` symlink directly inside its native project skills folder. A probe with the real Claude Code (2.1.302) showed that skills one folder deeper inside `.claude/skills/` are not discovered, while a per-skill symlink is discovered and runs.

## Why

When an agent works out how to do something in a project (re-run a proof against a cluster, regenerate a fixture, query a requirements document), that knowledge is lost when the session ends, or it ends up as a hand-made skill that only one CLI can see: `ztd-requirements` sits in `~/.claude/skills/` for every project, `medicentro-requirements` in one repo's `.claude/skills/`. Memory already captures facts and preferences automatically; procedures need the same, stored in the project, readable by every CLI, and easy to keep out of git.

## What Changes

- **New `learn` skill** (`skills/learn/SKILL.md` + `learn.sh`), installed for all five CLIs like `memory`. It tells the agent when a procedure deserves a skill, how to write one, and how to update an existing one instead of adding a duplicate.
- **New instruction block** `<!-- tmux-opsx:learn:start -->` written by `install.sh` beside the memory block in each CLI's global instructions file: after finishing a task, check whether it taught a new, verified, repeatable procedure specific to this project that no skill, README or AGENTS.md already covers; if so save it with the `learn` skill and say so in one line. Facts and preferences stay in memory.
- **`learn.sh`**: `root` (the main checkout of the current repository, never a worktree), `save <name>` (writes `.opsx/skills/<name>/SKILL.md` from stdin with `name: learned-<name>` frontmatter, then links it), `sync` (recreates missing links, removes dangling `learned-*` links), `list`, `remove <name>`, and `ignore` (adds `.opsx/skills/` and `**/skills/learned-*` to the repository's `.gitignore`, only when the user asks).
- **Links** `learned-<name>` in `.claude/skills/`, `.agents/skills/`, `.cursor/skills/` and `.gemini/skills/` of the main checkout. OpenCode reads `.claude/skills/` and `.agents/skills/`, so it gets no link of its own (no duplicates).
- **Install, tests, docs**: `--skip-learn`, uninstall removes the skill folders and the block (never `.opsx/skills/`), `tests/test-learn.sh`, README section.
- Not in scope: syncing learned skills between projects or machines, promoting a learned skill to a global one, deleting skills automatically.

## Capabilities

### New Capabilities
- `learned-skills`: automatic capture of project procedures as skills, their storage under `.opsx/skills/`, the per-CLI `learned-*` links, the `learn.sh` commands, the instruction block, and install and documentation.

### Modified Capabilities

None.

## Impact

- New `skills/learn/SKILL.md`, `skills/learn/learn.sh`, `tests/test-learn.sh`.
- `install.sh`: install of `skills/learn/`, the learn instruction block (same files and Cursor note as memory), `--skip-learn`, uninstall and verify. `README.md`: new section, overview tree, component table.
- In user projects: `.opsx/skills/` and `learned-*` symlinks in up to four CLI skills folders, created only when an agent saves a skill.
