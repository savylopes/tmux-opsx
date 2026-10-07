# tmux-opsx

My personal development harness for agent CLIs. It runs [OpenSpec](https://github.com/Fission-AI/OpenSpec) changes in Claude Code, Cursor CLI, Codex CLI, OpenCode, or Gemini CLI without blocking your session, checks them with eval, review, security and QA gates, and gives every CLI the same memory — all wired in by one installer.

```
 your dev harness
 ├── workflow     /opsx-run: change → window → apply → gates → merge/land
 ├── gates        ops-eval · ops-reviewer · ops-security · ops-qa
 ├── context      memory · fork
 ├── sharing      /expose: local port → public https://<name>--<project>.<domain> (opt-in)
 └── portability  install.sh → Claude Code · Cursor CLI · Codex CLI · OpenCode · Gemini CLI
```

**One change = one tmux window, named after the change.** `/opsx-run add-auth` opens a window called `add-auth` running an agent session (Claude Code, Cursor CLI — the `agent` command on Linux —, Codex CLI, OpenCode, or Gemini CLI). On Claude/Cursor/OpenCode it hands the implementation to the **ops-applier** subagent; a Codex or Gemini window applies the change itself in an isolated git worktree. You keep your prompt. Every later instruction about that change goes back into the same window, so each change keeps one long-lived conversation you can jump into at any time.

Not in tmux? It starts a session named after the project folder for you.

```
┌ tmux session ─────────────────────────────────────────────┐
│ 0:agent*   1:add-auth  2:rate-limiting  3:fix-webhooks    │
│    claude/agent/opencode ─> Task/Agent(ops-applier) ─> worktree │
│    codex/gemini ──────────> (applies directly) ──────> worktree │
└───────────────────────────────────────────────────────────┘

  /opsx-run add-auth ......... window opens, work starts
  /opsx-run add-auth verify .. gates run in your session
  /opsx-run add-auth apply --validate .. apply + eval + review + security + qa; change window /goal until PASS
  /opsx-run add-auth eval ...... one-shot spec eval (evals/ checks per scenario)
  /opsx-run add-auth review .... one-shot implementation review
  /opsx-run add-auth security .. one-shot security review
  /opsx-run add-auth qa ...... one-shot UI/UX QA
  /opsx-run add-auth qa "..." extra notes for ops-qa
  /opsx-run qa "..." ......... same, pick the change if omitted
  /opsx-run add-auth merge ... merge into main (branch/window stay)
  /opsx-run add-auth land .... merge + archive + cleanup, window closes
```

---

## Contents

| Piece | Installs to | What it does |
|---|---|---|
| `/opsx-run` skill | `~/.claude/skills/opsx-run/` · `~/.cursor/skills/opsx-run/` · `~/.agents/skills/opsx-run/` · `$CODEX_HOME/skills/opsx-run/` · `~/.config/opencode/skills/opsx-run/` · `~/.gemini/skills/opsx-run/` | The lifecycle: apply, verify, archive, land, close — one window per change |
| `opsx-window.sh` | `~/.claude/skills/opsx-run/` | All tmux mechanics — session/window lookup, literal-text sends, rename suppression, closing |
| `opsx-merge.sh` | `~/.claude/skills/opsx-run/` | Merge the change branch into a target (default `main`) — no archive or cleanup |
| `opsx-land.sh` | `~/.claude/skills/opsx-run/` | Landing a change — OpenSpec gates, eval regression gate, then `opsx-merge.sh`, archive, branch/worktree cleanup |
| `opsx-eval.sh` | `~/.claude/skills/opsx-run/` | Runs a repo's saved eval suite (`evals/`) with no LLM — scorecard, coverage, `--json`, regression compare |
| `ops-applier` subagent | `~/.claude/agents/opsx-applier.md` · `~/.cursor/agents/opsx-applier.md` · `~/.codex/agents/ops-applier.toml` · `~/.config/opencode/agents/ops-applier.md` · `~/.gemini/agents/opsx-applier.md` | Implements the change in an isolated worktree on `opsx/<change>` |
| `ops-eval` subagent | `~/.claude/agents/opsx-eval.md` · `~/.cursor/agents/opsx-eval.md` · `~/.codex/agents/ops-eval.toml` · `~/.config/opencode/agents/ops-eval.md` · `~/.gemini/agents/opsx-eval.md` | Spec eval gate: one executable check per scenario under `evals/`. Runs on `apply --validate` or `/opsx-run <change> eval` |
| `ops-reviewer` subagent | `~/.claude/agents/opsx-reviewer.md` · `~/.cursor/agents/opsx-reviewer.md` · `~/.codex/agents/ops-reviewer.toml` · `~/.config/opencode/agents/ops-reviewer.md` · `~/.gemini/agents/opsx-reviewer.md` | Implementation review gate. Runs on `apply --validate` or `/opsx-run <change> review` |
| `ops-security` subagent | `~/.claude/agents/opsx-security.md` · `~/.cursor/agents/opsx-security.md` · `~/.codex/agents/ops-security.toml` · `~/.config/opencode/agents/ops-security.md` · `~/.gemini/agents/opsx-security.md` | Security review gate. Runs on `apply --validate` or `/opsx-run <change> security` |
| `ops-qa` subagent | `~/.claude/agents/opsx-qa.md` · `~/.cursor/agents/opsx-qa.md` · `~/.codex/agents/ops-qa.toml` · `~/.config/opencode/agents/ops-qa.md` · `~/.gemini/agents/opsx-qa.md` | UI/UX gate. Runs on `apply --validate` (dispatcher window `/goal`) or `/opsx-run <change> qa` / `/opsx-run qa "..."` |
| `/opsx:*` commands + OpenSpec skills | global Claude / Cursor / Codex / OpenCode / Gemini dirs | OpenSpec propose/apply/archive/explore — installed globally by `./install.sh` |
| `/graphify` skill | `~/.claude/skills/graphify/` · `~/.cursor/skills/graphify/` · `~/.agents/skills/graphify/` · `~/.codex/skills/graphify/` · `~/.config/opencode/skills/graphify/` · `~/.gemini/skills/graphify/` | Graphify knowledge-graph skill — installed globally after the CLI is verified |
| OpenSpec CLI | npm global | `openspec` — the spec/change engine everything is built on |
| Graphify CLI | uv tool / pipx | `graphify` — required for `/graphify` |
| Graphify always-on wiring | `~/.claude/CLAUDE.md` · `~/.gemini/GEMINI.md` (marked block `<!-- tmux-opsx:graphify:start -->` … `:end -->`) · `~/.gemini/settings.json` (`BeforeTool` hook) · `~/.config/opencode/plugins/graphify.js` | Tells each agent to consult the knowledge graph. `graphify install` writes the Gemini/OpenCode parts into the current directory; the installer runs it in a scratch dir and lifts them into the global config so nothing lands in a project checkout |
| `memory` skill | `~/.claude/skills/memory/` · `~/.cursor/skills/memory/` · `~/.agents/skills/memory/` · `~/.codex/skills/memory/` · `~/.config/opencode/skills/memory/` · `~/.gemini/skills/memory/` | Shared cross-agent memory protocol — read/save/update/forget, project tagging, safe concurrent writes |
| Memory instruction block | `CLAUDE.md` (Claude config dir) · `~/.codex/AGENTS.md` · `~/.config/opencode/AGENTS.md` · `~/.gemini/GEMINI.md` | Marked block (`<!-- tmux-opsx:memory:start -->` … `:end -->`) telling each agent to use the shared store |
| Memory store | `~/.agents/memory/` | Plain folder: `MEMORY.md` index + `user/` `feedback/` `project/` `reference/` — created once, never overwritten |
| `/fork` skill + `fork.sh` | `~/.claude/skills/fork/` · `~/.cursor/skills/fork/` · `~/.agents/skills/fork/` · `$CODEX_HOME/skills/fork/` · `~/.config/opencode/skills/fork/` · `~/.gemini/skills/fork/` | Read-only side-question agent in a tmux pane, briefed with the current context; notify-then-pull results (see [Fork](#fork)) |
| `/expose` skill + `expose.sh` (opt-in, `--expose-domain`) | `~/.claude/skills/expose/` · `~/.cursor/skills/expose/` · `~/.agents/skills/expose/` · `$CODEX_HOME/skills/expose/` · `~/.config/opencode/skills/expose/` · `~/.gemini/skills/expose/` | Publish `127.0.0.1:<port>` at `https://<name>--<project>.<domain>` through Caddy; list/down/url (see [Expose](#expose)) |
| Expose proxy (opt-in) | `~/.config/tmux-opsx/{expose.env,caddy.json,tmux-opsx-caddy.service}` · `~/.local/share/tmux-opsx/bin/caddy` | Caddy with `caddy-dns/cloudflare`: one wildcard cert via DNS-01, `:443` only, admin API on a user-only unix socket |

---

## Requirements

- **tmux** — every change runs in a tmux window (you don't have to be inside a session; one is created per project if needed)
- **git** — the ops-applier agent works in worktrees
- **Node.js + npm** — to install the OpenSpec CLI
- **Graphify** (`graphify`) — verified on install; installed with `uv tool install graphifyy` if missing
- **Claude Code** (`claude`), **Cursor CLI** (`agent` on Linux), **Codex CLI** (`codex`), **OpenCode** (`opencode`), **or Gemini CLI** (`gemini`) — each window runs one of these (at least one must be on PATH)
- **uv** (`uvx`) — used to run the **browser-use** MCP server for Gemini, Codex, and OpenCode (optional; skip with `--skip-mcp`)
- macOS or Linux

---

## Install

```bash
git clone git@github.com:savylopes/tmux-opsx.git
cd tmux-opsx
./install.sh
```

The installer checks prerequisites, installs the OpenSpec CLI, installs OpenSpec **skills and `/opsx:*` commands globally** for Claude Code, Cursor, Codex, OpenCode, and Gemini, verifies **Graphify** and copies `/graphify` into those same global skill dirs, installs the tmux-opsx subagent and `/opsx-run` skill, registers the **browser-use** MCP server for Gemini, Codex, and OpenCode, and sets up the shared **memory** store (see [Memory](#memory) below).

```
./install.sh --prefix <dir>     # Claude config dir (default ~/.claude, or $CLAUDE_CONFIG_DIR)
./install.sh --skip-openspec    # leave the OpenSpec CLI alone
./install.sh --skip-graphify    # don't verify/install Graphify or copy /graphify
./install.sh --skip-commands    # don't install global OpenSpec skills / /opsx:* commands
./install.sh --skip-mcp         # don't install the browser-use MCP server
./install.sh --skip-memory      # don't install the memory skill, instruction blocks, store, or import
./install.sh --skip-fork        # don't install the /fork skill
./install.sh --expose-domain dev.example.com  # also set up /expose (opt-in; see Expose)
./install.sh --no-backup        # overwrite without keeping .bak copies
./install.sh --uninstall        # remove everything except the OpenSpec and Graphify CLIs
```

Run it as the user who will use the agent CLIs; `sudo` is not needed. On a VPS where root is the login user, `./install.sh` as root is fine and installs under `/root`. If a normal user runs `sudo ./install.sh`, the files still go into that user's home, not `/root`.

**Restart your agent CLI afterwards** (Claude Code, Cursor, Codex, OpenCode, or Gemini) so it picks up the new skill, subagent, and commands.

### Manual install

If you would rather not run the script:

```bash
npm install -g @fission-ai/openspec                      # 1. the CLI

tmp=$(mktemp -d)                                         # 2. global OpenSpec skills + commands
(cd "$tmp" && openspec init --tools claude,cursor,codex,opencode,gemini .)
mkdir -p ~/.claude/skills ~/.claude/commands \
         ~/.cursor/skills ~/.cursor/commands \
         ~/.codex/skills ~/.agents/skills \
         ~/.config/opencode/skills ~/.config/opencode/commands \
         ~/.gemini/skills ~/.gemini/commands
cp -R "$tmp"/.claude/skills/openspec-* ~/.claude/skills/
cp -R "$tmp"/.claude/commands/opsx ~/.claude/commands/
cp -R "$tmp"/.cursor/skills/openspec-* ~/.cursor/skills/
cp "$tmp"/.cursor/commands/opsx-*.md ~/.cursor/commands/
cp -R "$tmp"/.agents/skills/openspec-* ~/.codex/skills/    # Codex: openspec emits Agent Skills
cp -R "$tmp"/.agents/skills/openspec-* ~/.agents/skills/
cp -R "$tmp"/.opencode/skills/openspec-* ~/.config/opencode/skills/
cp "$tmp"/.opencode/commands/opsx-*.md ~/.config/opencode/commands/
cp -R "$tmp"/.gemini/skills/openspec-* ~/.gemini/skills/ 2>/dev/null || true
rm -rf "$tmp"

gtmp=$(mktemp -d)                                        # 2b. global /graphify
(cd "$gtmp" && graphify install --platform claude,codex,opencode,agents,gemini)
# graphify drops its Gemini/OpenCode wiring into the *current* dir — move it global:
mkdir -p ~/.gemini ~/.config/opencode/plugins ~/.cursor/skills/graphify
cat "$gtmp"/GEMINI.md >> ~/.gemini/GEMINI.md             # "## graphify" section
#   merge "$gtmp"/.gemini/settings.json hooks.BeforeTool into ~/.gemini/settings.json
cp "$gtmp"/.opencode/plugins/graphify.js ~/.config/opencode/plugins/   # auto-loaded
cp -R ~/.claude/skills/graphify/. ~/.cursor/skills/graphify/
rm -rf "$gtmp"

mkdir -p ~/.claude/skills ~/.claude/agents ~/.cursor/agents ~/.cursor/skills \
         ~/.agents/skills ~/.codex/skills ~/.codex/agents \
         ~/.config/opencode/skills ~/.config/opencode/agents \
         ~/.gemini/skills ~/.gemini/agents   # 3. tmux-opsx skill + subagents
cp -r skills/opsx-run ~/.claude/skills/
cp -r skills/opsx-run ~/.cursor/skills/
cp -r skills/opsx-run ~/.agents/skills/
cp -r skills/opsx-run ~/.codex/skills/
cp -r skills/opsx-run ~/.config/opencode/skills/
cp -r skills/opsx-run ~/.gemini/skills/
chmod +x ~/.claude/skills/opsx-run/*.sh ~/.cursor/skills/opsx-run/*.sh \
         ~/.agents/skills/opsx-run/*.sh ~/.codex/skills/opsx-run/*.sh \
         ~/.config/opencode/skills/opsx-run/*.sh ~/.gemini/skills/opsx-run/*.sh
cp agents/opsx-applier.md ~/.claude/agents/
cp agents/opsx-qa.md ~/.claude/agents/
cp agents/opsx-applier.md ~/.gemini/agents/
cp agents/opsx-qa.md ~/.gemini/agents/
cp agents/opsx-reviewer.md ~/.claude/agents/
cp agents/opsx-reviewer.md ~/.gemini/agents/
cp agents/opsx-security.md ~/.claude/agents/
cp agents/opsx-security.md ~/.gemini/agents/
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

## Workflow (`/opsx-run`)

One change = one tmux window: propose it with OpenSpec, apply it in its own window, run the gates, then merge or land it.

### Setting up OpenSpec in a project

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

### Usage

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
| `/opsx-run <change> apply --agent-cli gemini` | Same, but launches with Gemini CLI (applies directly — no subagent) |
| `/opsx-run <change> apply --model sonnet-4` | Same, but pins the apply window's model (default: the session that ran `/opsx-run`) |
| `/opsx-run <change> apply --validate` | Fire-and-forget: change window `/goal` runs apply → eval → review → security → qa → fixes until all PASS/SKIP. Caller is not blocked |
| `/opsx-run <change> verify` | Runs `openspec validate --strict` + `status` **inline** and reports; only bothers the window if it fails |
| `/opsx-run <change> eval` | One-shot **ops-eval** in the change window: writes/updates `evals/` checks for the change's scenarios, runs them, judges failures. No auto-fix |
| `/opsx-run <change> eval --agentic` | Same, plus L3 (agent-in-the-loop) checks |
| `/opsx-run eval` | Same as `eval`; pick the change (`eval` is the action, not a change name) |
| `/opsx-run <change> review` | One-shot **ops-reviewer** in the change window (creates it if needed). No auto-fix |
| `/opsx-run <change> review "..."` | Same, plus extra notes passed through to ops-reviewer |
| `/opsx-run review "..."` | Same as `review` with extra notes; pick the change if it was omitted |
| `/opsx-run <change> security` | One-shot **ops-security** in the change window (creates it if needed). No auto-fix |
| `/opsx-run <change> security "..."` | Same, plus extra notes passed through to ops-security |
| `/opsx-run security "..."` | Same as `security` with extra notes; pick the change if it was omitted |
| `/opsx-run <change> qa` | One-shot **ops-qa** in the change window (creates it if needed). No auto-fix |
| `/opsx-run <change> qa "..."` | Same, plus extra notes passed through to ops-qa |
| `/opsx-run qa "..."` | Same as `qa` with extra notes; pick the change if it was omitted (`qa` is the action, not a change name) |
| `/opsx-run <change> archive` | Gates on validate + all tasks complete, then dispatches the archive |
| `/opsx-run <change> status` | Snapshot of what that window is doing right now |
| `/opsx-run <change> "<text>"` | Sends any instruction to that change's window (creates the window if it was closed) |
| `/opsx-run <change> merge` | Merges the change branch into `main` (`--no-ff`). Keeps the branch, worktree and window |
| `/opsx-run <change> merge --into develop` | Same, into another branch |
| `/opsx-run <change> land` | Merge (via `opsx-merge.sh`) + archive + delete branch + close the window |
| `/opsx-run <change> land --into develop` | Same, into another branch |
| `/opsx-run <change> land --force-tasks` | Same, but skips the unchecked-tasks gate |
| `/opsx-run <change> land --skip-merge` | Already merged: skip merge, still archive + cleanup |
| `/opsx-run <change> land --skip-eval` | Same as `land`, but bypasses the eval regression gate |
| `/opsx-run <change> close` | Closes that change's window |
| `/opsx-run close-all` | Closes every tmux-opsx window in the session (asks first) |
| `/opsx-run list` | Shows the windows in the current session (or the project's, from outside tmux) |

#### The whole arc

```bash
/opsx:propose "add rate limiting to the public API"   # write proposal/design/specs/tasks
/opsx-run add-rate-limiting                           # window opens, ops-applier implements on opsx/add-rate-limiting
/opsx-run add-rate-limiting status                    # peek without leaving your session
/opsx-run add-rate-limiting "also cover the admin routes"   # steer it, same window
/opsx-run add-rate-limiting verify                    # validate --strict + status, inline
/opsx-run add-rate-limiting apply --validate          # apply + eval + review + security + qa; change window /goal until PASS
/opsx-run add-rate-limiting eval                      # one-shot spec eval (checks under evals/)
/opsx-run add-rate-limiting review                    # one-shot implementation review
/opsx-run add-rate-limiting security                  # one-shot security review
/opsx-run add-rate-limiting qa                        # one-shot UI/UX QA
/opsx-run add-rate-limiting qa "check the checkout on mobile"
/opsx-run qa "check the checkout on mobile"           # pick the change, then ops-qa
/opsx-run add-rate-limiting land                      # merge, archive, delete branch, close window
git push origin main                                  # you push, never the tool
```

Jump to a change's window with `tmux select-window -t <session>:<change>`, or your usual prefix + window number. If the session was created for you, `tmux attach -t <project-folder>` gets you in.

`verify` and `archive` run their read-only `openspec` checks in your **calling** session on purpose: they are fast, and a failed gate should reach you immediately rather than sit unread in a window you are not watching.

#### The helper script

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
~/.claude/skills/opsx-run/opsx-land.sh <change> [--into <branch>] [--skip-merge] [--force-tasks] [--skip-eval] [--dry-run]

~/.claude/skills/opsx-run/opsx-eval.sh [--change <c>] [--capability <cap>]... [--all] [--agentic] [--trials N] [--json] [--root <dir>]
~/.claude/skills/opsx-run/opsx-eval.sh --compare <baseline.json> <current.json>
```

`opsx-window.sh` prints one line — `created @7 2:add-auth`, `reused @7 2:add-auth`, `sent @7 2:add-auth`, or `marked @7 2:add-auth status=idle`. Called from outside tmux, `ensure` appends `session=created` when it had to start the session, plus an `# attach with: …` hint.

Windows opened by this tool use a distinct **`ox` title**, a **dark pane**, and muted status-bar colors (the **word color** is the status): `ox ·change` (idle/done, mint), `ox …change` (busy, amber), `ox ✗change` (fail, rose). `mark done` is treated as idle so follow-ups reuse the same window. If a busy window goes silent for ~40s (`$OPSX_IDLE_SILENCE`) without `mark done`/`fail`, it falls back to idle. Lookups use the `@opsx_change` tag, so titles do not break later commands.

Session names come from the project folder with `.`, `:` and whitespace folded to `-`, since tmux treats `.` and `:` as target separators — `~/code/my.app` becomes the session `my-app`.

### How it works

1. **Preconditions.** The skill refuses to guess a change name — if it is missing or ambiguous it lists the active changes and asks.
2. **Session.** Inside tmux, the window goes in your current session. Outside tmux, it creates (or reuses) a **session named after the project folder** and tells you how to attach.
3. **Window.** `opsx-window.sh` finds a window by `@opsx_change` (or creates one with `tmux new-window -n <change> -c <project>`) running the detected agent CLI (`claude --permission-mode bypassPermissions`, `agent --force --approve-mcps --trust` for Cursor, `codex --dangerously-bypass-approvals-and-sandbox` for Codex, `opencode --auto --prompt …` for OpenCode, or `gemini --approval-mode=yolo --skip-trust -i …` for Gemini) with a dispatcher prompt. Pass `--agent-cli claude|agent|cursor|codex|opencode|gemini` to override, or set `$OPSX_AGENT_CLI`. Pass `--model <id>` (or `$OPSX_MODEL`) to pin the model; the default is this session's model (Cursor `selectedModel`, else `$ANTHROPIC_MODEL` / Claude settings / Codex `~/.codex/config.toml` / OpenCode `~/.config/opencode/opencode.json{,c}` / Gemini `$GEMINI_MODEL` or `~/.gemini/settings.json`). From a Cursor CLI session (`$CURSOR_AGENT` set), new windows default to `agent`; from a Codex session, to `codex`; from OpenCode, to `opencode`; from Gemini, to `gemini`. New work marks the window **busy** (`ox …change`, amber on dark). When the agent finishes it marks **done** (idle: `ox ·change`, mint on dark) or **fail** (`ox ✗change`, rose on dark). The pane stays dark; word color is the status. If the agent never marks, busy falls back to idle after ~40s of pane silence. `automatic-rename` / `allow-rename` stay off so the badge is not overwritten by the process name.
4. **Dispatch.** On Claude/Cursor/OpenCode the window delegates to **ops-applier** (apply), **ops-eval** (eval), **ops-reviewer** (review), **ops-security** (security), or **ops-qa** (qa). Cursor CLI only loads project agents from `.cursor/agents/` — `ensure` symlinks all agents into the project. OpenCode `ensure` links them into `.opencode/agents/`. Gemini `ensure` links them into `.gemini/agents/`. Codex and Gemini usually do the work in the window. **`apply --validate`:** the **change window** uses `/goal` and loops apply → eval → review → security → qa → fix per gate until all PASS/SKIP. The calling session only starts that window and returns. Plain apply does not run eval, review, security, or QA.
5. **Apply.** The applier implements in a git worktree on **`opsx/<change>`**, then build/commit/report. Reviewer/security/qa only run on `apply --validate` or their standalone actions. Parallel workers are opt-in.
6. **Reuse.** Later instructions are typed into the same window with `tmux send-keys -l` (literal, so `;`, `Enter` and control-sequences in your text stay text) and submitted.

Windows are targeted by tmux **window id** (`@7`), never by index or name, so renames and reordering can't misdirect a send. Each one is also stamped with an `@opsx_change` tmux option, which is how `close --all` finds exactly the windows tmux-opsx created.

#### Merging a change

Merge the applied branch into `main` (or another target) without finishing the OpenSpec lifecycle:

```bash
/opsx-run add-auth merge                 # into main
/opsx-run add-auth merge --into develop  # into another branch
```

**clean tree → find `opsx/<change>` (or its worktree) → merge `--no-ff`.** The change branch, worktree and tmux window stay. `land` uses this same script (`opsx-merge.sh --stay`) before it archives. Review and security PASS are **not** required for merge or land.

If the change is checked out in a worktree with uncommitted files, merge refuses until those are committed.

#### Landing a change

When a change is done, one command finishes it:

```bash
/opsx-run add-auth land                 # into main
/opsx-run add-auth land --into develop  # into another branch
```

**OpenSpec gates → eval baseline → `opsx-merge.sh --stay` → eval regression check → `openspec archive` → commit → remove worktree → delete branch → close window.**

Nothing happens unless every gate passes:

| Gate | Why |
|---|---|
| `openspec validate <change> --strict` | The change itself must be well-formed |
| All artifacts present | Proposal/design/specs/tasks exist |
| **Every task in `tasks.md` checked** | `openspec status`'s `isComplete` only means the *artifacts* exist — it is true with tasks still unchecked, so the checkboxes are counted directly |
| Clean working tree | Land auto-stashes dirty WIP (incl. untracked), then restores it after. A dirty **change worktree** still blocks merge until those files are committed |
| Branch found | Discovery must pick the change branch |
| Branch ahead of the target | If it is **already merged**, land stops with `ALREADY_MERGED` (exit 2) and asks whether to `--skip-merge` and still archive + clean up |

**Not gated on land:** ops-eval, ops-reviewer or ops-security PASS — you can land without ever running them.

**Eval regression gate.** When the target or the change branch has an `evals/` directory, land runs `opsx-eval.sh` (L1 + L2 only — L3 never runs at land) on the target in a temporary worktree (baseline), merges, then runs it on the merged result. A check that **passed on the target and fails after the merge blocks** the land: it prints `EVAL_REGRESSION` and the checks, resets the target to its pre-merge commit, and archives nothing. New failures (no baseline), UNVERIFIABLE and MISSING results only warn. No `evals/` → skipped silently; `--skip-eval` bypasses it; `--skip-merge` skips it (no pre-merge baseline).

Run it with `--dry-run` first to see exactly what it would do. Other flags: `--branch <name>` when discovery guesses wrong, `--skip-specs` for tooling/doc changes, `--force-tasks` to land with unchecked boxes still in `tasks.md`, `--skip-merge` when the branch is already in the target, `--skip-eval` to bypass the eval regression gate, `--no-close`, `--keep-branch`, `--keep-worktree`.

**It never pushes.** The merge, archive and commit stay local, and it prints the `git push origin <branch>` to run when you're ready.

**Branch discovery**: `--branch` wins, then `opsx/<change>`, `feat/<change>`, `feature/<change>`, `<change>`, then a single fuzzy `*<change>*` match. Several fuzzy matches and it lists them rather than guessing. The ops-applier agent creates `opsx/<change>`, so the first candidate normally hits.

**On conflict** the merge is aborted, you land back on the branch you started from with a clean tree, and the conflicting paths are printed. Resolve them in the change's window and land again:

```bash
/opsx-run add-auth "resolve the conflicts merging opsx/add-auth into main"
```

If you were sitting *on* the change branch when you landed it, it stays on the target branch afterwards and tells you — it won't try to restore a branch it just deleted.

#### Closing windows

```bash
/opsx-run add-auth close      # close one change's window
/opsx-run close-all           # close all of them (confirms first)
```

Closing kills the agent session in that window along with anything it still had in flight; worktrees, commits and files already written stay on disk.

- `--all` only matches windows tmux-opsx created — your own windows in the same session are never touched.
- It refuses to close the window you are currently *in* unless you pass `--force`, so `close-all` from inside a change window can't pull the rug out from under itself.
- Closing the last window of a session ends the session (tmux behaviour) and the script tells you. `--keep-session` parks a plain shell window instead so the session survives.

---

## Gates

Gates are subagents that check an applied change and end with `VERDICT: PASS | FAIL | SKIP` plus numbered findings; they never fix product code themselves (ops-eval writes only its checks under `evals/`). `apply --validate` runs them in the change window (eval → review → security → qa) and fixes FAIL findings (via ops-applier, or directly on Codex/Gemini) until every gate is PASS or SKIP. Each one also runs on its own; review/security/qa take optional extra notes. No gate verdict is required for `merge` or `land` (land only runs the saved eval suite for regressions).

### ops-eval

Spec fidelity by execution: every `#### Scenario` in the change's delta specs becomes an executable check under `evals/`, run by `opsx-eval.sh` with no LLM, so the checks stay in the repo as a regression suite. Run it with `/opsx-run <change> eval` (add `--agentic` for L3 checks). Returns SKIP when the repo has no OpenSpec specs, the change has no scenarios, or the diff is markdown-only.

- **Blind:** expected results come only from the specs; ops-eval may read `design.md` and `--help` to learn how to invoke things, never the applier's report, commits or tests.
- **Ownership:** ops-eval is the only writer of `evals/` (its own `eval: <change>` commit). ops-applier never touches `evals/`; if it thinks a check is wrong it reports `DISPUTE F<n>: <reason>` and the next eval round fixes the check or justifies it.
- **Layout:** `evals/eval.yaml` (optional `setup`, `teardown`, `env`, `timeout` — default 60s — and `agentic: {trials, threshold, cli}`) plus `evals/<capability>/<scenario-slug>.check`.
- **Check contract:** any executable with `# scenario: <capability> / <Scenario title>` and `# level: L1|L2|L3` headers. Exit `0` PASS, `77` UNVERIFIABLE, anything else or a timeout FAIL; stdout/stderr is the evidence. Checks get `EVAL_ROOT`, a fresh `EVAL_TMP`, the `env` from `eval.yaml` and whatever `setup` wrote to `$EVAL_ENV_FILE`.
- **Levels:** L1 script/API contracts and L2 environment behaviour (tmux on a private socket, filesystem) always run; L3 agent-in-the-loop checks run only with `--agentic`, N trials, PASS when the pass count reaches `threshold` (default: all trials).
- **Runner:** `opsx-eval.sh --change <c>` also lists scenarios without a check as MISSING; `--json` keeps full evidence; exit 0 no FAIL, 1 FAIL, 2 config/runner error. Usable by hand or in CI. At land it guards against regressions (see [Landing a change](#landing-a-change)).

This repo's own suite config is `evals/eval.yaml` (scratch `HOME` + private tmux server via `evals/setup.sh` / `evals/teardown.sh`).

`bash tests/test-eval.sh` exercises the runner against fixture suites (exit-code mapping, timeout, teardown on failure and interrupt, L3 NOT RUN and pass rate, MISSING, `--json`, compare) and the land gate in scratch repos with a fake `openspec` (regression blocks and restores the target, new failures warn, no `evals/` skips, `--skip-eval`).

### ops-reviewer

Implementation review: spec fidelity, logic, tests and maintainability. Run it with `/opsx-run <change> review ["notes"]`. Returns SKIP for documentation-only or OpenSpec-metadata-only diffs.

### ops-security

Security review: auth, injection, secrets, unsafe defaults and trust boundaries. Run it with `/opsx-run <change> security ["notes"]`. Returns SKIP when the change has no security-relevant surface.

### ops-qa

UI/UX check: visual regressions, broken flows, console errors and accessibility, driven through the browser-use MCP. Run it with `/opsx-run <change> qa ["notes"]` or `/opsx-run qa "notes"`. Returns SKIP when the change has no user-facing UI.

---

## Context

### Memory

`./install.sh` sets up one shared, portable memory store used by every agent CLI, so preferences and project context learned in one tool aren't lost in the others.

```
~/.agents/memory/
├── MEMORY.md      # index — one line per memory, always cheap to read
├── user/
├── feedback/
├── project/
└── reference/
```

Each memory is a Markdown file with `name` / `description` / `type` frontmatter, optionally tagged `project: org/repo` (or a local folder name when there's no git remote) — memories with no `project` tag are global. See `skills/memory/SKILL.md` for the full read/save/forget protocol and safe concurrent writes.

Per CLI, the installer:

- installs the `memory` skill to the same six skill folders as `/opsx-run`;
- writes a short marked instruction block (`<!-- tmux-opsx:memory:start -->` … `:end -->`) into `CLAUDE.md` (Claude config dir), `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`, and `~/.gemini/GEMINI.md` — created if missing, replaced in place on re-run, everything else in the file left alone (with a `.bak.<timestamp>` copy on change);
- creates the `~/.agents/memory/` skeleton only where it's missing — an existing store is never modified;
- imports existing Claude Code memories once (`~/.claude/projects/*/memory/*.md`), tagging each with its source project; the import is idempotent (`~/.agents/memory/.claude-import-done`) and never touches the originals.

**Cursor** has no known global instructions file, so the installer prints the block for you to paste into Cursor Settings → Rules → User Rules. Cursor still gets the `memory` skill installed normally.

```
./install.sh --skip-memory      # skip the skill, instruction blocks, store, and import entirely
```

`./install.sh --uninstall` removes the `memory` skill and the instruction blocks but **never deletes `~/.agents/memory/`** — your memories stay on disk.

### Fork

`/fork` opens a **read-only child agent** beside the one you are talking to, already briefed with the current conversation, so you can ask side questions ("why did we pick X?", "where is Y handled?") without derailing the main thread. It is independent of OpenSpec and `/opsx-run`, and works from Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI. It needs tmux.

```
┌ tmux window ───────────────────────────┬──────────────────────────┐
│ parent agent (%3)                      │ fork 1 (read-only)       │
│  /fork "where are retries handled?"    │  answers questions…      │
│  … keeps working …                     │  /fork return            │
│  [pane title: fork 1 ✓]  <── notify ───│   └ result.md saved      │
│  /fork collect  ─── pulls result.md    │                          │
└────────────────────────────────────────┴──────────────────────────┘
```

| Command | Where | What it does |
|---|---|---|
| `/fork ["question"]` | parent | writes a brief (question + 5–15 lines of context) and opens the child in a side-by-side pane (~40% width) |
| `/fork --vertical …` / `/fork --window …` | parent | split top/bottom, or open a new window `fork-<id>` instead |
| `/fork --cli <claude\|agent\|codex\|opencode\|gemini> …` | parent | child CLI (default: the parent's) |
| `/fork return` | child | saves a short result (answer, evidence, unresolved) and notifies the parent |
| `/fork collect [id]` | parent | reads the result into the parent (default: most recently returned) |
| `/fork list` | parent | id, status, CLI, pane and question of every fork in this tmux session |
| `/fork close <id>` / `--all` | parent | saves a capture if there is no result, kills the pane/window, keeps the state |

With more than one child beside the parent, the window switches to `main-vertical` so the parent stays the large pane.

**Notify, never push.** On return the parent pane gets a tmux message and a title badge (`fork 1 ✓`, also in the pane option `@fork_badge`). Nothing is ever typed into the parent; you decide when to `/fork collect`.

**Read-only children.** Every child starts in its CLI's read-only / plan mode and never with bypass or force flags:

| CLI | Launched as | How `return` gets back |
|---|---|---|
| Claude Code | `claude --permission-mode plan` + an allow rule for exactly `fork.sh return` | `result.md` written directly |
| Codex CLI | `codex --sandbox read-only --ask-for-approval on-request` | sandbox blocks the write; approve that one command, or the marker fallback is used |
| Gemini CLI | `gemini --approval-mode plan -i` | marker fallback (plan mode applies once the folder is trusted) |
| Cursor CLI | `agent --mode ask` | marker fallback |
| OpenCode | `opencode --agent plan --prompt` | marker fallback |

*Marker fallback:* when a child cannot run `fork.sh return`, it prints the result between `<<<FORK-RESULT` and `FORK-RESULT>>>` lines, and `/fork collect` recovers it from the child pane's scrollback (saving it as `result.md`). If there is neither, `collect` returns the tail of the pane, clearly labelled as a raw capture. Full-screen TUIs keep little scrollback, so collect while the block is still on screen.

**State** lives outside the repo, in `${XDG_STATE_HOME:-~/.local/state}/agent-forks/<tmux-session>/<id>/` (`brief.md`, `meta`, `launch.sh`, `result.md`, `capture.txt`). It is kept after `close` and on `--uninstall`; delete old forks by hand when you like.

`bash tests/test-fork.sh` exercises `fork.sh` on a private tmux server with fake agent CLIs (open/return/collect/list/close, badges, layout, marker recovery, concurrent ids).

---

## Sharing

### Expose

`/expose` turns a local port into a public HTTPS URL, so you can open an app running on the VPS from a phone or laptop, or share it, without SSH tunnels. `/expose 3000` publishes `127.0.0.1:3000` at `https://3000--<project>.<domain>`, where `<project>` is the repo's folder name (the same in every worktree). It is opt-in: without `--expose-domain`, the installer sets up nothing expose-related.

```
 browser ──https──> *.dev.example.com:443 ──> Caddy (wildcard cert, DNS-01)
                                                 └─ route web--shop.dev.example.com ──> 127.0.0.1:3000
 expose.sh up/down ──> Caddy admin API (unix socket, user-only) — routes added live, no reload
```

**Exposed URLs are public, with no authentication.** Anyone with the link can reach the app — debug pages, seeded admin accounts and real data included. `up` prints that warning every time.

**Setup** (once per host):

1. In Cloudflare, create an API token scoped to **`Zone:DNS:Edit`** for the one zone (it is used only for the ACME DNS-01 challenge).
2. Add a wildcard DNS record `*.dev.example.com` pointing at the host's public IP, **DNS-only (grey cloud)**. The installer never creates or changes DNS records; it only checks that a random name under the domain resolves to this host, and warns otherwise.
3. Open port **443** in the VPS provider's firewall. Port 80 is not needed (DNS-01 needs no inbound port).
4. Run the installer with the domain. The token is read from `$CLOUDFLARE_API_TOKEN`, or from a hidden prompt when you run it in a terminal; it is never a command-line argument, never printed, and stored only in `~/.config/tmux-opsx/expose.env` (mode 600, in a mode-700 directory). A rerun without a token keeps the stored one.

   ```bash
   read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN   # paste the token, press Enter
   ./install.sh --expose-domain dev.example.com
   ```

   It verifies the token with Cloudflare, downloads Caddy built with `caddy-dns/cloudflare` into `~/.local/share/tmux-opsx/bin/caddy` (or reuses it; `$OPSX_CADDY_BIN` points at your own build), writes the base config and a systemd unit.
5. Run the **one privileged command** the installer prints (it never uses sudo itself; as root it runs this step for you):

   ```bash
   sudo install -m 644 ~/.config/tmux-opsx/tmux-opsx-caddy.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now tmux-opsx-caddy
   ```

   The unit runs Caddy as you, with only the capability to bind `:443`. On macOS no service is installed (a known gap); the installer prints the `caddy run --resume --config …` command to start it by hand.

**Usage** — from the agent (`/expose 3000`, `/expose list`, …) or the script directly:

```bash
EXPOSE=~/.claude/skills/expose/expose.sh  # or the expose/ folder of another CLI's skills dir
"$EXPOSE" up 3000                     # https://3000--<project>.dev.example.com
"$EXPOSE" up 3000 --name web          # https://web--<project>.dev.example.com
"$EXPOSE" up 3000 --name web --project shop   # https://web--shop.dev.example.com
"$EXPOSE" list                        # NAME PROJECT PORT URL UP   (--json for scripts)
"$EXPOSE" url web                     # print + copy the URL again
"$EXPOSE" down web                    # remove by name (down 3000 removes every exposure of port 3000)
```

- Names and projects are lowercased and reduced to `[a-z0-9-]`; a hostname label over 63 characters gets its name part cut and a stable 6-hex hash appended. Re-running `up` with the same name moves it to the new port.
- The URL is the last line of output. It is copied to your local clipboard with OSC 52 (through tmux when reachable, so it works from an agent's Bash tool too), and shown as a clickable OSC 8 link on a terminal. Nothing opens a browser.
- Exit codes: `0` ok, `2` bad usage, `3` not configured (run `install.sh --expose-domain`), `4` proxy not running, `1` other.
- Routes are recorded in `${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/expose/routes/`; every call puts back any route Caddy lost (e.g. after a restart without its autosave).
- **Bind apps to `127.0.0.1`**, not `0.0.0.0`. A dev server listening on all interfaces is also reachable directly at `<server-ip>:<port>`, bypassing Caddy — unless a host firewall allows only 22 and 443.

**tmux hint (OSC 8 links)** — tmux passes hyperlinks through only when the outer terminal is declared to support them. The installer does not edit your `tmux.conf`; add this yourself if you want clickable links inside tmux:

```
set -as terminal-features ',*:hyperlinks'
```

OSC 52 copying through tmux needs `set-clipboard` to be `on` or `external` (anything but `off`).

**Removing expose** (there is no `--uninstall` for it yet):

```bash
sudo systemctl disable --now tmux-opsx-caddy && sudo rm /etc/systemd/system/tmux-opsx-caddy.service && sudo systemctl daemon-reload
rm -rf ~/.config/tmux-opsx ~/.local/share/tmux-opsx ~/.local/state/tmux-opsx/expose
rm -rf ~/.claude/skills/expose ~/.cursor/skills/expose ~/.agents/skills/expose ~/.codex/skills/expose ~/.config/opencode/skills/expose ~/.gemini/skills/expose
```

`bash tests/test-expose.sh` runs `expose.sh` and `install.sh --expose-domain` fully offline: a fake Caddy admin server (`tests/fake-caddy-admin.py`), a fake `caddy`, a fake Cloudflare endpoint, and a private tmux server, in scratch HOMEs.

---

## Supported CLIs

One `./install.sh` wires everything into all five CLIs; each change window runs one of them.

| CLI | Command | Window launched as | Apply | Memory instructions |
|---|---|---|---|---|
| Claude Code | `claude` | `claude --permission-mode bypassPermissions` | ops-applier subagent | `CLAUDE.md` in the Claude config dir |
| Cursor CLI | `agent` (Linux) | `agent --force --approve-mcps --trust` | ops-applier subagent (agents symlinked into `.cursor/agents/`) | paste into Cursor Settings → Rules → User Rules |
| Codex CLI | `codex` | `codex --dangerously-bypass-approvals-and-sandbox` | directly in the window | `~/.codex/AGENTS.md` |
| OpenCode | `opencode` | `opencode --auto --prompt …` | ops-applier via Task / `@ops-applier` (agents linked into `.opencode/agents/`) | `~/.config/opencode/AGENTS.md` |
| Gemini CLI | `gemini` | `gemini --approval-mode=yolo --skip-trust -i …` | directly in the window (agents linked into `.gemini/agents/`) | `~/.gemini/GEMINI.md` |

New windows default to the CLI of the calling session; override with `--agent-cli` or `$OPSX_AGENT_CLI` (see [How it works](#how-it-works)).

---

## Uninstall

```
./install.sh --uninstall
```

Removes the `/opsx-run`, `memory`, `/fork` and `/graphify` skills (including `opsx-eval.sh`), the subagents (ops-applier, ops-eval, ops-reviewer, ops-security, ops-qa), the global OpenSpec skills and `/opsx:*` commands, the memory instruction blocks from every CLI, and graphify's global Gemini block/hook and OpenCode plugin. The OpenSpec and Graphify CLIs stay installed (the script prints how to remove them), browser-use MCP entries are left in place, and neither `~/.agents/memory/` nor fork state (`${XDG_STATE_HOME:-~/.local/state}/agent-forks/`) is ever deleted. The opt-in `/expose` setup is not removed either; see [Expose](#expose) for the manual steps.

---

## Troubleshooting

**Running outside tmux** — that's fine: `/opsx-run <change>` starts a detached session named after the project folder and puts the change window in it. It tells you the name; attach with `tmux attach -t <project>`. `apply`, `archive`, and free-form instructions all create the window (and the session, if needed) when it is missing. `status` and `list` only look it up. `/opsx-run` never falls back to running the work inline, because the whole point is not blocking your session.

**The window is named `claude` instead of the change** — something re-enabled tmux's automatic rename. The script disables it per window at creation; check `tmux show-window-options -t <win> automatic-rename`.

**`/opsx:*` commands or OpenSpec skills don't appear** — restart the agent CLI. `./install.sh` copies them into global dirs (`~/.claude/skills/openspec-*`, `~/.cursor/skills/openspec-*`, `~/.agents/skills/openspec-*` + `~/.codex/skills/openspec-*` for Codex, `~/.gemini/skills/openspec-*`, …). A project's own `.claude/` / `.cursor/` / `.opencode/` / `.gemini/` copies still take precedence when present.

**Window ran but nothing happened** — attach to it and look. The dispatcher session is a normal Claude session; it may be asking a question. `/opsx-run <change> status` prints its recent output without leaving your session.

**`merge`/`land` says "no branch found"** — the change was never applied, or its branch is named something discovery doesn't reach. `git branch --list "*<change>*"` will show it; pass it with `--branch <name>`. Branches created before the `opsx/<change>` convention are the usual cause.

**`land` says tasks are still unchecked** — that gate reads `- [ ]` boxes in `openspec/changes/<change>/tasks.md` directly, because `openspec status`'s `isComplete` only tells you the artifacts exist and stays `true` with tasks outstanding. Finish them (or tick them) and land again, or pass `--force-tasks` if you are deliberately landing with outstanding boxes.

**`merge`/`land` hit conflicts** — nothing was written: the merge is aborted and you are back on your starting branch with a clean tree. Resolve in the change's window, then merge (or land) again. If land had stashed WIP, it is restored automatically on exit.

**`land` with a dirty working tree** — land stashes local WIP (including untracked), finishes merge/archive/cleanup, then `stash pop`s. If the pop conflicts, the stash entry remains — `git stash list` / `git stash pop` by hand.

**`land` says already merged** — the change branch has no commits the target is missing (squash, merge, or cherry-pick already landed). Archive and cleanup did not run. `/opsx-run` asks whether to skip the merge and finish those steps (`--skip-merge`); it will not tell you to archive by hand.

**npm permission errors on install** — either `sudo npm install -g @fission-ai/openspec`, or point npm at a writable prefix with `npm config set prefix ~/.local`.

---

## Notes and limits

- Windows launch with permission bypass (`claude --permission-mode bypassPermissions`, `agent --force --approve-mcps --trust`, `codex --dangerously-bypass-approvals-and-sandbox`, `opencode --auto --prompt …`, or `gemini --approval-mode=yolo --skip-trust -i …`) so they never stall on a prompt while unattended. `--approve-mcps` loads `~/.cursor/mcp.json` (browser-use) into the Cursor tmux window; OpenCode uses `--auto`; Gemini uses YOLO. `./install.sh` also writes browser-use into `~/.gemini/settings.json`, `~/.codex/config.toml`, and `~/.config/opencode/opencode.json{,c}` (`uvx --from browser-use[cli] browser-use --mcp`). Cursor Task subagents often still lack MCP — the dispatcher then runs browser-use MCP itself. A Codex or Gemini window applies the change itself. Everything they do happens in git worktrees, and the agent reports its branch back.
- Landing never pushes, and it is the only command that writes to your git history. Everything else is confined to tmux and the OpenSpec files.
- The `ops-applier` agent has no `Skill` tool, so it drives the `openspec` CLI directly (`openspec instructions apply --change <c> --json`) instead of calling `/opsx:apply`. That is the same work the command describes. Add `Skill` to its `tools:` list in `agents/opsx-applier.md` if you want it to use the command instead.
- Back-to-back sends to the same window are spaced slightly, because the Claude TUI can concatenate two prompts into one input box otherwise.

## License

MIT
