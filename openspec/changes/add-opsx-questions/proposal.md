# Proposal

## Why

Open questions pile up in design.md files, tickets, briefs and conversations. Answering them means searching the code, the specs, the tracker and the web by hand. Decisions that were closed weeks ago are rarely re-checked, even after the code, the ticket or an upstream library has moved under them. The harness already fans work out to subagents for apply and review. The same machinery can close open questions with cited evidence, try to knock down closed ones, and leave the final call to the user.

## What Changes

- New `/opsx-answer <input>`: the parent agent extracts the open questions from the input. The user confirms or edits the list. Then one read-only subagent per question searches for an answer and returns a verdict (`answered`, `partial`, `needs-human`, `unanswerable`) with cited evidence.
- New `/opsx-challenge <input>`: the same flow, but the subagents try to invalidate closed decisions and return `stands`, `weakened` or `invalidated` with cited evidence. By default only decisions are challenged. `--include-requirements` also challenges spec requirements (MUST/SHALL) and ticket acceptance criteria. A client requirement that falls yields a draft question to the product owner, never an edit.
- New `/opsx-settle <input> [--rounds N]` (default 3): per question, it alternates answer and challenge rounds. Each round runs an answer, then two independent challengers in parallel: A internal (code, specs, tickets, memory, git history) and B external (internet, upstream docs). A question is settled only when both challengers return a validated `stands`. A `stands` with no relevant source counts as untested. A successful attack goes into the next round's answer brief. After the cap, the question is `contested` (both sides shown) or `needs-human`.
- Input for all three: an OpenSpec change name, a ticket key or tracker URL (resolved like `/opsx-task`), a file, free text, or nothing, which means the open questions or decisions in the current conversation. At most `--max 6` questions per run.
- New read-only subagent `ops-researcher`. It has named read tools only: no write, edit, shell, subagent or wildcard MCP tools. It returns only a verdict plus cited evidence. The parent runs any source scripts (`req.sh`, `graphify query`) itself and puts the excerpts in the brief.
- The parent validates every verdict before showing it:
  - First a mechanical citation check: the file line contains the excerpt, the URL contains the excerpt, the ticket or requirement field says it. Any failed citation is dropped.
  - Then a judgment. Rejecting an attack requires naming a concrete flaw in its evidence.
- The parent shows the result per question: the validated verdict, a recommendation, a justification, and in settle the history. It writes nothing to design.md, specs, memory or the tracker until the user says so. Ticket comments are drafted, never posted.
- Web pages, tickets and other people's text are untrusted input in every brief.
- On CLIs without reliable subagents, the parent researches each question itself, in sequence, and the README documents that the read-only guarantee is lost there.
- A helper `questions.sh` does the deterministic parts: extract questions from a change, check citations, keep the per-question settle state.
- `install.sh` installs the three skills and the agent for every supported CLI, with `--skip-questions`, uninstall and verify. `README.md` documents them and the overview tree.

## Capabilities

### New Capabilities
- `question-research`: answering open questions and challenging closed decisions with read-only subagents. Covers:
  - input resolution and question extraction;
  - user confirmation of the list;
  - the `ops-researcher` agent and its read-only tool set per CLI;
  - verdict vocabularies;
  - parent validation of citations;
  - the settle round state machine;
  - the report;
  - the write-only-on-command rule;
  - installation.

### Modified Capabilities
<!-- None. `ops-researcher` is installed with `inherit` and is not added to agents/models.conf, so agent-models is unchanged. -->

## Impact

- New: `skills/opsx-questions/` (shared `questions.sh` and reference text), `skills/opsx-answer/`, `skills/opsx-challenge/`, `skills/opsx-settle/` (each a `SKILL.md`), `agents/opsx-researcher.md`, `tests/test-questions.sh`.
- `install.sh`:
  - the four skill directories in the six skill folders;
  - a read-only conversion of `ops-researcher` for Claude Code, Cursor, Codex, OpenCode and Gemini (the existing OpenCode converter grants `edit` and `bash`, so it needs a read-only variant);
  - `--skip-questions`, uninstall and verify.
- `README.md`: component overview, table and a section.
- Repositories using it gain git-ignored per-run state under `.opsx/questions/`.
- Dependencies: none new. Ticket inputs need an issue-tracker MCP. Web research needs the CLI's web tools.
- Cost: settle can use up to `questions × rounds × 3` subagents (54 with the defaults). The report prints the number used.
