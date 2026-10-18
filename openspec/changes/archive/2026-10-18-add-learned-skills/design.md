# Design

## Context

See proposal.md and `specs/learned-skills/spec.md`. Building blocks in the repo: `install.sh` writes the memory block with `upsert_block_file` and removes it with `remove_marked_block` (both take markers, so a second block reuses them); `install_*_skill` helpers install a skill folder into six skill dirs; `expose.sh`/`explain.sh` compute "the main checkout" from `git rev-parse --git-common-dir`. Probe result (2026-10-18, Claude Code 2.1.302, scratch repo): `.claude/skills/<name>/` and a symlink `.claude/skills/<name> -> ../../.opsx/skills/<name>` are discovered and triggered; `.claude/skills/<group>/<name>/` and a symlinked group folder are not.

## Goals / Non-Goals

**Goals:** native discovery on every CLI from one copy; one place to delete or ignore; no accidental git noise from tmux-opsx itself.

**Non-Goals:** cross-project sharing, automatic deletion, rating skills.

## Decisions

### 1. One copy in `.opsx/skills/`, per-skill links with a `learned-` prefix
CLIs discover skills only directly inside their skills folder, so each skill needs its own entry there. Links keep one editable copy; the prefix keeps them apart from skills the project commits and makes one glob (`**/skills/learned-*`) ignore every link. Alternative: an index read through an instruction. Rejected: discovery would depend on the model remembering to read it.

### 2. Link folders: `.claude`, `.agents`, `.cursor`, `.gemini`; not `.opencode`
OpenCode reads `.claude/skills/` and `.agents/skills/`; a third link would list the skill twice. Codex reads `.agents/skills/`. The Cursor and Gemini folders follow the same one-folder-per-skill convention but were not verified on this machine (neither CLI is installed); a task re-checks once they are.

### 3. Relative links, created by the script only
`ln -s ../../.opsx/skills/<name> .claude/skills/learned-<name>` survives moving or re-cloning the repository. The agent never runs `ln` itself: `learn.sh save` and `sync` own the links, so a renamed or removed skill cannot leave a link behind unnoticed.

### 4. Root is the main checkout
Change work happens in `../wt-<change>` worktrees that are deleted after landing; a skill saved there would be lost. `learn.sh root` uses the directory holding the common git dir, as `expose.sh` does for the project name.

### 5. The save bar lives in two places
The instruction block (always in context) carries the short trigger and bar; the `learn` skill carries the full procedure: check `learn.sh list` for an existing skill first, write a SKILL.md with a `description` that says when to use it, name commands and paths concretely, no secrets, then `learn.sh save`. Saving is automatic, announced in one line, like memory.

### 6. `.gitignore` only on request
tmux-opsx never edits a project's `.gitignore` on its own; `learn.sh ignore` adds the two lines when the user asks ("keep learned skills private").

## Risks / Trade-offs

- [Too many low-value skills] → the five-part bar, update-don't-duplicate, and `learn.sh list`/`remove` for pruning.
- [Committed links pointing nowhere when only `.opsx/skills/` is ignored] → `ignore` always adds both lines; README explains why.
- [A CLI that does not follow symlinks] → `sync` can be extended to copy instead; flagged in the verification task.
- [Read-only forks cannot save] → by design; the parent saves.
