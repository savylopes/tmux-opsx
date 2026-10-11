# Tasks

## 1. Eligibility and session discovery in fork.sh

- [x] 1.1 Spike: with the real `claude`, start a throwaway session in a scratch dir, then from another dir run `claude --resume <id> --fork-session -p 'say ok'` and record in design.md whether resume works across directories; keep or drop the cwd rule accordingly (specs' "Different cwd" scenario must be updated in the same step if dropped)
- [x] 1.2 Add `parent_session_id` (env `CLAUDE_CODE_SESSION_ID`, else `recover_env_var`, UUID-validated) and `native_mode <cli> <cwd> <brief_only>` returning `full <cli> <source>` or `brief <reason>` per design Decision 3, honouring `FORK_NATIVE=0`; verify with `tests/test-fork.sh` cases: claude host + id → `full claude session S`; cross-CLI → `brief`; `--cwd` elsewhere → `brief`; `FORK_NATIVE=0` → `brief`; stripped env recovered through an intermediate `env -u` shell
- [x] 1.3 Add the `fork.sh native [--cli <name>] [--cwd <dir>]` subcommand (no stdin, no writes, exit 0 both ways) and the `--brief-only` flag to `open`; document both in the header comment and `help`; verify `fork.sh native --cli gemini` prints a `brief` line naming gemini and `fork.sh help` lists `native` and `--brief-only`

## 2. Native launch, meta and list

- [x] 2.1 Extend `build_launch_cmd`: claude inserts `--resume <id> --fork-session`, opencode inserts `--continue --fork`, only when `native_mode` says `full`; verify in `tests/test-fork.sh` with fakes that the claude log has `--resume`, `S`, `--fork-session`, `--permission-mode`, `plan` and no bypass flags, the opencode log has `--continue`, `--fork`, `--agent`, `plan`, and that codex/gemini/agent and `--brief-only` launches contain none of `--resume`, `--fork-session`, `--continue`, `--fork`
- [x] 2.2 Record `context=full|brief` plus the source in `meta`, print the `# context:` line after the unchanged first `open` line, and add the CONTEXT column to `list`; verify the existing "open prints id/pane" and model-line tests still pass, `meta` has `context=full` with `S` for the native case and `context=brief` for `--brief-only`, and `list` shows a CONTEXT header with `full`/`brief` rows
- [x] 2.3 Run `shellcheck skills/fork/fork.sh` and the full `bash tests/test-fork.sh`; verify both are clean with every pre-existing test still passing

## 3. Skill and README

- [x] 3.1 Update `skills/fork/SKILL.md`: `/fork --brief` usage row; step 1 runs `"$FORK_SH" native` with the same `--cli`/`--cwd` and writes the short brief (Question + Role, no Context) on `full` or today's brief on `brief`; pass `--brief-only` for `/fork --brief`; rewrite the secrets note for full mode; add the context mode to the "report the output line" sentence; verify the file mentions `fork.sh native`, `--brief`, `--brief-only` and the short brief form, and `install.sh` in a scratch HOME still installs it for all five CLIs
- [x] 3.2 Update README "Fork" section: native forking table (claude `--resume --fork-session`, opencode `--continue --fork`, others brief), fallbacks, `/fork --brief`, CONTEXT column in the list row, the full-context and context-window note; verify README mentions `--fork-session`, `--brief` and the brief fallback

## 4. Integration

- [x] 4.1 Manual check inside a real tmux session on this machine with Claude Code: `/fork "what did we decide about X?"` opens a native child that answers from history without the parent having summarised it, `/fork return` and `/fork collect` work unchanged, and `/fork --brief` opens a brief-mode child; record the outcome in the change's apply report
  - Outcome (2026-10-11): not run in the live tmux session (off limits for the applier); run instead on a private tmux server with the real `claude` 2.1.296, parent = a scratch session that had been told the codeword PELICAN. `fork.sh native` printed `full claude session <id>`; the native child (plan mode, haiku) answered PELICAN from the inherited history with a Question+Role brief only; `fork.sh return` (allow rule) wrote `result.md`, `collect` returned it, `list` showed `full`; a `--brief-only` child answered UNKNOWN and showed `brief`; the parent transcript was unchanged. The haiku child first printed the return command instead of running it and needed a second prompt (model behaviour, not specific to native mode). `/fork` typed in a real interactive parent was not exercised.
- [x] 4.2 Run `openspec validate add-fork-native-resume --strict`; verify it passes

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.
