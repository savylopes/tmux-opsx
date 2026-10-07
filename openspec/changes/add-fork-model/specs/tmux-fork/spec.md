# Spec Delta

## ADDED Requirements

### Requirement: Choose the child's model
`fork.sh open` SHALL accept `--model <m>` and read `$FORK_MODEL`. The child's model SHALL be chosen as: `--model`, else `$FORK_MODEL`, else an inherited parent model (see "Inherit the parent's model"), else none. When a model is chosen, the child SHALL be launched with its CLI's model flag set to that value; when none is chosen, no model flag SHALL be passed. A model value that is empty, contains whitespace or starts with `-` SHALL be rejected before anything is opened.

#### Scenario: Explicit model
- **WHEN** the user runs `fork.sh open --cli claude --model haiku` with a brief
- **THEN** the child's `launch.sh` passes `--model haiku` to `claude`

#### Scenario: No model anywhere
- **WHEN** `fork.sh open --cli claude` runs with no `--model`, no `--parent-model` and `$FORK_MODEL` unset
- **THEN** `launch.sh` contains no model flag, as before this change

#### Scenario: Environment default
- **WHEN** `$FORK_MODEL=sonnet` and `fork.sh open --cli claude` runs without `--model`
- **THEN** the child is launched with `--model sonnet`

#### Scenario: Flag beats environment
- **WHEN** `$FORK_MODEL=sonnet` and `fork.sh open --cli claude --model opus` runs
- **THEN** the child is launched with `--model opus`

#### Scenario: Per-CLI flag spelling
- **WHEN** a fork is opened with `--model m1` for each of `claude`, `agent`, `codex`, `opencode` and `gemini`
- **THEN** each child's launch line passes `m1` through that CLI's model flag (`--model` for claude and agent, `-m` for codex, opencode and gemini)

#### Scenario: Unsafe model value
- **WHEN** `fork.sh open --model "--dangerously-skip-permissions"` runs
- **THEN** it exits non-zero with a clear message, and no fork id, state directory or pane is created

### Requirement: Inherit the parent's model
`fork.sh open` SHALL accept `--parent-model <m>`, the parent agent's own model. It SHALL be used only when neither `--model` nor `$FORK_MODEL` gives a model and the child CLI is the same CLI as the host CLI. The host CLI SHALL be taken from `$FORK_HOST_CLI` when set (`none` meaning undetected), otherwise detected. Otherwise it SHALL be ignored without error. For OpenCode children it SHALL be used only if it has the `provider/model` form. The `/fork` skill SHALL instruct the parent agent to always pass `--parent-model` with its own model id.

#### Scenario: Same CLI inherits
- **WHEN** the parent runs under Claude Code and calls `fork.sh open --parent-model claude-opus-5-5` without `--cli`
- **THEN** the Claude child is launched with `--model claude-opus-5-5`

#### Scenario: Cross-CLI fork does not inherit
- **WHEN** the parent runs under Claude Code and calls `fork.sh open --cli codex --parent-model claude-opus-5-5`
- **THEN** the Codex child is launched with no model flag

#### Scenario: Environment default beats inheritance
- **WHEN** `$FORK_MODEL=haiku` and the parent calls `fork.sh open --parent-model claude-opus-5-5` from Claude Code
- **THEN** the child is launched with `--model haiku`

#### Scenario: Host not detected
- **WHEN** `$FORK_HOST_CLI=none` and `fork.sh open --cli claude --parent-model claude-opus-5-5` runs
- **THEN** the child is launched with no model flag

#### Scenario: OpenCode id without provider
- **WHEN** the parent runs under OpenCode and passes `--parent-model gpt-5`
- **THEN** the OpenCode child is launched with no model flag

### Requirement: Report the child's model
The `open` output line SHALL end with `model <m>` naming the chosen model, or `model default` when none was chosen.

#### Scenario: Output line
- **WHEN** `fork.sh open --cli claude --model haiku` succeeds as fork 3
- **THEN** its first output line has the form `fork 3 pane %<n> cli claude model haiku`

## MODIFIED Requirements

### Requirement: Fork state and ids
Each fork SHALL have a state directory `${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/<tmux-session>/<id>/` holding `brief.md`, `meta` and, once written, `result.md`. Ids SHALL be small integers, unique within the tmux session and allocated atomically. `meta` SHALL record the parent pane, child pane, CLI, model (empty when the CLI default is used), cwd, creation time and status (`open`, `returned`, `closed`). The child process SHALL receive `FORK_ID`, `FORK_DIR` and `FORK_PARENT` environment variables.

#### Scenario: Concurrent forks
- **WHEN** two parents in the same tmux session fork at the same moment
- **THEN** they receive different ids and separate state directories

#### Scenario: Model recorded
- **WHEN** a fork is opened with `--model haiku`
- **THEN** its `meta` contains `model=haiku`, and a fork opened with no model contains `model=`

### Requirement: List and close forks
`/fork list` SHALL show every fork of the current tmux session with id, status, CLI, model (`default` when none), pane and the first line of its question. `/fork close <id>` SHALL save a capture if no result exists, kill the child pane or window, and set status `closed`. `/fork close --all` SHALL do this for every open fork of the session. State directories SHALL be kept after closing.

#### Scenario: Close without result
- **WHEN** the user closes fork 1, which has no `result.md`
- **THEN** `capture.txt` is saved, the pane is killed, and a later `collect 1` returns that capture

#### Scenario: Model column
- **WHEN** fork 1 was opened with `--model haiku` and fork 2 with no model, and the user runs `fork.sh list`
- **THEN** the header has a MODEL column, fork 1's row shows `haiku` and fork 2's row shows `default`
