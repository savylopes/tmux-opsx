# Design

## Context

See proposal.md "Why". Facts the approach rests on, checked on 2026-10-11:

- Claude Code 2.1.296 exports `CLAUDE_CODE_SESSION_ID` to every shell command and offers `--resume <id>`, `--fork-session` ("when resuming, create a new session ID instead of reusing the original") and a positional first prompt. Transcripts live under `~/.claude/projects/<cwd-slug>/<id>.jsonl`; this session's file is about 1.1 MB.
- OpenCode's `tui` and `run` take `--continue`/`--session <id>` plus `--fork`. Its docs list no environment variable carrying the session id into shell tools; the id reaches MCP servers only as request metadata.
- Codex exposes `CODEX_THREAD_ID` to shell calls from its exec server and its SDK has `thread_fork`, but no `codex fork`/`codex resume --fork` command line was confirmed. Gemini (`--resume <uuid>`) and Cursor (`--resume=<chat-id>`) resume in place, reusing the id.
- `fork.sh` already recovers stripped variables from `/proc/<pid>/environ` up the parent chain (`recover_env_var`), detects the host CLI (`running_under_*`, overridable with `FORK_HOST_CLI`), and builds the launch line in one place (`build_launch_cmd`). `tests/test-fork.sh` runs fake CLIs that log their arguments.

## Goals / Non-Goals

**Goals:**
- A native child is indistinguishable from today's child except for what it knows: same pane, same read-only flags, same return/collect protocol.
- Every fallback is explicit and reportable before the parent writes a brief.
- No new dependency on the agent knowing its own session id; the script finds it.

**Non-Goals:**
- Native forks across CLIs, or for Codex, Gemini and Cursor (see Open Questions for Codex).
- Trimming or summarising the inherited transcript. A near-compaction parent yields a near-compaction child; that is accepted.
- Changing return, collect, notify, ids or model selection.

## Decisions

### 1. Default on, with `--brief-only` / `FORK_NATIVE=0` to opt out

The point of a fork is "the same conversation"; the summary brief was a workaround for CLIs that could not do it. Opt-in would leave the better behaviour unused by default. Alternative considered: `--full` opt-in. Kept as the fallback lever instead, named `--brief-only` on the script and `/fork --brief` in the skill.

### 2. The script decides, and tells the skill first

The parent must write the brief before `open`, but only `fork.sh` knows whether native mode applies (host detection, session id, cwd). So a new read-only subcommand `fork.sh native [--cli] [--cwd]` runs the same eligibility logic and prints `full <cli> <source>` or `brief <reason>`. `open` recomputes it (cheap, deterministic) rather than trusting a flag from the skill, so a stale answer cannot produce a native launch with a context-less brief or vice versa.

Alternative: always write the full brief and let `open` drop the context section in native mode. Rejected: parsing the agent's Markdown is brittle, and the parent would still spend tokens writing it.

### 3. Eligibility, in order

```
host cli detected                 else brief "host CLI not detected"
child cli == host cli             else brief "cross-CLI (<host> -> <child>)"
cli in {claude, opencode}         else brief "<cli> has no true fork"
opencode: cwd == session dir      else brief "cwd differs from the opencode session directory ..."
no --brief-only, FORK_NATIVE != 0 else brief "disabled (...)"
claude: session id found          else brief "no CLAUDE_CODE_SESSION_ID ..."
        and not stale             else brief "stale CLAUDE_CODE_SESSION_ID ..."
```

Session id lookup: `$CLAUDE_CODE_SESSION_ID`, else `recover_session_id`. The id is validated as a UUID before it reaches a command line; a malformed value in the environment counts as no id (brief), it does not trigger the ancestor search.

`recover_session_id` (review finding F1) does not reuse the generic `recover_env_var`. The claude process and the tmux server keep the `CLAUDE_CODE_SESSION_ID` they were launched with: a tmux server started from a Claude shell, and every claude started from one of its panes, carry an earlier conversation's id, while only the shells claude spawns get the live id (observed on this host: claude and tmux server held `d93a2975-…`, the Bash tool shell `494f3484-…`). So the walk stops at the first claude process (comm `claude`, or args matching `claude` / `claude-code`) or tmux process and never takes the id from it; it takes the nearest ancestor below that boundary. Pane shells inherit the server's environment, so a candidate equal to the boundary process's id or to the `$TMUX` server's id is rejected as stale. Stale or missing ids give `brief stale CLAUDE_CODE_SESSION_ID …` / `brief no CLAUDE_CODE_SESSION_ID …`: a visible fallback instead of a wrong session. A claude process above the candidate is not required, because the "Stripped environment" scenario (and hosts forced with `FORK_HOST_CLI`) have none.

OpenCode session directory (review finding F3): `--continue` picks the last session of the directory the child runs in, which must equal the directory the parent's OpenCode session runs in. That is the working directory of the nearest `opencode` ancestor process (`/proc/<pid>/cwd`); the agent's shell may have `cd`'d elsewhere. Without such an ancestor (tests, `FORK_HOST_CLI`), `pwd -P` is used.

The cwd rule existed because Claude stores sessions per project directory and it was not verified that `--resume` finds an id from another directory. If a spike shows it does, the rule can be dropped for Claude without touching the specs' other scenarios (the "Different cwd" scenario would then need revisiting, so run the spike first; task 1.1).

**Spike result (task 1.1, 2026-10-11, Claude Code 2.1.296):** in scratch dir `a`, `claude -p 'Remember the codeword PELICAN…' --output-format json` created session `0a4fdbc4-…`. From a different scratch dir `b`, `claude --resume 0a4fdbc4-… --fork-session -p 'What was the codeword?'` answered `PELICAN` with a new session id (`741f1d4a-…`), stored under `b`'s project directory (`~/.claude/projects/<b-slug>/`). The parent's transcript in `a` was not appended to (no line of the second prompt in it). So `--resume <id>` finds a session from another working directory, and `--fork-session` leaves the parent untouched. **The cwd rule is dropped for Claude** and kept for OpenCode, whose `--continue` means "the last session of this directory" and so cannot reach the parent's session from elsewhere. The spec's "Different cwd" scenario now covers OpenCode, and a "Claude in another cwd" scenario states that Claude stays native.

### 4. Launch lines

- Claude: today's line with `--resume <id> --fork-session` inserted before `--permission-mode plan`. The brief remains the positional prompt. `--append-system-prompt` keeps the carve-out text, and the allow rule is unchanged.
- OpenCode: today's line with `--continue --fork` inserted before `--agent plan`. `meta` records `context=full (opencode --continue)`. Risk: "last session" is wrong when another OpenCode session in the same project was updated more recently. Documented; the user can pass `--brief-only`. If OpenCode later exposes a session id variable, switch to `--session <id> --fork` behind the same eligibility check.

### 5. Recording and reporting

`meta` gets `context=full session=<id>` style lines, the `open` output gets a `# context:` comment line (the first line keeps its parseable form, so the "Report the child's model" requirement is untouched), and `list` gains a CONTEXT column between MODEL and PANE.

### 6. Tests with fakes only

`tests/test-fork.sh` sets `FORK_HOST_CLI` and `CLAUDE_CODE_SESSION_ID` explicitly per case, as the model tests already do, so the real host never leaks into assertions. The fake CLIs log every argument, so `--resume S` and `--fork-session` are asserted exactly, and the "stripped environment" scenario is covered by launching `fork.sh` through an intermediate `env -u CLAUDE_CODE_SESSION_ID bash -c` under a parent that has it.

## Risks / Trade-offs

- [Child sees secrets the parent saw] → The skill says so explicitly and keeps `/fork --brief` one flag away; the README states it. Same user, same machine, same files as the parent's own transcript.
- [First turn cost of a large inherited transcript] → For Claude the prefix equals the parent's and should hit the prompt cache; still stated in docs. No mitigation attempted beyond the opt-out.
- [`--resume` behaviour changes across Claude Code versions] → The flag is in the current `--help`; the test suite pins the launch line, and a failure is a visible fallback, never a silent wrong session.
- [OpenCode `--continue` picks the wrong session] → Documented; `--brief-only` escape; revisit when an id is discoverable.
- [Parent still running while the child reads its file] → `--fork-session` writes to a new id, so the parent's file is read-only from the child's point of view. A child launched mid-write sees the transcript up to the last flushed line, which is fine for a fork.

## Open Questions

- ~~Does `claude --resume <id>` locate a session from a different working directory?~~ Yes (task 1.1, see Decision 3).
- Codex: does the installed CLI offer a fork subcommand (`codex fork`, or `codex resume --fork`)? If yes, Codex joins the native list in a follow-up change using `CODEX_THREAD_ID`; the eligibility table and `build_launch_cmd` are the only touch points.
