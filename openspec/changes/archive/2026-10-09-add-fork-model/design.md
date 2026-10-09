# Design

## Context

`fork.sh open` resolves the child CLI (`resolve_cli`: `--cli` > `$FORK_CLI` > host detection > first on PATH) and writes a per-fork `launch.sh` from `build_launch_cmd`. No model flag is passed today. Host detection (`running_under_claude`, `running_under_cursor`, …) already exists in `fork.sh`. However, no CLI reliably exposes its *current* model to a subprocess: env vars are missing or stale, and `/model` can change it mid-session. The agent running the `/fork` skill does know its own model id.

## Goals / Non-Goals

**Goals:**
- Forks inherit the parent's model by default when the child uses the same CLI.
- An explicit choice (`--model`, `$FORK_MODEL`) always beats inheritance.
- Model precedence and same-CLI gating are deterministic in `fork.sh`, so tests can cover them without an LLM.

**Non-Goals:**
- Detecting the parent's model from env vars, settings files or process args.
- Mapping model ids across CLIs or providers (a Claude id never becomes a Codex model).
- Validating that a model id exists. The child CLI reports unknown models itself, in the child pane.

## Decisions

**1. The agent supplies the parent model; `fork.sh` decides whether to use it.**
SKILL.md tells the parent to *always* pass `--parent-model <own id>`. `fork.sh` applies it only after `--model` and `$FORK_MODEL`, and only when the resolved child CLI equals the detected host CLI.
*Alternative:* have the agent pass `--model <own id>` itself. Rejected: that would beat `$FORK_MODEL`, and the cross-CLI rule would depend on the agent's judgement instead of tested shell logic.
*Alternative:* `fork.sh` sniffs the model (e.g. `ANTHROPIC_MODEL`, `~/.claude/settings.json`). Rejected: unreliable and CLI-specific, and it misses `/model` switches.

**2. Same-CLI check uses host detection only, with no PATH fallback.**
Add a `host_cli` helper built from the existing `running_under_*` checks. It returns empty when nothing matches. An empty host means no inheritance. `$FORK_HOST_CLI` (a CLI name, or `none`) overrides detection. Without it, tests running inside a real agent session would always detect that agent through the ancestor walk. It also gives nested or unusual setups an escape hatch. This is conservative: a wrong model on a different CLI fails outright, while a skipped inheritance only falls back to today's behaviour.

**3. Per-CLI flag spelling.**

| CLI | Flag |
|---|---|
| claude | `--model <m>` |
| agent (Cursor) | `--model <m>` |
| codex | `-m <m>` |
| opencode | `-m <provider/model>` |
| gemini | `-m <m>` |

The flag is inserted before the prompt argument and quoted with `%q`, as the existing arguments are. Only `claude` is installed on the authoring machine. The other spellings come from each CLI's documented options and are checked against `--help` during apply where the CLI is available.

**4. Input hygiene.**
Reject model values that are empty, contain whitespace or start with `-`. `%q` already prevents shell injection, but a value starting with `-` could be read as a flag by the child CLI (for example a bypass flag), which would break the read-only guarantee. Validation runs before an id is allocated, so a rejected call leaves no state behind.

**5. OpenCode inheritance needs `provider/model`.**
OpenCode's `-m` takes `provider/model`. An agent may only know a bare id, so an inherited value without `/` is ignored for OpenCode. An explicit `--model` is passed through unchanged, because the user is responsible for it.

**6. Visibility.**
`meta` gains `model=` (empty means CLI default). The output line becomes `fork <id> pane <%N> cli <cli> model <m|default>`. This keeps the existing `fork <id> pane %` prefix that SKILL.md and the tests rely on. `list` gains a MODEL column between CLI and PANE.

## Risks / Trade-offs

- [The agent misreports or omits its model id] → The child falls back to the CLI default, the same behaviour as today. The output line shows `model default`, so the gap is visible.
- [Host detection is wrong, e.g. a nested CLI] → Worst case is no inheritance or inheriting into a mismatched CLI. In the mismatched case the child CLI shows a model error in its pane. `--model` and `$FORK_MODEL` remain as escape hatches.
- [Uninstalled CLIs' flag spellings drift] → Each spelling is one line in `build_launch_cmd`. The per-CLI test asserts on the launch line, so a fix is a one-line change.
- [Tests run inside a real Claude Code session and inherit `CLAUDE_CODE_*` env] → The new test cases unset or set the host-detection variables explicitly.
