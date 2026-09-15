## 1. Prerequisites

- [ ] 1.1 Resolve the stash-pop conflicts in `README.md`, `install.sh` and `skills/opsx-run/SKILL.md`, keeping the four-agent ("Updated upstream") side; confirm with the user before dropping `stash@{0}`
- [ ] 1.2 Remove the duplicate `ensure_gemini_project_agent` / `ensure_gemini_project_agents` definitions in `skills/opsx-run/opsx-window.sh`, keeping the four-agent version
- [ ] 1.3 Remove the leftover unarchived `openspec/changes/add-ops-reviewer-security/` copy after confirming the archived copy is complete

## 2. Memory skill

- [ ] 2.1 Create `skills/memory/SKILL.md` with `name`/`description` frontmatter and the store layout, file format and index line format
- [ ] 2.2 Document reading: when to open `MEMORY.md`, filtering to global and current-project lines, opening only relevant files
- [ ] 2.3 Document the project tag rule with the exact `git remote get-url origin` / `git rev-parse --show-toplevel` steps and URL stripping
- [ ] 2.4 Document the after-every-turn save check, the save list and the never-save list
- [ ] 2.5 Document updating instead of duplicating, resolving contradictions, and the forget procedure
- [ ] 2.6 Document safe writes: note mtime/hash, re-check before writing, redo up to 3 times, append-and-tell-user fallback
- [ ] 2.7 Add `skills/memory/templates/memory.md` and `skills/memory/templates/MEMORY.md`

## 3. install.sh: skill and instruction blocks

- [ ] 3.1 Add the `--skip-memory` flag, and list the memory step in the header comment and `--help`
- [ ] 3.2 Install `skills/memory/` to the six skill folders, following the `install_opsx_run_skill` pattern
- [ ] 3.3 Implement `upsert_marked_block <file> <block>`: create if missing, replace between markers, append if no markers, `.bak` backup unless `--no-backup`
- [ ] 3.4 Write the instruction block into `<claude-config>/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md` and `~/.gemini/GEMINI.md`
- [ ] 3.5 Print the Cursor note with the block text and the Cursor user rules location

## 4. install.sh: store skeleton

- [ ] 4.1 Create `~/.agents/memory/`, the `user/`, `feedback/`, `project/` and `reference/` folders, and `MEMORY.md` from the template, only where missing
- [ ] 4.2 Confirm a re-run leaves existing store files byte-for-byte identical

## 5. Claude memory import

- [ ] 5.1 Create `skills/memory/import-claude-memory.sh <store>` that exits early when `<store>/.claude-import-done` exists
- [ ] 5.2 Decode encoded Claude project folder names into paths by walking existing folders (longest token run per level), with the leftover-tokens fallback
- [ ] 5.3 Work out each source's project tag (origin `org/repo`, else folder name, else leftover tokens)
- [ ] 5.4 Convert frontmatter (`metadata.type` → `type`, drop `node_type`, `originSessionId` → `source: claude:<id>`, add `project`, default missing type to `project` with a warning)
- [ ] 5.5 Write files to `<store>/<type>/<name>.md`, prefix `<project-slug>--` on name collision, skip entries whose `source` already exists
- [ ] 5.6 Append one index line per import to `MEMORY.md`, write the marker with date and count, and print the summary
- [ ] 5.7 Call the import from `install.sh` after the skeleton step

## 6. Uninstall

- [ ] 6.1 In `--uninstall`, remove the six `memory` skill folders and delete the marked block from each instruction file, leaving `~/.agents/memory/` untouched

## 7. Docs and verification

- [ ] 7.1 Add a Memory section to `README.md`: store layout, what install sets up per CLI, Cursor manual step, `--skip-memory`, uninstall keeps the store
- [ ] 7.2 Run `bash -n` and `shellcheck` on `install.sh` and `import-claude-memory.sh`
- [ ] 7.3 Test in a scratch `HOME`: fresh install, re-run (single block, unchanged store), existing `CLAUDE.md` with graphify block preserved, `--skip-memory`, `--uninstall`
- [ ] 7.4 Test the import on a copy of the real `~/.claude/projects` (14 files): tags for bocv-crawler, cha-marinha-site and ship-mantianance, `[[links]]` still resolve, originals unchanged, second run imports nothing
- [ ] 7.5 Simulate a task in `savylopes/tmux-opsx`: confirm an agent following the skill reads only `MEMORY.md` plus global and tmux-opsx entries
