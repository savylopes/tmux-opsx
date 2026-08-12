---
name: opsx-run
description: "Run an OpenSpec change's apply/verify/archive lifecycle in its own tmux window named after the change, driven by the ops-applier agent. Reuses the same window for every follow-up instruction about that change. Trigger: /opsx-run <change> [action]"
trigger: /opsx-run
---

# /opsx-run

One OpenSpec change = one tmux window named after the change, in the current tmux session, running an agent CLI session (**Claude Code** or **Cursor CLI** — the `agent` command on Linux) that delegates the actual work to the **ops-applier** subagent. The window is created on first use and **reused** for every later instruction about that change.

## Usage

```
/opsx-run <change>                      # apply (default) — creates the window
/opsx-run <change> apply
/opsx-run <change> apply --agent-cli agent   # force Cursor CLI (Linux: the `agent` command)
/opsx-run <change> apply --agent-cli claude  # force Claude Code
/opsx-run <change> verify               # inline validate/status gate; only bothers the window on failure
/opsx-run <change> archive
/opsx-run <change> status               # snapshot of what the window is doing right now
/opsx-run <change> "<free-form text>"   # send any instruction to that change's window
/opsx-run <change> land                 # merge into main, archive, clean up, close the window
/opsx-run <change> land --into develop  # ... into another branch
/opsx-run <change> land --force-tasks   # ... even when tasks.md still has unchecked boxes
/opsx-run <change> close                # close that change's window
/opsx-run close-all                     # close every opsx window in the session
/opsx-run list                          # show the windows in this session
```

## Helper script

All tmux calls go through `~/.claude/skills/opsx-run/opsx-window.sh`. **Never hand-roll `tmux send-keys`** — the script handles literal-text quoting, newline collapsing, window-id targeting, and rename suppression, all of which break subtly when improvised.

```
opsx-window.sh ensure <change> --prompt-file <f> [--cwd <dir>] [--agent-cli <cmd>]
opsx-window.sh detect-cli [--agent-cli <cmd>]                          # print agent|claude for the host session
opsx-window.sh send   <change> --prompt-file <f>                 # send only; errors if the window doesn't exist
opsx-window.sh close  <change> [--force] [--keep-session]        # close one window
opsx-window.sh close  --all    [--force] [--keep-session]        # close every tagged opsx window
opsx-window.sh status <change> [--lines N]                       # capture-pane snapshot (default 60 lines)
opsx-window.sh list                                              # windows in the current session
```

It prints one line on success: `created @7 2:add-auth agent=agent`, `reused @7 2:add-auth`, or `sent @7 2:add-auth`. Relay which of the three happened — the user wants to know whether a new window appeared, and which agent CLI was used when `agent=` is present.

**Agent CLI selection** (new windows only — reused windows keep their existing session):

1. `--agent-cli <cmd>` on the `/opsx-run` invocation, forwarded to `ensure` (`claude`, `agent`, `cursor` as alias for `agent`, or a path)
2. `$OPSX_AGENT_CLI` environment variable (same values)
3. Auto-detect inside `opsx-window.sh`: Cursor env markers (`$CURSOR_AGENT`, `$CURSOR_RIPGREP_PATH`, …) or parent-process walk (Cursor CLI on Linux runs as `MainThread` with `…/agent` in argv) → `agent`; Claude Code markers → `claude`; else first of `claude`/`agent` on PATH

**When calling `ensure`, always pass an explicit CLI if the user named one.** Otherwise run `opsx-window.sh detect-cli` first and forward `--agent-cli "$(opsx-window.sh detect-cli)"` to `ensure` — do not rely on the skill session alone, because an outdated installed script or a stripped environment can otherwise pick `claude` when both CLIs are installed.

After upgrading the repo, re-run `./install.sh` so `~/.claude/skills/opsx-run/opsx-window.sh` picks up detection — an old install hardcodes `claude` and ignores Cursor entirely.

When called from **outside** tmux it also prints `session=created` on that line (if it had to start the session) and a `# attach with: tmux attach -t <session>` hint. Pass both on. `send`, `status` and `list` only ever *look up* the project session; they never create one, and they fail with a clear message if the user is outside tmux and no session exists yet.

Write prompts to a file in the session scratchpad (e.g. `<scratchpad>/opsx-<change>-<action>.txt`) and pass `--prompt-file`. Prompt text is never spliced into a command line.

## Preconditions — check in this order, fail fast

1. **tmux.** `tmux` must be installed. Being *inside* a session is not required: when `$TMUX` is unset, `ensure` creates (or reuses) a session named after the **project folder** and puts the change window there. Tell the user the session name and `tmux attach -t <session>`. Never fall back to running the work inline.
2. **Change exists.** `openspec/changes/<change>/` must exist under the current directory. If the name is missing, vague, or ambiguous, run `openspec list --json` and use **AskUserQuestion** to let the user pick from the active changes. **Never guess or auto-select** the change name.

Both `openspec` and the window's agent CLI run from the current working directory, so run `/opsx-run` from the project root.

## Actions

| Action | This session does | The window gets |
|---|---|---|
| `apply` (default) | `openspec status --change <c> --json` to confirm the change is applyable (report `isComplete` / missing artifacts if not), then `detect-cli` + `ensure --agent-cli …` | Apply dispatcher prompt |
| `verify` | `openspec validate <c> --strict --json` **and** `openspec status --change <c> --json` inline; report pass/fail with the actual errors | Nothing on pass. On failure, `send` a fix prompt containing the validation errors verbatim |
| `archive` | Gate inline: `validate --strict` passes **and** `status.isComplete` is true. If not, refuse and say exactly which check failed | Archive dispatcher prompt |
| `status` | — | Nothing; run `opsx-window.sh status <c>` and relay the meaningful tail |
| free text | — | `send` the user's text verbatim (window must already exist) |
| `close` | — | Nothing; `opsx-window.sh close <c>` kills that window |
| `close-all` | Confirm with **AskUserQuestion** first — this kills several live sessions at once | Nothing; `opsx-window.sh close --all` |
| `land` | Runs `opsx-land.sh <change> [--into <branch>] [--force-tasks]` **inline**; relays the gate that failed, or the merge commit and cleanup summary | Nothing — the window is closed as the last step |

`verify` and `archive` deliberately run their read-only `openspec` checks in **this** session: they are fast, and a failed gate should be reported to the user immediately rather than discovered inside a window they are not watching.

## Prompt templates

Every window prompt is a **dispatcher**: it must hand the work to the **ops-applier** subagent (isolated context), not implement in the window session itself.

| Host | How to run ops-applier |
|---|---|
| **Claude Code** | Agent tool with `subagent_type: "ops-applier"` (`~/.claude/agents/opsx-applier.md`) |
| **Cursor CLI** | Task tool with `subagent_type: "ops-applier"`. Cursor CLI only loads **project** agents from `<cwd>/.cursor/agents/` (not `~/.cursor/agents/`). `opsx-window.sh ensure` symlinks the installed agent into the project before launching the window so Task can see `ops-applier`. |

**apply**

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Delegate ALL implementation to the ops-applier **subagent** — do not implement in this window yourself.
> Claude Code: Agent tool, `subagent_type: "ops-applier"`, `run_in_background: false`.
> Cursor CLI: Task tool, `subagent_type: "ops-applier"`, `run_in_background: false`. Confirm `.cursor/agents/opsx-applier.md` exists in `<cwd>` first (ensure installs it). Do not fall back to `generalPurpose` unless Task rejects `ops-applier` after that file is present — if rejected, say so and stop.
> Task for the subagent: apply OpenSpec change `<change>` — read `openspec/changes/<change>/` (proposal.md, design.md, tasks.md), execute remaining unchecked tasks using `openspec instructions apply --change "<change>" --json`, tick tasks.md checkboxes as you go, report modified files, branch name (`opsx/<change>`), and pass/fail.
> When it returns, summarize its report and stop.

**archive**

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Delegate to the ops-applier subagent. Claude Code: Agent `subagent_type: "ops-applier"`. Cursor CLI: Task `subagent_type: "ops-applier"` (project `.cursor/agents/opsx-applier.md` must exist). `run_in_background: false`. Do NOT do the work yourself.
> Task for the subagent: archive OpenSpec change `<change>`. Confirm every task in `openspec/changes/<change>/tasks.md` is checked and `openspec validate "<change>" --strict` passes, then run `openspec archive "<change>" -y` and report what moved and any spec updates.
> When it returns, summarize its report and stop.

**verify-fix** (only sent when the inline gate fails)

> Verification of OpenSpec change `<change>` failed. `openspec validate "<change>" --strict` reported: `<errors verbatim>`.
> Delegate the fix to the ops-applier subagent (Claude: Agent / Cursor: Task, `subagent_type: "ops-applier"`, `run_in_background: false`). Do NOT fix it yourself. After it returns, re-run `openspec validate "<change>" --strict` and `openspec status --change "<change>" --json` and report the result.

The **"Do NOT do the work yourself"** line is load-bearing — the window must use the ops-applier subagent so implementation stays in an isolated context.

## Reporting back

After every invocation, tell the user:

- the window name and whether it was **created** or **reused**,
- **if a session was created** (running from outside tmux): its name and `tmux attach -t <session>`,
- what was dispatched (or, for `verify`, the inline gate result),
- how to jump to it: `tmux select-window -t <session>:<change>`.

Do not wait on or poll the window — it runs its own conversation. Use `/opsx-run <change> status` to check on it later.

## Landing a change

`~/.claude/skills/opsx-run/opsx-land.sh <change> [options]` finishes a change: **gate → merge `--no-ff` → `openspec archive` → commit → remove worktree → delete branch → close window.**

```
opsx-land.sh <change> [--into <branch>] [--branch <name>] [--skip-specs]
             [--force-tasks] [--no-close] [--keep-branch] [--keep-worktree] [--dry-run]
```

- Runs **inline in this session**, never dispatched to the window — a window cannot close itself while still running the merge.
- **It never pushes.** Relay the `git push origin <branch>` line it prints; do not run it unless the user asks.
- **Confirm with AskUserQuestion before the first real run** — it writes a merge commit, deletes a branch and kills a live session. Offer `--dry-run` if the user seems unsure. Skip the confirmation when the user's message already spells out the intent ("land add-auth into develop").
- Gates, in order: change dir exists → `validate --strict` → all artifacts present → **every task in tasks.md checked** (bypass with `--force-tasks`) → clean working tree → branch found → branch is ahead of target. Report *which* gate failed and stop; do not dispatch work to fix it unless asked.
- Branch discovery: `--branch`, else `opsx/<change>`, `feat/<change>`, `feature/<change>`, `<change>`, else a single fuzzy `*<change>*` match. Several fuzzy matches → it lists them and asks for `--branch`.
- On merge conflict it aborts the merge, returns to the starting branch and leaves the tree clean. The fix is a normal window instruction: `/opsx-run <change> "resolve the conflicts merging <branch> into <target>"`.

## Closing windows

`close` kills the window and the agent session running in it, ending any work that session still had in flight. Worktrees, commits and files already written survive on disk. Say this plainly before a `close-all`, and confirm it with **AskUserQuestion**; a single named `close` is unambiguous enough to just do.

- `--all` only touches windows this script created — they carry an `@opsx_change` tmux option. The user's own windows in the same session are never closed. Windows created before tagging existed aren't matched either; close those by name.
- The script refuses to close the window the caller is *in* unless `--force` is passed, so a `close-all` from inside a change window can't kill the caller mid-command. Relay the `# skipped …` line when it appears.
- Closing the last window in a session destroys the session — the script says so. Pass `--keep-session` to park a plain shell window and keep it alive.
- If the user asks to close a change that has no window, say so; it is not an error worth escalating.

## Notes

- New windows launch with permission bypass so they never stall on a prompt while unattended: `claude --permission-mode bypassPermissions` or `agent --force` (Cursor CLI on Linux).
- Forward `--agent-cli` from the user's `/opsx-run` message to `opsx-window.sh ensure` when they name a CLI explicitly; otherwise let the script auto-detect.
- `ops-applier` — Claude Code: `~/.claude/agents/opsx-applier.md`. Cursor CLI: installed to `~/.cursor/agents/opsx-applier.md`, and **`ensure` also links it into `<project>/.cursor/agents/`** because the Cursor CLI Task enum only loads project-level agents (not user-level). Dispatcher windows must use Task/Agent with `subagent_type: "ops-applier"`. It drives the `openspec` CLI directly. For Cursor OpenSpec slash commands, run `openspec init --tools cursor` in a project.
- Window names are set with `automatic-rename`/`allow-rename` disabled, so a window keeps its change name for the whole lifecycle and stays findable.
