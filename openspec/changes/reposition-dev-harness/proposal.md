## Why

tmux-opsx started as "run OpenSpec changes in tmux windows", but it now ships a lot more: quality gates (reviewer, security, QA, and soon eval), cross-agent memory, a fork skill for parallel questions, and one installer that wires all of it into five agent CLIs. It has become the user's personal development harness, yet the README and the repo itself still describe it only as an OpenSpec runner, and no OpenSpec `config.yaml` tells planning agents what the repo is for.

## What Changes

- Reframe `README.md` as a personal development harness, organised by what it provides:
  - **workflow** — `/opsx-run`: change → window → apply → gates → merge/land
  - **gates** — ops-reviewer, ops-security, ops-qa, ops-eval
  - **context** — cross-agent memory, fork
  - **portability** — one `install.sh` for Claude Code, Cursor CLI, Codex CLI, OpenCode, Gemini CLI
- Keep all existing usage documentation; only the intro, overview and section order change.
- Add `openspec/config.yaml` with a `context:` section describing the repo's purpose, what counts as the product (bash scripts, skills, agent definitions, installer), the supported CLIs, and conventions, so every OpenSpec agent plans with that context.
- The repo name `tmux-opsx`, install paths, skill names and the `ox` window prefix stay unchanged.

## Capabilities

### New Capabilities

- `harness-context`: How the repo describes itself — README framing as a development harness and the OpenSpec project context in `openspec/config.yaml`.

### Modified Capabilities

<!-- None. No behaviour changes. -->

## Impact

- **New files**: `openspec/config.yaml`
- **Modified files**: `README.md`
- **Non-breaking**: no script, skill, agent or install behaviour changes
