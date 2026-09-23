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

Outside the repo, so nothing to gitignore and no clutter. Ids are small integers per tmux session (`1`, `2`, …), allocated with `mkdir` (atomic) to avoid races between two parents in the same session.

### 4. Read-only child launch

| CLI | Launch |
|---|---|
| Claude | `claude --permission-mode plan "$(cat brief)"` |
| Codex | `codex --sandbox read-only …` |
| Gemini | read-only / default approval mode (flag to verify) |
| Cursor `agent` | to verify; else no force flags + brief instruction |
| OpenCode | to verify (plan agent/mode); else brief instruction |

Where a CLI has no enforceable read-only mode, the child runs with its **normal interactive approvals** (never the bypass flags opsx-run uses) plus the brief's "do not modify files" instruction. Task 1 verifies each flag before the rest is built.

**Writing the result from a sandbox.** `fork.sh return` writes to `FORK_DIR`, outside the working tree, which a read-only sandbox may block. Order of fallbacks:
1. `fork.sh return` succeeds → done.
2. It fails → the skill tells the child to print the result between `<<<FORK-RESULT` / `FORK-RESULT>>>` markers; `collect` extracts that block from `capture-pane -S -` scrollback.
3. Neither → `collect` returns the raw capture tail, labelled as such.

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

- Exact read-only flags for Gemini, Cursor `agent` and OpenCode (task 1).
- Whether Cursor/Gemini/OpenCode pass the launch env vars through to their shell tool unchanged (task 1).
