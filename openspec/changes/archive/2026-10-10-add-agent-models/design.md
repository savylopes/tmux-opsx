# Design

## Context

See proposal.md for why. Current state that shapes the approach:

- `agents/opsx-*.md` all carry `model: inherit`. `install.sh` copies them as-is for Claude Code and Gemini, rewrites frontmatter for Cursor (`install_cursor_agent`, always `model: inherit`) and OpenCode (`install_opencode_agent`, no model key), and converts them to TOML for Codex (`install_codex_agent`, no model key).
- `opsx-window.sh` already resolves the *window* model (`resolve_model`, `detect-model`) and tags windows with `@opsx_change`, `@opsx_agent_cli`, `@opsx_model`. Lookups go through the window id found by `@opsx_change`.
- The dispatcher prompts in `skills/opsx-run/SKILL.md` tell the window to spawn every sub-agent with `model: inherit`.
- Claude Code's Agent tool `model` parameter accepts only aliases (`sonnet`, `opus`, `haiku`, `fable`); agent frontmatter also accepts full ids.
- Codex and Gemini windows do the work themselves without spawning sub-agents.

## Goals / Non-Goals

**Goals:**
- One resolver for "which model does agent X get", used by both `install.sh` and the runtime.
- Every layer degrades to the next one instead of failing a run.

**Non-Goals:**
- Per-agent models on Codex or Gemini.
- Shipping non-`inherit` defaults for Cursor or OpenCode (their model ids cannot be checked from here; users set them in their own file).
- Checking that a well-formed Claude id actually exists offline (the spawn-time retry covers it).
- Changing `/opsx-run --model` or `detect-model`.

## Decisions

**1. `opsx-window.sh models` is the single resolver.** It reads the shipped file, merges the user file, applies window memory and flags, validates against the CLI, and prints `<agent> <model> <source>`. `install.sh` calls it with `--agent-cli <cli>` and no change name (config layers only) for each CLI it installs, instead of parsing the files itself.
*Alternative:* a separate `opsx-models.sh`. Rejected: the runtime part needs the window lookup helpers already in `opsx-window.sh`.

**2. Config file format `<cli>.<agent> = <model>`.** One flat key=value file, parsed with `awk`; keys use the CLI names from `detect-cli` (`claude`, `agent`, `opencode`). The shipped file lives at `agents/models.conf` and is installed next to `opsx-window.sh` in each skills dir as `models.conf`. The script looks for `$OPSX_MODELS_CONF`, then `<script dir>/models.conf`, then `<script dir>/../../agents/models.conf` (running from the repo). The user file is `${XDG_CONFIG_HOME:-$HOME/.config}/tmux-opsx/models.conf` and is never written by install.
*Alternative:* YAML or one section per CLI. Rejected: bash-only parsing, and a flat file diffs and greps easily.

**3. Validation per CLI.** Claude: shape check (`opus|sonnet|haiku|fable|claude-*`). Cursor: membership in `agent models` output when the command exists (10 s timeout), else accept. OpenCode: must contain `/`, plus membership in `opencode models` when available. Invalid → warning on stderr naming `<cli>.<agent>` and the value, then the next layer.

**4. Window memory in tmux options `@opsx_model_<agent>`.** `ensure` and `send` set them after the window is found or created; `default` unsets. They vanish with the window, so `close` and `land` need no cleanup. The CLI used for validation is the window's `@opsx_agent_cli` when the window exists, otherwise `--agent-cli` or `detect-cli`.
*Alternative:* a state file under `$XDG_STATE_HOME`. Rejected: needs cleanup on close/land and can go stale.

**5. Prompts carry only overrides.** The caller runs `models <change> [flags]` before writing the prompt. For each agent with source `flag` or `window` the prompt says "spawn ops-<agent> with model `<m>`"; other agents are spawned with no model so their installed frontmatter (the config default) applies. The prompt also says: if a spawn fails with a model error, retry once without a model and print that it did.
*Why not pass every model:* config defaults may be full ids that the Claude Agent tool's `model` parameter rejects; frontmatter accepts them.

**6. Codex and Gemini.** `models` reports `inherit`/`inherit` for every agent, and `ensure`/`send` print one note and store nothing. Their agent files are left unchanged by install.

## Risks / Trade-offs

- [A remembered full Claude id (`claude-…`) passed through the Agent tool `model` parameter is rejected] → the retry-on-model-error rule spawns without a model, falling back to the frontmatter default, and the pane says so.
- [Cursor's Task tool may not take a model parameter] → the prompt asks the dispatcher to pass it when supported and otherwise note that the override was not applied; the installed frontmatter still sets the default.
- [`agent models` / `opencode models` are slow or need login] → 10 s timeout; on timeout or error the value is accepted for Cursor and the `provider/model` check alone applies for OpenCode.
- [The user edits `models.conf` but forgets to reinstall] → frontmatter keeps the old default until `install.sh` runs; `models` shows the new value, so the README tells users to re-run install after editing.

## Migration Plan

No data migration. After landing, `./install.sh` rewrites the agent files with the new defaults (keeping `.bak` copies). Rollback: set every key to `inherit` in the user file and re-run install, or revert the change.
