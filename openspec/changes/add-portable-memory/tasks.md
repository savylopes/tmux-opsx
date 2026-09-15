## 1. Prerequisites

- [x] 1.1 Resolve the stash-pop conflicts in `README.md`, `install.sh` and `skills/opsx-run/SKILL.md`, keeping the four-agent ("Updated upstream") side; confirm with the user before dropping `stash@{0}` — branch starts from clean HEAD (`opsx/add-portable-memory` was created from `main` at commit `acd8600`, before the stash was popped); no conflict markers or pre-conflict state exist on this branch. Main-tree stash cleanup (`stash@{0}`) is left to the user — never touched per dispatcher instructions.
- [x] 1.2 Remove the duplicate `ensure_gemini_project_agent` / `ensure_gemini_project_agents` definitions in `skills/opsx-run/opsx-window.sh`, keeping the four-agent version — verified only a single four-agent definition of each function exists on this branch; no duplicate to remove.
- [x] 1.3 Remove the leftover unarchived `openspec/changes/add-ops-reviewer-security/` copy after confirming the archived copy is complete — not on this branch (only `openspec/changes/archive/2026-09-01-add-ops-reviewer-security/` exists here); the leftover unarchived copy is untracked cruft in the main working tree only — user removes it locally.

## 2. Memory skill

- [x] 2.1 Create `skills/memory/SKILL.md` with `name`/`description` frontmatter and the store layout, file format and index line format
- [x] 2.2 Document reading: when to open `MEMORY.md`, filtering to global and current-project lines, opening only relevant files
- [x] 2.3 Document the project tag rule with the exact `git remote get-url origin` / `git rev-parse --show-toplevel` steps and URL stripping
- [x] 2.4 Document the after-every-turn save check, the save list and the never-save list
- [x] 2.5 Document updating instead of duplicating, resolving contradictions, and the forget procedure
- [x] 2.6 Document safe writes: note mtime/hash, re-check before writing, redo up to 3 times, append-and-tell-user fallback
- [x] 2.7 Add `skills/memory/templates/memory.md` and `skills/memory/templates/MEMORY.md`

## 3. install.sh: skill and instruction blocks

- [x] 3.1 Add the `--skip-memory` flag, and list the memory step in the header comment and `--help`
- [x] 3.2 Install `skills/memory/` to the six skill folders, following the `install_opsx_run_skill` pattern
- [x] 3.3 Implement `upsert_marked_block <file> <block>`: create if missing, replace between markers, append if no markers, `.bak` backup unless `--no-backup`
- [x] 3.4 Write the instruction block into `<claude-config>/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md` and `~/.gemini/GEMINI.md`
- [x] 3.5 Print the Cursor note with the block text and the Cursor user rules location

## 4. install.sh: store skeleton

- [x] 4.1 Create `~/.agents/memory/`, the `user/`, `feedback/`, `project/` and `reference/` folders, and `MEMORY.md` from the template, only where missing
- [x] 4.2 Confirm a re-run leaves existing store files byte-for-byte identical — verified with `md5sum` over every store file before/after a second `./install.sh` run in a scratch `HOME`.

## 5. Claude memory import

- [x] 5.1 Create `skills/memory/import-claude-memory.sh <store>` that exits early when `<store>/.claude-import-done` exists
- [x] 5.2 Decode encoded Claude project folder names into paths by walking existing folders (longest token run per level), with the leftover-tokens fallback
- [x] 5.3 Work out each source's project tag (origin `org/repo`, else folder name, else leftover tokens)
- [x] 5.4 Convert frontmatter (`metadata.type` → `type`, drop `node_type`, `originSessionId` → `source: claude:<id>`, add `project`, default missing type to `project` with a warning)
- [x] 5.5 Write files to `<store>/<type>/<name>.md`, prefix `<project-slug>--` on name collision, skip entries whose `source` already exists
- [x] 5.6 Append one index line per import to `MEMORY.md`, write the marker with date and count, and print the summary
- [x] 5.7 Call the import from `install.sh` after the skeleton step

## 6. Uninstall

- [x] 6.1 In `--uninstall`, remove the six `memory` skill folders and delete the marked block from each instruction file, leaving `~/.agents/memory/` untouched

## 7. Docs and verification

- [x] 7.1 Add a Memory section to `README.md`: store layout, what install sets up per CLI, Cursor manual step, `--skip-memory`, uninstall keeps the store
- [x] 7.2 Run `bash -n` and `shellcheck` on `install.sh` and `import-claude-memory.sh` — both clean (`bash -n` OK; shellcheck reports only pre-existing warnings unrelated to this change, plus 3 intentional SC2016 infos for literal backticks in the instruction-block text)
- [x] 7.3 Test in a scratch `HOME`: fresh install, re-run (single block, unchanged store), existing `CLAUDE.md` with graphify block preserved, `--skip-memory`, `--uninstall` — all verified; see report for details
- [x] 7.4 Test the import on a copy of the real `~/.claude/projects` (14 files): tags for bocv-crawler, cha-marinha-site and ship-mantianance, `[[links]]` still resolve, originals unchanged, second run imports nothing — all 14 imported (0 skipped, 0 warnings) with correct tags; found and fixed a real bug (see report) where sibling memories sharing one Claude session id were wrongly treated as duplicates of each other
- [x] 7.5 Simulate a task in `savylopes/tmux-opsx`: confirm an agent following the skill reads only `MEMORY.md` plus global and tmux-opsx entries — confirmed: this repo's tag resolves to `savylopes/tmux-opsx` via `git remote get-url origin`; a scripted simulation of the skill's filter over a mixed index correctly keeps only `global` and `savylopes/tmux-opsx` lines and excludes `cha-marinha-site` / `savylopes/bo-cv` lines
