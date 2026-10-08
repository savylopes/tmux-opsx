---
name: opsx-run
description: "Run an OpenSpec change's apply/verify/eval/review/security/qa/preview/archive lifecycle in its own tmux window named after the change, driven by the ops-applier, ops-eval, ops-reviewer, ops-security, and ops-qa agents. Reuses the same window for every follow-up instruction about that change. Trigger: /opsx-run <change> [action]"
trigger: /opsx-run
---

# /opsx-run

One OpenSpec change = one tmux window named after the change, in the current tmux session, running an agent CLI session (**Claude Code**, **Cursor CLI** — the `agent` command on Linux —, **Codex CLI**, **OpenCode**, or **Gemini CLI**). Claude, Cursor, and OpenCode can hand the work to the **ops-applier** subagent; a Codex or Gemini window applies the change itself in an `opsx/<change>` git worktree (the tmux window is the isolation boundary). The window is created on first use and **reused** for every later instruction about that change.

## Usage

```
/opsx-run <change>                      # apply (default) — creates the window
/opsx-run <change> apply
/opsx-run <change> apply --agent-cli agent   # force Cursor CLI (Linux: the `agent` command)
/opsx-run <change> apply --agent-cli claude  # force Claude Code
/opsx-run <change> apply --agent-cli codex   # force Codex CLI (applies directly, no subagent)
/opsx-run <change> apply --agent-cli opencode # force OpenCode (Task/@ops-applier)
/opsx-run <change> apply --agent-cli gemini  # force Gemini CLI (applies in the window)
/opsx-run <change> apply --model sonnet-4    # pin the apply window's model (default: this session's)
/opsx-run <change> apply --validate          # fire-and-forget: window /goal drives apply → eval → review → security → qa → fixes until PASS
/opsx-run <change> verify               # inline validate/status gate; only bothers the window on failure
/opsx-run <change> eval                 # one-shot spec eval: ops-eval writes/runs evals/ checks (no auto-fix)
/opsx-run <change> eval --agentic       # same, plus L3 (agent-in-the-loop) checks
/opsx-run eval                          # same, but pick the change
/opsx-run <change> review               # one-shot implementation review in the change window (no auto-fix)
/opsx-run <change> review "..."         # same, plus extra notes passed through to ops-reviewer
/opsx-run review "..."                  # same, but pick the change if it was omitted
/opsx-run <change> security             # one-shot security review in the change window (no auto-fix)
/opsx-run <change> security "..."       # same, plus extra notes passed through to ops-security
/opsx-run security "..."                # same, but pick the change if it was omitted
/opsx-run <change> qa                   # one-shot UI/UX QA in the change window (no auto-fix)
/opsx-run <change> qa "..."             # same, plus extra notes passed through to ops-qa
/opsx-run qa "..."                      # same, but pick the change if it was omitted
/opsx-run <change> preview              # run the change's app from its worktree, publish it via /expose, print the URL
/opsx-run <change> preview stop         # remove the route, kill the app and its window
/opsx-run <change> preview url          # reprint (and copy) the running preview's URL
/opsx-run <change> preview share [--for <recipient>] [--ttl <dur>]   # share link for a client (one host, expires; default 7d)
/opsx-run <change> preview share --list | --revoke <recipient|id|all> # list or revoke the preview's share links
/opsx-run preview                       # same, but pick a change or the main checkout (main--<project>)
/opsx-run <change> archive
/opsx-run <change> status               # snapshot of what the window is doing right now
/opsx-run <change> "<free-form text>"   # send to that window (creates it if missing)
/opsx-run <change> merge                # merge the change branch into main (no archive/cleanup)
/opsx-run <change> merge --into develop # ... into another branch
/opsx-run <change> land                 # merge into main, archive, clean up, close the window
/opsx-run <change> land --into develop  # ... into another branch
/opsx-run <change> land --force-tasks   # ... even when tasks.md still has unchecked boxes
/opsx-run <change> land --skip-merge    # already merged: skip merge, still archive + cleanup
/opsx-run <change> land --skip-eval     # bypass the eval regression gate
/opsx-run <change> close                # close that change's window and stop its preview
/opsx-run close-all                     # close every opsx window in the session and stop every preview in the project
/opsx-run list                          # show the windows in this session
```

## Helper script

All tmux calls go through `~/.claude/skills/opsx-run/opsx-window.sh`. **Never hand-roll `tmux send-keys`** — the script handles literal-text quoting, newline collapsing, window-id targeting, and rename suppression, all of which break subtly when improvised.

```
opsx-window.sh ensure <change> --prompt-file <f> [--cwd <dir>] [--agent-cli <cmd>] [--model <id>]
opsx-window.sh detect-cli [--agent-cli <cmd>]                          # print agent|claude|codex|opencode|gemini for the host session
opsx-window.sh detect-model [--model <id>]                             # print the model id to launch with (or `default`)
opsx-window.sh send   <change> --prompt-file <f>                 # send; creates the window if it is gone
opsx-window.sh close  <change> [--force] [--keep-session]        # close one window
opsx-window.sh close  --all    [--force] [--keep-session]        # close every tagged opsx window
opsx-window.sh status <change> [--lines N]                       # capture-pane snapshot (default 60 lines)
opsx-window.sh mark   <change> <busy|done|fail|idle> # title badge + status-bar color
opsx-window.sh list                                              # windows in the current session
opsx-window.sh preview-start <change> --cwd <dir> --script <f>   # opsx-preview.sh only: tagged @opsx_preview window
opsx-window.sh preview-find  <change>                            # opsx-preview.sh only
opsx-window.sh preview-kill  <change>|--all                      # opsx-preview.sh only
```

Previews are run by `~/.claude/skills/opsx-run/opsx-preview.sh` — the **only** code that starts, finds or stops previews. Run it **inline** in this session (like `merge` and `land`); never send a preview prompt to the change window:

```
opsx-preview.sh up   <change>|--main     # start or reuse; the URL is the last stdout line
opsx-preview.sh stop <change>|--all      # exit 0 even when nothing runs; 1 when a window could not be closed
opsx-preview.sh url  <change>|--main     # non-zero when nothing runs
opsx-preview.sh share <change>|--main [--for <r>] [--ttl <n>m|<n>h|<n>d|never] [--list] [--revoke <r|id|all>]
                                         # expose.sh share for the preview; the link is the last stdout line
opsx-preview.sh list
opsx-preview.sh prune                    # forget state of changes whose worktree is gone (land runs it)
```

Preview URLs need a login like every exposure (owner cookie from `expose.sh url <name> --with-key`, or a share link). Do not print the owner login link or a share link unless the user asked for it; `preview share` is that request. A recipe whose app binds `0.0.0.0` fails `up` (expose refuses non-loopback binds) — relay that it must bind `127.0.0.1` (`$HOST`).

Preview windows are titled `ox ><change>` (ASCII, so non-UTF-8 clients show it as-is) and tagged `@opsx_preview=<change>`, never `@opsx_change`, so they are never mistaken for the agent window.

The saved eval suite is run by `~/.claude/skills/opsx-run/opsx-eval.sh` (no LLM; `--help` for options). ops-eval calls it; `land` calls it for the regression gate; you can run it by hand or in CI:

```
opsx-eval.sh [--change <c>] [--capability <cap>]... [--all] [--agentic] [--trials N] [--json] [--root <dir>]
opsx-eval.sh --compare <baseline.json> <current.json>
```

It prints one line on success: `created @7 2:add-auth agent=agent`, `reused @7 2:add-auth`, `sent @7 2:add-auth`, or `marked @7 2:add-auth status=idle`. Relay which happened — the user wants to know whether a new window appeared, and which agent CLI was used when `agent=` is present.

**Window titles.** Opsx windows use a distinct `ox` prefix, a **dark pane**, and muted bar colors (word color = status). New work is **busy** (`ox …change`, amber). When the agent finishes it must mark **done** or **idle** (`ox ·change`, mint) or **fail** (`ox ✗change`, rose). `done` is treated as idle so you can send follow-ups into the same window. If the agent forgets to mark, **busy falls back to idle** after ~40s of pane silence (`$OPSX_IDLE_SILENCE`). Lookups use `@opsx_change`, so the title does not break later `/opsx-run` calls. From the window, mark with:

```bash
for d in "$HOME/.agents/skills/opsx-run" "$HOME/.codex/skills/opsx-run" \
         "$HOME/.cursor/skills/opsx-run" "$HOME/.claude/skills/opsx-run" \
         "$HOME/.config/opencode/skills/opsx-run" "$HOME/.gemini/skills/opsx-run"; do
  [ -x "$d/opsx-window.sh" ] && { "$d/opsx-window.sh" mark "<change>" done; break; }
done
```

(Use `fail` instead of `done` when the work failed.)

**Agent CLI selection** (new windows only — reused windows keep their existing session):

1. `--agent-cli <cmd>` on the `/opsx-run` invocation, forwarded to `ensure` (`claude`, `agent`, `cursor` as alias for `agent`, `codex`, `opencode`, `gemini`, or a path)
2. `$OPSX_AGENT_CLI` environment variable (same values)
3. Auto-detect inside `opsx-window.sh`: Cursor env markers → `agent`; Claude Code markers → `claude`; Codex markers → `codex`; OpenCode markers (`opencode` in the parent chain / `$OPENCODE_*`) → `opencode`; Gemini markers (`gemini` in the parent chain / `$GEMINI_CLI`) → `gemini`; else first of `claude`/`agent`/`codex`/`opencode`/`gemini` on PATH

**When calling `ensure`, always pass an explicit CLI if the user named one.** Otherwise run `opsx-window.sh detect-cli` first and forward `--agent-cli "$(opsx-window.sh detect-cli)"` to `ensure` — do not rely on the skill session alone, because an outdated installed script or a stripped environment can otherwise pick `claude` when both CLIs are installed.

**Model selection** (new windows only — reused windows keep the model they were launched with):

1. `--model <id>` on `/opsx-run` (e.g. `sonnet-4`, `opus`, `gpt-5`, a Cursor model id)
2. `$OPSX_MODEL`
3. Auto-detect via `opsx-window.sh detect-model`: `$ANTHROPIC_MODEL`, else Cursor `~/.cursor/cli-config.json` `selectedModel.modelId`, else Claude `~/.claude/settings.json` `model`, else Codex `~/.codex/config.toml` `model`, else OpenCode `~/.config/opencode/opencode.json{,c}` `model`, else Gemini `$GEMINI_MODEL` / `~/.gemini/settings.json` `model`. Values `default` / `auto` / `inherit` mean "CLI default" — omit `--model` so the new window matches this session.

Forward `--model` when the user named one **or** when `detect-model` prints something other than `default`. On Claude/Cursor/OpenCode, tell the dispatcher to spawn ops-applier with `model: inherit` (or OpenCode's equivalent) so the apply worker uses that window's model. On Codex the model applies to the window itself (it launches with `-m <model>`).

After upgrading the repo, re-run `./install.sh` so `~/.claude/skills/opsx-run/opsx-window.sh` picks up detection — an old install hardcodes `claude` and ignores Cursor entirely.

When called from **outside** tmux it also prints `session=created` on that line (if it had to start the session) and a `# attach with: tmux attach -t <session>` hint. Pass both on. `send`, `status` and `list` only ever *look up* the project session; they never create one, and they fail with a clear message if the user is outside tmux and no session exists yet.

Codex often strips `$TMUX` from sandboxed shells. `opsx-window.sh` recovers `$TMUX` / `$TMUX_PANE` from `/proc` so a `/opsx-run … --agent-cli codex` from inside an existing session still opens a **window in that session**, not a new session named after the project.

Write prompts to a file in the session scratchpad (e.g. `<scratchpad>/opsx-<change>-<action>.txt`) and pass `--prompt-file`. Prompt text is never spliced into a command line.

## Preconditions — check in this order, fail fast

1. **tmux.** `tmux` must be installed. Being *inside* a session is not required: when `$TMUX` is unset, `ensure` creates (or reuses) a session named after the **project folder** and puts the change window there. Tell the user the session name and `tmux attach -t <session>`. Never fall back to running the work inline.
2. **Change exists.** `openspec/changes/<change>/` must exist under the current directory. If the name is missing, vague, or ambiguous, run `openspec list --json` and use **AskUserQuestion** to let the user pick from the active changes. **Never guess or auto-select** the change name. **`qa`**, **`review`**, **`security`**, and **`eval`** as the first token are **actions**, not change names — same reserved-word pattern as `list` and `close-all`. Parse:
   - `/opsx-run <change> qa` / `review` / `security` and `/opsx-run <change> qa "..."` / `review "..."` / `security "..."` — change is named.
   - `/opsx-run qa` / `review` / `security` and `/opsx-run qa "..."` / `review "..."` / `security "..."` — change is omitted; pick it as above, then run the same action. Extra quoted text is **not** free-form window chat: it is extra notes for **ops-qa**, **ops-reviewer**, or **ops-security** respectively.
   - `/opsx-run <change> eval [--agentic]` — change is named. `/opsx-run eval [--agentic]` — change is omitted; pick it as above. `eval` takes no free-form notes (ops-eval works from the specs only).
   - **`preview`** as the first token is an action too. `/opsx-run <change> preview [stop|url|share …]` — change is named. `/opsx-run preview [stop|url|share …]` — change is omitted: use **AskUserQuestion** with the active changes (from `openspec list --json`) **plus "main checkout"** as options, and never guess. Picking the main checkout maps to `opsx-preview.sh <up|stop|url|share> --main` (published as `main--<project>`).

Both `openspec` and the window's agent CLI run from the current working directory, so run `/opsx-run` from the project root.

## Actions

| Action | This session does | The window gets |
|---|---|---|
| `apply` (default) | `openspec status --change <c> --json` to confirm the change is applyable, then `detect-cli` + `detect-model` + `ensure` | Apply dispatcher prompt (**ops-applier only** — no eval, review, security, or QA) |
| `apply --validate` | Fire-and-forget: `ensure` the **validate** dispatcher prompt. Do **not** CreateGoal, do **not** poll | One prompt: window `/goal` + apply → eval → review → security → qa → fix rounds until all PASS/SKIP |
| `verify` | `openspec validate <c> --strict --json` **and** `openspec status --change <c> --json` inline; report pass/fail with the actual errors | Nothing on pass. On failure, `ensure` a fix prompt (creates the window if it was closed) |
| `eval` / `eval --agentic` | `detect-cli` + `detect-model` + `ensure` (creates the window if missing). Resolve the change first if the user wrote `/opsx-run eval` | Eval dispatcher prompt — **ops-eval once**; do not auto-fix. `--agentic` also runs L3 checks. Never pass the applier's report |
| `review` / `review "..."` | `detect-cli` + `detect-model` + `ensure` (creates the window if missing). Resolve the change first if the user wrote `/opsx-run review` / `/opsx-run review "..."` | Review dispatcher prompt — **ops-reviewer once**; do not auto-fix. If `"..."` is present, append it **verbatim** as extra notes for ops-reviewer |
| `security` / `security "..."` | `detect-cli` + `detect-model` + `ensure` (creates the window if missing). Resolve the change first if the user wrote `/opsx-run security` / `/opsx-run security "..."` | Security dispatcher prompt — **ops-security once**; do not auto-fix. If `"..."` is present, append it **verbatim** as extra notes for ops-security |
| `qa` / `qa "..."` | `detect-cli` + `detect-model` + `ensure` (creates the window if missing). Resolve the change first if the user wrote `/opsx-run qa` / `/opsx-run qa "..."` | QA dispatcher prompt — **ops-qa once**; do not auto-fix. If `"..."` is present, append it **verbatim** as extra notes for ops-qa |
| `archive` | Gate inline: `validate --strict` passes **and** `status.isComplete` is true. If not, refuse and say exactly which check failed | Archive dispatcher prompt |
| `status` | — | Nothing; run `opsx-window.sh status <c>` and relay the meaningful tail |
| free text | — | `ensure` with the user's text verbatim. **If the window is missing, create it** — never tell the user to `apply` first just to recreate the window |
| `preview` / `preview stop` / `preview url` / `preview share` | Runs `opsx-preview.sh up <c>` / `stop <c>` / `url <c>` / `share <c> [options]` **inline** (`--main` for the main checkout; `share` options passed as given). Relay the URL (its last stdout line), the `detected:` line when present, and any warning (e.g. unknown recipe keys). On failure relay the reason as printed — e.g. "apply the change first", "add `.opsx/preview.yaml`", or "run `install.sh --expose-domain <domain>`" — plus the log tail | Nothing |
| `close` | — | Nothing; `opsx-window.sh close <c>` stops the change's preview (route, app, window) and kills that window |
| `close-all` | Confirm with **AskUserQuestion** first — this kills several live sessions at once | Nothing; `opsx-window.sh close --all` also stops every preview in the project |
| `merge` | Runs `opsx-merge.sh <change> [--into <branch>]` **inline**; `--no-ff` merge only — keeps the branch, worktree and window | Nothing |
| `land` | Runs `opsx-land.sh`, which runs the eval regression gate (when `evals/` exists), calls `opsx-merge.sh --stay`, then archive + cleanup (cleanup stops the change's preview before removing the worktree). If the branch is already in the target (exit 2 / `ALREADY_MERGED`), **AskUserQuestion** whether to skip the merge and finish cleanup; on yes, re-run with `--skip-merge` and the same flags. Do not tell the user to archive by hand. | Nothing — the window is closed as the last step |

`verify` and `archive` deliberately run their read-only `openspec` checks in **this** session: they are fast, and a failed gate should be reported to the user immediately rather than discovered inside a window they are not watching.

## Prompt templates

On **Claude Code**, **Cursor CLI**, and **OpenCode**, every **window** prompt is a **dispatcher**: it must hand work to subagents, not implement in the window itself. **`/goal` lives in that dispatcher window**, and only for `apply --validate`. **You (the caller) never CreateGoal and never wait** — dispatch and return so the user can keep working here. Plain `apply` does not create a goal and does not run review, security, or QA. **`/loop` is a timer — do not use it** (not in this session, not in the window). **Codex CLI** and **Gemini CLI** spawn-by-name is unreliable; those windows still do the work themselves on `opsx/<change>`.

| Host | How to run ops-applier / ops-eval / ops-reviewer / ops-security / ops-qa |
|---|---|
| **Claude Code** | Agent tool with `subagent_type: "ops-applier"`, `"ops-eval"`, `"ops-reviewer"`, `"ops-security"`, or `"ops-qa"` (`~/.claude/agents/opsx-*.md`) |
| **Cursor CLI** | Task tool with `subagent_type: "ops-applier"`, `"ops-eval"`, `"ops-reviewer"`, `"ops-security"`, or `"ops-qa"`. Project agents only: `<cwd>/.cursor/agents/` (`ensure` symlinks them). |
| **OpenCode** | Task or `@ops-applier` / `@ops-eval` / `@ops-reviewer` / `@ops-security` / `@ops-qa` (`~/.config/opencode/agents/` and `<cwd>/.opencode/agents/`). |
| **Codex CLI** | Do the work in the window on `opsx/<change>` (`~/.codex/agents/ops-*.toml`). For eval, follow `~/.codex/agents/ops-eval.toml` inline and still never read the applier's output as expected behaviour. |
| **Gemini CLI** | Do the work in the window on `opsx/<change>` (`~/.gemini/agents/opsx-*.md`; `ensure` links into `<cwd>/.gemini/agents/`). For eval, follow `opsx-eval.md` inline. |

### `apply --validate` — `/goal` in the **window** (caller is not blocked)

When the user passes `--validate` (with `apply` or as the default action's flag):

1. **You (the `/opsx-run` caller)** only `ensure` the **validate** window prompt below. Then report the window and **stop**. Do not CreateGoal. Do not UpdateGoal. Do not poll `status`. Do not wait for apply or QA. This session must stay free for other work.
2. **The opsx-run window** (the dispatcher that spawns ops-applier / ops-eval / ops-reviewer / ops-security / ops-qa) owns `/goal` and the apply → eval → review → security → qa → fix loop. Put that in the window prompt; never run it here.
3. Never `/loop` (timer) in this session or in the window. The window drives continuation by calling subagents with `run_in_background: false` (or equivalent) so *it* blocks, not you.

### Window prompts

**validate** (`apply --validate` — dispatcher owns `/goal`)

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`. Stay in this window. Do NOT implement product code yourself (Claude/Cursor/OpenCode).
> Call `CreateGoal` **once in this window** (not the parent): Apply OpenSpec change `<change>` on `opsx/<change>`, then ops-eval, ops-reviewer, ops-security, and ops-qa each `VERDICT: PASS` or `SKIP` with no leftover P0/P1 FINDINGS. Ops-applier implements; eval/reviewer/security/qa only verify (ops-eval writes only `evals/`). If Goal tools are missing, keep that as this window's objective.
> Then loop in this window (never `/loop` timer):
> 1. Delegate apply to **ops-applier** only (`subagent_type: "ops-applier"` / `@ops-applier`, `run_in_background: false`, `model: inherit`). Codex/Gemini: apply yourself on `opsx/<change>` / `../wt-<change>`.
> 2. If apply failed, `UpdateGoal` incomplete, `opsx-window.sh mark <change> fail`, stop.
> 3. Delegate eval to **ops-eval** only (`subagent_type: "ops-eval"` / `@ops-eval`, `run_in_background: false`). Pass only: change name, `opsx/<change>` / `../wt-<change>`, and any `DISPUTE` lines from the last eval-fix round. **Never pass the applier's report.** Print `VERDICT:` and FINDINGS. Codex/Gemini: run eval yourself per the ops-eval agent file, deriving expectations from the specs only.
> 4. Eval `FAIL` → delegate **ops-applier** to fix eval FINDINGS **verbatim** (keep F1, F2, …) **without touching `evals/`**; it may answer `DISPUTE F<n>: <reason>` instead. Then go to step 3 with those disputes. Eval `PASS` or `SKIP` → step 5.
> 5. Delegate review to **ops-reviewer** only (`run_in_background: false`). Print `VERDICT:` and FINDINGS in this pane. Codex/Gemini: run review yourself.
> 6. Review `FAIL` → delegate **ops-applier** to fix review FINDINGS **verbatim** (keep F1, F2, …), then go to step 5. Review `PASS` or `SKIP` → step 7.
> 7. Delegate security to **ops-security** only (`run_in_background: false`). Print `VERDICT:` and FINDINGS. Codex/Gemini: run security yourself.
> 8. Security `FAIL` → delegate **ops-applier** to fix security FINDINGS **verbatim**, then go to step 7. Security `PASS` or `SKIP` → step 9.
> 9. Before QA, run `<skills>/opsx-run/opsx-preview.sh up <change>` from `<cwd>`, then on exit 0 `<skills>/opsx-run/opsx-preview.sh share <change> --for ops-qa --ttl 1d`. On exit 0 of both pass the share command's last stdout line (a share link) to ops-qa as `PREVIEW_URL` (open it first and keep the same browser context so its login cookie applies; do not start a server). Otherwise pass `PREVIEW_URL: none — <reason from its output>` and let ops-qa start the app as before. Then delegate QA to **ops-qa** only (`run_in_background: false`). Codex/Gemini: same, then run QA yourself against that URL. Print `VERDICT:` and FINDINGS. Leave the preview running.
> 10. QA `PASS` or `SKIP` → `UpdateGoal` complete, `mark <change> done`, stop.
> 11. QA `FAIL` → keep the goal active. Delegate **ops-applier** to fix QA FINDINGS **verbatim**. Then go to step 9.
> Stop after marking. Do not return work to the parent session.

**apply** (no eval, review, security, or QA)

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Do NOT implement in this window yourself (Claude/Cursor/OpenCode). Delegate ALL implementation to **ops-applier**. Do **not** run ops-eval, ops-reviewer, ops-security, or ops-qa.
> Claude Code: Agent `subagent_type: "ops-applier"`, `run_in_background: false`, `model: inherit`.
> Cursor CLI: Task `subagent_type: "ops-applier"` (`.cursor/agents/opsx-applier.md` must exist).
> OpenCode: Task or `@ops-applier`.
> Codex CLI / Gemini CLI: apply yourself on `opsx/<change>` / `../wt-<change>`.
> Task: apply OpenSpec change `<change>` — read `openspec/changes/<change>/`, `openspec instructions apply --change "<change>" --json`, tick tasks.md, report files, branch, pass/fail.
> Then `opsx-window.sh mark <change> done` or `fail`. Stop after marking.

**eval** (ops-eval once — the caller may send eval-fix next)

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Do NOT implement product code. Do not re-apply the whole change unless the worktree is missing.
> Delegate to **ops-eval** only (`subagent_type: "ops-eval"` / `@ops-eval`). Codex/Gemini: run the eval yourself per the ops-eval agent file (`~/.codex/agents/ops-eval.toml` / `~/.gemini/agents/opsx-eval.md`), deriving expected behaviour from the spec scenarios only.
> Pass only: change name, `opsx/<change>` / `../wt-<change>`, `agentic: yes` (only for `eval --agentic`), and these disputes (omit if none):
> <DISPUTE lines pasted by the caller, verbatim>
> Do **not** pass the applier's report, commit messages or tests as expected behaviour.
> Print `VERDICT: PASS|FAIL|SKIP`, SCORE, FINDINGS and CHECKS_CHANGED. Do not spawn ops-applier.
> Then `opsx-window.sh mark <change> done` on PASS/SKIP or `fail` on FAIL. Stop after marking.

**eval-fix** (caller sends this after eval FAIL)

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Do NOT implement in this window yourself. Delegate to **ops-applier** only.
> Fix these ops-eval FINDINGS **verbatim** (keep F1, F2, …) in the same `opsx/<change>` worktree. Fix product code only: **do not create, edit or delete anything under `evals/`**. If a finding comes from a broken check, change nothing for it and report `DISPUTE F<n>: <reason>` instead. Do not reopen unrelated tasks.
> <FINDINGS pasted by the caller>
> Print the applier's DISPUTE lines (if any) so the next `/opsx-run <change> eval` can pass them on.
> Then `opsx-window.sh mark <change> done` or `fail`. Stop after marking.

**review** (ops-reviewer once — the caller may send review-fix next)

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Do NOT implement product code. Do not re-apply the whole change unless the worktree is missing.
> Delegate to **ops-reviewer** only (`subagent_type: "ops-reviewer"` / `@ops-reviewer`). Codex/Gemini: run the implementation review yourself.
> Pass: change name, `opsx/<change>` / `../wt-<change>`, files the applier changed if known.
> Extra notes from the user (omit this block if they sent none):
> <quoted text after `review`, verbatim>
> Print `VERDICT: PASS|FAIL|SKIP` and FINDINGS. Do not spawn ops-applier.
> Then `opsx-window.sh mark <change> done` on PASS/SKIP or `fail` on FAIL. Stop after marking.

**security** (ops-security once — the caller may send security-fix next)

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Do NOT implement product code. Do not re-apply the whole change unless the worktree is missing.
> Delegate to **ops-security** only (`subagent_type: "ops-security"` / `@ops-security`). Codex/Gemini: run the security review yourself.
> Pass: change name, `opsx/<change>` / `../wt-<change>`, files the applier changed if known.
> Extra notes from the user (omit this block if they sent none):
> <quoted text after `security`, verbatim>
> Print `VERDICT: PASS|FAIL|SKIP` and FINDINGS. Do not spawn ops-applier.
> Then `opsx-window.sh mark <change> done` on PASS/SKIP or `fail` on FAIL. Stop after marking.

**review-fix** (caller sends this after review FAIL)

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Do NOT implement in this window yourself. Delegate to **ops-applier** only.
> Fix these ops-reviewer FINDINGS **verbatim** (keep F1, F2, …) in the same `opsx/<change>` worktree. Do not reopen unrelated tasks.
> <FINDINGS pasted by the caller>
> Then `opsx-window.sh mark <change> done` or `fail`. Stop after marking.

**security-fix** (caller sends this after security FAIL)

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Do NOT implement in this window yourself. Delegate to **ops-applier** only.
> Fix these ops-security FINDINGS **verbatim** (keep F1, F2, …) in the same `opsx/<change>` worktree. Do not reopen unrelated tasks.
> <FINDINGS pasted by the caller>
> Then `opsx-window.sh mark <change> done` or `fail`. Stop after marking.

**qa** (ops-qa once — the caller may send qa-fix next)

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Do NOT implement product code. Do not re-apply the whole change unless the worktree is missing.
> First run `<skills>/opsx-run/opsx-preview.sh up <change>` from `<cwd>`, then on exit 0 `<skills>/opsx-run/opsx-preview.sh share <change> --for ops-qa --ttl 1d`. On exit 0 of both pass the share command's last stdout line (a share link) to ops-qa as `PREVIEW_URL` (open it first and keep the same browser context so its login cookie applies; do not start a server). Otherwise pass `PREVIEW_URL: none — <reason from its output>` and let ops-qa start the app as before. Leave the preview running.
> Delegate to **ops-qa** only (`subagent_type: "ops-qa"` / `@ops-qa`). Codex/Gemini: run the QA checks yourself, against `PREVIEW_URL` when you have one.
> Pass: change name, `opsx/<change>` / `../wt-<change>`, `PREVIEW_URL` (or the reason there is none), how to run the app if known. Use browser-use MCP when user-facing.
> Extra notes from the user (omit this block if they sent none):
> <quoted text after `qa`, verbatim>
> Print `VERDICT: PASS|FAIL|SKIP` and FINDINGS. Do not spawn ops-applier.
> If MCP is missing and the change is user-facing, run browser MCP in this window.
> Then `opsx-window.sh mark <change> done` on PASS/SKIP or `fail` on FAIL. Stop after marking.

**qa-fix** (caller sends this after QA FAIL)

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Do NOT implement in this window yourself. Delegate to **ops-applier** only.
> Fix these ops-qa FINDINGS **verbatim** (keep F1, F2, …) in the same `opsx/<change>` worktree. Do not reopen unrelated tasks.
> <FINDINGS pasted by the caller>
> Then `opsx-window.sh mark <change> done` or `fail`. Stop after marking.

**archive**

> You are the dispatcher for OpenSpec change `<change>` in `<cwd>`.
> Delegate to the ops-applier subagent. Claude Code: Agent `subagent_type: "ops-applier"`. Cursor CLI: Task `subagent_type: "ops-applier"` (project `.cursor/agents/opsx-applier.md` must exist). OpenCode: Task/`@ops-applier`. Codex CLI / Gemini CLI: do it yourself in this window. Do NOT delegate to anything else.
> Task: archive OpenSpec change `<change>`. Confirm every task in `openspec/changes/<change>/tasks.md` is checked and `openspec validate "<change>" --strict` passes, then run `openspec archive "<change>" -y` and report what moved and any spec updates.
> When done, summarize the report, then `opsx-window.sh mark <change> done` (or `fail`). Stop after marking.

**verify-fix** (only sent when the inline gate fails)

> Verification of OpenSpec change `<change>` failed. `openspec validate "<change>" --strict` reported: `<errors verbatim>`.
> Delegate the fix to the ops-applier subagent (Claude: Agent / Cursor: Task / OpenCode: Task or `@ops-applier`). Codex CLI / Gemini CLI: fix it yourself in this window. After it is fixed, re-run `openspec validate "<change>" --strict` and `openspec status --change "<change>" --json` and report the result. Then `opsx-window.sh mark <change> done` (or `fail`).

`<skills>` in the prompts is the skills dir this skill was loaded from (e.g. `~/.claude/skills`); substitute the absolute path when writing the prompt file.

On Claude/Cursor/OpenCode, **"Do NOT do the work yourself"** in the window is load-bearing. On **Codex** and **Gemini** the window does the work; isolation is tmux + `opsx/<change>`. Exception on Cursor: if ops-qa cannot see MCP, **browser-use** stays in that window.

## Reporting back

After every invocation, tell the user:

- the window name and whether it was **created** or **reused**,
- **if a session was created** (running from outside tmux): its name and `tmux attach -t <session>`,
- what was dispatched (or, for `verify`, the inline gate result),
- how to jump to it: `tmux select-window -t <session>:<change>` (or the title `ox ·change` / `ox …change` — lookup still uses the change name).

Never wait on or poll the window — including `apply --validate`. That flag's `/goal` and eval → review → security → qa loop run **inside the change window**. Use `/opsx-run <change> status` later if the user asks. The window title shows work state: `ox ·change` (idle/done, mint on dark), `ox …change` (busy, amber on dark), `ox ✗change` (fail, rose on dark). Busy auto-clears to idle after pane silence if the agent never marks.

## Merging a change

`~/.claude/skills/opsx-run/opsx-merge.sh <change> [options]` merges the change branch into a target and **stops**. No archive, no branch/worktree delete, no window close. **Review and security PASS are not required** — only git merge gates apply.

```
opsx-merge.sh <change> [--into <branch>] [--branch <name>] [--stay] [--dry-run]
```

- Default target is `main`, else `master`. Override with `--into`.
- Runs **inline in this session**. **It never pushes.**
- Gates: clean working tree (or auto-stash — see land) → change branch found → its worktree (if any) is clean → branch is ahead of target. Already merged (nothing the target is missing) exits **2** with `ALREADY_MERGED` — report it; there is nothing else for `merge` to do. For land, that same case asks about `--skip-merge` instead.
- Branch discovery matches `land`: `--branch`, else `opsx/<change>`, `feat/<change>`, `feature/<change>`, `<change>`, else a single fuzzy match.
- On conflict: abort, restore the starting branch, print the conflicting paths. Then `/opsx-run <change> merge` again (or land).
- `--stay` leaves HEAD on the target (used by `land` so archive runs on the merged tree). Without it, HEAD returns to the branch you started on.

## Landing a change

`~/.claude/skills/opsx-run/opsx-land.sh <change> [options]` finishes a change: **OpenSpec gates → `opsx-merge.sh --stay` → `openspec archive` → commit → remove worktree → delete branch → close window.**

```
opsx-land.sh <change> [--into <branch>] [--branch <name>] [--skip-specs]
             [--skip-merge] [--force-tasks] [--skip-eval] [--no-close]
             [--keep-branch] [--keep-worktree] [--dry-run]
```

- Runs **inline in this session**, never dispatched to the window — a window cannot close itself while still running the merge.
- **It never pushes.** Relay the `git push origin <branch>` line it prints; do not run it unless the user asks.
- **Confirm with AskUserQuestion before the first real run** — it writes a merge commit, deletes a branch and kills a live session. Offer `--dry-run` if the user seems unsure. Skip the confirmation when the user's message already spells out the intent ("land add-auth into develop"). `merge` alone is lighter; still confirm once if the user has not named the target.
- OpenSpec gates, in order: change dir exists → `validate --strict` → all artifacts present → **every task in tasks.md checked** (bypass with `--force-tasks`). **Review and security PASS are not required** — `land` never checks ops-reviewer or ops-security verdicts. Git merge gates are those of `opsx-merge.sh`, except a dirty **main working tree**: land auto-stashes it (`git stash push -u`) before merge/archive/cleanup and restores it on EXIT (success, ALREADY_MERGED exit 2, or failure). A dirty change-branch **worktree** still blocks until those files are committed. Report *which* gate failed and stop; do not dispatch work to fix it unless asked.
- **Already merged:** if `opsx-land.sh` prints `ALREADY_MERGED` and exits 2, the change branch has no commits the target is missing. **AskUserQuestion immediately** — do not stop at "run archive by hand":
  - Prompt: `<branch> is already in <target> (tip <sha>). Skip the merge and continue with archive, worktree/branch cleanup, and window close?`
  - Options: **Skip merge and finish cleanup** / **Stop**
  - On skip: re-run `opsx-land.sh <change> --skip-merge` with the same `--into` / `--branch` / `--force-tasks` / … flags. `--skip-merge` checks out the target and runs archive + cleanup only; it refuses if the branch still has unmerged commits.
  - On stop: leave the change as-is.
- **Eval regression gate.** When the target or the change branch has `evals/`, land runs `opsx-eval.sh --all --json` (L1 + L2 only, never `--agentic`) on the target in a temporary worktree (**baseline**), merges, then runs it again on the merged result (**current**). A check that PASSed on the baseline and FAILs on the merged result **blocks**: land prints `EVAL_REGRESSION` and the regressed checks, resets the target to its pre-merge commit, archives nothing, and exits non-zero — relay the regressions and suggest `/opsx-run <change> "fix the eval regression in <check>"` or `/opsx-run <change> eval`. Other FAIL / UNVERIFIABLE / MISSING results only **warn**. No `evals/` → skipped silently. `--skip-eval` bypasses it (say so when relaying). `--skip-merge` skips it too (no pre-merge baseline). ops-eval / ops-reviewer / ops-security verdicts are still never required.
- Branch discovery is the same as `merge`.
- On merge conflict `opsx-merge.sh` aborts and restores; the fix is a normal window instruction: `/opsx-run <change> "resolve the conflicts merging <branch> into <target>"`.

## Closing windows

`close` kills the window and the agent session running in it, ending any work that session still had in flight. Worktrees, commits and files already written survive on disk. Say this plainly before a `close-all`, and confirm it with **AskUserQuestion**; a single named `close` is unambiguous enough to just do.

- `--all` only touches windows this script created — they carry an `@opsx_change` tmux option. The user's own windows in the same session are never closed. Windows created before tagging existed aren't matched either; close those by name.
- The script refuses to close the window the caller is *in* unless `--force` is passed, so a `close-all` from inside a change window can't kill the caller mid-command. Relay the `# skipped …` line when it appears.
- Closing the last window in a session destroys the session — the script says so. Pass `--keep-session` to park a plain shell window and keep it alive.
- If the user asks to close a change that has no window, say so; it is not an error worth escalating.
- `close` stops the change's preview and `close-all` stops every preview in the project (through `opsx-preview.sh stop`, before any window is killed). A missing or failing preview never makes the close fail. A QA preview is left running on purpose so the user can open what QA saw; `close`/`land` clean it up.
- Free-form text and verify-fix must **not** fail with "run apply first". `send` now creates the window when it is missing (same as `ensure`). Recreate and deliver the instruction in one step.

## Notes

- New windows launch with permission bypass so they never stall on a prompt while unattended: `claude --permission-mode bypassPermissions`, `agent --force --approve-mcps --trust` (Cursor CLI on Linux), `codex --dangerously-bypass-approvals-and-sandbox` (Codex CLI), `opencode --auto --prompt …` (OpenCode), or `gemini --approval-mode=yolo --skip-trust -i …` (Gemini CLI). `--approve-mcps` / `--auto` / YOLO load MCP tools in the tmux window where the host supports them. `./install.sh` writes the **browser-use** MCP server into Gemini (`~/.gemini/settings.json`), Codex (`~/.codex/config.toml`), and OpenCode (`~/.config/opencode/opencode.json{,c}`) using `uvx --from browser-use[cli] browser-use --mcp`. Cursor already reads `~/.cursor/mcp.json`.
- **Codex CLI** loads this skill from `~/.agents/skills/opsx-run/` (and `$CODEX_HOME/skills/opsx-run`). Restart Codex after install. Windows launch unattended; a Codex dispatcher window applies the change itself in an `opsx/<change>` worktree; `ops-applier` is also installed as `~/.codex/agents/ops-applier.toml`.
- **OpenCode** loads this skill from `~/.config/opencode/skills/opsx-run/` (and also reads `~/.claude/skills` / `~/.agents/skills`). Restart OpenCode after install. Windows launch as `opencode --auto --prompt …` (`-m provider/model` from config when detected). `ops-applier` is `~/.config/opencode/agents/ops-applier.md`; `ensure` also links it into `<project>/.opencode/agents/`. Dispatcher windows use Task or `@ops-applier`.
- **Gemini CLI** loads this skill from `~/.gemini/skills/opsx-run/` (and `~/.agents/skills`). Restart Gemini after install. Windows launch as `gemini --approval-mode=yolo --skip-trust -i …` (`-m` from `$GEMINI_MODEL` or `~/.gemini/settings.json`). Agents live in `~/.gemini/agents/`; `ensure` links them into `<project>/.gemini/agents/`. A Gemini window applies the change itself in `opsx/<change>`.
- Forward `--agent-cli` and `--model` from the user's `/opsx-run` message to `opsx-window.sh ensure` when they name them; otherwise `detect-cli` / `detect-model`.
- `ops-applier` / `ops-eval` / `ops-reviewer` / `ops-security` / `ops-qa` — Claude Code: `~/.claude/agents/opsx-*.md`. Cursor CLI: `~/.cursor/agents/` plus **`ensure` links into `<project>/.cursor/agents/`**. OpenCode: `~/.config/opencode/agents/` plus project `.opencode/agents/`. Codex: `~/.codex/agents/ops-*.toml`. Gemini: `~/.gemini/agents/opsx-*.md` plus project `.gemini/agents/`. Plain **apply** only runs ops-applier (no eval, review, security, or QA). **`apply --validate`**: the **opsx-run window** uses `/goal` (`CreateGoal`) and loops apply → eval → review → security → qa → fix; this calling session only `ensure`s that prompt and returns. Standalone **eval** / **review** / **security** / **qa** (and `review "..."` / `security "..."` / `qa "..."`) are one-shot with no auto-fix. Applier drives `openspec` and never edits `evals/`. ops-eval writes only `evals/` (its own `eval: <change>` commit); reviewer/security/qa are read-only gates. OpenSpec `/opsx:*` commands are installed globally by `./install.sh`.
- Window names are `ox ·change` / `ox …change` / `ox ✗change` with muted mint / amber / rose on a dark bar, plus a dark pane. Idle is never tmux default. `done` maps to idle so the window stays reusable. Busy windows that go silent (~40s) fall back to idle if the agent forgot `mark done`. Lookups use `@opsx_change`, not the display title.
