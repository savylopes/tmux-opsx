# learned-skills Specification

## Purpose
Lets coding agents turn a procedure they learned in a project into a skill stored in that project, found natively by every supported CLI, and easy to keep out of version control.

## Requirements

### Requirement: Skill store in the main checkout
Learned skills SHALL live in `<root>/.opsx/skills/<name>/SKILL.md`, where `<root>` is the main checkout of the current git repository (the directory holding its common git dir, the same for every worktree), else the current directory. `learn.sh root` SHALL print `<root>`.

#### Scenario: Worktree resolves to the main checkout
- **WHEN** `learn.sh root` runs inside a worktree `../wt-x` of the repository checked out at `shop`
- **THEN** it prints the path of `shop`

#### Scenario: Outside git
- **WHEN** `learn.sh root` runs in a directory that is not in a git repository
- **THEN** it prints that directory

### Requirement: Save a skill
`learn.sh save <name>` SHALL read a SKILL.md on stdin and write it atomically to `<root>/.opsx/skills/<name>/SKILL.md` with its frontmatter `name` set to `learned-<name>`, then create the links. `<name>` SHALL be kebab-case `[a-z0-9-]`, at most 40 characters. Saving an existing name SHALL replace that skill. Empty stdin, a bad name or stdin without a `description` in its frontmatter SHALL exit 2 and change nothing.

#### Scenario: Saved and linked
- **WHEN** `learn.sh save rerun-zone-proof` runs with a SKILL.md whose frontmatter has `name: whatever` and a `description`
- **THEN** `<root>/.opsx/skills/rerun-zone-proof/SKILL.md` exists with `name: learned-rerun-zone-proof`, and `<root>/.claude/skills/learned-rerun-zone-proof` is a symlink to that folder

#### Scenario: Refused input
- **WHEN** `learn.sh save "Bad Name"` runs, or `learn.sh save ok` runs with empty stdin or with frontmatter lacking `description`
- **THEN** it exits 2 and no file or link is created

#### Scenario: From a worktree
- **WHEN** `learn.sh save x` runs inside a worktree of `shop`
- **THEN** the skill and its links are created under `shop`, not under the worktree

### Requirement: Native links per CLI
For every saved skill, `learn.sh` SHALL keep a relative symlink `learned-<name>` to `.opsx/skills/<name>` directly inside `.claude/skills/`, `.agents/skills/`, `.cursor/skills/` and `.gemini/skills/` of `<root>`, creating those folders when missing. It SHALL NOT create a link in `.opencode/`. It SHALL NOT replace or touch any entry in those folders whose name does not start with `learned-`, and SHALL refuse to overwrite a `learned-<name>` entry that is not a symlink.

#### Scenario: Four links
- **WHEN** `learn.sh save x` runs in a repository with no CLI skills folders
- **THEN** `.claude/skills/learned-x`, `.agents/skills/learned-x`, `.cursor/skills/learned-x` and `.gemini/skills/learned-x` are relative symlinks resolving to `.opsx/skills/x`, and `.opencode/` does not exist

#### Scenario: Other skills untouched
- **WHEN** `.claude/skills/openspec-propose/` exists and `learn.sh save x` runs
- **THEN** `.claude/skills/openspec-propose/` is unchanged

#### Scenario: Not a link
- **WHEN** `.claude/skills/learned-x` is a regular directory and `learn.sh save x` runs
- **THEN** it exits non-zero naming that path, and the directory is unchanged

### Requirement: Sync, list and remove
`learn.sh sync` SHALL create every missing link for the skills under `.opsx/skills/` and remove every `learned-*` symlink in the four folders whose target no longer exists. `learn.sh list` SHALL print one line per skill: name, description, and the CLI folders whose link is present. `learn.sh remove <name>` SHALL delete the skill folder and its links; an unknown name SHALL exit 0 saying nothing matched.

#### Scenario: Sync repairs
- **WHEN** `.gemini/skills/learned-x` was deleted and `.opsx/skills/y/` was deleted while its links remain, then `learn.sh sync` runs
- **THEN** `.gemini/skills/learned-x` exists again and no `learned-y` link remains

#### Scenario: Remove
- **WHEN** `learn.sh remove x` runs
- **THEN** `.opsx/skills/x/` and every `learned-x` link are gone, and other skills are unchanged

### Requirement: Opt-in gitignore
`learn.sh ignore` SHALL append `.opsx/skills/` and `**/skills/learned-*` to `<root>/.gitignore` (creating it when missing) unless they are already present, and SHALL print what it added. Nothing else in `learn.sh` SHALL modify `.gitignore`.

#### Scenario: Ignored once
- **WHEN** `learn.sh ignore` runs twice
- **THEN** `.gitignore` contains each line exactly once and `git check-ignore` reports `.opsx/skills/x/SKILL.md` and `.claude/skills/learned-x` as ignored

#### Scenario: Save does not ignore
- **WHEN** `learn.sh save x` runs in a repository with no `.gitignore`
- **THEN** no `.gitignore` is created

### Requirement: Automatic capture rule
The learn instruction block and the `learn` skill SHALL tell the agent, after it finishes a task, to save a skill only for a procedure that is multi-step, specific to the project, verified to work in this session, likely needed again, and not already covered by a skill, README or AGENTS.md; to update the existing skill when one covers the task; to keep facts and preferences in memory instead; to never save secrets; and to announce each save in one line naming the skill and its path.

#### Scenario: Rule in the skill and block
- **WHEN** the installed `learn/SKILL.md` and the learn block in `~/.claude/CLAUDE.md` are read
- **THEN** both name `.opsx/skills/`, the save bar (multi-step, project-specific, verified, reusable, not already covered), updating instead of duplicating, the split with memory, no secrets, and the one-line announcement

### Requirement: Install and documentation
`install.sh` SHALL install `skills/learn/` (`SKILL.md`, executable `learn.sh`) into the same six skill folders as `memory`, write the learn block into the same instruction files as the memory block (with the same Cursor note), accept `--skip-learn`, and on `--uninstall` remove the skill folders and the block while leaving every project's `.opsx/skills/` alone. `README.md` SHALL document the feature and list it in the component overview.

#### Scenario: Installed
- **WHEN** `install.sh` runs in a scratch HOME
- **THEN** `~/.claude/skills/learn/learn.sh` is executable and `~/.claude/CLAUDE.md` contains the learn block once, also after a second run

#### Scenario: Skipped and uninstalled
- **WHEN** `install.sh --skip-learn` runs in a fresh scratch HOME, and `install.sh --uninstall` runs in one where it was installed
- **THEN** neither has a `learn` skill folder or a learn block afterwards, and the memory block is unaffected

#### Scenario: README
- **WHEN** `README.md` is read
- **THEN** it mentions `learn.sh`, `.opsx/skills/`, `learned-`, `--skip-learn` and `learn.sh ignore`
