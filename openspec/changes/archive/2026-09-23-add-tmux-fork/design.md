## Context

tmux-opsx already drives agent CLIs inside tmux through `skills/opsx-run/opsx-window.sh`, which solves several subtle problems: literal-text `send-keys`, collapsing newlines so a prompt is not submitted early, launching each CLI with a seeded first prompt (`claude "$(cat f)"`, `agent … "$(cat f)"`, `opencode --prompt …`, `codex …`, `gemini …`), and detecting the host CLI and model. It is tied to OpenSpec changes, worktrees and full-permission apply windows.

The user wants a separate tool for **parallel questions**: open a child agent next to the current one, already aware of the parent's context, ask it things, and let the parent pick up the outcome later. Decisions already made with the user:

- Questions only — children never edit code, so no worktrees.
- Must work with all five CLIs.
- Results come back by notify-then-pull, never by typing into the parent.
- Pane is the default; window is optional.
- Fully independent of `opsx-run` and OpenSpec.

## Goals / Non-Goals

**Goals:**
- One command to open a briefed, read-only child agent in a pane beside the parent.
- A small, predictable way for the child's findings to return to the parent.
- Same behavior across Claude, Cursor, Codex, OpenCode and Gemini, degrading gracefully where a CLI lacks a feature.

**Non-Goals:**
- Parallel code changes, worktrees, merging.
- Real session forking (`claude --resume --fork-session`) — possible later upgrade for Claude only.
- Pushing results into the parent automatically.
- Running outside tmux.
- Refactoring `opsx-window.sh` into a shared library.

## Decisions

### 1. Standalone skill + one script

```
skills/fork/
├── SKILL.md    # protocol the agent follows (/fork, collect, return, …)
└── fork.sh     # all tmux and filesystem work
```

The agent writes prose (brief, result); `fork.sh` does every tmux call. Like `opsx-window.sh`, the skill forbids hand-rolled `tmux send-keys`/`split-window`.

Patterns (launch command per CLI, literal send-keys, CLI detection) are **copied** from `opsx-window.sh`, not shared. Alternative — extracting a shared lib — rejected because the user wants the two skills independent and it would touch `opsx-run`.

### 2. Flow

```
 PARENT pane ($TMUX_PANE=%3)                    CHILD pane (%7)
 /fork "question"
   ├─ agent writes brief to stdin of: fork.sh open [--window] [--vertical] [--cli X]
   │     → allocates id, writes brief.md + meta
   │     → tmux split-window -h -l 40% -t %3  (or new-window)
   │         env FORK_ID FORK_DIR FORK_PARENT=%3
   │         <cli> <read-only flags> "$(cat brief.md)"
   │     → prints id + pane id
 ...                                            user asks questions
                                                /fork return
                                                  └─ fork.sh return < result
                                                       → result.md, status=returned
                                                       → display-message + badge on %3
 /fork collect [id] → fork.sh collect → prints result.md
```

`$TMUX_PANE` identifies the parent. The child learns its own fork from the env vars set on its launch command; they are inherited by the agent's shell tool, so `fork.sh return` needs no arguments.

### 3. State directory

`${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/<tmux-session-name>/<id>/`

| File | Written by | Content |
|---|---|---|
| `brief.md` | parent (via `open`) | question + context |
| `meta` | `fork.sh` | `parent_pane`, `child_pane`, `cli`, `cwd`, `created`, `status` (`open`/`returned`/`closed`) |
| `result.md` | child (via `return`) | answer, evidence, open doubts |
| `capture.txt` | `collect` fallback | last `capture-pane` of the child |

Outside the repo, so nothing to gitignore and no clutter. Ids are small integers per tmux session (`1`, `2`, …), claimed atomically by creating `.ids/<n>` with bash `noclobber` (O_EXCL) to avoid races between two parents in the same session (`mkdir` was the original plan but is not reliably atomic with uutils coreutils; see Decision 4). `launch.sh` (the generated child launcher) also lives in the fork dir.

### 4. Read-only child launch

Verified in the task-1 spike (2026-09-22) from each CLI's `--help` plus short
non-interactive probes (`claude -p`, `codex sandbox`, `opencode run`, `gemini -p`;
Cursor `agent -p` hit an account usage limit, so Cursor is verified from `--help`
only). Versions: Claude Code 2.1.280, Cursor agent (current), codex-cli 0.147.0,
opencode 1.18.30, gemini 0.56.0.

| CLI | Launch (read-only) | Seeded prompt | `FORK_*` env reaches shell | `fork.sh return` works |
|---|---|---|---|---|
| Claude | `claude --permission-mode plan --allowedTools "Bash(<abs fork.sh> return:*)" --append-system-prompt "<carve-out>" "$(cat brief)"` | positional | yes (probe) | yes, **only** with the narrow `--allowedTools` rule + carve-out prompt; without them plan mode refuses or needs approval, and a `$FORK_SH`-style variable is rejected, so the brief uses the literal absolute path |
| Codex | `codex --sandbox read-only --ask-for-approval on-request "$(cat brief)"` | positional `[PROMPT]` | yes (`codex sandbox` probe) | write is blocked by the read-only sandbox (`Read-only file system`); with `on-request` the model can ask the user to escalate that one command, else marker fallback |
| Gemini | `gemini --approval-mode plan -i "$(cat brief)"` | `-i/--prompt-interactive` | not observed (shell refused in plan mode) | no — plan mode is enforced read-only and the model only proposes; marker fallback |
| Cursor `agent` | `agent --mode ask "$(cat brief)"` | positional | assumed (normal child process env) | unverified at runtime; `ask` is documented as read-only Q&A, so expect marker fallback |
| OpenCode | `opencode --agent plan --prompt "$(cat brief)"` | `--prompt` | yes (probe printed `FORK_ID`) | no — the built-in `plan` agent denies edits and the model refuses any mutating shell command even with a carve-out; marker fallback |

None of the launches use bypass/force flags (`bypassPermissions`, `--force`,
`--yolo`, `--auto`, `--dangerously-bypass-approvals-and-sandbox`, `--trust`,
`--skip-trust`). Cursor and Gemini will show their normal workspace-trust prompt
in an untrusted folder; that is left to the user. Every CLI has an enforceable
read-only mode, so the "normal approvals + instruction" fallback is only used
for CLIs this table does not cover (unknown CLIs are rejected by `fork.sh`).

`fork.sh open` appends a generated "Fork protocol" section to every brief with
the fork id, the read-only rule, the literal absolute `fork.sh return` command,
and the marker-block fallback, so the return path does not depend on the parent
agent remembering it.

`return` finds its fork from `FORK_DIR`; if a CLI strips the variable it falls
back to the parent process chain (`/proc/*/environ`) and then to the `@fork_dir`
option stamped on the child pane.

**Writing the result from a sandbox.** `fork.sh return` writes to `FORK_DIR`, outside the working tree, which a read-only sandbox may block. Order of fallbacks:
1. `fork.sh return` succeeds → done (Claude; Codex after user approval).
2. It fails → the skill tells the child to print the result between `<<<FORK-RESULT` / `FORK-RESULT>>>` markers; `collect` extracts that block from `capture-pane -J -S -` scrollback and saves it as `result.md` (Gemini, OpenCode, Cursor, Codex without approval). No notification is sent in this path, since nothing ran in the child.
3. Neither → `collect` returns the raw capture tail, labelled as such.

**Scripted end-to-end runs (private tmux socket, task 6.3/6.4):**
- Claude (plan mode): answered, then `fork.sh return` ran without an approval
  prompt thanks to the narrow allow rule; `result.md` written, badge `fork 1 ✓`
  set on the parent, `collect` / `list` / `close` behaved as specified.
- Gemini: in an untrusted folder Gemini drops to default approvals (plan mode
  is not applied until the folder is trusted); it asked to approve the return
  command, then did not write `result.md` and printed the marker block instead;
  `collect` recovered it and saved it as `result.md`.
- OpenCode: launched in the `Plan` agent, but the configured model was out of
  quota, so only the raw-capture path was exercised.
- Codex (not logged in) and Cursor (usage limit) could not be run end to end.

**Id allocation.** `mkdir` turned out not to be atomic on this machine (uutils
coreutils `mkdir` let several racing processes "create" the same directory), so
ids are claimed with a bash `noclobber` (O_EXCL) file `.ids/<n>` and the fork
directory is created afterwards (see Decision 3).

Full-screen TUIs (OpenCode) have no tmux scrollback, so the marker block must
still be on screen when collecting; the skill tells the user to collect before
scrolling the child far away.

### 5. Notify, never push

`return` runs `tmux display-message -t <parent-client>` and sets a pane option / pane title badge (e.g. `fork 2 ✓`) on the parent pane. It never `send-keys` into the parent. If the parent pane is gone, `return` still writes the result and exits 0.

### 6. Brief and result stay small

Brief: question, 5–15 lines of parent context (goal, relevant files, current hypothesis), role statement, and how to return. Result: answer, evidence (`file:line`, commands), unresolved points — aimed at under ~40 lines so `collect` is cheap for the parent's context.

### 7. Layout

Default `split-window -h -l 40%` targeting the parent pane. With more than one child, apply `select-layout main-vertical` so the parent stays the large pane. `--vertical` splits top/bottom; `--window` opens a new window named `fork-<id>`.

### 8. Close

`close <id>`: if there is no `result.md`, save `capture.txt` first; then kill the pane/window and set `status=closed`. State dirs are kept; `close --all` closes every open fork of the current session. Old state is left for the user to remove (tiny text files).

## Risks / Trade-offs

- **Read-only flags differ or don't exist** → verified in task 1; fallback is normal approvals + instruction, documented per CLI.
- **Sandbox blocks `return`** → marker block + capture fallback (Decision 4).
- **Summary brief loses detail** vs a true fork → accepted; brief quality is on the parent agent. Real Claude fork is a possible follow-up.
- **Full-screen TUIs limit `capture-pane`** → marker block is printed into normal output; capture uses `-S -` for scrollback; still best-effort.
- **Narrow panes** → 40% default and `--window` escape hatch.
- **Duplicated launch logic with opsx-window.sh** → accepted for independence; small surface.

## Open Questions

- Resolved by the task-1 spike (see Decision 4). Still unverified at runtime: Cursor `agent --mode ask` (account usage limit during the spike) and whether Gemini plan mode exposes `FORK_*` to a shell tool (it refuses shell commands, so it does not matter for `return`).
