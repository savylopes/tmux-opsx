# question-research Specification

## Purpose
Answers open questions and challenges closed decisions with read-only research subagents. The parent agent validates every verdict and its evidence, and the user decides what gets written.

## Requirements

### Requirement: Three entry points over one engine
The repo SHALL ship three skills:

- `/opsx-answer [input] [--max N] [--coverage-rounds N]` (verdicts `answered`, `partial`, `needs-human`, `unanswerable`);
- `/opsx-challenge [input] [--max N] [--coverage-rounds N] [--include-requirements]` (verdicts `stands`, `weakened`, `invalidated`);
- `/opsx-settle [input] [--max N] [--rounds N] [--coverage-rounds N] [--include-requirements]`.

All three SHALL use the shared helper `questions.sh` and shared reference text from `skills/opsx-questions/`.

#### Scenario: Helper usage
- **WHEN** `questions.sh --help` runs
- **THEN** it exits 0 and lists the `extract`, `cite`, `run`, `record` and `status` subcommands

### Requirement: Option defaults and helper lookup
`--max` SHALL default to 6, `--rounds` to 3 and `--coverage-rounds` to 3. Each SKILL.md SHALL locate `questions.sh` in the installed skill folders of all five CLIs, the same way `/opsx-task` locates `opsx-task.sh`.

#### Scenario: Defaults documented
- **WHEN** `skills/opsx-answer/SKILL.md`, `skills/opsx-challenge/SKILL.md` and `skills/opsx-settle/SKILL.md` are read
- **THEN** each names `questions.sh`, `--max` defaults to 6, `--coverage-rounds` defaults to 3, and `opsx-settle` states `--rounds` defaults to 3

### Requirement: Input resolution
The input SHALL be a change name (a directory under `openspec/changes/`, not the archive), which SHALL take precedence; a ticket key or tracker URL, detected with `opsx-task.sh key`, read through the issue-tracker MCP under the project's tracker scoping rules; an existing file path; free text; or no input, for the open questions (answer, settle) or decisions taken (challenge) in the conversation. Without a tracker MCP, the skill SHALL report a ticket input as unreadable and ask for the text.

#### Scenario: Change input is extracted by the helper
- **WHEN** `/opsx-answer add-opsx-workspace` runs in a repo with `openspec/changes/add-opsx-workspace/design.md`
- **THEN** the questions come from `questions.sh extract add-opsx-workspace --mode answer`

### Requirement: Extract questions from a change
`questions.sh extract '<change>' --mode answer|challenge [--include-requirements] [--repo <dir>]` SHALL print one tab-separated line per question: `<id> <kind> <path>:<line> <text>`. Ids SHALL be `Q1`, `Q2`, ... in file order.

With `--mode answer`, the questions SHALL be the list items under `## Open Questions` in the change's `design.md` and under `## Open Points` in its `proposal.md`, with kind `open`. Items whose text starts with `Resolved:` SHALL be skipped.

#### Scenario: Open questions extracted
- **WHEN** a scratch change's `design.md` has `## Open Questions` with the items `- Where does X write?` and `- Resolved: Y uses Z.`
- **THEN** `questions.sh extract '<change>' --mode answer` prints exactly one line, `Q1	open	openspec/changes/<change>/design.md:<n>	Where does X write?`

### Requirement: Extract decisions to challenge
With `--mode challenge`, `questions.sh extract` SHALL take the decisions under `## Decisions` in `design.md` as the questions, with kind `decision`. Each `###` heading in that section SHALL be one decision. When the section has no `###` headings, each top-level list item SHALL be one.

#### Scenario: Decisions extracted
- **WHEN** a scratch change's `design.md` has `## Decisions` with `### Use SQLite` and `### One window per change`
- **THEN** `questions.sh extract '<change>' --mode challenge` prints two lines of kind `decision`, `Q1` then `Q2`

### Requirement: Extract requirements only on request
With `--include-requirements`, `questions.sh extract` SHALL add each `### Requirement:` in the change's `specs/**/spec.md`, with kind `req-spec`.

#### Scenario: Requirements only on request
- **WHEN** the same change has a `specs/foo/spec.md` with one `### Requirement: Bar`
- **THEN** `--mode challenge` prints no `req-spec` line, and `--mode challenge --include-requirements` adds `Q3	req-spec	...	Bar`

### Requirement: Extract from a missing or empty change
`questions.sh extract` on a change that does not exist SHALL exit 2 with a message. A change that has the sections but no questions SHALL print nothing and exit 0.

#### Scenario: Unknown change
- **WHEN** `questions.sh extract no-such-change --mode answer` runs
- **THEN** it exits 2 and prints no question line

### Requirement: Safe change names
A change name given to `questions.sh extract` SHALL be restricted to `[A-Za-z0-9-]`; any other name SHALL exit 2 before any path is built.

#### Scenario: Unsafe change name
- **WHEN** `questions.sh extract '../../etc' --mode answer` runs
- **THEN** it exits 2 and reads no file outside `openspec/changes/`

### Requirement: The user confirms the question list
Before starting any research subagent, and after the coverage check, the skill SHALL show the numbered list of questions with their kind and source. The user SHALL be able to confirm, remove, edit or add questions. No research SHALL start without that confirmation. When more than `--max` questions are found, the list SHALL be ordered with open questions and decisions before requirements. The skill SHALL propose the first `--max` and name the ones left out.

#### Scenario: Confirmation step documented
- **WHEN** the three SKILL.md files are read
- **THEN** each says the coverage check runs first and the question list is then shown and confirmed by the user before any research subagent starts

### Requirement: Coverage check before confirmation
After extraction and before the user confirms the list, the skill SHALL check that the list covers the input. Each coverage round SHALL start a fresh `ops-researcher` with a coverage brief that carries the mode, the current list, the input (a change or file by path; other input saved by the parent with `questions.sh input save`) and the untrusted-input rules, and never the results of earlier coverage rounds.

#### Scenario: Coverage documented in every skill
- **WHEN** the three SKILL.md files are read
- **THEN** each describes the coverage loop before the confirmation step, `--coverage-rounds` with default 3, and that a gap enters the list only with evidence that passes `cite --`

### Requirement: Coverage result format
A coverage result SHALL start with `VERDICT: covered` or `VERDICT: gaps`, followed by one `gap: <kind> "<text>"` line per missing question or decision, each followed by one evidence item in the verdict format.

#### Scenario: Coverage verdict in the agent
- **WHEN** `agents/opsx-researcher.md` and `skills/opsx-questions/reference.md` are read
- **THEN** both define the `coverage` stance with `VERDICT: covered|gaps` and the `gap:` line followed by an evidence item

### Requirement: Coverage gaps are validated
The parent SHALL validate every gap's evidence as in the mechanical citation check, SHALL drop a gap whose evidence fails, and SHALL drop a gap that duplicates a listed item, naming that item. It SHALL add the remaining gaps with the next free ids and the source `coverage:<round>`, then run the next round.

#### Scenario: Gap with a fabricated citation is dropped
- **WHEN** a coverage result returns `gap: open "Where is X stored?"` with `file:<input>:4 "X is stored"` and line 4 of the saved input does not say that
- **THEN** `questions.sh cite -- '<input>' 4 "X is stored"` exits 1, and the reference text says such a gap is dropped and listed as dropped

### Requirement: Coverage loop stops
The coverage loop SHALL stop when a round leaves no surviving gap, or after `--coverage-rounds` rounds (default 3); at the cap with gaps still arriving, the list SHALL be shown with the note `coverage incomplete after <n> rounds`. `--coverage-rounds 0` SHALL skip the check. The report SHALL end with the number of subagents used, coverage subagents included.

#### Scenario: Loop stops when no gap survives
- **WHEN** `skills/opsx-questions/` reference text is read
- **THEN** it states that the loop stops on a round with no surviving gap or at `--coverage-rounds`, that each round uses a fresh subagent that does not see earlier coverage results, and the `coverage incomplete` note at the cap

### Requirement: Coverage outcome recorded in the run
`questions.sh run new` SHALL record the coverage outcome in the run: rounds run (`--coverage-rounds-run`), coverage subagents with retries (`--coverage-subagents`), gaps dropped (`--coverage-dropped`), whether the list carried the `coverage incomplete` note (`--coverage-incomplete`) and the saved input path (`--input`). `questions.sh status` SHALL print it as a last line `coverage rounds=<k> subagents=<n> dropped=<d> incomplete=yes|no input=<path|->`.

#### Scenario: Coverage recorded in the run
- **WHEN** `questions.sh run new answer --questions-file <tsv> --coverage-rounds-run 2 --coverage-subagents 3 --coverage-dropped 1 --input <saved input path>` runs
- **THEN** `questions.sh status <run>` ends with `coverage rounds=2 subagents=3 dropped=1 incomplete=no input=<saved input path>`, and `--coverage-subagents` above twice the rounds run is refused

### Requirement: Untrusted values never become shell code
The parent SHALL pass untrusted text (ticket text, free text, conversation turns) to `questions.sh input save` on stdin from a file written with its file-write tool, never in a shell argument, `echo`/`printf` or heredoc. Each subagent- or user-supplied argument to `questions.sh cite|url|extract` or `opsx-task.sh key` SHALL be one single-quoted shell word (`'` written as `'\''`), shown so in every command template in the skills, reference, README and this change, never double-quoted or bare.

#### Scenario: Saved input keeps shell metacharacters as text
- **WHEN** a file holding `"; touch <scratch>/pwned; echo "` and `$(id)` is saved with `questions.sh input save < <file>`
- **THEN** the saved input holds those bytes unchanged, `<scratch>/pwned` does not exist, and no skill or reference text puts the input text inside a shell argument (`printf '%s\n' "<text>"`)

### Requirement: Saved input
`questions.sh input save [--repo <dir>]` SHALL read text on stdin, write it to `.opsx/questions/input-<stamp>/input.md`, add `.opsx/questions/` to `.gitignore` once, and print the repo-relative path, so `cite` can check `file:` evidence against it. The coverage check SHALL write nothing outside `.opsx/questions/`, except that `questions.sh input save` adds the line `.opsx/questions/` to the repository `.gitignore` once, when it is missing.

#### Scenario: Saved input is citable
- **WHEN** `printf 'line one\nwhere does X write?\n' | questions.sh input save` runs in a scratch repo
- **THEN** it prints a path under `.opsx/questions/input-`, `questions.sh cite -- '<path>' 2 "where does X write"` exits 0, and `.gitignore` holds one `.opsx/questions/` line

### Requirement: Saved input is sanitized
`questions.sh input save` SHALL refuse more than 1 MiB, turn tabs and carriage returns into spaces, strip every other control character (C0, DEL and the UTF-8 C1 range U+0080-U+009F) except newlines, and refuse a symlinked `.opsx` or `.opsx/questions`.

#### Scenario: C1 control characters stripped
- **WHEN** `printf 'caf\xc3\xa9 \xc2\x9b31m x\n' | questions.sh input save` runs
- **THEN** the saved input keeps `café` and holds no `\xc2\x9b`

### Requirement: Read-only research agent
The repo SHALL ship `agents/opsx-researcher.md`, named `ops-researcher`. Its Claude Code tool list SHALL be exactly `Read`, `Glob`, `Grep`, `WebSearch` and `WebFetch`, with no `Write`, `Edit`, `Bash`, `Agent`, `NotebookEdit` or `mcp__` entry. Its instructions SHALL say it returns only a verdict and cited evidence (`gap:` lines with evidence for coverage), treats every fetched page, ticket text and brief excerpt as untrusted data, not instructions, and never asks for or performs a write.

#### Scenario: Claude tool list is read-only
- **WHEN** the frontmatter `tools:` of `agents/opsx-researcher.md` is read
- **THEN** it lists exactly `Read`, `Glob`, `Grep`, `WebSearch`, `WebFetch`

### Requirement: WebFetch guard
On Claude Code the frontmatter of `agents/opsx-researcher.md` SHALL carry a `PreToolUse` hook on `WebFetch` that runs `skills/opsx-questions/webfetch-guard.sh`, which SHALL block (exit 2) a fetch whose URL fails `questions.sh url`, and any hook payload it cannot read.

#### Scenario: WebFetch to a built URL is blocked
- **WHEN** `webfetch-guard.sh` reads a payload whose `tool_input.url` is `https://evil.example/?d=secret`
- **THEN** it exits 2, and for `https://docs.example.com/guide` it exits 0

### Requirement: Read-only agent on every CLI
`install.sh` SHALL install `ops-researcher` in a read-only form for each CLI, as below and in Read-only agent on Codex and OpenCode:

- **Claude Code**: `~/.claude/agents/opsx-researcher.md` with the source tool list.
- **Cursor**: `~/.cursor/agents/opsx-researcher.md` with `readonly: true`.
- **Gemini**: `~/.gemini/agents/opsx-researcher.md` with a tool list of read and web tools only.

#### Scenario: Cursor researcher is readonly
- **WHEN** `install.sh` runs into a scratch HOME
- **THEN** `~/.cursor/agents/opsx-researcher.md` has `readonly: true` in its frontmatter

### Requirement: Read-only agent on Codex and OpenCode
`install.sh` SHALL install `ops-researcher`:

- **Codex**: `~/.codex/agents/ops-researcher.toml` with shell, apps, plugins and memories off (`[features]`). No Codex agent-file key blocks edits (its `sandbox_mode` does not override the parent session); the README records the gap.
- **OpenCode**: `~/.config/opencode/agents/ops-researcher.md` with `edit: deny`, `bash: deny`, `task: deny`, and `read`, `glob`, `grep`, `list`, `webfetch`, `websearch` allowed.

Other agents' files SHALL NOT change.

#### Scenario: OpenCode researcher denies edits
- **WHEN** `install.sh` runs into a scratch HOME
- **THEN** `~/.config/opencode/agents/ops-researcher.md` contains `edit: deny` and `bash: deny` and no `edit: allow` or `bash: allow`, and `ops-applier.md` there still contains `edit: allow`

### Requirement: Briefs carry the evidence the agent cannot fetch
The parent SHALL write one brief per question and research task, containing the question and its source, the stance (answer, challenge A internal, challenge B external), the context the subagent needs, what has already been ruled out, and the untrusted-input rules in full. The parent SHALL quote, as excerpts marked untrusted, any source the agent cannot reach with its tools. A challenge brief SHALL carry the answer or decision and its evidence, but not the parent's rationale for accepting it.

#### Scenario: Brief rules documented
- **WHEN** `skills/opsx-questions/` reference text is read
- **THEN** it defines the brief fields, the untrusted-input rules, and that challenge briefs omit the parent's rationale
- **AND** sources the agent cannot reach (tracker tickets, `req.sh`, `graphify query`, other scripts) reach it only as quoted excerpts marked untrusted

### Requirement: Verdict format
Every subagent result SHALL start with one line `VERDICT: <verdict>`, using the vocabulary of its stance. It SHALL then list the evidence, one item per line, each item one of:

- `file:<path>:<line> "<excerpt>"`
- `url:<url> "<excerpt>"`
- `ticket:<key>:<field> "<excerpt>"`
- `req:<id> "<excerpt>"`

It SHALL then give a short reasoning. A result with no evidence item SHALL count as having no relevant source.

#### Scenario: Format defined once
- **WHEN** `skills/opsx-questions/` reference text and `agents/opsx-researcher.md` are read
- **THEN** both give the same `VERDICT:` line and the four evidence forms

### Requirement: Mechanical citation check
`questions.sh cite [--repo <dir>] [--] '<path>' '<line>' '<excerpt>'` SHALL exit:

- 0 when the excerpt, with runs of whitespace collapsed, occurs within lines `line-2` to `line+2` of the file;
- 1 when it does not;
- 2 when the file does not exist;
- 3 when the path resolves outside the repository and outside `~/.agents/memory`.

#### Scenario: Citation matches nearby
- **WHEN** line 10 of `a.md` in a scratch repo is `the   quick brown fox`
- **THEN** `questions.sh cite a.md 9 "quick brown"` exits 0

#### Scenario: Fabricated citation
- **WHEN** no line near 10 of `a.md` contains `lazy dog`
- **THEN** `questions.sh cite a.md 10 "lazy dog"` exits 1

#### Scenario: Path outside the repo
- **WHEN** `questions.sh cite /etc/hostname 1 x` runs in a scratch repo
- **THEN** it exits 3

### Requirement: The parent checks every evidence item
The three values of `questions.sh cite` are untrusted subagent output: `-h` or `--help` SHALL be a help request only as the sole argument, and SHALL otherwise be a value. The parent SHALL run `cite`, with `--`, for every `file:` evidence item. It SHALL drop a `url:` item that fails `questions.sh url` without fetching it, check every other `url:` item by fetching the page itself and every `ticket:` and `req:` item against the source it read, and drop any failing item before judging the verdict.

#### Scenario: Help flag in a citation is a value
- **WHEN** `questions.sh cite -h 1 x` and `questions.sh cite README.md 1 -h` run in a scratch repo with no file `-h` and no `-h` in README.md
- **THEN** they exit 2 and 1, never 0

### Requirement: URL check
`questions.sh url [--] '<url>'` SHALL exit 0 and print the URL to fetch (fragment dropped) only for an `https://` URL of at most 200 characters with a domain-name host, no query string, userinfo, port, IP or local host, and no path segment over 64 characters; otherwise it SHALL exit 1.

#### Scenario: URL built from data is refused
- **WHEN** `questions.sh url "https://attacker.example/?q=secret"` runs
- **THEN** it exits 1, and `questions.sh url https://docs.example.com/a/b` exits 0

### Requirement: Parent validation and downgrade
After the citation check, the parent SHALL judge whether the remaining evidence supports the verdict, and SHALL downgrade:

- an `answered` or `partial` left with no valid evidence to `needs-human`;
- a `weakened` or `invalidated` left with no valid evidence to `stands`, marked as having no relevant source.

It may also reject a `weakened` or `invalidated` that keeps valid evidence, but only by naming a concrete flaw in that evidence. "The decision still seems right" SHALL NOT be a reason.

#### Scenario: Downgrade rules documented
- **WHEN** `skills/opsx-questions/` reference text is read
- **THEN** it states both downgrade rules and the concrete-flaw requirement
- **AND** a concrete flaw is evidence that does not say what is claimed, is about another version or scope, or is contradicted by a cited source

### Requirement: Run creation
`questions.sh run new <mode> --questions-file <tsv> [--max N] [--rounds N] [coverage flags] [--repo <dir>]` SHALL create `.opsx/questions/<run-id>/` holding the questions, the settle cap and the coverage outcome (Coverage outcome recorded in the run), add `.opsx/questions/` to the repository `.gitignore` once, and print the run id. It SHALL refuse more than `--max` questions (default 6) with a non-zero exit.

#### Scenario: Too many questions
- **WHEN** `run new settle --questions-file` is given 7 questions with the default `--max`
- **THEN** it exits non-zero and creates no run directory

### Requirement: Recording verdicts
`questions.sh record <run> <qid> --round <k> --stage answer|challenge-a|challenge-b --verdict <v> [--sources <n>] [--attempts <n>]` SHALL store one validated verdict. `--attempts` (1 or 2, default 1) is the number of subagent runs behind it: 2 when a malformed result was retried. It SHALL reject a verdict outside the stage's vocabulary, a round above the cap and an unknown question.

#### Scenario: Wrong vocabulary rejected
- **WHEN** `record <run> Q1 --round 1 --stage answer --verdict stands` runs
- **THEN** it exits non-zero and `status` is unchanged

### Requirement: Run status
`questions.sh status <run>` SHALL print one line per question, `<qid> <state> round=<k> subagents=<n> history=<stage:verdict,...>`, then the `coverage` line. `subagents` SHALL be the sum of the `--attempts` of the recorded verdicts. In answer mode the state SHALL be the last recorded verdict. In challenge mode it SHALL be the strongest recorded verdict (`invalidated` over `weakened` over `stands`), so a later `stands` does not hide an attack.

#### Scenario: Settled in one round
- **WHEN** Q1 records `answer answered`, then `challenge-a stands --sources 2` and `challenge-b stands --sources 1` in round 1
- **THEN** `status` prints `Q1 settled round=1 subagents=3 ...`

### Requirement: Settle state machine
In settle mode the state SHALL follow these rules:

- An `open` question starts `open` (an answer is due). A `decision`, `req-spec` or `req-client` starts `challenging` in round 1, its text being the claim under attack, with no answer subagent until an attack succeeds.
- An answer `needs-human` or `unanswerable` ends the question in that state; `answered` or `partial` moves it to `challenging` in the same round.

#### Scenario: Successful attack reopens
- **WHEN** Q1 records `answer answered`, `challenge-a invalidated --sources 1` and `challenge-b stands --sources 1` in round 1
- **THEN** `status` shows `Q1 open round=2`

### Requirement: Settle challenge outcomes
In settle mode, when both challenges of round `k` are recorded, the state SHALL become:

- `settled` when both are `stands` with `--sources` at least 1;
- on any `weakened` or `invalidated`, `open` in round `k+1` (a new answer is due), or `contested` when `k` is the cap;
- when no attack succeeded but a `stands` had 0 sources, `challenging` in round `k+1` (new challengers, same answer), or `needs-human` when `k` is the cap.

#### Scenario: Untested stands costs a round
- **WHEN** both round-1 challenges of Q1 record `stands`, one with `--sources 0`
- **THEN** `status` shows `Q1 challenging round=2`

#### Scenario: Cap reached while contested
- **WHEN** a run created with `--rounds 1` records an `answered` and a `weakened` challenge for Q1 in round 1
- **THEN** `status` shows `Q1 contested`

### Requirement: Settle rounds
`/opsx-settle` SHALL run each round for every question not yet in a final state: an answer (when the state is `open`), parent validation, then challenger A (internal sources: code, specs, tickets, memory, git history) and challenger B (external sources: web, upstream docs) in parallel. Neither challenger sees the other's brief or result. The answer brief of round `k+1` SHALL carry the attack that succeeded in round `k`. Settle SHALL stop when every question is final or the cap is reached.

#### Scenario: Round structure documented
- **WHEN** `skills/opsx-settle/SKILL.md` is read
- **THEN** it describes the two independent parallel challengers A and B, the carried attack, and the stop condition

### Requirement: Report and write only on command
At the end of a run the skill SHALL show one block per question: the question with its tag (`[open]`, `[decision]`, `[req spec]`, `[req client AC]`), the validated verdict and kept evidence, what validation dropped and why, and a recommendation with its justification. The skill SHALL NOT edit design.md, specs, memory, tickets or any file outside `.opsx/questions/`, nor post anything, until the user explicitly commands a write. It SHALL then write only what the user named.

#### Scenario: Run leaves the repo untouched
- **WHEN** `questions.sh run new`, `record` and `status` run in a scratch repo
- **THEN** `git status --porcelain` shows only `.gitignore` changed, with no other tracked or untracked file outside `.opsx/questions/`

### Requirement: Report details and drafted writes
In settle mode each report block SHALL also show the state, history and round. A `contested` question SHALL show both sides, and a `needs-human` question SHALL suggest the question to ask and whom to ask. A ticket write SHALL be a drafted comment shown to the user, never posted. An invalidated `req client AC` SHALL produce a drafted question to the product owner, never an edit. A resolved open question written back to a design.md SHALL keep its bullet, start with `Resolved:` and cite its source.

#### Scenario: Write rule documented
- **WHEN** the three SKILL.md files are read
- **THEN** each states that nothing is written or posted until the user commands it, and that ticket comments are drafts only

### Requirement: CLIs without reliable subagents
On Claude Code, Cursor CLI and OpenCode the skills SHALL run research through `ops-researcher` subagents. Challengers A and B run in parallel. On Codex CLI and Gemini CLI the parent SHALL research each brief itself, one at a time, following the same stance, verdict format and validation, and SHALL say at the start that the read-only guarantee does not hold there.

#### Scenario: Gap documented
- **WHEN** `README.md` is read
- **THEN** its `/opsx-answer` section states that Codex and Gemini research sequentially in the parent without the read-only guarantee

### Requirement: Installation
`install.sh` SHALL install `opsx-questions` (with an executable `questions.sh`), `opsx-answer`, `opsx-challenge` and `opsx-settle` into the six skill folders, together with `ops-researcher`. It SHALL accept `--skip-questions` to skip all of them. Uninstall SHALL remove them. Verify SHALL report each installed file and check that `questions.sh` parses. `README.md` SHALL list the three skills and `ops-researcher` in the component overview.

#### Scenario: Install and verify
- **WHEN** `install.sh` runs into a scratch HOME
- **THEN** `~/.claude/skills/opsx-questions/questions.sh` is executable, the three skill folders exist under `~/.claude/skills/`, `~/.agents/skills/` and `~/.gemini/skills/`, and verify reports no failure for them

#### Scenario: Skip flag
- **WHEN** `install.sh --skip-questions` runs into a scratch HOME
- **THEN** none of the four skill folders and no `ops-researcher` file is created

#### Scenario: Uninstall
- **WHEN** `install.sh --uninstall` runs after an install
- **THEN** the four skill folders and every `ops-researcher` file are gone
