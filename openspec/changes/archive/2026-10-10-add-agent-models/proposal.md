# Proposal

## Why

All five sub-agents (ops-applier, ops-eval, ops-reviewer, ops-security, ops-qa) run on the change window's model, because every agent file hardcodes `model: inherit` and the dispatcher prompts spawn them with `model: inherit`. The jobs differ: writing code and hunting security bugs reward the strongest model, while eval checks and long browser QA sessions do fine on a faster one. Today there is no way to set that per agent, either as a default or for one run.

## What Changes

- New `agents/models.conf`: shipped per-CLI, per-agent default models (`<cli>.<agent> = <model>|inherit`). Claude Code defaults: applier, reviewer, security `opus`; eval, qa `sonnet`. Cursor and OpenCode default to `inherit`. Codex and Gemini have no entries.
- Optional user overrides in `${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/models.conf`, one key at a time.
- `install.sh` resolves the defaults and writes them into each CLI's installed agent files (Claude Code, Cursor and OpenCode frontmatter). A model that is not valid for that CLI falls back to `inherit` with a warning.
- New per-agent flags on `/opsx-run`: `--applier-model`, `--eval-model`, `--reviewer-model`, `--security-model`, `--qa-model`. `default` clears a remembered choice.
- A model chosen with a flag is remembered on the change window (tmux option `@opsx_model_<agent>`) and reused by later runs in that window until it closes. Models that come from the config are never remembered.
- Per-agent precedence: flag > remembered in window > config default > inherit. Each layer is checked against the window's CLI; an invalid value falls through to the next layer.
- New `opsx-window.sh models <change>` subcommand prints the resolved model per agent; `ensure`/`send` accept the same flags and store them on the window; `list` and `status` show remembered models.
- Dispatcher prompts stop hardcoding `model: inherit`. They pass a model only for agents with a flag or remembered value, and retry once on inherit if the spawn fails with a model error, saying so in the pane.
- Codex and Gemini windows do the work themselves without spawning sub-agents, so per-agent models do not apply there: the flags are ignored with a one-line note.
- `/opsx-run --model` keeps its current meaning (the window's model only).

## Capabilities

### New Capabilities
- `agent-models`: per-sub-agent model selection for the opsx-run agents — shipped and user defaults, install-time application per CLI, per-run flags remembered on the change window, precedence, and fallback for models a CLI does not accept.

### Modified Capabilities

## Impact

- `agents/models.conf` (new), `agents/opsx-*.md` (frontmatter model now written by install).
- `install.sh`: read and merge the two config files, validate per CLI, write `model:` into Claude/Cursor/OpenCode agent files, install `models.conf` next to `opsx-window.sh`.
- `skills/opsx-run/opsx-window.sh`: `models` subcommand, per-agent flags on `ensure`/`send`, window options, `list`/`status` output.
- `skills/opsx-run/SKILL.md`: usage table, flag parsing and forwarding, dispatcher prompt templates.
- `README.md`: opsx-run section documents the defaults, config file and flags.
- `tests/`: a new test script for model resolution and install output.
