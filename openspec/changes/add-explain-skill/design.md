# Design

## Context

See proposal.md for motivation and the specs for behaviour. What the implementation builds on, as read in the checkout at the time of writing:

- `skills/fork/fork.sh`: `open` writes `brief.md` + a generated fork protocol, launches the child from a generated `launch.sh`, and records `meta`; `return` finds its own fork dir from `$FORK_DIR`, the process chain, or the pane option `@fork_dir`, and writes `result.md`. The Claude child runs `--permission-mode plan` with one `--allowedTools "Bash(<fork.sh> return:*)"` rule and a carve-out sentence in `--append-system-prompt`. Native full-context forks landed in `add-fork-native-resume`.
- `skills/expose/expose.sh`: `up <port> --name <n>` publishes `127.0.0.1:<port>` and prints the URL last; exit 3 means "not configured" with a message naming `install.sh --expose-domain`; `down <name>`, `share <name> …`, `url <name>` exist. Project name = the main checkout's folder name.
- `skills/opsx-run/opsx-preview.sh`: has `pick_port` (free loopback port), a record file per preview, and starts a tagged tmux window through `opsx-window.sh preview-start`. Its tag is `@opsx_preview`, which `close-all` treats as a preview, so the explain server must not reuse it.
- `install.sh`: `install_fork_skill` copies `SKILL.md` + `fork.sh` to six skill dirs, guarded by `--skip-fork`; `--uninstall` removes the dirs.
- `tests/test-fork.sh`: private tmux server, fake CLIs that log their arguments and `FORK_*` env, assertions on `launch.sh` and `meta`.
- `python3` is on the host; `python3 -m http.server` serves a directory, answers HEAD, and sends `Last-Modified`.

## Goals / Non-Goals

**Goals:**
- `fork.sh` learns one thing: a page directory it may write to through `page`. Everything about servers, URLs and the library lives in `explain.sh`.
- The page is a plain static file; the browser does the rendering (Mermaid) and the refreshing (polling). No daemon beyond `python3 -m http.server`.
- Reuse the harness's own patterns: atomic id allocation from `fork.sh`, port picking and tagged windows from previews, URL and sharing from `expose.sh`.

**Non-Goals:**
- Page-to-fork feedback (comments on the page). The fork pane is the only input.
- Editing pages outside a fork, converting pages to other formats, or serving anything but the explain root.
- Any write into a project checkout.

## Decisions

### 1. Split of responsibilities: `explain.sh` orchestrates, `fork.sh` only writes

`explain.sh "<topic>"`: resolve project, ensure server + exposure, allocate a page id, build the brief (topic + page protocol pointer), call `fork.sh open --page-dir <root>/<id> [--window|--vertical|--cli|--model] --parent-model …`, print the page URL and the fork line. `fork.sh` gains `--page-dir` on `open`, `page [--manifest]` for the child, `page_dir` in `meta`, `FORK_PAGE_DIR` in the child env, a second allow rule, and the page protocol text. Nothing in `fork.sh` knows about ports, exposures or the library.

Alternative: put everything in `fork.sh` (`fork.sh open --page`). Rejected: the fork script is already large and CLI-launch focused; servers and URLs are a different lifecycle (per project, not per fork).

### 2. Pages root keyed by project, server state beside it

```
${XDG_STATE_HOME:-~/.local/state}/agent-forks/explain/<project>/
  .ids/<n>          atomic id allocation (noclobber), same scheme as fork ids
  .server           port=<p> window=<@id> pid=<pid>   (record; absent = not running)
  .reindex          executable written by explain.sh; regenerates index.html
  index.html        library index
  <n>/index.html    page
  <n>/manifest.tsv  label<TAB>summary
  <n>/.meta         topic, created, fork id, tmux session
```

`<project>` is computed exactly as `expose.sh` and `opsx-dev.sh` do (basename of the directory holding the common git dir), so worktrees map to the same root and the exposure name `explain` is shared. Keying by project rather than tmux session was chosen in exploration: pages are a library, and two sessions must not race for the same exposure name.

Dotfiles are served too (python's server does not hide them). They contain no secrets (`.server` holds a loopback port and ids) and the whole host sits behind the expose login, so this is accepted rather than adding a custom server.

### 3. Server lifecycle

- Start: `pick_port` (copied from `opsx-preview.sh`, loopback bind check via `/dev/tcp`), write `launch.sh` under the root (`exec python3 -m http.server --bind 127.0.0.1 <port> --directory <root>`), `tmux new-window -d -n "ox >explain" bash launch.sh`, set `@opsx_explain=<project>` on the window, write `.server`, wait until the port answers (HEAD `/`, up to 10 s). The window is created directly by `explain.sh` (as `fork.sh` creates panes); `opsx-window.sh preview-start` is not used because its tag means "preview" to `close-all`.
- Reuse: `.server` exists, its window id still exists with the tag, and the port answers. Otherwise treat as stale and start again.
- Exposure: `expose.sh up <port> --name explain` on every `explain` call that (re)starts the server; on reuse call it too (it is idempotent and re-publishing the same name is allowed) so a lost route is restored. Exit 3 (not configured) is not fatal: print `http://127.0.0.1:<port>/<id>/` and the one-line hint.
- Stop: `expose.sh down explain` (ignore failures), `tmux kill-window` on the recorded id, delete `.server`. Pages untouched. Exit 0 when nothing ran.

### 4. `fork.sh page`

- Resolves the page dir from `$FORK_PAGE_DIR`, else `recover_env_var FORK_PAGE_DIR`, else `meta` of the fork dir found the way `return` finds it. Exit 1 when no fork, exit 4 when the fork has no page dir, exit 3 when the write fails, exit 2 on empty stdin.
- Writes to a temp file in the page dir and `mv -f` over `index.html` (or `manifest.tsv` with `--manifest`) so a browser never reads a half-written page. Prints the written path.
- After a successful `index.html` write, runs `<page_dir>/../.reindex` if it exists and is executable. This is how the library index stays current without `fork.sh` learning about libraries; `explain.sh` installs that script. Documented in the `fork.sh` header.
- Claude launch: `--allowedTools "Bash(<fork.sh> return:*)" "Bash(<fork.sh> page:*)"` (two rules; the heredoc form `fork.sh page <<'EOF'` matches `page:*` the same way `return` already does). The carve-out sentence names both commands. Codex: the sandbox asks approval per write, as with `return`. Gemini and Cursor plan modes: usually refused; the page protocol says to report and stop. No marker fallback for pages.

### 5. Page protocol and template

`fork.sh` appends a "Page protocol (fork <id>)" section after the fork protocol when `--page-dir` is set: the exact write commands (`page`, `page --manifest`), the label scheme and stability rules, "Mermaid, then inline SVG, then ASCII `<pre>`", "whole page every time", "first reply: confirm the URL (from the brief) and list the top-level labels", "edits are requested by label". The HTML skeleton itself (CSS, label click-to-copy, reload polling, Mermaid script tag) lives in `skills/explain/SKILL.md` as a fenced template the parent pastes into the brief, so the child never improvises the plumbing and `fork.sh` stays free of HTML.

Reload polling: every 2 s `fetch(location.pathname, {method:'HEAD', cache:'no-store'})`, compare `Last-Modified`, `location.reload()` on change. Labels: each block is `<section id="S1" data-label="S1">` or `<p id="P7" data-label="P7">`; CSS draws `data-label` in the margin via `::before`; a delegated click handler copies `#<label>` with `navigator.clipboard`.

### 6. Library index

`.reindex` (bash, written by `explain.sh`) scans `<root>/<n>/index.html`, extracts `<title>`, reads `.meta`, and writes `index.html` with a table (id, title, created, fork) linking to `/<n>/`. `explain.sh list` prints the same table plus server state and URL. Regeneration is idempotent and cheap (tens of pages at most).

### 7. Tests with fakes

`tests/test-explain.sh`: private tmux server, fake `expose.sh` (logs args; `up` prints a URL; a mode that exits 3), fake CLIs from `test-fork.sh`, scratch `XDG_STATE_HOME`, a scratch git repo for the project name. Asserts: server window tagged and port answering (real python server on a scratch port), `.server` record, reuse without a second window, exit-3 path prints the local URL, page id allocation, `.reindex` producing `index.html`, share pass-through, stop keeps pages. `tests/test-fork.sh` gains: `--page-dir` in `meta` and env, second allow rule in `launch.sh`, `page` writes/refuses per spec, protocol section present only with `--page-dir`.

## Risks / Trade-offs

- [Two allow rules in plan mode behave differently from one] → Task 1.5 verifies with the real `claude` in a scratch dir before the rest is built on it; fallback is a single combined rule `Bash(<fork.sh>:*)`, which still only permits that script.
- [Python server lists directories and serves dotfiles] → Behind the expose login; no secrets in the root. If a public exposure is ever wanted, revisit with a custom server.
- [Stale `.server` after a reboot] → Reuse checks window + port, not the file; stale records are overwritten.
- [Child rewrites a huge page on every edit] → Accepted for v1; pages are a few hundred lines. The manifest keeps label stability cheap.
- [Mermaid CDN unreachable on the viewer's device] → Diagram source stays visible as text; ASCII fallback is in the protocol for diagrams that matter.
- [`close-all` ignores the explain window] → Intended: pages outlive changes. `explain stop` is the only closer; documented.

## Open Questions

- Should `explain.sh` accept `--open` to also open the URL on the local desktop (`xdg-open`)? Deferred; the URL is printed and copied via `expose.sh url` semantics already.
