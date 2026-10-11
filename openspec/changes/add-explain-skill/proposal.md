# Proposal

> Captured from the `/opsx:explore` session of 2026-10-11. Decisions confirmed there: pages are served from this machine through `/expose` (not published to claude.ai); one server and one exposure per project, pages persist as a library; the page is addressable, the fork pane is the only control channel (v1 is one-directional).

## Why

Explaining something from a long agent session today means reading a wall of terminal text. The fork can already carry the whole conversation into a side agent; what it cannot do is turn that knowledge into a clean, diagrammed web page the user can open on any device, hand to a client, and then refine by talking to the fork: "expand P7", "the arrow in D2 is wrong". The harness already has every building block (full-context forks, `expose.sh` for login-protected URLs and share links, tmux-window plumbing for long-running local servers); this change wires them into one skill.

## What Changes

- **New `/explain` skill** (`skills/explain/`, installed for all five CLIs like `/fork`): `/explain "<topic>"` opens a fork briefed with a page protocol, starts the project's explain server and exposure if they are not up, and prints the page URL. `/explain share [--for <r>] [--ttl <d>]`, `/explain list`, `/explain stop` manage sharing, the library and the server.
- **One explain server per project.** A loopback static server (a small stdlib Python server that sends a strict CSP and serves only the pages) over `${XDG_STATE_HOME:-~/.local/state}/agent-forks/explain/<project>/`, exposed once as `explain--<project>.<domain>`. Pages live at `/<page-id>/` and outlive the fork; `index.html` at the root lists them. The server runs in a tagged tmux window like a preview; `stop` removes the exposure and the window and keeps the pages.
- **Addressable pages.** Every block carries a visible, stable, deep-linkable label: `S<n>` sections, `P<n>` paragraphs, `D<n>` diagrams, `T<n>` tables, `C<n>` code, `N<n>` callouts. Labels never change or get reused across rewrites; a `manifest.tsv` next to the page maps labels to one-line summaries so the fork can resolve "P7" without re-reading the HTML. Clicking a label copies its anchor.
- **Single-file pages.** One self-contained `index.html` per page: Mermaid from a CDN for diagrams (inline SVG or an ASCII `<pre>` when Mermaid cannot express it), a few lines of JS for click-to-copy labels and reload-on-change (polls `Last-Modified`), no build step.
- **`fork.sh page`** (in `/fork`): a new child-side subcommand that reads an HTML document on stdin and writes it only into that fork's page directory, allowed in plan mode by the same narrow-rule pattern as `fork.sh return`. The brief gains a page protocol section when the fork is opened by `/explain`. No marker fallback for pages: when the command is blocked, the child says so and stops.
- **Docs and install.** `install.sh` installs and uninstalls `skills/explain/` with a `--skip-explain` flag; README gains an "Explain" section; the `/fork` README section mentions `page`.
- Not in scope: comments or edits typed on the page reaching the fork (v1 is one-directional), publishing through claude.ai artifacts, rendering diagrams server-side, pages written into the project repo.

## Capabilities

### New Capabilities
- `explain-page`: the `/explain` skill: opening a page-writing fork, the per-project explain server and exposure, page layout and labelling rules, the manifest, library listing, sharing, stop, install and documentation.

### Modified Capabilities
- `tmux-fork`: new requirement for the child-side `page` write subcommand and its allow rule; "Brief content" gains the optional page protocol section; "Fork state and ids" records the page directory in `meta`.

## Impact

- New `skills/explain/SKILL.md` and `skills/explain/explain.sh` (server, exposure, library, share, stop; calls `fork.sh open` and `expose.sh`).
- `skills/fork/fork.sh`: `page` subcommand, `--page-dir` on `open`, allow rule and protocol text; `skills/fork/SKILL.md`: child-side `page` instructions.
- `install.sh`: install/uninstall/skip for the explain skill. `README.md`: new section, overview tree.
- Tests: `tests/test-explain.sh` (fake `expose.sh`, fake CLIs, private tmux server) and `tests/test-fork.sh` cases for `page`.
- Depends on `/expose` being set up (`install.sh --expose-domain`); without it `/explain` prints the local URL only and says how to enable sharing.
- Content written by the fork is served from this machine behind the expose login; nothing leaves the VPS unless a share link is issued.
