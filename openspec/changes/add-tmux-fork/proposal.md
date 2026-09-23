## Why

While working with a coding agent in tmux, side questions ("why did we pick X?", "where is Y handled?") either interrupt the main thread or get lost in a separate session that starts with no context. A way to fork the current conversation into a tmux pane — briefed with the parent's context, read-only, and able to report back — lets the user ask parallel questions without derailing the parent, and keeps the answers available to it afterwards.

## What Changes

- Add a new, standalone `fork` skill (`/fork`), independent of OpenSpec and `/opsx-run`, that works from any of the five supported agent CLIs (Claude Code, Cursor CLI, Codex CLI, OpenCode, Gemini CLI).
- `/fork ["question"]` writes a short **brief** (question + parent context) and opens a child agent in a **new tmux pane by default** (side-by-side split), or in a new window with `--window`. The child uses the same CLI as the parent unless `--cli` overrides it.
- Children are **questions-only**: they are launched in each CLI's read-only / plan mode where one exists, and the brief tells them not to modify files.
- Results flow back by **notify-then-pull**:
  - in the child, `/fork return` writes a concise `result.md` (answer, evidence, open doubts) and notifies the parent pane with a tmux message and a pane badge — nothing is ever typed into the parent;
  - in the parent, `/fork collect [id]` reads the result into its context, falling back to a `capture-pane` snapshot when no result was written.
- `/fork list` shows the forks of the current tmux session and their status; `/fork close [id|--all]` collects if needed, then kills the pane.
- Fork state lives outside the repo under `${XDG_STATE_HOME:-~/.local/state}/agent-forks/<tmux-session>/<id>/`.
- `install.sh` installs the skill to the same six skill folders as `memory` and `opsx-run`, with a new `--skip-fork` flag; `--uninstall` removes it.

## Capabilities

### New Capabilities

- `tmux-fork`: Forking an agent conversation into a tmux pane or window: brief format, read-only child launch per CLI, fork ids and state dir, `return` / notify / `collect` / `list` / `close` behavior, and error handling outside tmux.
- `fork-install`: What `install.sh` does for the fork skill: install locations, `--skip-fork`, and uninstall behavior.

### Modified Capabilities

<!-- None. opsx-run, memory and the ops-* agents are unaffected. -->

## Impact

- **New files**: `skills/fork/SKILL.md`, `skills/fork/fork.sh`
- **Modified files**: `install.sh`, `README.md`
- **Files written on the user's machine**: the six skill folders, and fork state under `~/.local/state/agent-forks/` (or `$XDG_STATE_HOME`)
- **Dependencies**: tmux; the agent CLIs already supported by tmux-opsx
- **Non-breaking**: `/opsx-run` and `opsx-window.sh` are not changed; the fork script borrows their patterns but shares no code
