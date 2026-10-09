# Spec Delta

## Purpose

Lets each opsx-run sub-agent (applier, eval, reviewer, security, qa) run on its own model: shipped and user defaults per CLI, written into the installed agent files, plus per-run flags that the change window remembers.

## ADDED Requirements

### Requirement: Shipped default models
The repo SHALL ship `agents/models.conf` with lines `<cli>.<agent> = <model>` where `<agent>` is one of `applier`, `eval`, `reviewer`, `security`, `qa` and `<model>` may be `inherit`. It SHALL set Claude Code to `opus` for applier, reviewer and security and `sonnet` for eval and qa, and `inherit` for every Cursor (`agent`) and OpenCode agent. Blank lines and `#` comments SHALL be ignored.

#### Scenario: Claude defaults
- **WHEN** `agents/models.conf` is read
- **THEN** it maps `claude.applier`, `claude.reviewer` and `claude.security` to `opus`, and `claude.eval` and `claude.qa` to `sonnet`

#### Scenario: Cursor and OpenCode inherit
- **WHEN** `agents/models.conf` is read
- **THEN** every `agent.<agent>` and `opencode.<agent>` key maps to `inherit`

### Requirement: User model overrides
A key in `${XDG_CONFIG_HOME:-$HOME/.config}/tmux-opsx/models.conf` SHALL replace the same key from the shipped file. Keys the user file does not set SHALL keep the shipped value. A missing user file SHALL NOT be an error.

#### Scenario: One key overridden
- **WHEN** the user file contains only `claude.qa = haiku` and `opsx-window.sh models c1 --agent-cli claude` runs with no window for `c1`
- **THEN** it reports qa as `haiku` from `config` and reviewer as `opus` from `config`

#### Scenario: No user file
- **WHEN** no user file exists and `opsx-window.sh models c1 --agent-cli claude` runs
- **THEN** it exits 0 and reports the shipped Claude defaults

### Requirement: Install writes models into agent files
`install.sh` SHALL write each agent's resolved config model into the installed agent file for Claude Code (`~/.claude/agents/opsx-<agent>.md`), Cursor (`~/.cursor/agents/opsx-<agent>.md`) and OpenCode (`~/.config/opencode/agents/ops-<agent>.md`) as the frontmatter `model:` value. `inherit` SHALL be written as `model: inherit` for Claude Code and Cursor and as no `model:` key for OpenCode.

#### Scenario: Claude agent files
- **WHEN** `install.sh` runs in a scratch HOME with no user file
- **THEN** `~/.claude/agents/opsx-reviewer.md` has frontmatter `model: opus` and `~/.claude/agents/opsx-qa.md` has `model: sonnet`

#### Scenario: User override reaches the agent file
- **WHEN** the user file sets `claude.reviewer = haiku` and `install.sh` runs
- **THEN** `~/.claude/agents/opsx-reviewer.md` has frontmatter `model: haiku`

#### Scenario: OpenCode inherit has no model key
- **WHEN** `install.sh` runs with the shipped defaults
- **THEN** `~/.config/opencode/agents/ops-applier.md` has no `model:` line in its frontmatter

### Requirement: Model validity per CLI
A model SHALL be valid for Claude Code only if it is `opus`, `sonnet`, `haiku`, `fable` or starts with `claude-`. For Cursor it SHALL be valid if `agent models` lists it, or if that command is unavailable. For OpenCode it SHALL be valid only in `provider/model` form and, when `opencode models` is available, only if listed. `inherit` SHALL always be valid.

#### Scenario: Claude rejects a foreign id
- **WHEN** the user file sets `claude.eval = gpt-5` and `opsx-window.sh models c1 --agent-cli claude` runs
- **THEN** it reports eval as `inherit` and prints a warning naming `gpt-5` on stderr

#### Scenario: OpenCode bare id
- **WHEN** the user file sets `opencode.qa = gpt-5` and `opsx-window.sh models c1 --agent-cli opencode` runs
- **THEN** it reports qa as `inherit` and prints a warning on stderr

### Requirement: Install falls back on invalid models
When a config model is not valid for a CLI, `install.sh` SHALL write that agent's file as `inherit`, print a warning naming the CLI, agent and model, and continue with exit status 0.

#### Scenario: Invalid Claude config model
- **WHEN** the user file sets `claude.security = gpt-5` and `install.sh` runs
- **THEN** it exits 0, prints a warning containing `claude.security` and `gpt-5`, and `~/.claude/agents/opsx-security.md` has `model: inherit`

### Requirement: Per-agent model flags
`opsx-window.sh models`, `ensure` and `send` SHALL accept `--applier-model`, `--eval-model`, `--reviewer-model`, `--security-model` and `--qa-model`, each taking one value. A value that is empty, contains whitespace or starts with `-` SHALL be rejected with a non-zero exit before any window is created or changed.

#### Scenario: Unsafe value rejected
- **WHEN** `opsx-window.sh ensure c1 --prompt-file p --reviewer-model "--x"` runs
- **THEN** it exits non-zero and no window tagged `@opsx_change=c1` exists

### Requirement: Model resolution order
For each agent, `opsx-window.sh models <change>` SHALL print one line `<agent> <model> <source>` where the model is chosen as: the flag, else the value remembered on the change window, else the config value, else `inherit`. `<source>` SHALL be `flag`, `window`, `config` or `inherit`. A value invalid for the window's CLI SHALL be skipped in favour of the next layer.

#### Scenario: Flag beats everything
- **WHEN** the window for `c1` remembers reviewer `sonnet` and `opsx-window.sh models c1 --reviewer-model haiku` runs on Claude Code
- **THEN** the reviewer line is `reviewer haiku flag`

#### Scenario: Remembered beats config
- **WHEN** the window for `c1` remembers reviewer `sonnet` and `opsx-window.sh models c1` runs without flags
- **THEN** the reviewer line is `reviewer sonnet window` and the applier line is `applier opus config`

#### Scenario: Invalid flag falls through
- **WHEN** `opsx-window.sh models c1 --agent-cli claude --qa-model gpt-5` runs with no window memory
- **THEN** the qa line is `qa sonnet config` and stderr warns about `gpt-5`

### Requirement: Flag choices are remembered on the window
When `ensure` or `send` receives a per-agent flag, it SHALL store the value on the change window as the tmux window option `@opsx_model_<agent>`. Agents without a flag SHALL keep any value already stored. Models taken from the config SHALL NOT be stored.

#### Scenario: Flag stored
- **WHEN** `opsx-window.sh ensure c1 --prompt-file p --qa-model haiku` creates the window
- **THEN** the window has `@opsx_model_qa` set to `haiku` and no `@opsx_model_reviewer` option

#### Scenario: Later run reuses it
- **WHEN** a later `opsx-window.sh send c1 --prompt-file p` runs without flags
- **THEN** `@opsx_model_qa` is still `haiku` and `opsx-window.sh models c1` reports `qa haiku window`

### Requirement: Clearing a remembered model
A flag value of `default` SHALL remove that agent's `@opsx_model_<agent>` option from the window, so the agent resolves from the config again.

#### Scenario: Reset to config
- **WHEN** the window remembers qa `haiku` and `opsx-window.sh send c1 --prompt-file p --qa-model default` runs
- **THEN** the window has no `@opsx_model_qa` option and `opsx-window.sh models c1` reports `qa sonnet config`

### Requirement: Memory ends with the window
Remembered models SHALL live only on the change window. After the window is closed, a new window for the same change SHALL start with no remembered models.

#### Scenario: Close and recreate
- **WHEN** the window for `c1` remembers qa `haiku`, `opsx-window.sh close c1` runs, then `opsx-window.sh ensure c1 --prompt-file p` runs
- **THEN** the new window has no `@opsx_model_qa` option

### Requirement: Remembered models are visible
`opsx-window.sh list` SHALL show each change window's remembered models as `<agent>=<model>` pairs, and `opsx-window.sh status <change>` SHALL print them before the pane capture. Windows with none SHALL show no model pairs.

#### Scenario: List shows memory
- **WHEN** the window for `c1` remembers qa `haiku` and `opsx-window.sh list` runs
- **THEN** the line for `c1` contains `qa=haiku`

### Requirement: Codex and Gemini ignore per-agent models
For a window whose CLI is `codex` or `gemini`, per-agent flags SHALL be accepted, not stored, and reported with one stderr note that per-agent models do not apply to that CLI. `models` SHALL report every agent as `inherit` with source `inherit`.

#### Scenario: Codex window
- **WHEN** `opsx-window.sh ensure c2 --prompt-file p --agent-cli codex --qa-model gpt-5` runs
- **THEN** it exits 0, stderr has one note about per-agent models, and the window has no `@opsx_model_qa` option

### Requirement: Window model flag unchanged
`--model` on `ensure` SHALL keep setting only the model the window's CLI is launched with. It SHALL NOT change any agent's resolved model or any `@opsx_model_<agent>` option.

#### Scenario: Window model only
- **WHEN** `opsx-window.sh ensure c1 --prompt-file p --agent-cli claude --model haiku` creates the window
- **THEN** the launch command contains `--model haiku`, no `@opsx_model_*` option is set, and `models c1` reports `applier opus config`

### Requirement: Dispatcher passes per-agent models
The `/opsx-run` skill SHALL accept the five per-agent flags, forward them to `opsx-window.sh`, and write dispatcher prompts that name a model for an agent only when `models` reports source `flag` or `window`. The prompts SHALL NOT tell the dispatcher to spawn agents with `model: inherit`. On a model error at spawn, the dispatcher SHALL retry once without a model and say so in the pane.

#### Scenario: Skill text
- **WHEN** `skills/opsx-run/SKILL.md` is read
- **THEN** it documents `--applier-model`, `--eval-model`, `--reviewer-model`, `--security-model` and `--qa-model`, contains the retry-on-model-error instruction, and contains no `model: inherit` spawn instruction

### Requirement: Documentation
`README.md` SHALL document `agents/models.conf`, the user override file, the five per-agent flags, the resolution order and that Codex and Gemini ignore per-agent models.

#### Scenario: README
- **WHEN** `README.md` is read
- **THEN** it mentions `models.conf`, `--reviewer-model` and the order flag > window > config > inherit
