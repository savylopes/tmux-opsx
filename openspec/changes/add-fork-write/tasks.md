# Tasks

## 1. Launch and state

- [x] 1.1 Add `--write` to `fork.sh open` (refused with `--page-dir`), pass it to `build_launch_cmd`, record `write=0|1` in `meta`; verify in `tests/test-fork.sh` that `--write --page-dir` exits non-zero with no new fork and that `meta` has `write=0` without the flag
- [x] 1.2 In `build_launch_cmd`, use the normal mode per CLI with `--write` (Claude `--permission-mode manual`, or `default` on older versions, Codex `--sandbox workspace-write --ask-for-approval on-request`, OpenCode `--agent build`, Gemini `--approval-mode default`, Cursor no `--mode ask`), keep native and model flags, write a writable carve-out prompt for Claude, and add `Bash(<fork.sh> write:*)` to read-only Claude forks; verify in `tests/test-fork.sh` the flags of all five CLIs with `--write`, no bypass flags, and the allow rules of read-only plain and page forks

## 2. Protocol and child command

- [x] 2.1 `protocol_footer`: read-only variant names `/fork write` and the literal `fork.sh write` command; writable variant says the child may edit, warns about the shared checkout and asks for the changed files in the result; verify in `tests/test-fork.sh` both variants in `brief.md`
- [x] 2.2 Add `fork.sh write` (resolve own fork, `write=1` + `write_since`, pane title `fork <id> (write)`, notify the parent, mode-switch hint; already-writable is exit 0; not a fork is exit 1) and `list` status `<status>,write`; verify in `tests/test-fork.sh` meta, title, the repeat call, the outside-a-fork exit code and the list row; `shellcheck skills/fork/fork.sh` clean

## 3. Docs

- [x] 3.1 Update `skills/fork/SKILL.md` (parent `--write`, child `/fork write` with the per-CLI mode switch, the per-CLI table) and the `fork.sh` header; verify they mention `--write`, `fork.sh write` and `workspace-write`
- [x] 3.2 README Fork section: `--write`, `/fork write`, same-checkout warning; verify README mentions `/fork write` and `--write`

## 4. Integration

- [x] 4.1 Run `bash tests/test-fork.sh`, `bash tests/test-explain.sh` and `openspec validate add-fork-write --strict`; verify all pass

## Workflow follow-up

- Archive the change, land it, run the installer.
