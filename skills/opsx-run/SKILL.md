---
name: opsx-run
description: "Run an OpenSpec change's apply/verify/archive lifecycle in its own tmux window named after the change, driven by the ops-applier agent. Reuses the same window for every follow-up instruction about that change. Trigger: /opsx-run <change> [action]"
trigger: /opsx-run
---

# /opsx-run

One OpenSpec change = one tmux window named after the change, in the current tmux session, running an agent CLI session (**Claude Code**, **Cursor CLI** — the `agent` command on Linux — or **Codex CLI**). Claude and Cursor delegate the actual work to the **ops-applier** subagent; a Codex window applies the change itself in an `opsx/<change>` git worktree (the tmux window is the isolation boundary). The window is created on first use and **reused** for every later instruction about that change.

## Usage

```
/opsx-run <change>                      # apply (default) — creates the window
/opsx-run <change> apply
/opsx-run <change> apply --agent-cli agent   # force Cursor CLI (Linux: the `agent` command)
/opsx-run <change> apply --agent-cli claude  # force Claude Code
/opsx-run <change> apply --agent-cli codex   # force Codex CLI (applies directly, no subagent)
/opsx-run <change> apply --model sonnet-4    # pin the apply window's model (default: this session's)
/opsx-run <change> verify               # inline validate/status gate; only bothers the window on failure
/opsx-run <change> archive
/opsx-run <change> status               # snapshot of what the window is doing right now
/opsx-run <change> "<free-form text>"   # send to that window (creates it if missing)
/opsx-run <change> merge                # merge the change branch into main (no archive/cleanup)
/opsx-run <change> merge --into develop # ... into another branch
/opsx-run <change> land                 # merge into main, archive, clean up, close the window
/opsx-run <change> land --into develop  # ... into another branch
/opsx-run <change> land --force-tasks   # ... even when tasks.md still has unchecked boxes
/opsx-run <change> land --skip-merge    # already merged: skip merge, still archive + cleanup
/opsx-run <change> close                # close that change's window
/opsx-run close-all                     # close every opsx window in the session
/opsx-run list                          # show the windows in this session
```

## Helper script

All tmux calls go through `~/.claude/skills/opsx-run/opsx-window.sh`. **Never hand-roll `tmux send-keys`** — the script handles literal-text quoting, newline collapsing, window-id targeting, and rename suppression, all of which break subtly when improvised.

```
opsx-window.sh ensure <change> --prompt-file <f> [--cwd <dir>] [--agent-cli <cmd>] [--model <id>]
opsx-window.sh detect-cli [--agent-cli <cmd>]                          # print agent|claude|codex for the host session
opsx-window.sh detect-model [--model <id>]                             # print the model id to launch with (or `default`)
opsx-window.sh send   <change> --prompt-file <f>                 # send; creates the window if it is gone
opsx-window.sh close  <change> [--force] [--keep-session]        # close one window
opsx-window.sh close  --all    [--force] [--keep-session]        # close every tagged opsx window
opsx-window.sh status <change> [--lines N]                       # capture-pane snapshot (default 60 lines)
opsx-window.sh mark   <change> <busy|done|fail|idle> # title badge + status-bar color
opsx-window.sh list                                              # windows in the current session
```

It prints one line on success: `created @7 2:add-auth agent=agent`, `reused @7 2:add-auth`, `sent @7 2:add-auth`, or `marked @7 2:add-auth status=done`. Relay which happened — the user wants to know whether a new window appeared, and which agent CLI was used when `agent=` is present.

**Window status badges.** New work sets the window to **busy** (`…change`, yellow). When the agent finishes it must mark **done** (`✓change`, green) or **fail** (`✗change`, red). Lookups use `@opsx_change`, so the badge does not break later `/opsx-run` calls. From the window, mark with:

```bash
for d in "$HOME/.agents/skills/opsx-run" "$HOME/.codex/skills/opsx-run" \
         "$HOME/.cursor/skills/opsx-run" "$HOME/.claude/skills/opsx-run"; do
  [ -x "$d/opsx-window.sh" ] && { "$d/opsx-window.sh" mark "<change>" done; break; }
done
```

(Use `fail` instead of `done` when the work failed.)

**Agent CLI selection** (new windows only — reused windows keep their existing session):

1. `--agent-cli <cmd>` on the `/opsx-run` invocation, forwarded to `ensure` (`claude`, `agent`, `cursor` as alias for `agent`, `codex`, or a path)
2. `$OPSX_AGENT_CLI` environment variable (same values)
3. Auto-detect inside `opsx-window.sh`: Cursor env markers (`$CURSOR_AGENT`, `$CURSOR_RIPGREP_PATH`, …) or parent-process walk (Cursor CLI on Linux runs as `MainThread` with `…/agent` in argv) → `agent`; Claude Code markers → `claude`; Codex markers (`$CODEX_SANDBOX`, `codex` in the parent chain) → `codex`; else first of `claude`/`agent`/`codex` on PATH

**When calling `ensure`, always pass an explicit CLI if the user named one.** Otherwise run `opsx-window.sh detect-cli` first and forward `--agent-cli "$(opsx-window.sh detect-cli)"` to `ensure` — do not rely on the skill session alone, because an outdated installed script or a stripped environment can otherwise pick `claude` when both CLIs are installed.

**Model selection** (new windows only — reused windows keep the model they were launched with):

1. `--model <id>` on `/opsx-run` (e.g. `sonnet-4`, `opus`, `gpt-5`, a Cursor model id)
2. `$OPSX_MODEL`
3. Auto-detect via `opsx-window.sh detect-model`: `$ANTHROPIC_MODEL`, else Cursor `~/.cursor/cli-config.json` `selectedModel.modelId`, else Claude `~/.claude/settings.json` `model`, else Codex `~/.codex/config.toml` `model`. Values `default` / `auto` / `inherit` mean "CLI default" — omit `--model` so the new window matches this session.

Forward `--model` when the user named one **or** when `detect-model` prints something other than `default`. On Claude/Cursor, tell the dispatcher to spawn ops-applier with `model: inherit` so the apply worker uses that window's model. On Codex the model applies to the window itself (it launches with `-m <model>`).

After upgrading the repo, re-run `./install.sh` so `~/.claude/skills/opsx-run/opsx-window.sh` picks up detection — an old install hardcodes `claude` and ignores Cursor entirely.

When called from **outside** tmux it also prints `session=created` on that line (if it had to start the session) and a `# attach with: tmux attach -t <session>` hint. Pass both on. `send`, `status` and `list` only ever *look up* the project session; they never create one, and they fail with a clear message if the user is outside tmux and no session exists yet.

Codex often strips `$TMUX` from sandboxed shells. `opsx-window.sh` recovers `$TMUX` / `$TMUX_PANE` from `/proc` so a `/opsx-run … --agent-cli codex` from inside an existing session still opens a **window in that session**, not a new session named after the project.

Write prompts to a file in the session scratchpad (e.g. `<scratchpad>/opsx-<change>-<action>.txt`) and pass `--prompt-file`. Prompt text is never spliced into a command line.

## Preconditions — check in this order, fail fast

1. **tmux.** `tmux` must be installed. Being *inside* a session is not required: when `$TMUX` is unset, `ensure` creates (or reuses) a session named after the **project folder** and puts the change window there. Tell the user the session name and `tmux attach -t <session>`. Never fall back to running the work inline.
2. **Change exists.** `openspec/changes/<change>/` must exist under the current directory. If the name is missing, vague, or ambiguous, run `openspec list --json` and use **AskUserQuestion** to let the user pick from the active changes. **Never guess or auto-select** the change name.

Both `openspec` and the window's agent CLI run from the current working directory, so run `/opsx-run` from the project root.

## Actions

| Action | This session does | The window gets |
|---|---|---|
| `apply` (default) | `openspec status --change <c> --json` to confirm the change is applyable (report `isComplete` / missing artifacts if not), then `detect-cli` + `detect-model` + `ensure --agent-cli … [--model …]` | Apply dispatcher prompt |
| `verify` | `openspec validate <c> --strict --json` **and** `openspec status --change <c> --json` inline; report pass/fail with the actual errors | Nothing on pass. On failure, `ensure` a fix prompt (creates the window if it was closed) |
| `archive` | Gate inline: `validate --strict` passes **and** `status.isComplete` is true. If not, refuse and say exactly which check failed | Archive dispatcher prompt |
| `status` | — | Nothing; run `opsx-window.sh status <c>` and relay the meaningful tail |
| free text | — | `ensure` with the user's text verbatim. **If the window is missing, create it** — never tell the user to `apply` first just to recreate the window |
| `close` | — | Nothing; `opsx-window.sh close <c>` kills that window |
| `close-all` | Confirm with **AskUserQuestion** first — this kills several live sessions at once | Nothing; `opsx-window.sh close --all` |
| `merge` | Runs `opsx-merge.sh <change> [--into <branch>]` **inline**; `--no-ff` merge only — keeps the branch, worktree and window | Nothing |
| `land` | Runs `opsx-land.sh`, which calls `opsx-merge.sh --stay` then archive + cleanup. If the branch is already in the target (exit 2 / `ALREADY_MERGED`), **AskUserQuestion** whether to skip the merge and finish cleanup; on yes, re-run with `--skip-merge` and the same flags. Do not tell the user to archive by hand. | Nothing — the window is closed as the last step |

`verify` and `archive` deliberately run their read-only `openspec` checks in **this** session: they are fast, and a failed gate should be reported to the user immediately rather than discovered inside a window they are not watching.

## Prompt templates

On **Claude Code** and **Cursor CLI**, every window prompt is a **dispatcher**: it must hand the work to the **ops-applier** subagent (isolated context), not implement in the window session itself. **Codex CLI** has custom agents (`~/.codex/agents/ops-applier.toml`) but spawn-by-name is unreliable — a Codex **dispatcher** window should still apply the change itself in an `opsx/<change>` git worktree. Isolation is the dedicated tmux window plus that worktree.

| Host | How to run ops-applier |
|---|---|
| **Claude Code** | Agent tool with `subagent_type: "ops-applier"` (`~/.claude/agents/opsx-applier.md`) |
| **Cursor CLI** | Task tool with `subagent_type: "ops-applier"`. Cursor CLI only loads **project** agents from `<cwd>/.cursor/agents/` (not `~/.cursor/agents/`). `opsx-window.sh ensure` symlinks the installed agent into the project before launching the window so Task can see `ops-applier`. |
| **Codex CLI** | Custom agent `~/.codex/agents/ops-applier.toml` is installed. Prefer applying **in this window** (Codex spawn-by-name is unreliable). Work in a git worktree on `opsx/<change>`. |

**apply**

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Delegate ALL implementation to the ops-applier **subagent** — do not implement in this window yourself.
> Claude Code: Agent tool, `subagent_type: "ops-applier"`, `run_in_background: false`, `model: inherit` (window model).
> Cursor CLI: Task tool, `subagent_type: "ops-applier"`, `run_in_background: false`, `model: inherit`. Confirm `.cursor/agents/opsx-applier.md` exists in `<cwd>` first (ensure installs it). Do not fall back to `generalPurpose` unless Task rejects `ops-applier` after that file is present — if rejected, say so and stop.
> Codex CLI (no subagent tool): apply the change yourself in this window. Create/checkout a git worktree on branch `opsx/<change>` and do all work there — never on the current branch.
> Task (for the subagent, or for yourself on Codex): apply OpenSpec change `<change>` — read `openspec/changes/<change>/` (proposal.md, design.md, tasks.md), execute remaining unchecked tasks using `openspec instructions apply --change "<change>" --json`, tick tasks.md checkboxes as you go, report modified files, branch name (`opsx/<change>`), and pass/fail.
> **MCP / browser-use:** This window is launched with `--approve-mcps`, so browser-use MCP is available *here*. Cursor Task subagents often do **not** inherit MCP. If the user asked for browser-use MCP tests: still delegate code to ops-applier, then run the MCP browser tools **yourself in this window** after it returns (or immediately if the subagent reports MCP unavailable). Never tell the subagent to use CLI/CDP as a substitute.
> When it returns (or when you finish, on Codex), summarize the report. Then mark the tmux window: run `opsx-window.sh mark <change> done` on success or `mark <change> fail` on failure (resolve the script under `~/.agents/skills/opsx-run`, `~/.codex/skills/opsx-run`, `~/.cursor/skills/opsx-run`, or `~/.claude/skills/opsx-run`). Stop after marking.

**archive**

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Delegate to the ops-applier subagent. Claude Code: Agent `subagent_type: "ops-applier"`. Cursor CLI: Task `subagent_type: "ops-applier"` (project `.cursor/agents/opsx-applier.md` must exist). `run_in_background: false`. Codex CLI: no subagent tool — do it yourself in this window. Do NOT delegate to anything else.
> Task: archive OpenSpec change `<change>`. Confirm every task in `openspec/changes/<change>/tasks.md` is checked and `openspec validate "<change>" --strict` passes, then run `openspec archive "<change>" -y` and report what moved and any spec updates.
> When done, summarize the report, then `opsx-window.sh mark <change> done` (or `fail`). Stop after marking.

**verify-fix** (only sent when the inline gate fails)

> Verification of OpenSpec change `<change>` failed. `openspec validate "<change>" --strict` reported: `<errors verbatim>`.
> Delegate the fix to the ops-applier subagent (Claude: Agent / Cursor: Task, `subagent_type: "ops-applier"`, `run_in_background: false`). Codex CLI: fix it yourself in this window. After it is fixed, re-run `openspec validate "<change>" --strict` and `openspec status --change "<change>" --json` and report the result. Then `opsx-window.sh mark <change> done` (or `fail`).

On Claude/Cursor, the **"Do NOT do the work yourself"** line is load-bearing — the window must use the ops-applier subagent so implementation stays in an isolated context. On **Codex** there is no subagent, so the window does the work itself; the isolation comes from the dedicated tmux window plus the `opsx/<change>` git worktree. Exception on Cursor: **browser-use MCP tests** stay in the dispatcher window, because Task children typically do not inherit MCP tools.

## Reporting back

After every invocation, tell the user:

- the window name and whether it was **created** or **reused**,
- **if a session was created** (running from outside tmux): its name and `tmux attach -t <session>`,
- what was dispatched (or, for `verify`, the inline gate result),
- how to jump to it: `tmux select-window -t <session>:<change>` (or the badged title such as `…change` / `✓change` — lookup still uses the change name).

Do not wait on or poll the window — it runs its own conversation. Use `/opsx-run <change> status` to check on it later. The window title shows work state: `…change` (busy, yellow), `✓change` (done, green), `✗change` (fail, red).

## Merging a change

`~/.claude/skills/opsx-run/opsx-merge.sh <change> [options]` merges the change branch into a target and **stops**. No archive, no branch/worktree delete, no window close.

```
opsx-merge.sh <change> [--into <branch>] [--branch <name>] [--stay] [--dry-run]
```

- Default target is `main`, else `master`. Override with `--into`.
- Runs **inline in this session**. **It never pushes.**
- Gates: clean working tree → change branch found → its worktree (if any) is clean → branch is ahead of target. Already merged (nothing the target is missing) exits **2** with `ALREADY_MERGED` — report it; there is nothing else for `merge` to do. For land, that same case asks about `--skip-merge` instead.
- Branch discovery matches `land`: `--branch`, else `opsx/<change>`, `feat/<change>`, `feature/<change>`, `<change>`, else a single fuzzy match.
- On conflict: abort, restore the starting branch, print the conflicting paths. Then `/opsx-run <change> merge` again (or land).
- `--stay` leaves HEAD on the target (used by `land` so archive runs on the merged tree). Without it, HEAD returns to the branch you started on.

## Landing a change

`~/.claude/skills/opsx-run/opsx-land.sh <change> [options]` finishes a change: **OpenSpec gates → `opsx-merge.sh --stay` → `openspec archive` → commit → remove worktree → delete branch → close window.**

```
opsx-land.sh <change> [--into <branch>] [--branch <name>] [--skip-specs]
             [--skip-merge] [--force-tasks] [--no-close] [--keep-branch]
             [--keep-worktree] [--dry-run]
```

- Runs **inline in this session**, never dispatched to the window — a window cannot close itself while still running the merge.
- **It never pushes.** Relay the `git push origin <branch>` line it prints; do not run it unless the user asks.
- **Confirm with AskUserQuestion before the first real run** — it writes a merge commit, deletes a branch and kills a live session. Offer `--dry-run` if the user seems unsure. Skip the confirmation when the user's message already spells out the intent ("land add-auth into develop"). `merge` alone is lighter; still confirm once if the user has not named the target.
- OpenSpec gates, in order: change dir exists → `validate --strict` → all artifacts present → **every task in tasks.md checked** (bypass with `--force-tasks`). Git merge gates are those of `opsx-merge.sh`. Report *which* gate failed and stop; do not dispatch work to fix it unless asked.
- **Already merged:** if `opsx-land.sh` prints `ALREADY_MERGED` and exits 2, the change branch has no commits the target is missing. **AskUserQuestion immediately** — do not stop at "run archive by hand":
  - Prompt: `<branch> is already in <target> (tip <sha>). Skip the merge and continue with archive, worktree/branch cleanup, and window close?`
  - Options: **Skip merge and finish cleanup** / **Stop**
  - On skip: re-run `opsx-land.sh <change> --skip-merge` with the same `--into` / `--branch` / `--force-tasks` / … flags. `--skip-merge` checks out the target and runs archive + cleanup only; it refuses if the branch still has unmerged commits.
  - On stop: leave the change as-is.
- Branch discovery is the same as `merge`.
- On merge conflict `opsx-merge.sh` aborts and restores; the fix is a normal window instruction: `/opsx-run <change> "resolve the conflicts merging <branch> into <target>"`.

## Closing windows

`close` kills the window and the agent session running in it, ending any work that session still had in flight. Worktrees, commits and files already written survive on disk. Say this plainly before a `close-all`, and confirm it with **AskUserQuestion**; a single named `close` is unambiguous enough to just do.

- `--all` only touches windows this script created — they carry an `@opsx_change` tmux option. The user's own windows in the same session are never closed. Windows created before tagging existed aren't matched either; close those by name.
- The script refuses to close the window the caller is *in* unless `--force` is passed, so a `close-all` from inside a change window can't kill the caller mid-command. Relay the `# skipped …` line when it appears.
- Closing the last window in a session destroys the session — the script says so. Pass `--keep-session` to park a plain shell window and keep it alive.
- If the user asks to close a change that has no window, say so; it is not an error worth escalating.
- Free-form text and verify-fix must **not** fail with "run apply first". `send` now creates the window when it is missing (same as `ensure`). Recreate and deliver the instruction in one step.

## Notes

- New windows launch with permission bypass so they never stall on a prompt while unattended: `claude --permission-mode bypassPermissions`, `agent --force --approve-mcps --trust` (Cursor CLI on Linux), or `codex --dangerously-bypass-approvals-and-sandbox` (Codex CLI). `--approve-mcps` is required so `~/.cursor/mcp.json` (browser-use) loads in the Cursor tmux window; without it, ops-applier Task children have no MCP tools.
- **Codex CLI** loads this skill from `~/.agents/skills/opsx-run/` (and `$CODEX_HOME/skills/opsx-run`). Restart Codex after install. Windows launch as `codex --dangerously-bypass-approvals-and-sandbox` (`-m <model>` from `~/.codex/config.toml` `model` when detected). A Codex dispatcher window applies the change itself in an `opsx/<change>` worktree; `ops-applier` is also installed as `~/.codex/agents/ops-applier.toml`.
- Forward `--agent-cli` and `--model` from the user's `/opsx-run` message to `opsx-window.sh ensure` when they name them; otherwise `detect-cli` / `detect-model`.
- `ops-applier` — Claude Code: `~/.claude/agents/opsx-applier.md`. Cursor CLI: installed to `~/.cursor/agents/opsx-applier.md`, and **`ensure` also links it into `<project>/.cursor/agents/`** because the Cursor CLI Task enum only loads project-level agents (not user-level). Dispatcher windows must use Task/Agent with `subagent_type: "ops-applier"`. It drives the `openspec` CLI directly. For Cursor OpenSpec slash commands, run `openspec init --tools cursor` in a project.
- Window names keep a status badge (`…` busy / `✓` done / `✗` fail) plus a matching status-bar color. Lookups use `@opsx_change`, not the display title.
