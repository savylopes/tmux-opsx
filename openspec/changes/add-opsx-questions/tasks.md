# Tasks

## 1. `questions.sh` engine

- [x] 1.1 Create `skills/opsx-questions/questions.sh`: bash, `set -euo pipefail`, a usage header for `--help`, `die`, and the repo top level from `git rev-parse --show-toplevel` or `--repo`. Add `tests/test-questions.sh` (scratch repos, no network). Verify that `questions.sh --help` exits 0 and lists `extract`, `cite`, `run`, `record` and `status`.
- [x] 1.2 Add `extract <change> --mode answer|challenge [--include-requirements]`:
  - name check `[A-Za-z0-9-]`, exit 2 on an unsafe or missing change;
  - `## Open Questions` (design.md) and `## Open Points` (proposal.md) items, skipping `Resolved:`;
  - `## Decisions` as `###` headings, or top-level items when there are no headings;
  - `### Requirement:` in the change's specs only with the flag;
  - TSV output with `path:line`.
  
  Verify the open-questions, decisions, requirements-only-on-request, unknown-change and unsafe-name scenarios. Also run it against this repo's `add-opsx-workspace` change and check that it prints its two open questions.
- [x] 1.3 Add `cite <path> <line> <excerpt>`: `realpath -m` confinement to the repo or `~/.agents/memory` (exit 3), missing file (exit 2), a ±2-line window with collapsed whitespace (0/1). Verify the nearby-match, fabricated-citation and outside-repo scenarios.
- [x] 1.4 Add `run new <mode> --questions-file <tsv> [--max] [--rounds]`: run id `YYYYmmdd-HHMMSS-<rand4>`, `questions.tsv`, `meta`, an empty `verdicts.tsv`, and `.opsx/questions/` appended to `.gitignore` once. Refuse more than `--max` questions without creating the run. Verify the too-many-questions scenario and that one `.gitignore` line remains after two runs.
- [x] 1.5 Add `record` (stage vocabulary, round cap and question checks) and `status`, which replays `verdicts.tsv` through the D3 state machine for settle, and gives the plain verdict for answer and challenge modes. Verify the settled, reopen, untested, contested-at-cap and wrong-vocabulary scenarios, and the run-leaves-the-repo-untouched scenario (`git status --porcelain`).
- [x] 1.6 Run `shellcheck skills/opsx-questions/questions.sh tests/test-questions.sh` and verify it is clean.

## 2. Agent and shared reference

- [x] 2.1 Write `agents/opsx-researcher.md`: name `ops-researcher`, `tools: [Read, Glob, Grep, WebSearch, WebFetch]`, `model: inherit`, `permissionMode: bypassPermissions`, and a body with the three stances, the `VERDICT:` line, the four evidence forms, the untrusted-input rules, and "no writes, no commands". Verify the Claude tool-list scenario with a grep of the frontmatter.
- [x] 2.2 Write `skills/opsx-questions/reference.md`:
  - brief fields per stance;
  - untrusted-input rules in full, adapted from `/opsx-pr`;
  - the verdict and evidence format, identical to the agent's;
  - validation steps (`cite`, URL fetch, ticket and req comparison);
  - downgrade rules and the concrete-flaw rule;
  - malformed-result retry;
  - the report block format with tags;
  - the write-only-on-command rule, with the `Resolved:` bullet format and ticket and PO drafts.
  
  Verify the brief-rules, format-defined-once and downgrade-rules scenarios by grepping both files.

## 3. Skills

- [x] 3.1 Write `skills/opsx-answer/SKILL.md`:
  - trigger and flags;
  - locating `questions.sh` and `reference.md` across the six folders;
  - input resolution (change, `opsx-task.sh key` and tracker MCP, file, text, conversation);
  - the list confirmation;
  - fan-out to `ops-researcher` on Claude, Cursor and OpenCode, and sequential parent research with the read-only notice on Codex and Gemini;
  - validate, `record`, report;
  - write only on command.
  
  Verify the defaults, confirmation and write-rule scenarios for this file.
- [x] 3.2 Write `skills/opsx-challenge/SKILL.md` (same structure; decisions by default, `--include-requirements`, `[req client AC]` → PO draft). Verify the same three scenarios.
- [x] 3.3 Write `skills/opsx-settle/SKILL.md`:
  - `--rounds`;
  - the per-round loop driven by `questions.sh status`;
  - parallel independent challengers A (internal) and B (external);
  - the carried attack in the next answer brief;
  - the stop condition;
  - the report with history and subagent count.
  
  Verify the round-structure scenario, and that every subcommand named in the three SKILL.md files appears in `questions.sh --help`.

## 4. Install and docs

- [x] 4.1 Verify the read-only keys before relying on them: Cursor subagent `readonly`, Codex agent TOML `sandbox_mode`, Gemini subagent tool names, from current docs (Context7 or web). Record the result in a comment next to the converters. If a CLI cannot express read-only, note it in the README instead of inventing a key.
  - Result (2026-11): Cursor `readonly: true` confirmed (cursor.com/docs/context/subagents). Gemini tool names confirmed; the grep tool is now `grep_search` (`search_file_content` is its legacy alias). OpenCode permission keys confirmed. Codex: `sandbox_mode` in an agent file does not override the parent session (developers.openai.com/codex/subagents), so it is not written; the agent gets `[features]` `shell_tool`/`apps`/`plugins`/`memories = false`, and the README records that Codex cannot block file edits for an agent.
- [x] 4.2 Extend the converters without changing other agents' output:
  - an optional read-only argument for `install_cursor_agent` (`readonly: true`) and `install_codex_agent` (`sandbox_mode`);
  - a read-only OpenCode permission variant;
  - a Gemini tool-list rewrite for the researcher.
  
  Install `ops-researcher` on all five CLIs. Verify the OpenCode-denies-edits and Cursor-readonly scenarios in a scratch HOME, and that `ops-applier`'s installed files are byte-identical to before.
- [x] 4.3 Add `install_questions_skills` for `opsx-questions` (`questions.sh` executable, `reference.md`), `opsx-answer`, `opsx-challenge` and `opsx-settle` into the six skill folders. Also add `--skip-questions` (which also skips `ops-researcher`), uninstall, the verify block (files present, `bash -n questions.sh`) and the header comment. Verify the install, skip and uninstall scenarios in `tests/test-questions.sh` with a scratch HOME.
- [x] 4.4 Update `README.md`: the component overview tree and table (three skills and `ops-researcher`), and a section covering inputs, flags, the flow, the verdicts, the settle rounds, the write rule and the Codex/Gemini gap. Update the `openspec/config.yaml` context product-surface line for agents if it lists them. Verify the gap scenario and that the flags in the README match the SKILL.md files.

## 5. Integration

- [x] 5.1 Run `bash tests/test-questions.sh`, `bash tests/test-task.sh`, `bash tests/test-agent-models.sh` and `bash tests/test-review.sh`, and verify that all pass.

## Workflow follow-up

- Run `/opsx-run add-opsx-questions --validate`, then land the change and run `./install.sh`.
