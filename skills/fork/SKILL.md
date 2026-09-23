---
name: fork
description: "Fork the current agent conversation into a read-only child agent in a tmux pane (or window), briefed with this session's context, so the user can ask side questions without derailing the main thread; the child returns a short result that the parent collects later. Works from Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI. Use when the user types /fork, asks to 'fork', 'open a side agent', 'ask a question in parallel', or, inside a fork, says '/fork return'. Also /fork collect, /fork list, /fork close. Trigger: /fork"
trigger: /fork
---

# /fork

Open a **read-only child agent** next to this one, already briefed with the current context, so the user can ask it side questions ("why did we pick X?", "where is Y handled?"). The child never edits code. When the user is done, the child **returns** a short result; the parent is **notified** (tmux message + pane badge, never typed into) and **collects** the result when the user asks.

Independent of OpenSpec and `/opsx-run`. Requires tmux (except `/fork return`).

## Usage

| Where | Command | What it does |
|---|---|---|
| parent | `/fork ["question"]` | write a brief, open the child in a side-by-side pane (~40% width) |
| parent | `/fork --vertical ["question"]` | same, split top/bottom |
| parent | `/fork --window ["question"]` | same, in a new window `fork-<id>` |
| parent | `/fork --cli <claude\|agent\|codex\|opencode\|gemini> …` | use another CLI for the child (default: the same CLI as this session) |
| child | `/fork return` | write the result and notify the parent |
| parent | `/fork collect [id]` | read a fork's result into this conversation (default: the most recently returned) |
| parent | `/fork list` | list this tmux session's forks |
| parent | `/fork close <id>` / `/fork close --all` | save a capture if needed, kill the child pane/window |

## The script

All tmux and filesystem work goes through `fork.sh`, next to this file (for Claude Code: `~/.claude/skills/fork/fork.sh`; other CLIs: the `fork/` folder of their skills dir). Resolve it once:

```bash
FORK_SH=$(ls ~/.claude/skills/fork/fork.sh ~/.cursor/skills/fork/fork.sh ~/.agents/skills/fork/fork.sh \
  ~/.codex/skills/fork/fork.sh ~/.config/opencode/skills/fork/fork.sh ~/.gemini/skills/fork/fork.sh 2>/dev/null | head -n1)
```

```
fork.sh open [--window] [--vertical] [--cli <name>] [--cwd <dir>]   < brief
fork.sh return                                                      < result
fork.sh collect [<id>]
fork.sh list
fork.sh close <id> | --all
fork.sh detect-cli [--cli <name>]
```

**Rules**

- Never hand-roll `tmux split-window`, `new-window`, `send-keys`, `kill-pane` for forks — `fork.sh` handles targeting, env vars, layout, badges and pane-id safety.
- **Never send keys to the parent pane**, and never paste a child's result into the parent yourself. Results only reach the parent through `collect`.
- Keep briefs and results small; they cost context on both sides.

## Parent: `/fork ["question"]`

1. Write a **brief** with these sections (Markdown), then pipe it to `fork.sh open` on stdin with a quoted heredoc so nothing is expanded:

   ```bash
   "$FORK_SH" open <<'EOF'
   ## Question
   <the user's question, or "general exploration" if none>

   ## Context
   - Goal: <what the parent session is working on>
   - Relevant files: <paths, with line numbers where useful>
   - Current state / hypothesis: <what is known, what was tried, open doubts>
   - <5–15 lines total: only what the child needs to answer well>

   ## Role
   You are a read-only fork: answer questions, do not modify files.
   EOF
   ```

   Add `--window`, `--vertical` or `--cli <name>` only when the user asked for them. `fork.sh` appends a generated **Fork protocol** section (read-only rule, the exact return command, the marker fallback), stores everything as `brief.md` and uses it as the child's first prompt.

2. Report the output line (`fork <id> pane <%N> cli <cli>`) to the user in one sentence, e.g. "Opened fork 2 in the pane on the right (Claude, plan mode). Ask it anything; say `/fork return` there when done." Then continue with your own work. Do not wait for or poll the child.

Brief content comes from **this conversation**, not a re-investigation: summarize, don't research. Never include secrets (tokens, keys, passwords) in the brief.

## Child: `/fork return`

You are in a fork when your first prompt contains a "Fork protocol" section (and `$FORK_DIR` is set). When the user says `/fork return` (or asks you to report back):

1. Write a concise result, at most ~40 lines:

   ```
   **Answer**: <direct answer>
   **Evidence**: <file:line references, commands run and what they showed>
   **Unresolved**: <open points, or "none">
   ```

2. Save it with the **exact command from the Fork protocol** (it uses the literal absolute path of `fork.sh`, which read-only modes such as Claude plan mode are set up to allow):

   ```bash
   /abs/path/to/fork.sh return <<'FORK_EOF'
   <result>
   FORK_EOF
   ```

   It prints `fork <id>: result saved; parent … notified.` Tell the user the result was returned.

3. **Fallback** — if the command is refused, blocked by a sandbox, needs an approval the user declines, or exits non-zero (exit 3 = could not write): print the same result in your reply wrapped in marker lines, each on its own line with nothing else on it: `<<<FORK-RESULT` before the result and `FORK-RESULT>>>` after it. The parent's `collect` recovers the block from this pane. Tell the user to run `/fork collect <id>` in the parent while this pane is still open.

Running `/fork return` outside a fork prints "this session is not a fork" — say so and stop.

Stay read-only for the whole session: no edits, no state-changing commands, no git writes. `fork.sh return` is the only exception.

## Parent: `/fork collect [id]`

Run `"$FORK_SH" collect [id]` and use its output as the child's findings. Without an id it picks the most recently returned fork. The output starts with a header saying where it came from:

- `# fork <id> result` — the child's `result.md`;
- `… (recovered from the marker block …)` — the child printed the fallback block;
- `RAW CAPTURE — no result was returned` — only the tail of the child pane. Treat it as unverified notes and say so.

Collecting clears that fork's badge on the parent pane. Summarize the result for the user in a few lines and fold it into your work. Do not re-open or message the child.

## Parent: `/fork list` and `/fork close`

- `"$FORK_SH" list` — show the table (id, status `open` / `returned` / `closed`, CLI, pane, first line of the question). `(pane gone)` means the child exited without being closed.
- `"$FORK_SH" close <id>` / `close --all` — if a fork has no result yet, a `capture.txt` is saved first, so a later `collect <id>` still returns something. The pane/window is killed; state is kept.

## Read-only children per CLI

| CLI | Launched as | `return` |
|---|---|---|
| Claude Code | `claude --permission-mode plan` + an allow rule for exactly `fork.sh return` | writes `result.md` directly |
| Codex CLI | `codex --sandbox read-only --ask-for-approval on-request` | sandbox blocks the write; Codex may ask the user to approve that one command, else marker fallback |
| Gemini CLI | `gemini --approval-mode plan -i` | usually marker fallback |
| Cursor CLI | `agent --mode ask` | usually marker fallback |
| OpenCode | `opencode --agent plan --prompt` | marker fallback (plan agent refuses shell writes) |

No child is ever launched with bypass/force/auto-approve flags. Full-screen TUIs (OpenCode) keep little scrollback, so collect while the marker block is still on screen.

## Where things live

`${XDG_STATE_HOME:-~/.local/state}/agent-forks/<tmux-session>/<id>/` — `brief.md`, `meta`, `launch.sh`, `result.md`, `capture.txt`. Outside the repo; nothing to gitignore. Old forks are kept until the user deletes them.

The parent badge is the pane title `fork <ids> ✓` (tmux's default status line shows it) and the pane option `@fork_badge` (usable in `pane-border-format`). While a badge is shown, `allow-set-title` is turned off on the parent pane so the agent CLI does not overwrite it; `collect`/`close` restore it.
