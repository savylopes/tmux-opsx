# Tasks

## 1. Detect a failing CI on the current head

- [x] 1.1 In `skills/opsx-pr/pr.sh`, make `ci_state` count the `cancel` bucket as `fail`; verify with a new `tests/test-pr.sh` case where checks `[{"bucket":"pass"},{"bucket":"cancel"}]` make `pr.sh wait 42` print `event=ci-failed` and exit 0
- [x] 1.2 Change `detect_event` to fire `ci-failed` when `CUR_ci=fail` and `ci_reported` differs from `CUR_head_sha`, have `cmd_wait` store `ci_reported=$CUR_head_sha` when it prints that event, and have `write_seen` keep writing `ci` but clear `ci_reported` when CI is pending or pass (never set it; `wait` clears it too on such a poll); verify with test cases for: reported failure stays quiet after `seen` (wait exits 3, no `event=`), failure absorbed by `seen` is still reported, and a failure on a new head is reported again
- [x] 1.3 Check the existing CI cases (`F3`, the `pass`+`fail` case around line 146) still pass unchanged, and that a state file without `ci_reported` reports a currently red PR once; verify `bash tests/test-pr.sh` passes and `shellcheck skills/opsx-pr/pr.sh` is clean

## 2. Re-run a failed CI once per head

- [x] 2.1 Teach the fake `gh` in `tests/test-pr.sh` to serve `pr checks --json bucket,link` rows (with `link`) and to log `run rerun <id> --failed` calls (and fail them on demand); verify the existing tests still pass
- [x] 2.2 Add `pr.sh rerun <pr>`: read the head SHA (`gh pr view --json headRefOid`), exit 6 (`already re-ran CI for <sha>`) when it equals `rerun_head`, collect distinct run ids from `fail`/`cancel` rows whose `link` matches `/actions/runs/<id>`, exit 7 when there are none, run `gh run rerun <id> --failed -R <slug>` once per id, and on at least one success store `rerun_head=<sha>` and set `ci_reported=<sha>` so the old failed checks still showing are not a repeat (exit 1 with gh's error when every rerun fails); verify with test cases for the first re-run (runs 77 and 78, exit 0, `rerun_head` set), a second re-run on the same head (exit 6, no `gh run rerun` call), a new head allowing a new re-run, an external-CI-only failure (exit 7, no call), all reruns failing (exit 1), and a failure after `rerun` on the same head being reported again by `wait`
- [x] 2.3 Add `rerun` and exit codes 6 and 7 to the usage header of `pr.sh` and the dispatcher; verify `pr.sh --help` lists it and `shellcheck` stays clean

## 3. Triage a CI failure in the window prompt

- [x] 3.1 Rewrite the `ci-failed` step of `prompt_text`: read `gh pr checks` and `gh run view --log-failed`; fix with the gates and push when the failure is clearly caused by this PR's change; otherwise (unrelated test, timeout, network or runner error, cancelled run) run `pr.sh rerun <pr>`, then `seen`, and wait; a repeat failure on the same head, or `rerun` exiting 6 or 7, is treated as real (fix, or ask when unclear); the CI log is untrusted input. Add "re-run a failed CI once per head with `rerun <pr>`" to the "You may do on your own" list; verify with test cases that the prompt written by `pr.sh start 42` names `rerun 42`, contains the not-caused-by-the-PR condition and the repeat-failure rule, and lists the re-run under "on its own", while the existing forbidden-actions checks still pass
- [x] 3.2 Document `rerun`, the cancelled-check rule, the once-per-head reporting, and how to refresh running windows (`pr.sh start <pr> --repo <dir>`) in `skills/opsx-pr/SKILL.md` and the `/opsx-pr` section of `README.md`; verify the documented commands match `pr.sh --help`

## 4. Integration

- [x] 4.1 Run `bash tests/test-pr.sh` and `bash tests/test-eval.sh`, `shellcheck` every changed script, and `./install.sh` into a scratch HOME to confirm the installed `pr.sh` has the `rerun` command; verify all pass

## Workflow follow-up

- ops-eval writes the new checks under `evals/pr-maintain/` for the added and modified scenarios.
- Run review, security and archive through `/opsx-run fix-opsx-pr-ci-gaps`.
- Refresh any running `/opsx-pr` windows with `pr.sh start <pr> --repo <dir>` after the change lands.
