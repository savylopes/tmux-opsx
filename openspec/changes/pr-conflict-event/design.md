# Design

## Context

See proposal.md for the motivation. `detect_event` compares a `snapshot` with the state file. `PR_FIELDS` has no `mergeable`, and `seen` overwrites `base_sha`, so after any `seen` the conflict signal is gone. `ci_reported` already solves the same problem for CI: `wait` records it, `seen` does not.

## Goals / Non-Goals

**Goals:**
- A conflicting PR is reported from GitHub's own answer, whatever happened to `base_sha`.
- A held conflict does not wake the window on every poll.

**Non-Goals:**
- Informal stacks. The FACIS PRs share commits but all target `main`, so `parent=` is empty and a push to one raises nothing in the others. Windows work around this with ad-hoc pollers. This is a larger, separate problem.
- A `seen` that absorbs a base move while the PR stays mergeable. The PR is still mergeable, so the goal holds.
- Resolving the conflicts currently open on the FACIS PRs. Those wait on the questions already asked in the windows.

## Decisions

**Use `mergeable` from the existing `gh pr view` call.** It adds no API call per poll. `mergeStateStatus` was rejected because it also mixes in CI and review state. A local `git merge-tree` was rejected because it needs a fetch on each poll and can disagree with what the PR page shows.

**Key on head and base, with no clearing.** The event fires only for a pair not yet reported, so `UNKNOWN` needs no handling and a flip between `MERGEABLE` and `CONFLICTING` on the same pair cannot re-fire. This is simpler than copying `clear_ci_reported`, which has to clear because a failed check on one head can legitimately fail again after a re-run. A merge result for one head and base cannot change.

**Skip the check without a base tip.** `remote_tip` prints nothing when `ls-remote` fails. An empty base would form a new pair and re-fire on every network blip.

**Priority: after `head-moved`, before `ci-failed` and `comments`.** The moves already lead to a rebase, and a later wait still reports the conflict if it remains. A conflict outranks CI because CI results mean little on a branch that must be rebased anyway. The spec's kind list does not encode priority, so its order stays close to the existing text.

**The prompt keeps an acknowledge path.** After `base-moved`, a stopped rebase and a question, the next wait reports `conflict` for the same situation. Without this rule the window would redo the rebase or ask again. Acknowledging costs one short turn per head and base pair.

**Back off in `pr.sh wait`, persisted in the state.** On Claude Code one call lasts at most 170 s, so a counter inside one call would never pass the first gaps. `poll_step` and `next_poll_at` carry the position across calls. The loop still ticks every `--poll` seconds for `check_gen` and `last_wait_at`, so `stop`, a refresh and `watch=` are unaffected, and only the GitHub calls are skipped. No new flag: the monitor guard allows an exact command shape.

**The monitor's schedule stays as it is.** The monitor still makes a call every 170 s and returns `idle` about every 25 minutes. The backoff therefore saves GitHub requests, not agent turns. Reducing those means changing `max-calls` and the monitor contract, a separate decision.

**What starts the progression over.** Events, `seen`, `push`, `rerun`, `start` and `restart-input`: each means the window just acted, and quick follow-ups are likely. A window question or `note` does not, since nothing on the PR changes until the user answers and the window acts.

## Risks / Trade-offs

- [A quiet PR reports a merge, comment or moved base up to an hour late] → This is the requested trade-off. Own actions reset the gaps. `pr.sh seen` forces a poll on the next tick.

- [GitHub keeps returning `UNKNOWN`] → No event, the same as today, and `base-moved` still fires.
- [Rollout wakes every conflicting window once] → Their open questions already cover it, so each takes the acknowledge path. Roll out when a short burst of turns is acceptable.
- [Refreshing while a fix round runs, as in pr-17 now] → Follow the `learned-refresh-pr-maintainers` procedure and pick a quiet moment. `pr.sh start` raises `monitor_gen`, and the window then restarts its monitor.

## Migration Plan

No state migration: a missing `conflict_reported` reads as nothing reported. Install, then refresh running windows. To roll back, reinstall the previous `pr.sh`; the extra state line is ignored.
