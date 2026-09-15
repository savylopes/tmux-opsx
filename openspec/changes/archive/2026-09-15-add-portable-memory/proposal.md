## Why

Each coding agent keeps its own memory, or none: Claude Code saves per-project memory under `~/.claude/projects/<encoded-path>/memory/`, and Codex, Cursor, OpenCode and Gemini don't remember anything between sessions. Preferences, corrections and project context learned in one tool are lost in the others. tmux-opsx already installs shared skills and agents for all five CLIs, so it can also install one shared memory and turn the repo into a personal harness rather than only an OpenSpec wrapper.

## What Changes

- Add a global, plain-folder memory store at `~/.agents/memory/`: a small `MEMORY.md` index plus `user/`, `feedback/`, `project/`, `reference/` folders, one Markdown file per memory.
- Memories are global by default. Project-specific ones carry a `project:` tag (git remote `org/repo`, falling back to the folder name).
- Add a `memory` skill with the full protocol: when to read, how to filter by project, what to save and never save, updating instead of duplicating, forgetting, and a write step that re-checks the file and retries when another agent wrote it at the same time.
- After every user turn, agents check whether the last exchange held something worth saving (explicit request, correction, confirmed choice, lasting fact).
- `install.sh` sets everything up automatically:
  - installs the `memory` skill to the same six skill folders as `opsx-run`;
  - adds a short marked instruction block to `CLAUDE.md` (Claude config dir), `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md` and `~/.gemini/GEMINI.md`, replacing it in place on re-run and leaving the rest of each file alone;
  - prints the block for the user to paste into Cursor user rules, since Cursor has no known global instructions file;
  - creates the store skeleton only if it is missing;
  - imports existing Claude Code memories once, tagging each with its source project.
- Claude Code is told to use `~/.agents/memory/` instead of its built-in memory.
- New `--skip-memory` flag. `--uninstall` removes the skill and the instruction blocks but never deletes `~/.agents/memory/`.

## Capabilities

### New Capabilities

- `agent-memory`: Store layout, file format, project tagging, and the read / save / forget / concurrent-write protocol that every agent follows via the `memory` skill.
- `memory-install`: What `install.sh` does for memory: skill install, marked instruction blocks per CLI, Cursor note, skeleton creation, `--skip-memory`, and uninstall behavior.
- `memory-import`: One-time import of existing Claude Code memories into the store, with format conversion, project tagging and duplicate protection.

### Modified Capabilities

<!-- None. Existing specs (ops-reviewer, ops-security, opsx-validate-pipeline) are unaffected. -->

## Impact

- **New files**: `skills/memory/SKILL.md`, `skills/memory/templates/`, `skills/memory/import-claude-memory.sh`
- **Modified files**: `install.sh`, `README.md`
- **Files written on the user's machine**: the six skill folders, `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` in the Claude, Codex, OpenCode and Gemini config folders (marked block only, with `.bak` backups), and `~/.agents/memory/`
- **Behavior change**: Claude Code stops using its built-in per-project memory in favor of the shared store
- **Prerequisite**: the unresolved stash-pop conflict in `README.md`, `install.sh` and `skills/opsx-run/SKILL.md` must be resolved first
- **Non-breaking**: OpenSpec, graphify, agents and `/opsx-run` behavior are unchanged
