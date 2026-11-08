# Proposal

## Why

`pr.sh wait` never asks GitHub whether a PR can merge, so a conflict is only found as a side effect: `base-moved` fires, and the window hits the conflict when it tries to rebase. Any path that skips that step hides the conflict. On 2026-11-06, after #20 and #29 merged, six of seven maintained FACIS PRs were `CONFLICTING`; every state file already held the new base SHA, so their monitors report "no change" while the PRs stay conflicted.

## What Changes

- `pr.sh wait` doubles the gap between its GitHub polls, up to one hour, so a quiet PR costs far fewer API calls. Anything that changes the PR starts the progression over. A quiet PR can take up to an hour to report a change.
- `pr.sh wait` reports a new event, `conflict`, when GitHub says the PR is `CONFLICTING`.
- The event fires once per head and base pair. `wait` records the pair; `seen` never does, so `seen` cannot hide a conflict that appeared while the window was busy, or one already there when the watch started.
- `UNKNOWN` (GitHub still computing) and `MERGEABLE` never raise the event.
- The maintain prompt gets a `conflict` entry: rebase through the existing conflict path, or acknowledge when an open question or a running rebase already covers it.

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

- `pr-maintain`: the wait event kinds gain `conflict`; new requirements cover when it fires, how the prompt handles it, and the poll backoff.

## Impact

- `skills/opsx-pr/pr.sh`: `PR_FIELDS`, `snapshot`, `detect_event`, `cmd_wait`, header comment, Events section of the prompt.
- `skills/opsx-pr/SKILL.md`, `README.md`: the event lists.
- `tests/test-pr.sh`, `evals/pr-maintain/`: new cases and checks.
- Running windows keep the old behaviour until the new `pr.sh` is installed and they are refreshed. On the first wait after that, each PR that is still conflicting raises `conflict` once.
