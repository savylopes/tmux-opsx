# Tasks

## 1. Detect the conflict

- [x] 1.1 `skills/opsx-pr/pr.sh`: add `mergeable` to `PR_FIELDS` and `CUR_mergeable` to `snapshot`, reading a missing field as empty; verify with `pr.sh wait` against the fake `gh`
- [x] 1.2 `detect_event`: after `head-moved`, return `conflict` for `CONFLICTING` with a non-empty base tip and an unreported `<head>:<base>` pair; `cmd_wait` records `conflict_reported` when it prints the event; `seen` leaves it alone
- [x] 1.3 `tests/test-pr.sh`: cases for every scenario of "Detect a conflicting PR" (reported, once, seen does not hide, new base tip, `UNKNOWN`, base-moved wins, empty base tip); verify with `bash tests/test-pr.sh`
- [x] 1.4 `evals/pr-maintain/`: add `conflict-reported.check`, `conflict-reported-once.check`, `conflict-not-hidden-by-seen.check`, `conflict-new-base-tip.check`, `conflict-still-computing.check`, `conflict-base-moved-wins.check`; verify each passes under `opsx-eval.sh`

## 1b. Back off between polls

- [x] 1b.1 `cmd_wait`: tick every `--poll` for `check_gen` and `last_wait_at`, poll only when `next_poll_at` is due, advance `poll_step` after a successful poll, cap at 3600 s; resets in event, `seen`, `push`, `rerun`, `start`, `restart-input`; verify with `tests/test-pr.sh` cases for all "Back off between polls" scenarios
- [x] 1b.2 `evals/pr-maintain/`: add `poll-gaps-grow.check`, `poll-gap-capped.check`, `poll-seen-starts-over.check`, `poll-backoff-stop.check`, `poll-backoff-liveness.check`; verify they pass under `opsx-eval.sh`

## 2. Tell the window

- [x] 2.1 `prompt_text`, Events section: add the `conflict` entry with the acknowledge path and the rebase path, reusing the existing PRE/OLDBASE and fix round wording; verify with `pr.sh prompt 42 --agent-cli claude` and `--agent-cli codex`, and a `tests/test-pr.sh` case plus `evals/pr-maintain/conflict-in-prompt.check`
- [x] 2.2 Update the event lists in the `pr.sh` header, `skills/opsx-pr/SKILL.md` and `README.md`, and add a README paragraph beside "CI failures"; verify with `grep -n 'head-moved' skills/opsx-pr/SKILL.md README.md skills/opsx-pr/pr.sh` showing `conflict` in each list

## 3. Integration checks

- [x] 3.1 Run `shellcheck skills/opsx-pr/pr.sh`, `bash tests/test-pr.sh` and `openspec validate pr-conflict-event --strict`; all pass
- [x] 3.2 Read-only check against a live conflicting PR: `gh pr view 34 -R eclipse-xfsc/facis-zero-trust-demonstrator --json mergeable` returns `CONFLICTING` through the new `PR_FIELDS`

## Workflow follow-up

- Install the new `pr.sh` and refresh running windows with `learned-refresh-pr-maintainers`, only when the user asks; pr-17 has a fix round running.
- Archive the change after the gates pass.
