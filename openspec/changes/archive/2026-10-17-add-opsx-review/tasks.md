# Tasks

## 1. Script and tests

- [x] 1.1 Check `skills/opsx-review/opsx-review.sh` against every requirement in `specs/pr-review/spec.md` (resolve forms and ticket order, exit codes 2 and 3, read-only `gh`, session folding/refusal/hint, worktree create/reuse/refuse) and verify `bash tests/test-review.sh` passes and `shellcheck` is clean on both files
- [x] 1.2 Fill any spec scenario the test does not cover (the `session renamed <old> -> <new>` line, the remove command named on refusal) and verify the suite still passes

## 2. Skill text

- [x] 2.1 Check `skills/opsx-review/SKILL.md` names `resolve`, `session`, `worktree`, `openspec validate`, `/opsx-run <change> --validate`, `--no-run`, `--no-session`, `report.md`, `pr-comment.md`, `questions.md` and the no-posting rule; verify with grep

## 3. Install and documentation

- [x] 3.1 Verify in a scratch HOME that `install.sh` installs `~/.claude/skills/opsx-review/{SKILL.md,opsx-review.sh}` executable, `--help` lists `--skip-review`, `--skip-review` leaves no `opsx-review` folder, and `--uninstall` removes it
- [x] 3.2 Verify README mentions `/opsx-review`, `opsx-review.sh`, `--skip-review` and `pr-comment.md`

## 4. Integration

- [x] 4.1 Run `bash tests/test-review.sh`, `shellcheck` on the script and test, and `openspec validate add-opsx-review --strict`; verify all pass

## Workflow follow-up

- Land only the review hunks of `install.sh` and `README.md`; the other uncommitted work stays out.
- Archive the change, then run the installer.
