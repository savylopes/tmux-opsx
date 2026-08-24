# tmux-opsx

Run [OpenSpec](https://github.com/Fission-AI/OpenSpec) changes in Claude Code, Cursor CLI, Codex CLI, or OpenCode without blocking your session.

**One change = one tmux window, named after the change.** `/opsx-run add-auth` opens a window called `add-auth` running an agent session (Claude Code, Cursor CLI — the `agent` command on Linux —, Codex CLI, or OpenCode). On Claude/Cursor/OpenCode it hands the implementation to the **ops-applier** subagent; a Codex window applies the change itself in an isolated git worktree. You keep your prompt. Every later instruction about that change goes back into the same window, so each change keeps one long-lived conversation you can jump into at any time.

Not in tmux? It starts a session named after the project folder for you.

```
┌ tmux session ─────────────────────────────────────────────┐
│ 0:agent*   1:add-auth  2:rate-limiting  3:fix-webhooks    │
│    claude/agent/opencode ─> Task/Agent(ops-applier) ─> worktree │
│    codex ─────────────────> (applies directly) ──────> worktree │
└───────────────────────────────────────────────────────────┘

  /opsx-run add-auth ......... window opens, work starts
  /opsx-run add-auth verify .. gates run in your session
  /opsx-run add-auth apply --validate .. apply + QA; this session /goal until PASS
  /opsx-run add-auth qa ...... one-shot UI/UX QA
  /opsx-run add-auth merge ... merge into main (branch/window stay)
  /opsx-run add-auth land .... merge + archive + cleanup, window closes
```

---

## Contents

| Piece | Installs to | What it does |
|---|---|---|
| `/opsx-run` skill | `~/.claude/skills/opsx-run/` · `~/.cursor/skills/opsx-run/` · `~/.agents/skills/opsx-run/` · `$CODEX_HOME/skills/opsx-run/` · `~/.config/opencode/skills/opsx-run/` | The lifecycle: apply, verify, archive, land, close — one window per change |
| `opsx-window.sh` | `~/.claude/skills/opsx-run/` | All tmux mechanics — session/window lookup, literal-text sends, rename suppression, closing |
| `opsx-merge.sh` | `~/.claude/skills/opsx-run/` | Merge the change branch into a target (default `main`) — no archive or cleanup |
| `opsx-land.sh` | `~/.claude/skills/opsx-run/` | Landing a change — OpenSpec gates, then `opsx-merge.sh`, archive, branch/worktree cleanup |
| `ops-applier` subagent | `~/.claude/agents/opsx-applier.md` · `~/.cursor/agents/opsx-applier.md` · `~/.codex/agents/ops-applier.toml` · `~/.config/opencode/agents/ops-applier.md` | Implements the change in an isolated worktree on `opsx/<change>` |
| `ops-qa` subagent | `~/.claude/agents/opsx-qa.md` · `~/.cursor/agents/opsx-qa.md` · `~/.codex/agents/ops-qa.toml` · `~/.config/opencode/agents/ops-qa.md` | UI/UX gate. Runs on `apply --validate` (caller `/goal`) or `/opsx-run <change> qa` |
| `/opsx:*` commands + OpenSpec skills | global Claude / Cursor / Codex / OpenCode dirs | OpenSpec propose/apply/archive/explore — installed globally by `./install.sh` |
| `/graphify` skill | `~/.claude/skills/graphify/` · `~/.cursor/skills/graphify/` · `~/.agents/skills/graphify/` · `~/.codex/skills/graphify/` · `~/.config/opencode/skills/graphify/` | Graphify knowledge-graph skill — installed globally after the CLI is verified |
| OpenSpec CLI | npm global | `openspec` — the spec/change engine everything is built on |
| Graphify CLI | uv tool / pipx | `graphify` — required for `/graphify` |

---

## Requirements

- **tmux** — every change runs in a tmux window (you don't have to be inside a session; one is created per project if needed)
- **git** — the ops-applier agent works in worktrees
- **Node.js + npm** — to install the OpenSpec CLI
- **Graphify** (`graphify`) — verified on install; installed with `uv tool install graphifyy` if missing
- **Claude Code** (`claude`), **Cursor CLI** (`agent` on Linux), **Codex CLI** (`codex`), **or OpenCode** (`opencode`) — each window runs one of these (at least one must be on PATH)
- macOS or Linux

---

## Install

```bash
git clone git@github.com:savylopes/tmux-opsx.git
cd tmux-opsx
./install.sh
```

The installer checks prerequisites, installs the OpenSpec CLI, installs OpenSpec **skills and `/opsx:*` commands globally** for Claude Code, Cursor, Codex, and OpenCode, verifies **Graphify** and copies `/graphify` into those same global skill dirs, and installs the tmux-opsx subagent and `/opsx-run` skill.

```
./install.sh --prefix <dir>     # Claude config dir (default ~/.claude, or $CLAUDE_CONFIG_DIR)
./install.sh --skip-openspec    # leave the OpenSpec CLI alone
./install.sh --skip-graphify    # don't verify/install Graphify or copy /graphify
./install.sh --skip-commands    # don't install global OpenSpec skills / /opsx:* commands
./install.sh --no-backup        # overwrite without keeping .bak copies
./install.sh --uninstall        # remove everything except the OpenSpec and Graphify CLIs
```

**Restart your agent CLI afterwards** (Claude Code, Cursor, Codex, or OpenCode) so it picks up the new skill, subagent, and commands.

### Manual install

If you would rather not run the script:

```bash
npm install -g @fission-ai/openspec                      # 1. the CLI

tmp=$(mktemp -d)                                         # 2. global OpenSpec skills + commands
(cd "$tmp" && openspec init --tools claude,cursor,codex,opencode .)
mkdir -p ~/.claude/skills ~/.claude/commands \
         ~/.cursor/skills ~/.cursor/commands \
         ~/.codex/skills ~/.agents/skills \
         ~/.config/opencode/skills ~/.config/opencode/commands
cp -R "$tmp"/.claude/skills/openspec-* ~/.claude/skills/
cp -R "$tmp"/.claude/commands/opsx ~/.claude/commands/
cp -R "$tmp"/.cursor/skills/openspec-* ~/.cursor/skills/
cp "$tmp"/.cursor/commands/opsx-*.md ~/.cursor/commands/
cp -R "$tmp"/.codex/skills/openspec-* ~/.codex/skills/
cp -R "$tmp"/.codex/skills/openspec-* ~/.agents/skills/
cp -R "$tmp"/.opencode/skills/openspec-* ~/.config/opencode/skills/
cp "$tmp"/.opencode/commands/opsx-*.md ~/.config/opencode/commands/
rm -rf "$tmp"

graphify install --platform claude,codex,opencode,agents   # 2b. global /graphify
mkdir -p ~/.cursor/skills/graphify
cp -R ~/.claude/skills/graphify/. ~/.cursor/skills/graphify/

mkdir -p ~/.claude/skills ~/.claude/agents ~/.cursor/agents ~/.cursor/skills \
         ~/.agents/skills ~/.codex/skills ~/.codex/agents \
         ~/.config/opencode/skills ~/.config/opencode/agents   # 3. tmux-opsx skill + subagents
cp -r skills/opsx-run ~/.claude/skills/
cp -r skills/opsx-run ~/.cursor/skills/
cp -r skills/opsx-run ~/.agents/skills/
cp -r skills/opsx-run ~/.codex/skills/
cp -r skills/opsx-run ~/.config/opencode/skills/
chmod +x ~/.claude/skills/opsx-run/*.sh ~/.cursor/skills/opsx-run/*.sh \
         ~/.agents/skills/opsx-run/*.sh ~/.codex/skills/opsx-run/*.sh \
         ~/.config/opencode/skills/opsx-run/*.sh
cp agents/opsx-applier.md ~/.claude/agents/
cp agents/opsx-qa.md ~/.claude/agents/
# Cursor CLI subagent (name + description frontmatter only):
awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' agents/opsx-applier.md \
  | { printf '%s\n' '---' 'name: ops-applier' \
      'description: Run when asked to implement features, apply changes, or execute OpenSpec apply tasks using a git worktree' \
      '---'; cat; } > ~/.cursor/agents/opsx-applier.md
awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' agents/opsx-qa.md \
  | { printf '%s\n' '---' 'name: ops-qa' \
      'description: Run after ops-applier to validate UI/UX and catch visual regressions. Do not implement fixes.' \
      '---'; cat; } > ~/.cursor/agents/opsx-qa.md
```

Skills and commands are generated by the CLI rather than vendored here, so they always match the OpenSpec version you actually have installed.

---

## Setting up OpenSpec in a project

`./install.sh` already puts OpenSpec skills and `/opsx:*` commands in your **global** agent dirs. Per project you only need the OpenSpec data folders:

```bash
openspec init --tools none
```

Or pass `--tools claude` / `cursor` / … if you also want project-local copies (they override the global ones). That creates:

```
openspec/
├── changes/          # active change proposals
│   └── archive/      # completed ones
└── specs/            # the living specification
```

`--tools` also accepts `all`, `none`, or a comma-separated list (`claude,cursor,codex`, …) if you use more than one assistant. Useful CLI commands:

```bash
openspec list                              # active changes and their task progress
openspec show <change>                     # read a change
openspec status --change <change> --json   # artifact completion
openspec validate <change> --strict        # validate a change
openspec archive <change> -y               # archive a finished change
openspec update                            # refresh instruction files after a CLI upgrade
```

---

## Usage

Propose a change the normal OpenSpec way, then hand it to tmux-opsx:

```
/opsx:propose "add rate limiting to the public API"    # creates openspec/changes/add-rate-limiting/
/opsx-run add-rate-limiting                            # applies it in its own tmux window
```

| Command | What happens |
|---|---|
| `/opsx-run <change>` | Same as `apply`. Creates the window — and the session, if you're outside tmux — on first use |
| `/opsx-run <change> apply` | Checks the change is applyable, then dispatches the apply to ops-applier |
| `/opsx-run <change> apply --agent-cli agent` | Same, but launches the window with Cursor CLI (`agent` on Linux) |
| `/opsx-run <change> apply --agent-cli claude` | Same, but launches with Claude Code |
| `/opsx-run <change> apply --agent-cli codex` | Same, but launches with Codex CLI (applies directly — no subagent) |
| `/opsx-run <change> apply --agent-cli opencode` | Same, but launches with OpenCode (Task / `@ops-applier`) |
| `/opsx-run <change> apply --model sonnet-4` | Same, but pins the apply window's model (default: the session that ran `/opsx-run`) |
| `/opsx-run <change> apply --validate` | Apply, then **this session** `/goal`: run ops-qa; on FAIL send findings to ops-applier until PASS |
| `/opsx-run <change> verify` | Runs `openspec validate --strict` + `status` **inline** and reports; only bothers the window if it fails |
| `/opsx-run <change> qa` | One-shot **ops-qa** in the change window (creates it if needed). No auto-fix |
| `/opsx-run <change> archive` | Gates on validate + all tasks complete, then dispatches the archive |
| `/opsx-run <change> status` | Snapshot of what that window is doing right now |
| `/opsx-run <change> "<text>"` | Sends any instruction to that change's window (creates the window if it was closed) |
| `/opsx-run <change> merge` | Merges the change branch into `main` (`--no-ff`). Keeps the branch, worktree and window |
| `/opsx-run <change> merge --into develop` | Same, into another branch |
| `/opsx-run <change> land` | Merge (via `opsx-merge.sh`) + archive + delete branch + close the window |
| `/opsx-run <change> land --into develop` | Same, into another branch |
| `/opsx-run <change> land --force-tasks` | Same, but skips the unchecked-tasks gate |
| `/opsx-run <change> land --skip-merge` | Already merged: skip merge, still archive + cleanup |
| `/opsx-run <change> close` | Closes that change's window |
| `/opsx-run close-all` | Closes every tmux-opsx window in the session (asks first) |
| `/opsx-run list` | Shows the windows in the current session (or the project's, from outside tmux) |

### The whole arc

```bash
/opsx:propose "add rate limiting to the public API"   # write proposal/design/specs/tasks
/opsx-run add-rate-limiting                           # window opens, ops-applier implements on opsx/add-rate-limiting
/opsx-run add-rate-limiting status                    # peek without leaving your session
/opsx-run add-rate-limiting "also cover the admin routes"   # steer it, same window
/opsx-run add-rate-limiting verify                    # validate --strict + status, inline
/opsx-run add-rate-limiting apply --validate          # apply + ops-qa; this session /goal until PASS
/opsx-run add-rate-limiting qa                        # one-shot UI/UX QA
/opsx-run add-rate-limiting land                      # merge, archive, delete branch, close window
git push origin main                                  # you push, never the tool
```

Jump to a change's window with `tmux select-window -t <session>:<change>`, or your usual prefix + window number. If the session was created for you, `tmux attach -t <project-folder>` gets you in.

`verify` and `archive` run their read-only `openspec` checks in your **calling** session on purpose: they are fast, and a failed gate should reach you immediately rather than sit unread in a window you are not watching.

### The helper script

Everything tmux-related goes through one script, which you can also drive by hand:

```bash
~/.claude/skills/opsx-run/opsx-window.sh ensure <change> --prompt-file <f> [--cwd <dir>] [--agent-cli <cmd>] [--model <id>]
~/.claude/skills/opsx-run/opsx-window.sh send   <change> --prompt-file <f>
~/.claude/skills/opsx-run/opsx-window.sh close  <change> [--force] [--keep-session]
~/.claude/skills/opsx-run/opsx-window.sh close  --all    [--force] [--keep-session]
~/.claude/skills/opsx-run/opsx-window.sh status <change> [--lines N]
~/.claude/skills/opsx-run/opsx-window.sh mark   <change> <busy|done|fail|idle>
~/.claude/skills/opsx-run/opsx-window.sh list

~/.claude/skills/opsx-run/opsx-merge.sh <change> [--into <branch>] [--dry-run]
~/.claude/skills/opsx-run/opsx-land.sh <change> [--into <branch>] [--skip-merge] [--force-tasks] [--dry-run]
```

`opsx-window.sh` prints one line — `created @7 2:add-auth`, `reused @7 2:add-auth`, `sent @7 2:add-auth`, or `marked @7 2:add-auth status=idle`. Called from outside tmux, `ensure` appends `session=created` when it had to start the session, plus an `# attach with: …` hint.

Windows show work state in the **title and status-bar color**: `·change` (idle/done, cyan — reusable, not tmux default), `…change` (busy, yellow), `✗change` (fail, red). `mark done` is treated as idle so follow-ups reuse the same window. If a busy window goes silent for ~40s (`$OPSX_IDLE_SILENCE`) without `mark done`/`fail`, it falls back to idle so it does not stay yellow. Lookups use the `@opsx_change` tag, so badges do not break later commands.

Session names come from the project folder with `.`, `:` and whitespace folded to `-`, since tmux treats `.` and `:` as target separators — `~/code/my.app` becomes the session `my-app`.

---

## How it works

1. **Preconditions.** The skill refuses to guess a change name — if it is missing or ambiguous it lists the active changes and asks.
2. **Session.** Inside tmux, the window goes in your current session. Outside tmux, it creates (or reuses) a **session named after the project folder** and tells you how to attach.
3. **Window.** `opsx-window.sh` finds a window by `@opsx_change` (or creates one with `tmux new-window -n <change> -c <project>`) running the detected agent CLI (`claude --permission-mode bypassPermissions`, `agent --force --approve-mcps --trust` for Cursor, `codex --dangerously-bypass-approvals-and-sandbox` for Codex, or `opencode --auto --prompt …` for OpenCode) with a dispatcher prompt. Pass `--agent-cli claude|agent|cursor|codex|opencode` to override, or set `$OPSX_AGENT_CLI`. Pass `--model <id>` (or `$OPSX_MODEL`) to pin the model; the default is this session's model (Cursor `selectedModel`, else `$ANTHROPIC_MODEL` / Claude settings / Codex `~/.codex/config.toml` / OpenCode `~/.config/opencode/opencode.json{,c}`). From a Cursor CLI session (`$CURSOR_AGENT` set), new windows default to `agent`; from a Codex session, to `codex`; from OpenCode, to `opencode`. New work marks the window **busy** (`…change`, yellow). When the agent finishes it marks **done** (shown as idle: `·change`, cyan — reusable) or **fail** (`✗change`, red). Idle waiting is cyan, not tmux default. If the agent never marks, busy falls back to idle after ~40s of pane silence. `automatic-rename` / `allow-rename` stay off so the badge is not overwritten by the process name.
4. **Dispatch.** On Claude/Cursor/OpenCode the window delegates to **ops-applier** (apply) or **ops-qa** (qa). Cursor CLI only loads project agents from `.cursor/agents/` — `ensure` symlinks both agents into the project. OpenCode `ensure` links them into `.opencode/agents/`. Codex usually does the work in the window. **`apply --validate`:** the **calling** session uses `/goal` — after apply it runs ops-qa and sends FAIL findings back to ops-applier until PASS. Plain apply does not run QA.
5. **Apply.** The applier implements in a git worktree on **`opsx/<change>`**, then build/commit/report. QA only runs on `apply --validate` or `/opsx-run <change> qa`. Parallel workers are opt-in.
6. **Reuse.** Later instructions are typed into the same window with `tmux send-keys -l` (literal, so `;`, `Enter` and control-sequences in your text stay text) and submitted.

Windows are targeted by tmux **window id** (`@7`), never by index or name, so renames and reordering can't misdirect a send. Each one is also stamped with an `@opsx_change` tmux option, which is how `close --all` finds exactly the windows tmux-opsx created.

### Merging a change

Merge the applied branch into `main` (or another target) without finishing the OpenSpec lifecycle:

```bash
/opsx-run add-auth merge                 # into main
/opsx-run add-auth merge --into develop  # into another branch
```

**clean tree → find `opsx/<change>` (or its worktree) → merge `--no-ff`.** The change branch, worktree and tmux window stay. `land` uses this same script (`opsx-merge.sh --stay`) before it archives.

If the change is checked out in a worktree with uncommitted files, merge refuses until those are committed.

### Landing a change

When a change is done, one command finishes it:

```bash
/opsx-run add-auth land                 # into main
/opsx-run add-auth land --into develop  # into another branch
```

**OpenSpec gates → `opsx-merge.sh --stay` → `openspec archive` → commit → remove worktree → delete branch → close window.**

Nothing happens unless every gate passes:

| Gate | Why |
|---|---|
| `openspec validate <change> --strict` | The change itself must be well-formed |
| All artifacts present | Proposal/design/specs/tasks exist |
| **Every task in `tasks.md` checked** | `openspec status`'s `isComplete` only means the *artifacts* exist — it is true with tasks still unchecked, so the checkboxes are counted directly |
| Clean working tree | Land auto-stashes dirty WIP (incl. untracked), then restores it after. A dirty **change worktree** still blocks merge until those files are committed |
| Branch found | Discovery must pick the change branch |
| Branch ahead of the target | If it is **already merged**, land stops with `ALREADY_MERGED` (exit 2) and asks whether to `--skip-merge` and still archive + clean up |

Run it with `--dry-run` first to see exactly what it would do. Other flags: `--branch <name>` when discovery guesses wrong, `--skip-specs` for tooling/doc changes, `--force-tasks` to land with unchecked boxes still in `tasks.md`, `--skip-merge` when the branch is already in the target, `--no-close`, `--keep-branch`, `--keep-worktree`.

**It never pushes.** The merge, archive and commit stay local, and it prints the `git push origin <branch>` to run when you're ready.

**Branch discovery**: `--branch` wins, then `opsx/<change>`, `feat/<change>`, `feature/<change>`, `<change>`, then a single fuzzy `*<change>*` match. Several fuzzy matches and it lists them rather than guessing. The ops-applier agent creates `opsx/<change>`, so the first candidate normally hits.

**On conflict** the merge is aborted, you land back on the branch you started from with a clean tree, and the conflicting paths are printed. Resolve them in the change's window and land again:

```bash
/opsx-run add-auth "resolve the conflicts merging opsx/add-auth into main"
```

If you were sitting *on* the change branch when you landed it, it stays on the target branch afterwards and tells you — it won't try to restore a branch it just deleted.

### Closing windows

```bash
/opsx-run add-auth close      # close one change's window
/opsx-run close-all           # close all of them (confirms first)
```

Closing kills the agent session in that window along with anything it still had in flight; worktrees, commits and files already written stay on disk.

- `--all` only matches windows tmux-opsx created — your own windows in the same session are never touched.
- It refuses to close the window you are currently *in* unless you pass `--force`, so `close-all` from inside a change window can't pull the rug out from under itself.
- Closing the last window of a session ends the session (tmux behaviour) and the script tells you. `--keep-session` parks a plain shell window instead so the session survives.

---

## Troubleshooting

**Running outside tmux** — that's fine: `/opsx-run <change>` starts a detached session named after the project folder and puts the change window in it. It tells you the name; attach with `tmux attach -t <project>`. `apply`, `archive`, and free-form instructions all create the window (and the session, if needed) when it is missing. `status` and `list` only look it up. `/opsx-run` never falls back to running the work inline, because the whole point is not blocking your session.

**The window is named `claude` instead of the change** — something re-enabled tmux's automatic rename. The script disables it per window at creation; check `tmux show-window-options -t <win> automatic-rename`.

**`/opsx:*` commands or OpenSpec skills don't appear** — restart the agent CLI. `./install.sh` copies them into global dirs (`~/.claude/skills/openspec-*`, `~/.cursor/skills/openspec-*`, …). A project's own `.claude/` / `.cursor/` / `.opencode/` copies still take precedence when present.

**Window ran but nothing happened** — attach to it and look. The dispatcher session is a normal Claude session; it may be asking a question. `/opsx-run <change> status` prints its recent output without leaving your session.

**`merge`/`land` says "no branch found"** — the change was never applied, or its branch is named something discovery doesn't reach. `git branch --list "*<change>*"` will show it; pass it with `--branch <name>`. Branches created before the `opsx/<change>` convention are the usual cause.

**`land` says tasks are still unchecked** — that gate reads `- [ ]` boxes in `openspec/changes/<change>/tasks.md` directly, because `openspec status`'s `isComplete` only tells you the artifacts exist and stays `true` with tasks outstanding. Finish them (or tick them) and land again, or pass `--force-tasks` if you are deliberately landing with outstanding boxes.

**`merge`/`land` hit conflicts** — nothing was written: the merge is aborted and you are back on your starting branch with a clean tree. Resolve in the change's window, then merge (or land) again. If land had stashed WIP, it is restored automatically on exit.

**`land` with a dirty working tree** — land stashes local WIP (including untracked), finishes merge/archive/cleanup, then `stash pop`s. If the pop conflicts, the stash entry remains — `git stash list` / `git stash pop` by hand.

**`land` says already merged** — the change branch has no commits the target is missing (squash, merge, or cherry-pick already landed). Archive and cleanup did not run. `/opsx-run` asks whether to skip the merge and finish those steps (`--skip-merge`); it will not tell you to archive by hand.

**npm permission errors on install** — either `sudo npm install -g @fission-ai/openspec`, or point npm at a writable prefix with `npm config set prefix ~/.local`.

---

## Notes and limits

- Windows launch with permission bypass (`claude --permission-mode bypassPermissions`, `agent --force --approve-mcps --trust`, `codex --dangerously-bypass-approvals-and-sandbox`, or `opencode --auto --prompt …`) so they never stall on a prompt while unattended. `--approve-mcps` loads `~/.cursor/mcp.json` (browser-use) into the Cursor tmux window; OpenCode uses `--auto`. Cursor Task subagents often still lack MCP — the dispatcher then runs browser-use MCP itself. A Codex window applies the change itself. Everything they do happens in git worktrees, and the agent reports its branch back.
- Landing never pushes, and it is the only command that writes to your git history. Everything else is confined to tmux and the OpenSpec files.
- The `ops-applier` agent has no `Skill` tool, so it drives the `openspec` CLI directly (`openspec instructions apply --change <c> --json`) instead of calling `/opsx:apply`. That is the same work the command describes. Add `Skill` to its `tools:` list in `agents/opsx-applier.md` if you want it to use the command instead.
- Back-to-back sends to the same window are spaced slightly, because the Claude TUI can concatenate two prompts into one input box otherwise.

## License

MIT
