---
name: opsx-answer
description: "Answer open questions with cited evidence: extract the open questions from an OpenSpec change, a ticket, a file, free text or the current conversation, let the user confirm the list, then research each one with a read-only ops-researcher subagent and report a validated verdict (answered, partial, needs-human, unanswerable) with a recommendation. Writes nothing until the user says so. Works from Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI. Use when the user types /opsx-answer, or asks to 'answer the open questions in this change', 'find out where X writes', 'research these questions'. Trigger: /opsx-answer"
trigger: /opsx-answer
---

# /opsx-answer

Close open questions with cited evidence. One read-only research subagent per question; you validate every verdict before showing it; the user decides what gets written.

## Usage

```
/opsx-answer [input] [--max N]
/opsx-answer add-opsx-workspace          # an OpenSpec change: its Open Questions / Open Points
/opsx-answer MED-43                      # a ticket key or tracker URL
/opsx-answer docs/notes.md               # a file
/opsx-answer "does the cache survive a restart?"
/opsx-answer                             # the open questions in this conversation
```

`--max` defaults to 6: at most that many questions per run.

## Files

Resolve the helper and the shared reference once (they sit in the sibling `opsx-questions` skill folder):

```bash
QS=$(ls ~/.claude/skills/opsx-questions/questions.sh ~/.cursor/skills/opsx-questions/questions.sh \
  ~/.agents/skills/opsx-questions/questions.sh ~/.codex/skills/opsx-questions/questions.sh \
  ~/.config/opencode/skills/opsx-questions/questions.sh ~/.gemini/skills/opsx-questions/questions.sh 2>/dev/null | head -n1)
REF=$(dirname "$QS")/reference.md
TK=$(ls ~/.claude/skills/opsx-task/opsx-task.sh ~/.cursor/skills/opsx-task/opsx-task.sh \
  ~/.agents/skills/opsx-task/opsx-task.sh ~/.codex/skills/opsx-task/opsx-task.sh \
  ~/.config/opencode/skills/opsx-task/opsx-task.sh ~/.gemini/skills/opsx-task/opsx-task.sh 2>/dev/null | head -n1)
```

**Read `reference.md` now.** It defines the brief fields, the untrusted-input rules, the verdict and evidence format, validation, the report and the write rule. This file only adds what is specific to answering.

## Steps

1. **Resolve the input** (reference section 1). A change name wins: run `"$QS" extract <change> --mode answer` (`questions.sh extract`), which lists the `## Open Questions` of design.md and the `## Open Points` of proposal.md, skipping `Resolved:` items. A ticket key is detected with `"$TK" key "<input>"` (`opsx-task.sh key`) and read through the issue-tracker MCP under the project's tracker scoping rules; without a tracker MCP, say so and ask for the text. A file is read; free text is used as given; no input means the open questions in this conversation. For anything but a change, write the TSV yourself.
2. **Confirm the list.** Show the numbered questions with their tag (`[open]`, ...) and source. The user confirms, removes, edits or adds. Do not start any subagent and do not research anything before the user confirms. More than `--max`: propose the first `--max` and name the ones left out.
3. **Create the run**: `"$QS" run new answer --questions-file <tsv> [--max N]` (`questions.sh run new`). Keep the printed run id.
4. **Research.** Write one `answer` brief per question (reference section 2), with the untrusted-input rules pasted in full and any ticket, `req.sh` or `graphify query` excerpts you collected quoted as UNTRUSTED DATA.
   - **Claude Code, Cursor CLI, OpenCode**: start one `ops-researcher` subagent per question, all in parallel (Claude Code: the Agent tool with `subagent_type: ops-researcher`; Cursor and OpenCode: their `ops-researcher` subagent). It is read-only: named read and web tools only, no shell, no writes.
   - **Codex CLI, Gemini CLI**: say at the start, once: "This CLI has no reliable subagents: I research each question myself, one at a time; the read-only guarantee of ops-researcher does not hold here, but I still write nothing until you say so." Then research each brief yourself in sequence, in the same stance and with the same output format.
5. **Validate** each result (reference section 5): parse, `"$QS" cite` (`questions.sh cite`) every `file:` item, fetch every `url:` item yourself, compare `ticket:` and `req:` items, drop failures, apply the downgrade rules, judge. Retry a malformed result once and record the verdict that follows with `--attempts 2`.
6. **Record** each validated verdict: `"$QS" record <run> <qid> --round 1 --stage answer --verdict <v> --sources <n>` (`questions.sh record`), then `"$QS" status <run>` (`questions.sh status`).
7. **Report** one block per question (reference section 6): the verdict, the evidence kept, what validation dropped and why, a recommendation and its justification; `needs-human` names the question to ask and whom. End with the number of subagents used.

## Write only on command

Nothing is written or posted until the user commands it: no edit to design.md, proposal.md, specs, memory or tickets, and no file outside `.opsx/questions/`. Then write only what the user named. A resolved question written back to a design.md keeps its bullet, starts with `Resolved:` and cites its source. Ticket comments are drafts only, shown to the user and never posted.
