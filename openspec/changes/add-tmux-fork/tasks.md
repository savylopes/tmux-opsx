## 1. Verify CLI behavior (spike)

- [ ] 1.1 For each CLI (claude, agent, codex, opencode, gemini), find the read-only/plan launch flag and confirm it still accepts a seeded first prompt; record results in design.md Decision 4
- [ ] 1.2 Confirm each CLI passes `FORK_ID`/`FORK_DIR`/`FORK_PARENT` from its launch environment through to its shell tool
- [ ] 1.3 Confirm whether each read-only mode allows running `fork.sh return` writing under `~/.local/state/agent-forks/`; note which CLIs need the marker-block fallback

## 2. fork.sh core

- [ ] 2.1 Create `skills/fork/fork.sh` with subcommand dispatch, `$TMUX` check (all but `return`), and state-dir resolution per tmux session
- [ ] 2.2 Implement atomic id allocation (`mkdir`) and `meta` read/write helpers
- [ ] 2.3 Implement CLI detection (copying the pattern from `opsx-window.sh`) and `--cli` override
- [ ] 2.4 Implement the per-CLI read-only launch command builder, never using bypass/force flags

## 3. fork.sh subcommands

- [ ] 3.1 `open [--window] [--vertical] [--cli X]`: read brief from stdin, write `brief.md`/`meta`, split pane (`-h -l 40%`) or new window `fork-<id>`, set env vars, apply `main-vertical` when the parent has >1 child, print id and pane
- [ ] 3.2 `return`: read result from stdin, write `result.md`, set status, `display-message` + badge on the parent pane, succeed if parent is gone, error clearly when `FORK_DIR` is unset
- [ ] 3.3 `collect [id]`: default to latest returned fork; print `result.md`, else marker block from `capture-pane -S -`, else labelled raw capture tail; clear the badge
- [ ] 3.4 `list`: id, status, CLI, pane, first line of question for the current session
- [ ] 3.5 `close <id>|--all`: save `capture.txt` when no result, kill pane/window, set `closed`, keep state

## 4. SKILL.md

- [ ] 4.1 Write `skills/fork/SKILL.md` frontmatter (name, description with triggers, `trigger: /fork`) and usage table
- [ ] 4.2 Document how the parent writes the brief (sections, 5–15 context lines) and pipes it to `fork.sh open`
- [ ] 4.3 Document `/fork return` in the child: result format (answer, evidence, unresolved; ~40 lines max) and the marker-block fallback
- [ ] 4.4 Document `collect`, `list`, `close`, and the rule never to hand-roll tmux commands or send keys to the parent

## 5. install.sh

- [ ] 5.1 Add `--skip-fork` to flags, header comment and `--help`
- [ ] 5.2 Install `skills/fork/` to the six skill folders following `install_memory_skill`, keeping `fork.sh` executable
- [ ] 5.3 Remove the six `fork/` folders on `--uninstall`, leaving `agent-forks/` state untouched

## 6. Docs and verification

- [ ] 6.1 Add a Fork section to `README.md`: purpose, commands, pane/window modes, read-only behavior per CLI, state location
- [ ] 6.2 Run `bash -n` and `shellcheck` on `fork.sh` and `install.sh`
- [ ] 6.3 Manual test in tmux with Claude: open pane, ask, return, notify badge, collect, list, close
- [ ] 6.4 Repeat 6.3 for each other installed CLI, including the sandbox fallback path where it applies
- [ ] 6.5 Test outside tmux (clear error), two concurrent forks (distinct ids), collect on a never-returned fork, and closing when the parent pane is gone
- [ ] 6.6 Test install in a scratch `HOME`: fresh, re-run, `--skip-fork`, `--uninstall` keeps state
