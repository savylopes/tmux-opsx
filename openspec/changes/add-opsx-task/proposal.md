# Proposal

## Why

Starting work on a task is manual and repetitive: open a tmux session, name it after the ticket, start an agent, name its conversation, paste the ticket in, explain it, then start exploring. Coming back later means finding the right session and conversation by hand. A single `/opsx-task <ticket | file | text>` can do all of that and give each task one named home (tmux session plus conversation) that a second run returns to instead of starting over.

## What Changes

- New `/opsx-task` skill with an `opsx-task.sh` helper. Input is a ticket key (`MED-43`, any case) or tracker URL, a file describing the task, or free text.
- **Name.** The ticket key, upper-cased (`MED-43`). Without a key, the agent proposes 2-4 kebab-case words from the content, at most 30 characters (`rate-limit-api`). A name already used by a **different** task gets `-2`, `-3`…; the same input reuses its name.
- **Brief.** The calling agent reads the task (an issue-tracker MCP for a ticket, honouring the project's tracker scoping rules; the file; or the text) and writes `.opsx/tasks/<name>.md`: a header (`source:`, `cli:`, `session_id:`, `created:`) and a description of what the task does (summary, scope, acceptance criteria, links, unknowns). `.opsx/tasks/` is added to `.gitignore` once.
- **Session.** A new tmux session named `<name>` in the repository root, tagged as an opsx task, running the agent CLI with normal approvals (the user is present). Its first input asks the agent to read the brief, describe the task, then explore it with `/opsx:explore` (the openspec-explore skill on CLIs without the slash command). When the caller is inside tmux, the client switches to the new session.
- **Conversation name.** Claude Code launches as `claude -n <name> --session-id <uuid>`, with the uuid stored in the brief. The other CLIs cannot name a conversation at launch: only the tmux session carries the name, and `opsx-task.sh` captures the CLI's session id after launch (newest session created after the launch time) into the brief. Gemini's explore prompt also runs `/chat save <name>`.
- **Run again.** `/opsx-task MED-43` again:
  - session alive: switch to it, nothing else;
  - session gone, brief has a session id: relaunch the session resuming that conversation;
  - session gone, no usable id: relaunch and explore again from the brief, saying so;
  - `--refresh`: re-read the source, rewrite the brief's description (keeping the header), and tell a running session what changed.
  It never refetches on its own and never resumes a "latest" conversation, since every task in a repo shares the same folder.
- `install.sh` installs the skill into the six skill folders, with `--skip-task`, uninstall and verify. `README.md` documents `/opsx-task` and lists it in the component overview.

## Capabilities

### New Capabilities
- `task-session`: starting and returning to one named tmux session plus agent conversation per task. Covers input resolution (key, file, text), naming and collisions, the brief file and its header, launching with the name and an explore-first prompt, session-id capture per CLI, and resume, refresh and switch behaviour.

### Modified Capabilities
<!-- None. `/opsx-review`'s session naming stays as it is. -->

## Impact

- New: `skills/opsx-task/` (`SKILL.md`, `opsx-task.sh`), `tests/test-task.sh` (scratch repo, private tmux server, stub agent CLIs).
- Repositories using it gain a git-ignored `.opsx/tasks/` folder.
- `install.sh`: six skill folders, `--skip-task`, uninstall, verify. `README.md`: overview tree, table and a section.
- Dependencies: tmux; an issue-tracker MCP only for ticket inputs; `uuidgen` or `/proc/sys/kernel/random/uuid` for Claude session ids.
- Security: ticket and file text is data, not instructions, both in the brief and in the launch prompt. Names are restricted to `[A-Za-z0-9-]` before they reach tmux, a file name or a command line.

## Open Points

1. **Session-id capture for Codex, Cursor, OpenCode and Gemini** is based on their docs (`codex resume <id>` and `~/.codex/sessions/`, `agent ls` and `--resume=<id>`, `opencode session list` and `-s <id>`, `gemini --list-sessions` and `--resume <uuid>`), not on running them. None of them is installed on this machine. The tests use stubs. Where capture fails on a real CLI, a second run falls back to exploring from the brief.
