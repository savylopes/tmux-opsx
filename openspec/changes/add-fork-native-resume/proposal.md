# Proposal

> Assumption recorded from the `/opsx:explore` session of 2026-10-11: native forking is the **default** whenever the child runs on the same CLI as the parent and that CLI has a true fork; the summary brief stays as the automatic fallback and can be forced with a flag. Flip this to opt-in if you prefer.

## Why

`/fork` today hands the child a 5–15 line summary the parent writes about the conversation. It is lossy, costs the parent tokens to write, and the child cannot answer "why did we pick X three hours ago?" unless the parent remembered to put X in the brief. Claude Code and OpenCode can fork a live session natively: a new session id seeded with the entire transcript, leaving the parent's file untouched. The parent's session id is already in the environment of every shell command (`CLAUDE_CODE_SESSION_ID` on Claude Code), so `fork.sh` can do this without the agent knowing anything new.

## What Changes

- **Native fork when the child CLI is the host CLI and it has a true fork.** Claude Code: `claude --resume <parent session id> --fork-session …`. OpenCode: `opencode --continue --fork …` (the TUI exposes no session id to shell commands; "continue the last session of this project" is the parent in the normal case). Plan mode, the narrow `fork.sh return` allow rule, the appended system prompt and the model flags stay exactly as today.
- **Brief shrinks in native mode.** The child's first prompt becomes the question plus the generated fork protocol; the parent no longer writes a context summary. Cross-CLI forks, CLIs without a true fork (Codex, Gemini, Cursor), an OpenCode child with a `--cwd` different from the parent's (a Claude child stays native: `--resume` finds the session from any directory, verified in task 1.1), an unknown session id, `--brief-only`, or `FORK_NATIVE=0` fall back to today's full brief.
- **`fork.sh native [--cli <name>] [--cwd <dir>]`**: new read-only subcommand the skill runs first, printing `full <cli> <how>` or `brief <reason>`, so the parent knows which brief to write before writing it.
- **Visibility.** `meta` records `context=full|brief` and how the session was found; `open` prints a `# context:` line; `list` gains a CONTEXT column.
- **Skill and docs.** `/fork --brief` forces the summary brief; the skill's brief template has a short form for native mode and keeps the "no secrets" rule, now phrased for a child that sees everything the parent saw. README "Fork" section updated.
- Not changed: return/collect/notify, ids and state layout, model selection, read-only launch modes, `install.sh`.

## Capabilities

### New Capabilities
_None._

### Modified Capabilities
- `tmux-fork`: "Brief content" (context summary only in brief mode), "Fork state and ids" (`context` recorded in `meta`), "List and close forks" (CONTEXT column); new requirements for native fork selection per CLI, the `native` subcommand, fallbacks, and the `--brief`/`--brief-only` overrides.

## Impact

- `skills/fork/fork.sh`: session-id discovery (env plus the existing `/proc` recovery), native eligibility, `build_launch_cmd` for `claude` and `opencode`, `native` subcommand, `meta`/`list`/`open` output.
- `skills/fork/SKILL.md`: the detect-then-brief step, the short brief form, `--brief`.
- `tests/test-fork.sh`: native and fallback cases with the fake CLIs (they log their arguments, so `--resume`/`--fork-session`/`--fork` are directly assertable).
- `README.md`: Fork section.
- Behavioural shift: in native mode the child inherits the parent's full context, including anything sensitive the parent saw, and starts as close to compaction as the parent is.
