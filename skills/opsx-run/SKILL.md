---
name: opsx-run
description: "Run an OpenSpec change's apply/verify/archive lifecycle in its own tmux window named after the change, driven by the ops-applier agent. Reuses the same window for every follow-up instruction about that change. Trigger: /opsx-run <change> [action]"
trigger: /opsx-run
---

# /opsx-run

One OpenSpec change = one tmux window named after the change, in the current tmux session, running a `claude` session that delegates the actual work to the **ops-applier** subagent. The window is created on first use and **reused** for every later instruction about that change.

## Usage

```
/opsx-run <change>                      # apply (default) — creates the window
/opsx-run <change> apply
/opsx-run <change> verify               # inline validate/status gate; only bothers the window on failure
/opsx-run <change> archive
/opsx-run <change> status               # snapshot of what the window is doing right now
/opsx-run <change> "<free-form text>"   # send any instruction to that change's window
/opsx-run list                          # show the windows in this session
```

## Helper script

All tmux calls go through `~/.claude/skills/opsx-run/opsx-window.sh`. **Never hand-roll `tmux send-keys`** — the script handles literal-text quoting, newline collapsing, window-id targeting, and rename suppression, all of which break subtly when improvised.

```
opsx-window.sh ensure <change> --prompt-file <f> [--cwd <dir>]   # create window (launching claude with the prompt), or send prompt to the existing one
opsx-window.sh send   <change> --prompt-file <f>                 # send only; errors if the window doesn't exist
opsx-window.sh status <change> [--lines N]                       # capture-pane snapshot (default 60 lines)
opsx-window.sh list                                              # windows in the current session
```

It prints one line on success: `created @7 2:add-auth`, `reused @7 2:add-auth`, or `sent @7 2:add-auth`. Relay which of the three happened — the user wants to know whether a new window appeared.

Write prompts to a file in the session scratchpad (e.g. `<scratchpad>/opsx-<change>-<action>.txt`) and pass `--prompt-file`. Prompt text is never spliced into a command line.

## Preconditions — check in this order, fail fast

1. **Inside tmux.** If `$TMUX` is unset, stop and tell the user to run this from a tmux session. Do not fall back to running the work inline.
2. **Change exists.** `openspec/changes/<change>/` must exist under the current directory. If the name is missing, vague, or ambiguous, run `openspec list --json` and use **AskUserQuestion** to let the user pick from the active changes. **Never guess or auto-select** the change name.

Both `openspec` and the window's `claude` run from the current working directory, so run `/opsx-run` from the project root.

## Actions

| Action | This session does | The window gets |
|---|---|---|
| `apply` (default) | `openspec status --change <c> --json` to confirm the change is applyable (report `isComplete` / missing artifacts if not), then `ensure` | Apply dispatcher prompt |
| `verify` | `openspec validate <c> --strict --json` **and** `openspec status --change <c> --json` inline; report pass/fail with the actual errors | Nothing on pass. On failure, `send` a fix prompt containing the validation errors verbatim |
| `archive` | Gate inline: `validate --strict` passes **and** `status.isComplete` is true. If not, refuse and say exactly which check failed | Archive dispatcher prompt |
| `status` | — | Nothing; run `opsx-window.sh status <c>` and relay the meaningful tail |
| free text | — | `send` the user's text verbatim (window must already exist) |

`verify` and `archive` deliberately run their read-only `openspec` checks in **this** session: they are fast, and a failed gate should be reported to the user immediately rather than discovered inside a window they are not watching.

## Prompt templates

Every window prompt is a **dispatcher** prompt: the window's `claude` must hand the work to the `ops-applier` subagent, not do it itself.

**apply**

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Delegate ALL implementation to the ops-applier subagent: call the Agent tool with `subagent_type: "ops-applier"` and `run_in_background: false`. Do NOT read or edit implementation files yourself.
> Task for the subagent: apply OpenSpec change `<change>` — read `openspec/changes/<change>/` (proposal.md, design.md, tasks.md), execute the remaining unchecked tasks using `openspec instructions apply --change "<change>" --json`, tick the tasks.md checkboxes as it goes, and report modified files, branch name, and pass/fail.
> When it returns, summarize its report and stop.

**archive**

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Delegate to the ops-applier subagent (Agent tool, `subagent_type: "ops-applier"`, `run_in_background: false`). Do NOT do the work yourself.
> Task for the subagent: archive OpenSpec change `<change>`. Confirm every task in `openspec/changes/<change>/tasks.md` is checked and `openspec validate "<change>" --strict` passes, then run `openspec archive "<change>" -y` and report what moved and any spec updates.
> When it returns, summarize its report and stop.

**verify-fix** (only sent when the inline gate fails)

> Verification of OpenSpec change `<change>` failed. `openspec validate "<change>" --strict` reported: `<errors verbatim>`.
> Delegate the fix to the ops-applier subagent (Agent tool, `subagent_type: "ops-applier"`, `run_in_background: false`). Do NOT fix it yourself. After it returns, re-run `openspec validate "<change>" --strict` and `openspec status --change "<change>" --json` and report the result.

The **"Do NOT do the work yourself"** line is load-bearing — it is what makes the window actually use `ops-applier` instead of the outer session quietly doing the implementation.

## Reporting back

After every invocation, tell the user:

- the window name and whether it was **created** or **reused**,
- what was dispatched (or, for `verify`, the inline gate result),
- how to jump to it: `tmux select-window -t <session>:<change>`.

Do not wait on or poll the window — it runs its own conversation. Use `/opsx-run <change> status` to check on it later.

## Notes

- The window runs `claude --permission-mode bypassPermissions` so it never stalls on a permission prompt while unattended.
- `ops-applier` (`~/.claude/agents/opsx-applier.md`) has no `Skill` tool, so it drives the `openspec` CLI directly rather than invoking `/opsx:apply`. The `/opsx:*` commands are installed globally at `~/.claude/commands/opsx/`, so the dispatcher session (which does have `Skill`) can use them; a project copy under `<project>/.claude/commands/opsx/` takes precedence where one exists.
- Window names are set with `automatic-rename`/`allow-rename` disabled, so a window keeps its change name for the whole lifecycle and stays findable.
