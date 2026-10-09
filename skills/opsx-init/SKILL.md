---
name: opsx-init
description: "Set up the current git repo for tmux-opsx and OpenSpec: run `opsx init` (openspec init --tools none, openspec/config.yaml with a context: skeleton, graphify-out/ in .gitignore, .opsx/dev.yaml from the detected toolchain, docker check), then replace the context: skeleton with a description written from the actual repo. Never overwrites user files, never commits. Use when the user types /opsx-init, or asks to 'init this repo for opsx', 'set up openspec here', or 'write the openspec context'. Trigger: /opsx-init"
trigger: /opsx-init
---

# /opsx-init

Set up the repo the user is in, then write its OpenSpec `context:`. Two parts:

1. **`opsx init`** does every deterministic step (shell, idempotent, never commits).
2. **You** replace the `context:` skeleton in `openspec/config.yaml` with a short description of the repo — only while the skeleton marker is still there.

## Usage

| Command | What it does |
|---|---|
| `/opsx-init` | `opsx init` in the current repo, then write `context:` |
| `/opsx-init --git` | `git init` first when the directory is not a repo yet |
| `/opsx-init --graphify` | also build the code graph (`graphify update .`, no LLM) |
| `/opsx-init --force config` | regenerate `openspec/config.yaml` (skeleton), then write `context:` |
| `/opsx-init --force dev` | regenerate `.opsx/dev.yaml` from the toolchain files |

Flags combine and pass straight through to `opsx init`. Only `config` and `dev` are valid for `--force`; reject anything else.

## Step 1 — run `opsx init`

Run it from the repo root (or the directory the user named) with exactly the user's flags:

```bash
opsx init [--git] [--graphify] [--force config|dev]
```

When `opsx` is not on PATH (e.g. `~/.local/bin` missing from PATH), run the script that ships next to this file instead:

```bash
OPSX_INIT=$(ls ~/.claude/skills/opsx-init/opsx-init.sh ~/.cursor/skills/opsx-init/opsx-init.sh \
  ~/.agents/skills/opsx-init/opsx-init.sh ~/.codex/skills/opsx-init/opsx-init.sh \
  ~/.config/opencode/skills/opsx-init/opsx-init.sh ~/.gemini/skills/opsx-init/opsx-init.sh 2>/dev/null | head -n1)
bash "$OPSX_INIT" [--git] [--graphify] [--force config|dev]
```

Relay its output to the user: the `✓` (created), `·` (skipped) and `!` (warning) lines and the closing summary with the `git add` line. If it exits non-zero (not a git repo, missing `openspec` CLI, bad `--force` value), show the message and stop — do not write anything yourself. Never run `git add` or `git commit` for the user.

## Step 2 — write `context:` (only over the skeleton)

Find the config: `openspec/config.yaml`, else `openspec/config.yml`.

- **If the file contains the line `# opsx-init: context skeleton`**, replace the whole `context:` block (from `context: |` down to the last indented line of that block) with a description of this repo, and remove the marker.
- **If the marker is absent, leave `context:` unchanged** — the user (or an earlier run) wrote it. Say so and stop. Do not "improve" or merge into a user-written context.
- If there is no config file at all, say so and stop.

Change nothing else in the file: keep `schema:`, `rules:`, comments and any other keys byte-for-byte.

### What to write

Read the repo first — README, manifest files (`go.mod`, `package.json`, `pyproject.toml`, …), the top-level layout, CI config, test scripts, `.opsx/dev.yaml` — and use `graphify-out/` if it exists. Then write a YAML literal block, 2-space indented, roughly 10–25 lines, covering:

- **Purpose** — what the project does and for whom, one or two sentences.
- **Stack** — languages, frameworks, key libraries, versions that matter.
- **Layout** — the main directories and what lives in each.
- **Conventions** — style, naming, error handling, commit or branching rules you can see in the repo.
- **Tests** — the exact commands to run tests, lint and build.

Prefer facts that guide OpenSpec proposals and tasks (constraints, supported platforms, things not to break) over general documentation. State only what the repo shows; do not invent commands. Example shape:

```yaml
context: |
  Purpose: CLI that syncs Markdown notes to a static site.
  Stack: Go 1.22, cobra, goldmark; no cgo.
  Layout: cmd/ entry points, internal/ packages, testdata/ fixtures.
  Conventions: errors wrapped with fmt.Errorf("...: %w"); no global state.
  Tests: go test ./... ; golangci-lint run
```

After writing, check the file still parses as YAML (e.g. `openspec validate --all` or `python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' openspec/config.yaml` when available).

## Finish

Tell the user what was created, show the `git add` line from the summary (adding the config file if you changed it), and leave staging and committing to them.
