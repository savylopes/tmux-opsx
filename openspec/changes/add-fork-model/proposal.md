# Proposal

## Why

A `/fork` child is launched with no model flag, so it runs on its CLI's default model, which is often not the parent's. A fork is meant to be "the same agent on the side". A child on a different model answers side questions differently from the session it was forked from, and the user has no way to choose otherwise.

## What Changes

- `fork.sh open` gains `--model <m>`: an explicit model for the child, passed to the child CLI's own model flag.
- `fork.sh open` gains `--parent-model <m>`: the parent agent's own model. It is applied only when the child runs on the same CLI as the parent, and only if nothing more specific was asked for.
- New `$FORK_MODEL` environment default, following the `$FORK_CLI` pattern.
- Precedence: `--model` > `$FORK_MODEL` > `--parent-model` (same CLI only) > the CLI's default (no flag, as today).
- The `/fork` skill tells the parent agent to always pass `--parent-model <its own model id>`, so forks inherit the parent's model by default.
- The chosen model is recorded in the fork's `meta`, shown on the `open` output line (`… cli <cli> model <m|default>`) and in a MODEL column of `fork.sh list`.
- README fork section and `/fork` usage table document `--model` and `$FORK_MODEL`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `tmux-fork`: adds model selection and parent-model inheritance for children, records the model in fork state, and shows it in `open` output and `list`.

## Impact

- `skills/fork/fork.sh`: option parsing in `open`, model resolution, `build_launch_cmd` for all five CLIs, `meta`, `list`, the header usage comment.
- `skills/fork/SKILL.md`: parent instructions (always pass `--parent-model`), usage table, script synopsis, output line.
- `tests/test-fork.sh`: new cases for precedence, per-CLI flag spelling, same-CLI gating, `list` column.
- `README.md`: Fork section.
- No install.sh change; no new dependencies.
