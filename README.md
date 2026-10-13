# tmux-opsx

My personal development harness for agent CLIs. It runs [OpenSpec](https://github.com/Fission-AI/OpenSpec) changes in Claude Code, Cursor CLI, Codex CLI, OpenCode, or Gemini CLI without blocking your session, checks them with eval, review, security and QA gates, and gives every CLI the same memory — all wired in by one installer.

```
 your dev harness
 ├── setup        opsx init · /opsx-init: OpenSpec, config context, graphify ignore, .opsx/dev.yaml per repo
 │                opsx dev: the repo's toolchain in a per-checkout Docker container, nothing installed on the host
 ├── workflow     /opsx-run: change → window → apply → gates → merge/land
 ├── gates        ops-eval · ops-reviewer · ops-security · ops-qa
 ├── context      memory · fork
 │                /explain: a topic → a designed, diagrammed web page with labelled blocks, written by a fork, served by /expose (directory)
 ├── sharing      /expose: local port or directory → https://<name>--<project>.<domain> behind a login, share links for clients (opt-in)
 │                /opsx-run <change> preview: a change's app → https://<change>--<project>.<domain>
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
  /opsx-run add-auth preview . run the change's app, URL (behind a login) via /expose
  /opsx-run add-auth merge ... merge into main (branch/window stay)
  /opsx-run add-auth land .... merge + archive + cleanup, window closes
```

---

## Contents

| Piece | Installs to | What it does |
|---|---|---|
| `opsx` command | `~/.local/bin/opsx` (or `~/bin` when only that is on `PATH`) | `opsx init` sets up the repo you are in (see [Initialising a repo](#initialising-a-repo)); `opsx dev` runs commands in its dev container (see [Dev container](#dev-container-opsx-dev)); dispatches to the installed skill scripts |
| `/opsx-init` skill + `opsx-init.sh` | `~/.claude/skills/opsx-init/` · `~/.cursor/skills/opsx-init/` · `~/.agents/skills/opsx-init/` · `$CODEX_HOME/skills/opsx-init/` · `~/.config/opencode/skills/opsx-init/` · `~/.gemini/skills/opsx-init/` | Runs `opsx init`, then writes the OpenSpec `context:` from the actual repo |
| `/opsx-run` skill | `~/.claude/skills/opsx-run/` · `~/.cursor/skills/opsx-run/` · `~/.agents/skills/opsx-run/` · `$CODEX_HOME/skills/opsx-run/` · `~/.config/opencode/skills/opsx-run/` · `~/.gemini/skills/opsx-run/` | The lifecycle: apply, verify, archive, land, close — one window per change |
| `opsx-window.sh` | `~/.claude/skills/opsx-run/` | All tmux mechanics — session/window lookup, literal-text sends, rename suppression, closing |
| `opsx-merge.sh` | `~/.claude/skills/opsx-run/` | Merge the change branch into a target (default `main`) — no archive or cleanup |
| `opsx-land.sh` | `~/.claude/skills/opsx-run/` | Landing a change — OpenSpec gates, eval regression gate (with `--eval`), then `opsx-merge.sh`, archive, branch/worktree cleanup |
| `opsx-eval.sh` | `~/.claude/skills/opsx-run/` | Runs a repo's saved eval suite (`evals/`) with no LLM — scorecard, coverage, `--json`, regression compare |
| `opsx-preview.sh` | `~/.claude/skills/opsx-run/` | Runs a change's app (or the main checkout) from its worktree in a tagged tmux window and publishes it through `/expose` — recipe, port, health wait, stop |
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
| `/explain` skill + `explain.sh` | `~/.claude/skills/explain/` · `~/.cursor/skills/explain/` · `~/.agents/skills/explain/` · `$CODEX_HOME/skills/explain/` · `~/.config/opencode/skills/explain/` · `~/.gemini/skills/explain/` | A fork writes a self-contained web page about a topic, with labelled blocks you refine by name; the project's pages directory is published through `/expose` and served by Caddy (see [Explain](#explain)) |
| `/expose` skill + `expose.sh` (opt-in, `--expose-domain`) | `~/.claude/skills/expose/` · `~/.cursor/skills/expose/` · `~/.agents/skills/expose/` · `$CODEX_HOME/skills/expose/` · `~/.config/opencode/skills/expose/` · `~/.gemini/skills/expose/` | Publish `127.0.0.1:<port>` at `https://<name>--<project>.<domain>` through Caddy, behind a login; list/down/url, share links, key rotate (see [Expose](#expose)) |
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

The installer checks prerequisites, installs the OpenSpec CLI, installs OpenSpec **skills and `/opsx:*` commands globally** for Claude Code, Cursor, Codex, OpenCode, and Gemini, verifies **Graphify** and copies `/graphify` into those same global skill dirs, installs the tmux-opsx subagent and `/opsx-run` skill, the `opsx` command and `/opsx-init` skill, registers the **browser-use** MCP server for Gemini, Codex, and OpenCode, and sets up the shared **memory** store (see [Memory](#memory) below).

```
./install.sh --prefix <dir>     # Claude config dir (default ~/.claude, or $CLAUDE_CONFIG_DIR)
./install.sh --skip-openspec    # leave the OpenSpec CLI alone
./install.sh --skip-graphify    # don't verify/install Graphify or copy /graphify
./install.sh --skip-commands    # don't install global OpenSpec skills / /opsx:* commands
./install.sh --skip-mcp         # don't install the browser-use MCP server
./install.sh --skip-memory      # don't install the memory skill, instruction blocks, store, or import
./install.sh --skip-fork        # don't install the /fork skill
./install.sh --skip-explain     # don't install the /explain skill
./install.sh --skip-init        # don't install the opsx command or the /opsx-init skill
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

A manual install keeps every agent on `model: inherit`; `./install.sh` is what writes the per-agent defaults from `agents/models.conf` (see [Per-agent models](#per-agent-models)).

Skills and commands are generated by the CLI rather than vendored here, so they always match the OpenSpec version you actually have installed.

---

## Workflow (`/opsx-run`)

One change = one tmux window: propose it with OpenSpec, apply it in its own window, run the gates, then merge or land it.

### Initialising a repo

`./install.sh` is global-only. Each repo you want to drive with `/opsx-run` needs a little per-repo setup; `opsx init` does it in one command, run inside the repo:

```bash
cd my-project
opsx init                 # set up this repo
opsx init --git           # not a git repo yet: git init first
opsx init --graphify      # also build the code graph (graphify update ., no LLM)
opsx init --force dev     # regenerate .opsx/dev.yaml (or: --force config)
```

Each step prints one line — `✓ step: created …`, `· step: skipped (…)` or `! step: warning` — and is skipped when already done, so it is safe to re-run:

| Step | What it does |
|---|---|
| git | refuses to run outside a git repo (exit 1, nothing written) unless `--git`, which runs `git init` first |
| openspec | `openspec init --tools none` when there is no `openspec/` (skills and `/opsx:*` are global, so no project copies) |
| config | `openspec/config.yaml` with `schema: spec-driven` and a `context:` skeleton starting with `# opsx-init: context skeleton`; an existing `config.yaml`/`config.yml` is never touched |
| gitignore | appends `graphify-out/` to `.gitignore` once (creates the file if needed) |
| graphify | with `--graphify`, `graphify update .`; otherwise prints that command. A missing `graphify` is only a warning |
| dev | `.opsx/dev.yaml` from the toolchain files: `go.mod` `go 1.22` → `image: golang:1.22` + `setup: go mod download`; `.python-version` or `pyproject.toml` `requires-python` → `python:X.Y` (+ `pip install --user -r requirements.txt` when present); `.nvmrc` or `package.json` `engines.node` → `node:<major>` + the lockfile's install (`npm ci`, `pnpm install --frozen-lockfile`, `yarn install --frozen-lockfile`, `bun install`). Several toolchains: the first of Go, Python, Node becomes `image:`, the others are `#` comments and a warning suggests `dockerfile:`. Nothing detected: no file, just a hint |
| docker | warns when `docker` is missing; never pulls, builds or runs anything |

It never overwrites a file you have — `--force config` or `--force dev` regenerates just that file (any other `--force` value is rejected before anything is written) — and it **never stages or commits**: it ends with the list of paths it created or changed and a `git add …` line to review and run yourself. It does not write `.opsx/preview.yaml` (previews auto-detect without one).

From an agent CLI, **`/opsx-init`** (same flags) runs `opsx init` and then replaces the `context:` skeleton with a description written from the repo — purpose, stack, layout, conventions, test commands. It only does that while the `# opsx-init: context skeleton` marker is there; a `context:` you wrote is left unchanged.

`bash tests/test-init.sh` covers every step, idempotency, `--force`, `--git`, `--graphify`, toolchain detection and the install/uninstall of `opsx` and `/opsx-init` with fake `openspec`/`graphify`/`docker` in scratch repos and a scratch HOME.

### Dev container (`opsx dev`)

Go, Python or Node do not need to be installed on the host — not for you, not for the agents. A repo declares its toolchain once in `.opsx/dev.yaml` (written by `opsx init`), and `opsx dev` runs commands in a long-lived Docker container built from it, one per checkout. The agents themselves stay on the host with their logins, MCP and tmux; only builds, tests, package managers and the app go into the container.

```bash
opsx dev go test ./...        # run a command in this checkout's container (created on first use)
opsx dev npm ci               # arguments are passed as-is; the exit status is the command's
opsx dev -- -weird-cmd        # a command that starts with "-"
opsx dev --shell              # interactive shell in the container
opsx dev --status             # container name, image and state (or: none yet)
opsx dev --rm                 # remove this checkout's dev and preview containers
opsx dev --rm --all           # remove every opsx container of the project
```

**`.opsx/dev.yaml`** — flat `key: value` lines, `#` comments:

| Key | Meaning |
|---|---|
| `image:` | Base image, e.g. `golang:1.22`, `python:3.12`, `node:20` |
| `dockerfile:` | Build from this Dockerfile instead (path relative to the checkout root, which is the build context) — for multi-language repos. Tagged `opsx-dev/<project>:<sha256 of the file>` and built only when that tag is missing. Exactly one of `image:` / `dockerfile:` |
| `setup:` | Run once after the container is created, as you, in the checkout root (`sh -c`). May repeat; runs in order. A failing line removes the container and names the line |
| `cache:` | An absolute path in the container kept in a named volume `opsx-dev-<project>-cache-<path>`, shared by all checkouts of the project (e.g. `cache: /go/pkg/mod`). May repeat |

Unknown keys are a warning. Without `.opsx/dev.yaml`, `opsx dev` says to run `opsx init`; without `docker` on `PATH`, it says so.

```yaml
# .opsx/dev.yaml — a Go service
image: golang:1.22
setup: go mod download
cache: /go/pkg/mod
```

**Naming and lifetime.** The container is `opsx-dev-<project>-<name>`: `<project>` is the main checkout's folder name, `<name>` is `<change>` for a worktree on `opsx/<change>`, `main` for the main checkout, else the worktree folder name (lowercased; anything outside `[a-z0-9_.-]` becomes `-`). It is created on first use (`docker run -d --entrypoint sleep <image> infinity`, so any image works) and reused by every later `opsx dev` through `docker exec`. Editing `.opsx/dev.yaml` or the Dockerfile changes the `opsx.dev.hash` label, and the next `opsx dev` recreates the container and runs `setup:` again.

**Same paths, same user, same ports.** The checkout is mounted at its own absolute path and the main repo's `.git` at its own (so a worktree's `.git` file resolves and git works inside). Commands run as your uid:gid in the directory you ran `opsx dev` from, with `HOME=/opsx-home` on a per-project volume `opsx-dev-<project>-home` — files you create are owned by you, and `pip install --user`, npm and Go caches persist. The container uses host networking, so an app listening on `127.0.0.1:$PORT` inside is on the host's loopback, which is what [`/expose`](#expose) needs. **This assumes a Linux host with Docker** (Docker Desktop on macOS/Windows does not give host networking). Images need `sh`, `sleep` and `chown`; for distroless images use a dev image or a `dockerfile:`.

**Previews** of a checkout with `.opsx/dev.yaml` run `install` and `cmd` in a container `opsx-dev-<project>-<name>-preview` from the same image (see [Preview](#preview)).

**Cleanup.** `/opsx-run <change> close` and `land` remove the change's dev and preview containers; `close-all` removes every opsx container of the project. A missing `docker` or a failed removal never fails them. Volumes are kept on purpose (caches survive); remove them by hand when you no longer need them:

```bash
docker volume ls --filter name=opsx-dev-<project>-
docker volume rm opsx-dev-<project>-home opsx-dev-<project>-cache-go-pkg-mod
```

Agents (ops-applier, ops-eval, ops-reviewer, ops-security, ops-qa) are told to use `opsx dev` whenever `.opsx/dev.yaml` exists and never to install a toolchain on the host; a host command that fails for a missing tool is retried through `opsx dev`.

`bash tests/test-dev.sh` covers the `dev.yaml` keys, naming, container creation arguments, exec user/workdir/argv/exit status, setup, Dockerfile builds, recreation, `--status`/`--rm` and the cleanup from `close`, against a fake `docker` (`tests/fake-docker.sh`) that records every call.

### Setting up OpenSpec in a project

`opsx init` (above) does this for you. By hand: `./install.sh` already puts OpenSpec skills and `/opsx:*` commands in your **global** agent dirs, so per project you only need the OpenSpec data folders:

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
| `/opsx-run <change> review --reviewer-model opus` | Same action, but ops-reviewer runs on `opus`; the window remembers it. Also `--applier-model`, `--eval-model`, `--security-model`, `--qa-model` on any action (see [Per-agent models](#per-agent-models)) |
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
| `/opsx-run <change> preview` | Runs the change's app from its worktree in its own window and publishes it at `https://<change>--<project>.<domain>` (needs `/expose`; see [Preview](#preview)) |
| `/opsx-run <change> preview stop` | Stops it: removes the route, kills the app and its window |
| `/opsx-run <change> preview url` | Prints (and copies) the URL of the running preview |
| `/opsx-run <change> preview share [--for <r>] [--ttl <d>]` | Prints a share link for the running preview (one host, expires; `--list`, `--revoke <r>` too) |
| `/opsx-run preview` | Same as `preview`; pick a change or the main checkout (`main--<project>`) |
| `/opsx-run <change> archive` | Gates on validate + all tasks complete, then dispatches the archive |
| `/opsx-run <change> status` | Snapshot of what that window is doing right now |
| `/opsx-run <change> "<text>"` | Sends any instruction to that change's window (creates the window if it was closed) |
| `/opsx-run <change> merge` | Merges the change branch into `main` (`--no-ff`). Keeps the branch, worktree and window |
| `/opsx-run <change> merge --into develop` | Same, into another branch |
| `/opsx-run <change> land` | Merge (via `opsx-merge.sh`) + archive + delete branch + close the window |
| `/opsx-run <change> land --into develop` | Same, into another branch |
| `/opsx-run <change> land --force-tasks` | Same, but skips the unchecked-tasks gate |
| `/opsx-run <change> land --skip-merge` | Already merged: skip merge, still archive + cleanup |
| `/opsx-run <change> land --eval` | Same as `land`, but runs the eval regression gate (off by default; `--skip-eval` is an accepted no-op) |
| `/opsx-run <change> close` | Closes that change's window and stops its preview |
| `/opsx-run close-all` | Closes every tmux-opsx window in the session and stops every preview in the project (asks first) |
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
/opsx-run add-rate-limiting preview                   # run its app, open https://add-rate-limiting--<project>.<domain>
/opsx-run add-rate-limiting qa                        # one-shot UI/UX QA (tests the preview URL when expose is set up)
/opsx-run add-rate-limiting qa "check the checkout on mobile"
/opsx-run qa "check the checkout on mobile"           # pick the change, then ops-qa
/opsx-run add-rate-limiting land                      # merge, archive, delete branch, stop the preview, close window
git push origin main                                  # you push, never the tool
```

Jump to a change's window with `tmux select-window -t <session>:<change>`, or your usual prefix + window number. If the session was created for you, `tmux attach -t <project-folder>` gets you in.

`verify` and `archive` run their read-only `openspec` checks in your **calling** session on purpose: they are fast, and a failed gate should reach you immediately rather than sit unread in a window you are not watching.

#### The helper script

Everything tmux-related goes through one script, which you can also drive by hand:

```bash
~/.claude/skills/opsx-run/opsx-window.sh ensure <change> --prompt-file <f> [--cwd <dir>] [--agent-cli <cmd>] [--model <id>] [--<agent>-model <m>]...
~/.claude/skills/opsx-run/opsx-window.sh send   <change> --prompt-file <f> [--<agent>-model <m>]...
~/.claude/skills/opsx-run/opsx-window.sh models [<change>] [--agent-cli <cmd>] [--<agent>-model <m>]...
~/.claude/skills/opsx-run/opsx-window.sh close  <change> [--force] [--keep-session]
~/.claude/skills/opsx-run/opsx-window.sh close  --all    [--force] [--keep-session]
~/.claude/skills/opsx-run/opsx-window.sh status <change> [--lines N]
~/.claude/skills/opsx-run/opsx-window.sh mark   <change> <busy|done|fail|idle>
~/.claude/skills/opsx-run/opsx-window.sh list
~/.claude/skills/opsx-run/opsx-window.sh preview-start <change> --cwd <dir> --script <file>   # used by opsx-preview.sh
~/.claude/skills/opsx-run/opsx-window.sh preview-find  <change>
~/.claude/skills/opsx-run/opsx-window.sh preview-kill  <change>|--all

~/.claude/skills/opsx-run/opsx-preview.sh up   <change>|--main
~/.claude/skills/opsx-run/opsx-preview.sh stop <change>|--all
~/.claude/skills/opsx-run/opsx-preview.sh url  <change>|--main
~/.claude/skills/opsx-run/opsx-preview.sh share <change>|--main [--for <r>] [--ttl <d>] [--list] [--revoke <r|id|all>]
~/.claude/skills/opsx-run/opsx-preview.sh list
~/.claude/skills/opsx-run/opsx-preview.sh prune

~/.claude/skills/opsx-run/opsx-merge.sh <change> [--into <branch>] [--dry-run]
~/.claude/skills/opsx-run/opsx-land.sh <change> [--into <branch>] [--skip-merge] [--force-tasks] [--eval] [--skip-eval] [--dry-run]

~/.claude/skills/opsx-run/opsx-eval.sh [--change <c>] [--capability <cap>]... [--all] [--agentic] [--trials N] [--json] [--root <dir>]
~/.claude/skills/opsx-run/opsx-eval.sh --compare <baseline.json> <current.json>
```

`opsx-window.sh` prints one line — `created @7 2:add-auth`, `reused @7 2:add-auth`, `sent @7 2:add-auth`, or `marked @7 2:add-auth status=idle`. Called from outside tmux, `ensure` appends `session=created` when it had to start the session, plus an `# attach with: …` hint.

Windows opened by this tool use a distinct **`ox` title**, a **dark pane**, and muted status-bar colors (the **word color** is the status): `ox ·change` (idle/done, mint), `ox …change` (busy, amber), `ox ✗change` (fail, rose). `mark done` is treated as idle so follow-ups reuse the same window. If a busy window goes silent for ~40s (`$OPSX_IDLE_SILENCE`) without `mark done`/`fail`, it falls back to idle. Lookups use the `@opsx_change` tag, so titles do not break later commands.

Session names come from the project folder with `.`, `:` and whitespace folded to `-`, since tmux treats `.` and `:` as target separators — `~/code/my.app` becomes the session `my-app`.

#### Per-agent models

Each sub-agent (ops-applier, ops-eval, ops-reviewer, ops-security, ops-qa) can run on its own model, separate from the window's `--model`. Writing code and hunting security bugs get the strongest model; eval checks and long QA sessions get a faster one.

**Defaults** live in `agents/models.conf`, one `<cli>.<agent> = <model>` per line (`<cli>` is `claude`, `agent` for Cursor, or `opencode`; `<model>` may be `inherit`, the window's model):

```
claude.applier  = opus
claude.eval     = sonnet
claude.reviewer = opus
claude.security = opus
claude.qa       = sonnet
agent.qa        = inherit      # every Cursor and OpenCode key ships as inherit
```

Override any key in `~/.config/tmux-opsx/models.conf` (`$XDG_CONFIG_HOME/tmux-opsx/models.conf`); keys you do not set keep the shipped value, and install never writes this file. `./install.sh` writes the resolved defaults into the installed agent files' frontmatter `model:` for Claude Code, Cursor and OpenCode (OpenCode gets no `model:` key for `inherit`), and installs `models.conf` next to `opsx-window.sh`. **Re-run `./install.sh` after editing either file** so the agent files pick up the change. A model the CLI does not accept (Claude: `opus`, `sonnet`, `haiku`, `fable` or `claude-*`; Cursor: listed by `agent models`; OpenCode: `provider/model`, listed by `opencode models`) warns and becomes `inherit`; install still succeeds.

**Per run**, `--applier-model`, `--eval-model`, `--reviewer-model`, `--security-model` and `--qa-model` on `/opsx-run` pick one agent's model. The change window remembers the choice (tmux option `@opsx_model_<agent>`) for later runs until it closes; `--<agent>-model default` forgets it. `list` and `status` show remembered models as `qa=haiku`. The order, per agent, is **flag > window > config > inherit**; a value the window's CLI rejects falls through to the next layer with a warning. Check what each agent would get:

```bash
~/.claude/skills/opsx-run/opsx-window.sh models --agent-cli claude
# applier opus config
# eval sonnet config
# ...
~/.claude/skills/opsx-run/opsx-window.sh models add-auth --qa-model haiku   # uses add-auth's window memory
```

The dispatcher names a model only for agents with a flag or a remembered value (others use their installed agent file), and if a spawn fails with a model error it retries once without one and says so in the pane.

**Codex and Gemini** windows do the work themselves without sub-agents, so per-agent models do not apply there: the flags are ignored with a one-line note and their agent files are left unchanged.

`bash tests/test-agent-models.sh` covers the config merge, validation per CLI, window memory and install output on a private tmux server with fake CLIs in a scratch HOME.

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
/opsx-run add-auth land --eval          # also run the eval regression gate
```

**OpenSpec gates → eval baseline (`--eval` only) → `opsx-merge.sh --stay` → eval regression check (`--eval` only) → `openspec archive` → commit → remove worktree → delete branch → close window.**

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

**Eval regression gate.** Off by default, because it runs the whole suite twice: plain `land` runs no evals and, when `evals/` exists, prints one `eval gate off (pass --eval to run the regression gate)` line. Pass `--eval` to turn it on: when the target or the change branch has an `evals/` directory, land runs `opsx-eval.sh` (L1 + L2 only — L3 never runs at land) on the target in a temporary worktree (baseline), merges, then runs it on the merged result. A check that **passed on the target and fails after the merge blocks** the land: it prints `EVAL_REGRESSION` and the checks, resets the target to its pre-merge commit, and archives nothing. New failures (no baseline), UNVERIFIABLE and MISSING results only warn. No `evals/` → skipped silently; `--skip-eval` is still accepted but is a no-op (it prints a note that the gate is already off); `--dry-run` shows whether the gate would run; `--skip-merge` skips it (no pre-merge baseline).

Run it with `--dry-run` first to see exactly what it would do. Other flags: `--branch <name>` when discovery guesses wrong, `--skip-specs` for tooling/doc changes, `--force-tasks` to land with unchecked boxes still in `tasks.md`, `--skip-merge` when the branch is already in the target, `--eval` to run the eval regression gate (`--skip-eval` is an accepted no-op), `--no-close`, `--keep-branch`, `--keep-worktree`.

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

Closing kills the agent session in that window along with anything it still had in flight; worktrees, commits and files already written stay on disk. `close` also stops the change's preview and removes its [dev containers](#dev-container-opsx-dev), and `close-all` stops every preview and removes every opsx container in the project (a missing or failing preview, or a missing `docker`, never blocks the close).

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
- **Runner:** `opsx-eval.sh --change <c>` also lists scenarios without a check as MISSING; `--json` keeps full evidence; exit 0 no FAIL, 1 FAIL, 2 config/runner error. Usable by hand or in CI. With `land --eval` it guards against regressions (off by default; see [Landing a change](#landing-a-change)).

This repo's own suite config is `evals/eval.yaml` (scratch `HOME` + private tmux server via `evals/setup.sh` / `evals/teardown.sh`).

`bash tests/test-eval.sh` exercises the runner against fixture suites (exit-code mapping, timeout, teardown on failure and interrupt, L3 NOT RUN and pass rate, MISSING, `--json`, compare) and the land gate in scratch repos with a fake `openspec` (with `--eval`: regression blocks and restores the target, new failures warn; no `evals/` skips silently; the gate is off by default and a planted regression lands; `--skip-eval` is a no-op with a note; `--dry-run` shows the gate state with and without `--eval`).

### ops-reviewer

Implementation review: spec fidelity, logic, tests and maintainability. Run it with `/opsx-run <change> review ["notes"]`. Returns SKIP for documentation-only or OpenSpec-metadata-only diffs.

### ops-security

Security review: auth, injection, secrets, unsafe defaults and trust boundaries. Run it with `/opsx-run <change> security ["notes"]`. Returns SKIP when the change has no security-relevant surface.

### ops-qa

UI/UX check: visual regressions, broken flows, console errors and accessibility, driven through the browser-use MCP. Run it with `/opsx-run <change> qa ["notes"]` or `/opsx-run qa "notes"`. Returns SKIP when the change has no user-facing UI.

Before ops-qa runs (in `qa` and in the `apply --validate` QA step), the window runs `opsx-preview.sh up <change>` and then `opsx-preview.sh share <change> --for ops-qa --ttl 1d`, and passes that share link to ops-qa as `PREVIEW_URL`, so the gate tests exactly what you would share. ops-qa opens the link first and keeps the same browser context, so its login cookie applies; the link opens only that preview's host, expires after a day, and the next QA run replaces it. The owner key never reaches an agent transcript. The preview is left running afterwards. When expose is not configured (or the preview fails), ops-qa gets the reason and starts the app itself as before.

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

`/fork` opens a **read-only child agent** beside the one you are talking to that already knows the current conversation (on Claude Code and OpenCode it is a native fork of it, elsewhere it gets a summary brief), so you can ask side questions ("why did we pick X?", "where is Y handled?") without derailing the main thread. It is independent of OpenSpec and `/opsx-run`, and works from Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI. It needs tmux.

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
| `/fork ["question"]` | parent | opens the child in a side-by-side pane (~40% width): a native fork of this conversation when possible (the brief is just the question), else a summary brief (question + 5–15 lines of context) |
| `/fork --brief ["question"]` | parent | force the summary brief: the child sees only the brief, never the parent's conversation |
| `/fork --vertical …` / `/fork --window …` | parent | split top/bottom, or open a new window `fork-<id>` instead |
| `/fork --cli <claude\|agent\|codex\|opencode\|gemini> …` | parent | child CLI (default: the parent's) |
| `/fork --model <m> …` | parent | child model (default: `$FORK_MODEL`, else the parent's model when the child uses the same CLI, else the CLI's default) |
| `/fork return` | child | saves a short result (answer, evidence, unresolved) and notifies the parent |
| `/fork collect [id]` | parent | reads the result into the parent (default: most recently returned) |
| `/fork list` | parent | id, status, CLI, MODEL (`default` = the CLI's default), CONTEXT (`full` / `brief`), pane and question of every fork in this tmux session |
| `/fork close <id>` / `--all` | parent | saves a capture if there is no result, kills the pane/window, keeps the state |

With more than one child beside the parent, the window switches to `main-vertical` so the parent stays the large pane.

**Model.** A fork runs on the parent's model by default: the `/fork` skill always passes the parent agent's own model id as `--parent-model`, and `fork.sh` applies it only when the child runs on the same CLI as the parent (for OpenCode only in `provider/model` form). Precedence is `--model` > `$FORK_MODEL` > inherited parent model (same CLI only) > the CLI's default (no model flag). Each CLI gets its own flag (`--model` for claude and agent, `-m` for codex, opencode and gemini); ids are never mapped across CLIs. Values that are empty, contain whitespace or start with `-` are rejected before anything opens. The chosen model is shown on the `open` line (`fork 3 pane %7 cli claude model haiku`, or `model default`), in `meta` and in `/fork list`. Called directly: `fork.sh open --cli claude --model haiku <<<'## Question …'`. `$FORK_HOST_CLI` (a CLI name, or `none`) overrides host CLI detection.

**Native forks (full context).** When the child runs on the same CLI as the parent and that CLI can fork a session, the child starts as a fork of the parent's whole conversation: a new session seeded with the full transcript, while the parent's own session is never written to. The parent then writes only the question, not a context summary, and the child can answer "why did we pick X three hours ago?" from the history itself.

| Child CLI (same as the parent) | Native launch | Notes |
|---|---|---|
| Claude Code | `claude --resume <parent session id> --fork-session …` | the id comes from `$CLAUDE_CODE_SESSION_ID` (recovered from the process chain below the claude process when a shell strips it; an id held only by the claude process or the tmux server is the one they were launched with, possibly an earlier conversation's, so it is never used and the fork falls back to the brief); works with any `--cwd` |
| OpenCode | `opencode --continue --fork …` | "the last session of this directory", so only when the child runs in the OpenCode session's directory (the `opencode` process's working directory, not wherever the agent's shell has `cd`'d to); if another OpenCode session in the same project was used more recently, it is picked instead (use `/fork --brief`) |
| Codex, Gemini, Cursor | — | always the summary brief (no true fork on the command line) |

*Brief fallback:* the summary brief is used automatically for cross-CLI forks (e.g. a Codex child of a Claude parent), for Codex / Gemini / Cursor, for an OpenCode child with a different `--cwd`, when no trustworthy Claude session id is found, and when forced with `/fork --brief` (`fork.sh open --brief-only`) or `FORK_NATIVE=0`. A brief-mode launch is exactly the pre-native launch line. `fork.sh native [--cli …] [--cwd …]` prints the decision before anything opens (`full claude session <id>` or `brief <reason>`); the skill runs it to decide which brief to write. `open` prints the mode on a `# context: full …` / `# context: brief …` line, `meta` records `context=full|brief` and `context_source`, and `/fork list` shows it in the CONTEXT column. All read-only flags, the allow rule, the appended system prompt and the model flags are the same in both modes.

*What a full-context child inherits:* everything the parent saw, including anything sensitive that appeared in the conversation (pasted tokens, file contents, command output), and the parent's context-window usage: a parent close to compaction gives a child close to compaction, and the first turn processes the whole transcript (for Claude it normally hits the prompt cache). Use `/fork --brief` when you want a clean, small child.

**Notify, never push.** On return the parent pane gets a tmux message and a title badge (`fork 1 ✓`, also in the pane option `@fork_badge`). Nothing is ever typed into the parent; you decide when to `/fork collect`.

**Read-only children.** Every child starts in its CLI's read-only / plan mode and never with bypass or force flags:

| CLI | Launched as | How `return` gets back |
|---|---|---|
| Claude Code | `claude --permission-mode plan` + an allow rule for exactly `fork.sh return` (and one for `fork.sh page` in a page fork) | `result.md` written directly |
| Codex CLI | `codex --sandbox read-only --ask-for-approval on-request` | sandbox blocks the write; approve that one command, or the marker fallback is used |
| Gemini CLI | `gemini --approval-mode plan -i` | marker fallback (plan mode applies once the folder is trusted) |
| Cursor CLI | `agent --mode ask` | marker fallback |
| OpenCode | `opencode --agent plan --prompt` | marker fallback |

*Marker fallback:* when a child cannot run `fork.sh return`, it prints the result between `<<<FORK-RESULT` and `FORK-RESULT>>>` lines, and `/fork collect` recovers it from the child pane's scrollback (saving it as `result.md`). If there is neither, `collect` returns the tail of the pane, clearly labelled as a raw capture. Full-screen TUIs keep little scrollback, so collect while the block is still on screen.

**State** lives outside the repo, in `${XDG_STATE_HOME:-~/.local/state}/agent-forks/<tmux-session>/<id>/` (`brief.md`, `meta`, `launch.sh`, `result.md`, `capture.txt`). It is kept after `close` and on `--uninstall`; delete old forks by hand when you like.

**Page forks.** `fork.sh open --page-dir <abs dir>` (used by [`/explain`](#explain)) makes a fork that writes one web page: `meta` records `page_dir`, the child gets `FORK_PAGE_DIR`, the brief ends with a *Page protocol* section, and on Claude Code a second narrow allow rule permits exactly `fork.sh page`. The child writes the whole page with `fork.sh page <<'PAGE_EOF' … PAGE_EOF` (atomic replace of `<dir>/index.html`) and its label list with `fork.sh page --manifest` (`<dir>/manifest.tsv`); nothing else can be written. Exit codes: 1 not a fork, 2 empty input, 3 not writable, 4 no page directory. After a page write, `<dir>/../.reindex` runs when present (the library index), only for page dirs under `${XDG_STATE_HOME:-~/.local/state}/agent-forks/explain/<project>/` and never through a symlink. The page protocol forbids secrets, tokens and credentials in the page. There is no marker fallback for pages: a child that cannot run `fork.sh page` says so and stops.

`bash tests/test-fork.sh` exercises `fork.sh` on a private tmux server with fake agent CLIs (open/return/collect/list/close, badges, layout, marker recovery, concurrent ids, model selection and inheritance, native forks and their brief fallbacks, page forks and `fork.sh page`).

### Explain

`/explain "<topic>"` turns something from the current session into a designed, diagrammed web page (English by default; `--lang pt` or `--lang en,pt` for Portuguese or both) that you can open on any device, hand to a client, and refine by talking to the fork that wrote it. It opens a read-only [fork](#fork) (a native full-context fork when possible) whose only job is that page, publishes the project's pages directory through [`/expose`](#expose) if it is not published yet, and prints the page URL:

```
/explain "how /opsx-run land works"
  → page 3 https://explain--shop.dev.example.com/3/   (fork 2 in the pane on the right)
```

| Command | What it does |
|---|---|
| `/explain "<topic>"` | open a page fork (`--window`, `--vertical`, `--cli`, `--model` as for `/fork`), print the page URL |
| `/explain --lang <en\|pt\|en,pt> "<topic>"` | the page's language(s); default `en` (one article, no switch); `en,pt` writes both with the EN / PT switch |
| `/explain share [--for <r>] [--ttl <d>]` | share link for the project's explain host (`expose.sh share explain …`); `--list`, `--revoke <r\|id\|all>` |
| `/explain list` | pages (id, created, fork, title), whether they are exposed, and the URL |
| `/explain stop` | remove the exposure (`expose.sh down explain`); pages are kept |

**URL shape.** One exposure per project: `https://explain--<project>.<domain>/<id>/` for page `<id>`, and the library index at `https://explain--<project>.<domain>/`. `<project>` is the main checkout's folder name, so every worktree of a repo shares the same pages and host. There is no server of explain's own: `explain.sh` runs `expose.sh up --dir <pages root> --name explain --hide manifest.tsv --hide '*.sha256' --csp <policy>` on every `open` and `serve` (idempotent, and it restores a route the proxy lost), and Caddy serves the directory itself behind the expose login.

**Labels.** Every block has a visible label in the left margin and an HTML id equal to it: `S<n>` sections (`S1.2` nested), `P<n>` paragraphs, `D<n>` diagrams, `T<n>` tables, `C<n>` code, `N<n>` callouts. Clicking a label copies `#P7`, and `<url>#P7` deep-links to it. Tell the fork pane what to change by label ("expand P7", "D2: the arrow from cache to db is wrong"). Labels are stable: an edited block keeps its label, new blocks take the next unused number, removed labels are never reused. The fork keeps them in `manifest.tsv` beside the page (`label<TAB>summary`) and reads it before every rewrite. The fork writes the whole page with `fork.sh page` and the open browser reloads by itself within a few seconds (it polls the page's `ETag` and `Last-Modified`, and ignores error answers and redirects, so a page open on another device never reloads into an error). The `ETag` comes from `index.html.sha256`, a sidecar `.reindex` writes beside every page and the library after each write, so even a rewrite within the same second and with the same length is seen. Diagrams are inline SVG first (a framed figure with `viewBox`, `role="img"` and an `aria-label`, drawn with the page's colour tokens), Mermaid only when a diagram has too many nodes to draw by hand (the fork then adds the one pinned CDN file, exact version with a Subresource Integrity hash and no referrer; a page without Mermaid loads no script from outside), then ASCII.

**The design.** Every page uses one visual system, taken from the user's reference page: Red Hat Display, Text and Mono from Google Fonts (`display=swap`, system fallbacks when they cannot load), colour tokens for light and dark (`--accent`, `--warn`, `--bad`, `--ok` with soft backgrounds), an 880 px rail for figures and tables and a 68 ch column for prose. A page opens with a hero (`header.hero`: a mono eyebrow with the provenance, the title, a lede that gives the whole answer) and is built from labelled elements: key cards (`.key`), framed figures alone or in a `.pair`, tables in `.tscroll` with `.pill` states, callouts (`.callout`, `.warn`, `.bad`, `.ok`), a `dl.terms` list and a footer naming the sources. The template lives in `skills/explain/SKILL.md`; `explain.sh open` pastes it into the brief cut down to the requested languages, and the fork keeps its `<style>` and scripts.

**Languages.** The page carries the language(s) you asked for at `open` (`--lang`, English by default). With `en,pt`, the whole explanation is written twice: an `<article lang="en">` and an `<article lang="pt">` with the same labelled blocks in the same order (same labels, same ids), written together in one `fork.sh page` write. An EN / PT switch at the top shows one language without a reload and remembers the choice in the browser (`localStorage`). The first visit picks `?lang=en` or `?lang=pt` from the URL, else the remembered choice, else Portuguese when the browser language starts with `pt`, else English. Labels work the same in both languages, so `<url>?lang=pt#P7` opens the Portuguese P7, and a switch without a `#label` keeps the block you are reading at the top of the screen. Diagrams appear in both articles (translated node text, same `D<n>`). The library index shows both titles (`English title · Título em português`). Ask the fork for changes by label, and they apply to every language the page carries unless you name one; "add Portuguese" turns an English page into a bilingual one.

**Where pages live.** `${XDG_STATE_HOME:-~/.local/state}/agent-forks/explain/<project>/<id>/` (`index.html`, `index.html.sha256`, `manifest.tsv`, `.meta`), with the library `index.html` and its sidecar, `.ids/`, `.lock` and `.reindex` at the root. Never in the project checkout. Pages survive `fork.sh close`, `/explain stop` and `install.sh --uninstall`; delete them by hand. The root is private (mode 700, files 600).

**Page safety.** The fork writes the whole page and its context may hold untrusted text, so the proxy, not the page, sets the limits. The directory exposure carries explain's policy: every response has a strict `Content-Security-Policy` (scripts only inline and from the pinned Mermaid file; styles from the page and `fonts.googleapis.com`, fonts from the page, `data:` and `fonts.gstatic.com`; fetches and images only from the explain host or `data:`; no forms, frames or objects), `Referrer-Policy: no-referrer`, `nosniff`, `X-Frame-Options: DENY` and `Cache-Control: no-cache`. Page script therefore cannot send requests, with or without the owner cookie, to your other exposed apps or to outside hosts. Caddy serves regular files only: no directory listing, never a dotfile or dot-directory (`.meta`, `.ids/`, `.reindex`, `.lock`), and `manifest.tsv` and `*.sha256` are hidden through `--hide`. `/explain share` links open the **whole library** of the project, not one page.

**Needs `/expose`.** With [`/expose`](#expose) set up (`install.sh --expose-domain <domain>`), pages sit behind the expose login, and nothing leaves the machine unless you create a share link. Without it nothing serves the pages: `/explain` prints the page's file path with a hint, and the fork still writes it. The fork can write its page only where its CLI's read-only mode allows `fork.sh page`. That is Claude Code (allow rule) and Codex (if you approve the command). On Gemini, Cursor and OpenCode it reports that it cannot write the page and stops.

`bash tests/test-explain.sh` exercises `explain.sh` on a private tmux server with fake agent CLIs, a fake `expose.sh` and a scratch state dir: the directory exposure it asks for (`up --dir`, hides, the policy) and the not-configured and failing paths, page ids, the library index and the `.sha256` sidecars, worktrees, share, list and stop, `--lang` (English-only brief and template by default, Portuguese-only, bilingual), the template's design elements, and the page scripts (single-language page, EN / PT switch, reload poll) checked under node.

---

## Sharing

### Expose

`/expose` turns a local port, or a directory of static files, into an HTTPS URL behind a login, so you can open an app running on the VPS from a phone or laptop, or share it with a client, without SSH tunnels. `/expose 3000` publishes `127.0.0.1:3000` at `https://3000--<project>.<domain>`, where `<project>` is the repo's folder name (the same in every worktree). It is opt-in: without `--expose-domain`, the installer sets up nothing expose-related.

```
 browser ──https──> *.dev.example.com:443 ──> Caddy (wildcard cert, DNS-01)
                                                 └─ route web--shop.dev.example.com ──> 127.0.0.1:3000
 expose.sh up/down ──> Caddy admin API (unix socket, user-only) — routes added live, no reload
```

**Exposed URLs require a login.** Caddy lets a request through only with your owner cookie (any exposed host) or a share cookie (that one host); anything else gets a 401 login page and never reaches the app. See [Login and share links](#login-and-share-links). `--public` turns that off for one exposure.

**Setup** (once per host):

1. In Cloudflare, create a **user** API token under **My Profile > API Tokens**, scoped to **`Zone:DNS:Edit`** for the one zone (it is used only for the ACME DNS-01 challenge). The installer checks it with `/user/tokens/verify`, which does not know account-owned tokens (Manage Account > API Tokens); to use one of those, set `OPSX_EXPOSE_SKIP_VERIFY=1` to skip the check.
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

   The unit runs Caddy as you, with only the capability to bind `:443`. On macOS no service is installed (a known gap); the installer prints the `caddy run --config …` command to start it by hand.

**Usage** — from the agent (`/expose 3000`, `/expose list`, …) or the script directly:

```bash
EXPOSE=~/.claude/skills/expose/expose.sh  # or the expose/ folder of another CLI's skills dir
"$EXPOSE" up 3000                     # https://3000--<project>.dev.example.com
"$EXPOSE" up 3000 --name web          # https://web--<project>.dev.example.com
"$EXPOSE" up 3000 --name web --project shop   # https://web--shop.dev.example.com
"$EXPOSE" list                        # NAME PROJECT PORT URL UP BIND ACCESS   (--json for scripts)
"$EXPOSE" url web                     # print + copy the URL again
"$EXPOSE" url web --with-key          # your login link: open it once per device
"$EXPOSE" share web --for acme        # share link for a client: this host only, 7 days
"$EXPOSE" share web --list            # FOR ID EXPIRES LINK
"$EXPOSE" share web --revoke acme     # that link and its cookie stop working at once
"$EXPOSE" up 3001 --name hook --public   # no login (webhooks, OAuth callbacks)
"$EXPOSE" up --dir /abs/site --name docs --hide '*.map' --csp "default-src 'self'"   # static files, served by Caddy
"$EXPOSE" key rotate                  # new owner key: logs every device out
"$EXPOSE" down web                    # remove by name, with its share links (down 3000 removes every exposure of port 3000)
```

- Names and projects are lowercased and reduced to `[a-z0-9-]`; a hostname label over 63 characters gets its name part cut and a stable 6-hex hash appended. Re-running `up` with the same name moves it to the new port (or directory); share links survive the move.
- **Directories.** `up --dir <abs dir> --name <n>` publishes the files under a directory with Caddy's file server, behind the same login and share links, with no app or port involved. Only regular files are served: no directory listing (a folder without `index.html` answers 404), never a path component starting with `.`, never a name matching a `--hide <glob>` (repeatable; without `/` it matches a name at any depth), and `/dir` is redirected to `/dir/` with its query. Every response carries `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Cache-Control: no-cache` and a strict default `Content-Security-Policy` (`default-src 'none'; script-src 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'`), replaced by `--csp "<policy>"`. A regular file `<f>.sha256` beside `<f>` is served as its `ETag` (hide the sidecars with `--hide '*.sha256'`). `up` refuses a relative or missing directory, `/` and your home directory itself (exit 2). `list` shows a directory row with PORT `-`, BIND `dir` and UP `yes` while the directory is readable; `list --json` gives `"port": null` and `"dir": "<path>"` (`"dir": null` on port rows). `/explain` uses this for its pages.
- The URL is the last line of output. It is copied to your local clipboard with OSC 52 (through tmux when reachable, so it works from an agent's Bash tool too), and shown as a clickable OSC 8 link on a terminal; a line on stderr says where it went (through tmux it lands in tmux's paste buffer, and reaches your clipboard only when tmux forwards it, see `set-clipboard` below). Nothing opens a browser. When `$TMUX` is unset, tmux is looked up through the parent processes' environment; set `TMUX=` (empty) to skip that lookup, or `OPSX_EXPOSE_NO_COPY=1` to never copy. `up` also notes on stderr when nothing listens on the port yet.
- Exit codes: `0` ok, `2` bad usage, a refused non-loopback bind or a refused directory, `3` not configured (run `install.sh --expose-domain`), `4` proxy not running, `1` other.
- Routes are recorded in `${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/expose/routes/`; every call puts back any route Caddy lost. Caddy starts from `caddy.json` alone (no `--resume`), and the unit runs `expose.sh list` right after start, so routes come back after a restart or reboot.
- Rerunning `install.sh --expose-domain <other-domain>` (or with a new token) updates an existing setup: a changed `caddy.json` is loaded into the running proxy through its admin socket and the recorded routes are re-added on the new domain (their `URL=` is rewritten). When the token or the unit changed, the installer restarts the service the same way (as root or through sudo), or prints the `sudo … systemctl restart tmux-opsx-caddy` command when it can't. A rerun also starts the service if it is installed but not running.
- **Bind apps to `127.0.0.1`**, not `0.0.0.0`. A dev server listening on all interfaces is also reachable directly at `<server-ip>:<port>`, bypassing Caddy — unless a host firewall allows only 22 and 443.

**tmux hint (OSC 8 links)** — tmux passes hyperlinks through only when the outer terminal is declared to support them. The installer does not edit your `tmux.conf`; add this yourself if you want clickable links inside tmux:

```
set -as terminal-features ',*:hyperlinks'
```

OSC 52 copying through tmux needs `set-clipboard` to be `on` or `external` (anything but `off`).

#### Login and share links

Every exposure needs a login unless it was published with `--public`. All checks run inside Caddy on every request (no extra service), and both cookies are removed from the request before it reaches your app, which still gets all its other cookies.

- **You (owner):** `expose.sh url <name> --with-key` prints `https://<name>--<project>.<domain>/?opsx_key=<key>`. Open it once on each device (phone, laptop): it sets an `opsx_auth` cookie for every host under your domain (30 days, `Secure`, `HttpOnly`, `SameSite=Lax`) and redirects to the same path without the key. Because that cookie holds the owner key and goes to every host under the domain, use a domain that serves nothing but `/expose` (e.g. a dedicated `dev.example.com`). The login page also has a field to paste the key. The key lives in `~/.config/tmux-opsx/expose.key` (mode 600, created on first use, kept across reinstalls); only `url --with-key` prints it. `expose.sh key rotate` replaces it: every device is logged out and old login links stop working, share links keep working. If the proxy refuses to rebuild a route, `key rotate` exits non-zero and names the routes that may still accept the old key; the next `expose.sh` call retries them.
- **Clients:** `expose.sh share <name> --for <recipient>` prints a share link `…/?opsx_share=<token>`. It works only on that one hostname and sets a host-only cookie there. One link per recipient: sharing again with the same `--for` replaces the old link. `--ttl` takes `<n>m`, `<n>h`, `<n>d` or `never` (default `7d`); Caddy refuses the link and its cookie after that time even if `expose.sh` never runs again. `share <name> --list` shows FOR, ID, EXPIRES and LINK; `share <name> --revoke <recipient|id|all>` deletes links at once. Expired links are cleaned out of the state on the next call. Re-publishing a name on another port keeps its links; `down` deletes them.
- **No login:** `up <port> --public` publishes without any login, for webhooks or OAuth callbacks, and prints a warning that the URL is public. Caddy still catches `?opsx_key=` and `?opsx_share=` on a public host (a 302 to the same path without the query; the right owner key also logs you in), so a key or token never reaches the app's request log. Running `up` again without `--public` puts the login back.
- **Agents** print the plain URL from `up` and `url`. The `/expose` skill tells them not to print a login or share link unless you asked for one.
- **Loopback only:** `up` refuses (exit 2, nothing changed) a port that something listens on at `0.0.0.0`, `[::]` or another non-loopback address, because the app would be reachable at `<server-ip>:<port>` without the login. Bind it to `127.0.0.1` (Docker: `-p 127.0.0.1:3000:3000`). The check uses `ss` on Linux and `lsof` on macOS; without them `up` refuses too. When nothing listens yet, `up` publishes anyway, and `list` shows each exposure's BIND (`loopback`, `PUBLIC`, or `-`), so an app that binds publicly later shows up there.

**Upgrading from public URLs:** links handed out before this version stop working without a cookie. After reinstalling (`install.sh --expose-domain <domain>`), the next `expose.sh` call (or a proxy restart) creates the key and rebuilds every recorded route with the login. Then run `expose.sh url <name> --with-key` once per device, issue `share` links to anyone who had the old URLs, and use `up --public` for anything that must stay open.

**Removing expose** (there is no `--uninstall` for it yet):

```bash
sudo systemctl disable --now tmux-opsx-caddy && sudo rm /etc/systemd/system/tmux-opsx-caddy.service && sudo systemctl daemon-reload
rm -rf ~/.config/tmux-opsx ~/.local/share/tmux-opsx ~/.local/state/tmux-opsx/expose
rm -rf ~/.claude/skills/expose ~/.cursor/skills/expose ~/.agents/skills/expose ~/.codex/skills/expose ~/.config/opencode/skills/expose ~/.gemini/skills/expose
```

`bash tests/test-expose.sh` runs `expose.sh` and `install.sh --expose-domain` fully offline: a fake Caddy admin server (`tests/fake-caddy-admin.py`), a fake `caddy`, a fake Cloudflare endpoint, and a private tmux server, in scratch HOMEs. The login, share-link, expiry and cookie-stripping checks run real requests through a scratch Caddy on a private socket and a high port on 127.0.0.1 (the installed `~/.local/share/tmux-opsx/bin/caddy`, `$OPSX_CADDY_BIN`, or `caddy` on `PATH`; skipped with a notice when there is none).

### Preview

`/opsx-run <change> preview` runs a change's app from its worktree (`opsx/<change>`) and publishes it through [`/expose`](#expose) at `https://<change>--<project>.<domain>`. The hostname stays the same across restarts, so you can keep the tab open on your phone. `/opsx-run preview` without a change asks which one to run, and also offers the main checkout (`https://main--<project>.<domain>`). It needs expose set up (`install.sh --expose-domain <domain>`); without it, `preview` fails with that hint before starting anything.

```
/opsx-run add-auth preview          # start (or reuse) — prints the URL
/opsx-run add-auth preview url      # print + copy it again
/opsx-run add-auth preview stop     # remove the route, kill the app and its window
/opsx-run add-auth preview share --for acme --ttl 3d   # share link for a client (--list, --revoke acme)
```

What happens on `preview`:

1. **Recipe.** `.opsx/preview.yaml` in the checkout, else detection (below), else an error asking for `.opsx/preview.yaml`.
2. **Install**, only when the install command or a lockfile changed since the last successful install in that checkout.
3. **Port.** The change's last port when free, else the first free one in 3100–3999. `PORT` and `HOST=127.0.0.1` are exported to `install` and `cmd`. When the checkout has [`.opsx/dev.yaml`](#dev-container-opsx-dev), `install` and `cmd` run (through `sh -c`) in a container `opsx-dev-<project>-<change>-preview` from the dev image — same mounts, user and host network as `opsx dev`, `PORT` and `HOST` set inside — and `stop` removes it; otherwise they run on the host.
4. **Window.** The app runs in its own tmux window `ox ><change>` (ASCII, so non-UTF-8 clients show it as-is), tagged `@opsx_preview=<change>` (never `@opsx_change`, so it is never mistaken for the agent window), in its own process group; output also goes to `~/.local/state/tmux-opsx/preview/<project>/<change>.log`. The window stays open after the app exits.
5. **Health.** `http://127.0.0.1:<port><health>` is polled until it answers 2xx/3xx. If the app exits or `timeout` passes first, the last log lines are printed, the app is stopped, and nothing is published.
6. **Publish** with `expose.sh up <port> --name <change> --project <project>`. The URL needs a login like any exposure (your owner cookie, or a link from `preview share`). The app must listen on `127.0.0.1` (use `$HOST`): if it binds `0.0.0.0`, expose refuses it and `preview` stops the app, closes its window and says to bind `127.0.0.1`. A second `preview` while it is healthy just prints the same URL. Two `preview` runs for the same change never race: the second waits for the first (including its health wait) and then reuses it, and a `preview stop` during a start waits for it and then stops it.

Failure output shows only the current run's log lines. State lives in `~/.local/state/tmux-opsx/preview/<project>/`; `land` (and every `up`/`stop`/`list`) prunes the files of changes whose worktree is gone, and `opsx-preview.sh prune` does it by hand.

`close` and `land` always stop the change's preview (route removed, process group killed, window closed); `close-all` stops every preview in the project. `opsx-preview.sh list` shows what is running.

**`.opsx/preview.yaml`** — flat `key: value` lines, `#` comments, one layer of quotes stripped:

| Key | Default | Meaning |
|---|---|---|
| `cmd` | — (required) | Starts the app; run with `bash -c` in the checkout. Must listen on `$PORT` |
| `install` | none | Run before the first start and again when it or a lockfile changes |
| `health` | `/` | Path polled until it returns 2xx/3xx |
| `timeout` | `120` | Seconds to wait for health |

<!-- preview-example -->
```yaml
# .opsx/preview.yaml — a Next.js app with pnpm
install: pnpm install
cmd: pnpm dev --port $PORT --hostname 127.0.0.1
health: /
timeout: 180
```

**Detection** (no `.opsx/preview.yaml`): a `package.json` with a `dev` script runs with the package manager its lockfile implies — `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `bun.lock`/`bun.lockb` → bun, otherwise npm — as `<pm> run dev --port $PORT` (`npm run dev -- --port $PORT` for npm), with `<pm> install` as the install step. `preview` prints a `detected:` line so you can see the guess. If the dev script hard-codes its own port (`-p 3000`), the health check fails with the log tail; add a one-line `.opsx/preview.yaml`.

**Bind to `127.0.0.1`.** Many dev servers ignore `HOST` and listen on every interface, which makes the app reachable at `<server-ip>:<port>` without going through Caddy. Pass the binding flag in `cmd` — `--hostname 127.0.0.1` for Next.js, `--host 127.0.0.1` for Vite — and keep a host firewall that allows only 22 and 443.

`bash tests/test-preview.sh` covers recipes, detection, install hashing, health failures, reuse, stop, `--main`, containerised previews, close/close-all/land teardown and the README example above, against a fake `expose.sh` and a fake `docker` on a private tmux server.

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

Removes the `opsx` command (only if it is the tmux-opsx launcher), the `/opsx-run`, `/opsx-init`, `memory`, `/fork` and `/graphify` skills (including `opsx-eval.sh`), the subagents (ops-applier, ops-eval, ops-reviewer, ops-security, ops-qa), the global OpenSpec skills and `/opsx:*` commands, the memory instruction blocks from every CLI, and graphify's global Gemini block/hook and OpenCode plugin. The OpenSpec and Graphify CLIs stay installed (the script prints how to remove them), browser-use MCP entries are left in place, and neither `~/.agents/memory/` nor fork state (`${XDG_STATE_HOME:-~/.local/state}/agent-forks/`) is ever deleted. The opt-in `/expose` setup is not removed either; see [Expose](#expose) for the manual steps.

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
- `opsx dev` and containerised previews assume a Linux host with Docker (host networking). Agents are only *told* to use `opsx dev`; nothing forces them.
- Back-to-back sends to the same window are spaced slightly, because the Claude TUI can concatenate two prompts into one input box otherwise.

## License

MIT
