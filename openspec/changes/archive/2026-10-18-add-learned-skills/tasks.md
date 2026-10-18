# Tasks

## 1. learn.sh

- [x] 1.1 Create `skills/learn/learn.sh` with `root` (main checkout via the common git dir, else `$PWD`) and name validation (`[a-z0-9-]`, at most 40 characters); verify in `tests/test-learn.sh` with a scratch repo, a worktree and a non-git directory
- [x] 1.2 Implement `save <name>` (stdin, exit 2 on empty input, bad name or missing `description`; frontmatter `name: learned-<name>`; atomic write) and the link step for `.claude`, `.agents`, `.cursor`, `.gemini` (relative symlinks, folders created, refuse a non-symlink `learned-<name>`, never touch other entries, nothing in `.opencode`); verify in `tests/test-learn.sh` every scenario of "Save a skill" and "Native links per CLI"
- [x] 1.3 Implement `sync`, `list`, `remove <name>` and `ignore`; verify in `tests/test-learn.sh` the repair, removal and gitignore scenarios (including `git check-ignore` on a skill file and a link, and that `save` never creates `.gitignore`); `shellcheck` clean

## 2. Skill text and instruction block

- [x] 2.1 Write `skills/learn/SKILL.md`: when to save (the five-part bar), check `learn.sh list` first and update instead of duplicating, SKILL.md shape (frontmatter `description` saying when to use it, concrete commands and paths, no secrets), `learn.sh save`, the one-line announcement, memory vs skill, `ignore` only on request; verify with grep for each item of the "Automatic capture rule" requirement
- [x] 2.2 Add the learn instruction block to `install.sh` (markers `<!-- tmux-opsx:learn:start -->` / `end`, same files as the memory block, Cursor note); verify in a scratch HOME that `~/.claude/CLAUDE.md` holds it once after two runs

## 3. Install and documentation

- [x] 3.1 Install `skills/learn/` into the six skill dirs, `--skip-learn`, uninstall (skill dirs and block, never `.opsx/skills/`), verify step; verify in scratch HOMEs install, skip and uninstall, and that the memory block is unaffected
- [x] 3.2 README: section (what is saved, `.opsx/skills/`, the `learned-` links per CLI, `learn.sh` commands, `ignore` and why it adds both lines), overview tree, component table, `--skip-learn`; verify README mentions `learn.sh`, `.opsx/skills/`, `learned-`, `--skip-learn`, `learn.sh ignore`

## 4. Integration

- [x] 4.1 Run `bash tests/test-learn.sh`, `shellcheck` on `learn.sh` and `install.sh`, `openspec validate add-learned-skills --strict`; verify all pass
- [x] 4.2 With the real Claude Code in a scratch repo: `learn.sh save probe` and confirm `claude -p` lists and triggers `learned-probe`; record the result. Re-check Cursor, Gemini and Codex discovery when they are installed and note it in the README
  - Result 2026-10-18 (Claude Code 2.1.302, scratch repo under /tmp, removed afterwards): `learn.sh save probe` created `.claude/skills/learned-probe -> ../../.opsx/skills/probe`; `claude -p "List the names of all available skills whose name starts with learned-"` printed `learned-probe`, and the trigger phrase `run the zebra lantern check` made it answer with the skill's marker `LANTERN-OK-7731`. Cursor CLI, Codex CLI, Gemini CLI and OpenCode are not installed on this machine; the README says they are unverified.

## Workflow follow-up

- Land, archive and run the installer.
