# Tasks

## 1. Model selection in fork.sh

- [ ] 1.1 Parse `--model <m>` and `--parent-model <m>` in `cmd_open`, validate both (non-empty, no whitespace, no leading `-`) before `alloc_id`, and verify `fork.sh open --model "--x"` exits non-zero and leaves no new state directory
- [ ] 1.2 Add a `host_cli` helper (honours `$FORK_HOST_CLI`, `none` = undetected; else the existing `running_under_*` checks, no PATH fallback) and a `resolve_model` step implementing `--model` > `$FORK_MODEL` > `--parent-model` (same CLI only; OpenCode only with `provider/model`) > none; verify with `bash -n` and shellcheck
- [ ] 1.3 Pass the resolved model to `build_launch_cmd` and emit the per-CLI flag (`--model` for claude/agent, `-m` for codex/opencode/gemini) quoted with `%q`, emitting no flag when empty; verify by inspecting `launch.sh` for each CLI with the fake CLIs
- [ ] 1.4 Record `model=` in `meta`, append `model <m|default>` to the `open` output line, update the header usage/selection comment, and verify `fork.sh help` shows `--model`, `--parent-model`, `$FORK_MODEL` and `$FORK_HOST_CLI`
- [ ] 1.5 Add tests to `tests/test-fork.sh` (with `FORK_HOST_CLI` set explicitly in each case): explicit model, no model, `$FORK_MODEL`, flag beats env, per-CLI spelling for all five CLIs, unsafe value rejected, same-CLI inheritance, cross-CLI no inheritance, env beats inheritance, `FORK_HOST_CLI=none`, OpenCode bare id ignored, `meta` model field, output line; verify `bash tests/test-fork.sh` passes with no FAIL lines

## 2. List column

- [ ] 2.1 Add a MODEL column (value or `default`) to `cmd_list` between CLI and PANE, and verify with a `tests/test-fork.sh` case that the header has MODEL and rows show `haiku` / `default`

## 3. Skill and docs

- [ ] 3.1 Update `skills/fork/SKILL.md`: the parent step always passes `--parent-model <your own model id>` (with a note that `fork.sh` ignores it for other CLIs), adds `--model` only when the user names one, documents `$FORK_MODEL` in the usage table and synopsis, and shows the new output line in step 2; verify by grepping the file for `--parent-model`, `--model` and `FORK_MODEL`
- [ ] 3.2 Update the README Fork section: a `/fork --model <m> …` row, the inheritance and precedence rules, `$FORK_MODEL`, and the MODEL column in the `/fork list` row; verify the documented `fork.sh open --model` invocation runs against a private tmux server (`tmux -L`)

## 4. Integration

- [ ] 4.1 Where `agent`, `codex`, `opencode` or `gemini` is installed, confirm its model flag spelling against `<cli> --help` and record any CLI you could not check; verify `bash tests/test-fork.sh` and `shellcheck skills/fork/fork.sh tests/test-fork.sh` both pass
