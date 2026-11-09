---
name: opsx-settle
description: "Settle questions by alternating answer and challenge rounds: for each open question (from an OpenSpec change, a ticket, a file, free text or the current conversation, confirmed by the user), a read-only ops-researcher answers it, then two independent challengers (A internal: code, specs, tickets, memory, git history; B external: web, upstream docs) try to invalidate the answer in parallel; a successful attack feeds the next round. A question is settled only when both challengers fail with cited sources; after --rounds (default 3) it is contested or needs-human. Writes nothing until the user says so. Works from Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI. Use when the user types /opsx-settle, or asks to 'settle these questions', 'answer and stress-test this'. Trigger: /opsx-settle"
trigger: /opsx-settle
---

# /opsx-settle

Answer each question, then attack the answer twice, independently, and repeat until it holds or the round cap is reached. You validate every verdict; `questions.sh status` decides the state; the user decides what gets written.

## Usage

```
/opsx-settle [input] [--max N] [--rounds N] [--coverage-rounds N] [--include-requirements]
/opsx-settle add-opsx-workspace              # the open questions of a change
/opsx-settle MED-43 --rounds 2
/opsx-settle "is the 30 s timeout still enough after the upgrade?"
/opsx-settle                                 # the open questions in this conversation
```

`--max` defaults to 6 questions, `--rounds` defaults to 3. `--coverage-rounds` defaults to 3: at most that many coverage rounds check the extracted list for missing questions before you confirm it; `0` skips the check. `--include-requirements` also brings in requirements and acceptance criteria, as for `/opsx-challenge`. Cost: up to `questions × rounds × 3` subagents (54 with the defaults), plus up to `--coverage-rounds` coverage subagents (3 with the defaults), plus one per retried malformed result; the report prints the number used.

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

**Read `reference.md` now.** It defines the brief fields, the untrusted-input rules, the verdict and evidence format, validation, the report and the write rule. This file only adds the rounds.

## Steps

1. **Resolve the input** (reference section 1). A change name wins: run `"$QS" extract <change> --mode answer [--include-requirements]` (`questions.sh extract`): its open questions are kind `open`, and with the flag each `### Requirement:` of the change's specs is added as `req-spec`. A ticket key is detected with `"$TK" key "<input>"` (`opsx-task.sh key`) and read through the issue-tracker MCP under the project's tracker scoping rules; without a tracker MCP, say so and ask for the text. A file is read; free text is used as given; no input means the open questions in this conversation. For anything but a change, write the TSV yourself.
2. **Coverage check** (reference section 1, "Coverage check"), unless `--coverage-rounds 0`. Make the input citable: a change or file is cited where it lives; for a ticket, free text or the conversation, save the text with `printf '%s\n' "<text>" | "$QS" input save` (`questions.sh input save`) and use the path it prints. Then, round by round, start a **fresh** `ops-researcher` with a coverage brief (stance `coverage`, mode settle (open questions; with `--include-requirements` also `req-spec` and `req-client`), the current list, the input path, the untrusted-input rules in full); it never sees earlier coverage results. It returns `VERDICT: covered|gaps` and `gap: <kind> "<text>"` lines, each followed by one evidence item. A gap enters the list only with evidence that passes `"$QS" cite -- <path> <line> "<excerpt>"` (or the ticket or requirement comparison); drop a gap whose evidence fails and a gap that duplicates a listed item (name that item). Add the rest with the next free ids and source `coverage:<round>`. Stop when a round leaves no surviving gap, or after `--coverage-rounds` rounds; at the cap with gaps still arriving, note `coverage incomplete after <n> rounds` above the list. On Codex CLI and Gemini CLI you do the coverage pass yourself, with the same brief and validation.
3. **Confirm the list.** After the coverage check, show the numbered questions with their tag and source. The user confirms, removes, edits or adds. Do not start any research subagent and do not research anything before the user confirms. More than `--max`: open questions and decisions before requirements; propose the first `--max` and name the ones left out.
4. **Create the run**: `"$QS" run new settle --questions-file <tsv> [--max N] [--rounds N]` (`questions.sh run new`). Keep the printed run id.
5. **Rounds.** Repeat while `"$QS" status <run>` (`questions.sh status`) shows a question that is not final (`open` or `challenging`). An `open` question starts `open`; a `decision`, `req-spec` or `req-client` starts `challenging`: it is already a claim, so round 1 challenges its text directly (with its source as the evidence) and no answer brief runs for it until an attack succeeds. In round `k`, for every such question:
   1. **Answer** (only when its state is `open`): an `answer` brief. From round 2 on, the brief carries the attack that succeeded in the previous round (its verdict and kept evidence), so the new answer has to meet it; for a decision or requirement the answer brief asks whether the claim still holds against that attack, or how it should change. Validate (reference section 5) and record with `--stage answer`. `needs-human` or `unanswerable` ends the question.
   2. **Challenge**, when the state is `challenging` (right after an `answered` or `partial`, from round 1 for a decision or requirement, or a new round after an untested `stands`): two challengers **in parallel**, each with its own brief and neither seeing the other's brief or result:
      - **A, internal**: code, specs, tickets, memory, git history (excerpts you collected, quoted as UNTRUSTED DATA).
      - **B, external**: web, upstream docs, release notes.
      Both get the answer and its kept evidence, and **not** your rationale for accepting it. Validate each result; you may reject a surviving attack only by naming a concrete flaw in its evidence. Record with `--stage challenge-a` and `--stage challenge-b`, and `--sources` the number of items that survived.
   3. Run `"$QS" status <run>` and read the new state:
      - `settled`: both challengers returned a validated `stands` with at least one source.
      - `open` round `k+1`: an attack (`weakened` or `invalidated`) succeeded; a new answer is due, carrying that attack.
      - `challenging` round `k+1`: no attack succeeded, but a `stands` had no source (untested); new challengers, same answer.
      - `contested` (attack succeeded at the cap) or `needs-human` (still untested at the cap).
   Run the briefs of all non-final questions of a round in parallel where the CLI allows it.
6. **Stop** when every question is final (`settled`, `contested`, `needs-human`, `unanswerable`) or the round cap is reached. Questions that are already final do not run again.
7. **Report** one block per question (reference section 6): the state, the round and the history from `questions.sh status`, the validated verdicts with the evidence kept, what validation dropped and why, a recommendation and its justification. A `contested` question shows both sides. A `needs-human` question names the question to ask and whom. End with the number of subagents used (the sum of `subagents=` from `questions.sh status`, plus the coverage subagents).

### Subagents per CLI

- **Claude Code, Cursor CLI, OpenCode**: every brief goes to an `ops-researcher` subagent (Claude Code: the Agent tool with `subagent_type: ops-researcher`; Cursor and OpenCode: their `ops-researcher` subagent). Challengers A and B of a round run in parallel. It is read-only: named read and web tools only, no shell, no writes.
- **Codex CLI, Gemini CLI**: say at the start, once: "This CLI has no reliable subagents: I research each brief myself, one at a time; the read-only guarantee of ops-researcher does not hold here, but I still write nothing until you say so." Then work through the briefs in sequence. Keep A and B independent: research B from its own brief without looking back at A's result, and judge each against its own evidence.

## Write only on command

Nothing is written or posted until the user commands it: no edit to design.md, specs, memory or tickets, and no file outside `.opsx/questions/` (the one exception: `questions.sh run new` and `questions.sh input save` add the line `.opsx/questions/` to the repository `.gitignore` once, when it is missing). Then write only what the user named. A settled question written back to a design.md keeps its bullet, starts with `Resolved:` and cites its source. Ticket comments are drafts only, shown to the user and never posted. An invalidated `[req client AC]` produces a drafted question to the product owner, never an edit.
