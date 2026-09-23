## Context

The README opens with "Run OpenSpec changes in Claude Code, Cursor CLI, Codex CLI, OpenCode, or Gemini CLI without blocking your session" and is organised around `/opsx-run`. Memory, gates and (in progress) fork and eval are documented as add-ons. `openspec/` has only `specs/` and `changes/`; there is no `config.yaml`, so OpenSpec's planning instructions carry no project context.

## Goals / Non-Goals

**Goals:**
- A reader (human or agent) understands in the first screen that this is a personal harness and what its parts are.
- OpenSpec agents get project context automatically.

**Non-Goals:**
- Renaming the repo, commands, skills, paths or window prefix.
- Changing any behaviour, including ops-reviewer's markdown-only SKIP rule (kept as is by user decision).

## Decisions

### 1. README structure

```
# tmux-opsx
<one paragraph: my personal development harness for agent CLIs>

 your dev harness
 ├── workflow     /opsx-run …
 ├── gates        ops-reviewer · ops-security · ops-qa · ops-eval
 ├── context      memory · fork
 └── portability  install.sh → 5 CLIs

## Install
## Workflow (/opsx-run)        ← existing content, moved
## Gates                        ← reviewer/security/qa/eval, one short section each
## Context (memory, fork)       ← existing memory section; fork/eval added by their changes
## Supported CLIs
## Uninstall
```

Components that are not merged yet (fork, eval) are listed in the overview only once their change lands; this change must not document unshipped features. The overview tree is written so later changes add one line each.

### 2. `openspec/config.yaml`

Uses the OpenSpec project config format (`schema: spec-driven` plus a `context:` block; `rules:` only if needed). Context covers:
- purpose: personal development harness; the user is the only consumer;
- product surface: `install.sh`, `skills/*/` (SKILL.md + scripts), `agents/*.md`, tmux behaviour;
- supported CLIs and the rule that features should work across all five, degrading gracefully;
- conventions: bash, `shellcheck` clean, `.bak` backups on install, never push, never hand-roll `tmux send-keys`;
- tests: no unit test suite yet; verification is scripted in a scratch `HOME` and a private tmux socket.

Keep it under ~40 lines so it stays cheap in every planning prompt.

## Risks / Trade-offs

- **Context drift** — `config.yaml` can go stale as components are added → each future change that adds a component updates the overview tree and, if relevant, `config.yaml` (noted in its tasks).
