# Tasks

## 1. Config files and resolver

- [x] 1.1 Add `agents/models.conf` with the shipped defaults (Claude: applier/reviewer/security `opus`, eval/qa `sonnet`; every `agent.*` and `opencode.*` key `inherit`; header comment explaining the format and the user file path); verify by grepping the file for all 15 keys
- [x] 1.2 In `skills/opsx-run/opsx-window.sh`, add config loading (`$OPSX_MODELS_CONF` > `<script dir>/models.conf` > `<script dir>/../../agents/models.conf`, merged with `${XDG_CONFIG_HOME:-$HOME/.config}/tmux-opsx/models.conf`, ignoring blanks and `#` comments) and per-CLI validation (Claude shape check; Cursor `agent models` membership with 10 s timeout, accept when unavailable; OpenCode `provider/model` plus `opencode models` membership when available); verify with `bash -n` and shellcheck
- [x] 1.3 Add `opsx-window.sh models [<change>] [--agent-cli <cli>] [--<agent>-model <m>]...` printing `<agent> <model> <source>` for all five agents in the order flag > `@opsx_model_<agent>` > config > inherit, skipping invalid values with a stderr warning, using the window's `@opsx_agent_cli` when the window exists, and reporting all `inherit inherit` for codex/gemini; update the header usage comment and verify `models --agent-cli claude` prints the shipped defaults
- [x] 1.4 Add `tests/test-agent-models.sh` (scratch HOME/XDG, private `tmux -L` server, fake `agent`/`opencode` binaries for the model-list commands) covering: shipped defaults, user override of one key, no user file, Claude rejecting `gpt-5`, OpenCode bare id, invalid flag falling through; verify `bash tests/test-agent-models.sh` passes with no FAIL lines

## 2. Window memory

- [x] 2.1 Parse the five `--<agent>-model` flags in `cmd_ensure` and `cmd_send`, reject empty/whitespace/leading-`-` values before any window is created, set `@opsx_model_<agent>` for each flag after the window is found or created, unset it for `default`, and print one stderr note and store nothing for codex/gemini windows; verify with `bash -n` and shellcheck
- [x] 2.2 Show remembered models as `<agent>=<model>` pairs in `cmd_list` and before the pane capture in `cmd_status`; verify against a window with `@opsx_model_qa=haiku` on the private tmux server
- [x] 2.3 Extend `tests/test-agent-models.sh` with: unsafe flag value leaves no window, flag stored and other agents unset, later `send` reuses it (`models` reports `window`), flag beats remembered, `default` clears, close-and-recreate starts empty, `list` shows `qa=haiku`, codex window ignores flags with one note, `ensure --model haiku` sets no `@opsx_model_*` and leaves `applier opus config`; verify the script passes with no FAIL lines

## 3. Install

- [x] 3.1 In `install.sh`, install `agents/models.conf` as `models.conf` next to `opsx-window.sh` in every opsx-run skills dir, and for Claude Code, Cursor and OpenCode write each agent file's frontmatter `model:` from `opsx-window.sh models --agent-cli <cli>` (Claude/Cursor `model: inherit` for inherit, OpenCode no key), leaving Codex and Gemini agent files unchanged; verify with `bash -n` and shellcheck
- [x] 3.2 Make `install.sh` print a warning naming `<cli>.<agent>` and the value for each config model that fell back to inherit, and still exit 0; verify in a scratch HOME with `claude.security = gpt-5` in the user file
- [x] 3.3 Add install cases to `tests/test-agent-models.sh` (scratch HOME): Claude reviewer `opus` and qa `sonnet`, user override `claude.reviewer = haiku` reaches the file, OpenCode applier has no `model:` line, invalid `claude.security` warns and writes `inherit`; verify the script passes with no FAIL lines

## 4. Skill and docs

- [x] 4.1 Update `skills/opsx-run/SKILL.md`: usage lines for the five flags, a "Per-agent models" section (resolution order, memory, `default`, Codex/Gemini note), the caller step to run `models` and forward the flags to `ensure`/`send`, and every dispatcher template naming a model only for `flag`/`window` sources, dropping `model: inherit`, and adding the retry-once-without-a-model rule; verify by grepping for all five flags, the retry rule, and no remaining `model: inherit` spawn instruction
- [x] 4.2 Update `README.md` opsx-run section: `agents/models.conf`, the user override file, the five flags, the order flag > window > config > inherit, re-run `install.sh` after editing the config, and the Codex/Gemini gap; add the new test to the tests list; verify the documented `opsx-window.sh models --agent-cli claude` command runs as written in a scratch HOME

## 5. Integration

- [x] 5.1 Run `./install.sh` in a scratch HOME and confirm the five Claude agent files carry the expected models, then run `bash tests/test-agent-models.sh`, `bash tests/test-fork.sh` and `bash tests/test-preview.sh` and confirm all pass
