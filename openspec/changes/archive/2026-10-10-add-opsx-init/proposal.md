# Proposal

## Why

`install.sh` sets up the harness globally, but every new repo still needs hand setup before `/opsx-run` works well: `openspec init`, a `config.yaml` with a real `context:`, graphify ignores, and (with add-opsx-dev) a toolchain image. Doing this by hand is slow and easy to get half right. One command run inside a repo should do it, safely and repeatably.

## What Changes

- New shell command `opsx`, installed by `install.sh` into the user's bin dir (`~/.local/bin`). This change adds its `init` subcommand; add-opsx-dev adds `dev`.
- `opsx init` in a git repo, each step skipped when already done:
  - `openspec init --tools none` when there is no `openspec/` (skills are global, so no project copies)
  - `openspec/config.yaml` with `schema: spec-driven` and a marked `context:` skeleton when missing
  - `graphify-out/` added to `.gitignore`; `--graphify` also builds the code graph with `graphify update .` (no LLM)
  - `.opsx/dev.yaml` generated from detected toolchains (`go.mod`, `.python-version`/`pyproject.toml`, `.nvmrc`/`package.json`)
  - a warning when `docker` is missing; nothing is pulled or built
- It never overwrites a file the user has; `--force <step>` regenerates one step's file. It never commits: it prints what it created and a `git add` hint.
- Outside a git repo it stops with a clear message; `--git` runs `git init` first.
- New `/opsx-init` skill for all five CLIs: runs `opsx init` with the user's flags, then replaces the `context:` skeleton in `openspec/config.yaml` with a description written from the actual repo. It never rewrites a `context:` the user wrote.
- README gains an "Initialising a repo" section and the component overview lists `opsx` and `/opsx-init`.

## Capabilities

### New Capabilities
- `project-init`: per-repo setup with `opsx init` and the `/opsx-init` skill — steps, idempotency, `--force`, `--git`, `--graphify`, toolchain detection into `.opsx/dev.yaml`, and the agent-written `context:`.

### Modified Capabilities

## Impact

- New `skills/opsx-init/` (SKILL.md, `opsx-init.sh`) and a small `opsx` launcher that dispatches subcommands to skill scripts.
- `install.sh`: install the launcher to the user's bin dir and the `opsx-init` skill to every CLI's skills dir; uninstall removes them.
- `README.md`: new section, overview tree, OpenSpec setup section points to `opsx init`.
- `tests/test-init.sh` (new): scratch repos and HOME, fake `openspec`/`graphify`/`docker` on PATH.
- Writes only inside the target repo; touches no global config.
