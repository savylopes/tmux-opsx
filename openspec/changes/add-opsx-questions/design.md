# Design

## Context

See proposal.md (Why). Relevant current state:

- Skills live in `skills/<name>/SKILL.md` plus helper scripts. `install.sh` copies each skill into six folders (Claude, Cursor, `~/.agents`, `$CODEX_HOME`, OpenCode, Gemini), with one `install_<x>_skill` function, a `--skip-<x>` flag, an uninstall block and a verify block per skill (see `/opsx-review`, `/opsx-task`).
- Agents live in `agents/opsx-<name>.md` (Claude frontmatter). `install.sh` converts them per CLI:
  - `install_claude_agent`: rewrites `model:`;
  - `install_cursor_agent`: name, description and model only;
  - `install_codex_agent`: TOML with `developer_instructions`;
  - `install_opencode_agent`: a fixed permission block that **allows** `edit` and `bash`;
  - Gemini gets the source file copied as is.
  
  None of these converters can express "read-only" today.
- `/opsx-task` already resolves ticket keys (`opsx-task.sh key`) and documents how to read tickets through the tracker MCP under the project's scoping rules.
- `/opsx-pr` already defines the Untrusted input rules and the split between CLIs: Claude Code, Cursor and OpenCode use subagents; Codex and Gemini do the work in the parent.

## Goals / Non-Goals

**Goals:**
- One engine, three entry points, so answer, challenge and settle share the brief format, verdict format, validation rules and state.
- Every deterministic rule (extraction, citation check, round state) lives in `questions.sh`, so it is testable without an LLM and checkable by evals.
- Read-only enforced by tool configuration on every CLI that runs subagents, not only by prompt.

**Non-Goals:**
- No new model key: `ops-researcher` is installed as `inherit` and `agents/models.conf` and the `agent-models` capability stay unchanged. It can be added later if a different model for the challengers turns out to be useful.
- No persistent cross-run question ledger. The run directory under `.opsx/questions/` is per run, and the design.md `Resolved:` bullets and memory entries are the durable record.
- No automatic tracker or memory writes, ever, and no posting of ticket comments.
- No extraction from arbitrary code (`TODO`/`FIXME` scanning). Questions from code come in as free text or from the conversation.

## Decisions

### D1. A shared `skills/opsx-questions/` plus three thin skills
`skills/opsx-questions/` holds:

- `questions.sh`;
- `reference.md`: brief fields, untrusted-input rules, verdict format, validation and downgrade rules, report format.

`opsx-answer`, `opsx-challenge` and `opsx-settle` are short SKILL.md files. Each locates `questions.sh` and `reference.md` and adds only what differs for its mode.

A skill cannot portably call another skill across five CLIs, so "settle uses answer and challenge" is implemented as shared reference text, not as nested skill calls. A single skill with a mode argument was the alternative. Three names trigger better from natural language ("challenge this decision") and match the user's request.

### D2. `questions.sh` subcommands
- `extract <change> --mode answer|challenge [--include-requirements]` prints TSV (`id kind path:line text`). It is a section-aware awk over `design.md`, `proposal.md` and the change's `specs/**/spec.md`. It covers only change inputs. Other inputs are extracted by the parent, which writes the same TSV.
- `cite <path> <line> <excerpt>` checks a ±2-line window with collapsed whitespace. Paths are resolved with `realpath -m` and must stay under the repo top level or `~/.agents/memory`. Exit codes 0/1/2/3.
- `run new <mode> --questions-file <tsv> [--max] [--rounds]` creates `.opsx/questions/<YYYYmmdd-HHMMSS>-<rand4>/` with `questions.tsv`, `meta` (mode, rounds cap) and an empty `verdicts.tsv`. It adds `.opsx/questions/` to `.gitignore` once, as `opsx-task.sh` does for `.opsx/tasks/`.
- `record <run> <qid> --round k --stage s --verdict v [--sources n]` validates and appends a line to `verdicts.tsv`.
- `status <run>` replays `verdicts.tsv` through the state machine below. The state is derived from the log, never stored, so a half-written run cannot leave an inconsistent state.

URLs are not fetched by the script. The parent checks `url:` evidence with its own web tool, because a shell `curl` of a URL proposed by a subagent is exactly what the untrusted-input rules forbid.

### D3. The settle state machine

```
             answer: needs-human / unanswerable
   open(k) -------------------------------------------> needs-human | unanswerable
     |
     | answer: answered / partial
     v
   challenging(k) --(A,B both recorded)--+-- both stands, sources>=1 --> settled
         ^                               |
         |  no attack won, but a stands  +-- any weakened/invalidated --> open(k+1)    | contested   (k = cap)
         +-- had 0 sources --------------+-- (untested)               --> challenging(k+1) | needs-human (k = cap)
```

Both challengers run in the same round, in parallel. That satisfies "two independent challenges" without forcing a second round on a sound answer. Independence comes from different briefs and source scopes (A internal, B external) and from neither seeing the other.

### D4. `ops-researcher` read-only per CLI
| CLI | How read-only is enforced |
|---|---|
| Claude Code | `tools: [Read, Glob, Grep, WebSearch, WebFetch]`. `permissionMode: bypassPermissions` is safe because no write tool is listed, and it avoids WebFetch prompts in a fan-out. |
| Cursor | frontmatter `readonly: true` (new optional argument to `install_cursor_agent`) |
| Codex | `[features]` `shell_tool`, `apps`, `plugins`, `memories` = false in the TOML (new optional argument to `install_codex_agent`). Verified during apply: `sandbox_mode` in an agent file does not override the parent session, and no key removes file edits, so Codex cannot make the agent fully read-only (README gap; Codex researches in the parent anyway) |
| OpenCode | a read-only permission block: `edit`, `bash`, `task`, `todowrite` deny; `read`, `glob`, `grep`, `list`, `webfetch`, `websearch` allow (new `install_opencode_agent` variant) |
| Gemini | the copied file gets `tools:` rewritten to Gemini's read and web tool names (`read_file`, `read_many_files`, `glob`, `grep_search`, `list_directory`, `google_web_search`, `web_fetch`) |

The researcher gets **no MCP tools**. Tracker MCP servers mix read and write tools under per-install names, so a safe allow-list cannot be written portably. The parent reads tickets, runs `req.sh` and `graphify query`, and passes excerpts in the brief (spec: "Briefs carry the evidence the agent cannot fetch"). The cost is that a researcher cannot search the tracker by itself. Challenger A gets the linked tickets the parent collected.

The Cursor `readonly` key, the Codex agent keys and the Gemini tool names come from those CLIs' documentation. None of these CLIs is installed here, so task 3.x checks them against the docs (Context7 or web) before relying on them. Tests check the generated files, not the CLIs.

### D5. Validation is in the parent, mechanical first
For each result: parse `VERDICT:` and the evidence lines, run `questions.sh cite` for each `file:` item, fetch each `url:` item, compare `ticket:` and `req:` items against what the parent read, and drop failures. Then judge, and apply the downgrade rules, before `record`. `--sources` is the number of evidence items that survived. The parent records validated verdicts only, so `status` reflects validation.

A malformed result (no `VERDICT:` line or an unknown verdict) is retried once with the same brief. A second malformed result is recorded as `needs-human` (answer) or `stands` with 0 sources (challenge).

### D6. Conversation input
With no argument, the parent itself lists the open questions (answer, settle) or the decisions taken (challenge) from the conversation, writes the TSV with kind `open` or `decision` and source `conversation`, and continues as for any input. Subagents never see the conversation, only the briefs.

## Risks / Trade-offs

- [The challenger always finds something] → Verdicts need surviving citations, the downgrade rules apply, and the parent can reject an attack only by naming a concrete flaw. The report shows what was dropped, so the user sees the filtering.
- [The parent defends its own decisions when validating a conversation challenge] → The concrete-flaw rule, and the report shows rejected attacks with the stated flaw, so the user can overrule.
- [Cost: up to 54 subagents with the defaults] → `--max 6` and the list confirmation step. Questions that are already final do not run again. The report prints the count.
- [Read-only is lost on Codex and Gemini, where the parent researches] → Said at the start of the run and in the README. The parent is still bound by the write-only-on-command rule.
- [CLI frontmatter keys for read-only (Cursor `readonly`, Codex `sandbox_mode`, Gemini tool names) may differ from the docs] → Verified against docs during apply, and recorded in the README if a CLI cannot express it.
- [Prompt injection from web pages or tickets] → No write or shell tools in the researcher, untrusted-input rules in every brief, and the parent never runs a command or opens a URL just because a result suggests it. URL evidence is fetched only to check the excerpt.

## Migration Plan

Additive. Re-run `install.sh`. `--skip-questions` opts out, and `--uninstall` removes the skills and agent files.
