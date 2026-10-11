# Spec Delta

## Purpose
Turns a topic from the current agent session into a clean, diagrammed, addressable web page written by a full-context fork and served from this machine through `/expose`, so the user can read it on any device, share it with a client, and refine it by talking to the fork.

## ADDED Requirements

### Requirement: Open an explain fork
`/explain "<topic>"` SHALL open a fork through `fork.sh open` with a brief containing the topic and a page protocol, passing the fork's page directory, and SHALL print the page URL (`https://explain--<project>.<domain>/<page-id>/`) and the fork line. `--window`, `--vertical`, `--cli` and `--model` SHALL pass through to `fork.sh open`. The fork pane SHALL be the only way to change the page.

#### Scenario: Open
- **WHEN** the user runs `/explain "how landing works"` with the explain server up
- **THEN** a fork opens whose `brief.md` contains the topic and a page protocol section, and the output names the page URL and the fork id

#### Scenario: Topic required
- **WHEN** `/explain` runs without a topic
- **THEN** the skill asks for one and opens nothing

### Requirement: Explain server and exposure per project
The explain skill SHALL serve `${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/explain/<project>/` with a loopback-only static server in a tmux window tagged `@opsx_explain=<project>`, started on first use and reused afterwards, and SHALL publish its port once through `expose.sh up <port> --name explain`. `<project>` SHALL be the main checkout's folder name.

#### Scenario: First use starts the server
- **WHEN** `/explain "x"` runs with no explain server for the project
- **THEN** a window tagged `@opsx_explain=<project>` exists, something listens on the recorded loopback port, and the fake `expose.sh` was called with `up <port> --name explain`

#### Scenario: Reuse
- **WHEN** `/explain "y"` runs while the server is up
- **THEN** no second window or exposure is created and the new page is served under the same host

#### Scenario: Expose not configured
- **WHEN** `expose.sh up` fails with its not-configured message
- **THEN** the skill prints the local `http://127.0.0.1:<port>/` URL, names `install.sh --expose-domain`, and the fork still opens

#### Scenario: Same project from a worktree
- **WHEN** `/explain "x"` runs inside a change worktree of project `shop`
- **THEN** the pages root and the exposure name are those of `shop`, not of the worktree folder

### Requirement: Page files and library
Each page SHALL be one self-contained `index.html` at `<root>/<page-id>/`, with `manifest.tsv` (label, one-line summary) beside it. `<page-id>` SHALL be unique per project and SHALL NOT be reused. The root `index.html` SHALL list every page with title, creation time and fork id, regenerated whenever a page is written. Pages SHALL survive `fork.sh close` and `/explain stop`.

#### Scenario: Library index
- **WHEN** two pages have been written in the project
- **THEN** `<root>/index.html` lists both titles and `/explain list` prints both with their ids

#### Scenario: Pages persist
- **WHEN** the fork that wrote page 3 is closed and `/explain stop` runs
- **THEN** `<root>/3/index.html` still exists

### Requirement: Addressable blocks
Every block in a page SHALL carry a visible label in the margin and an HTML id equal to it: `S<n>` for sections (nested as `S1.2`), `P<n>` paragraphs, `D<n>` diagrams, `T<n>` tables, `C<n>` code blocks, `N<n>` callouts. Labels SHALL be stable across rewrites: an edited block keeps its label, a new block takes the next unused number, a removed label is never reused. Clicking a label SHALL copy `#<label>` to the clipboard. `manifest.tsv` SHALL list every current label with a summary.

#### Scenario: Deep link
- **WHEN** the page contains paragraph `P7`
- **THEN** `index.html` has an element with `id="P7"` whose visible label text is `P7`, and `manifest.tsv` has a `P7` row

#### Scenario: Stable labels across a rewrite
- **WHEN** the user tells the fork to expand `P7` and the fork rewrites the page
- **THEN** `P7` still identifies the same paragraph, every previously existing label is still present or absent (never renumbered), and new blocks use numbers not seen in the previous manifest

### Requirement: Diagrams and rendering
Pages SHALL render diagrams with Mermaid loaded from a CDN, falling back to inline SVG or an ASCII `<pre>` block when Mermaid cannot express the diagram, each still carrying a `D<n>` label. Pages SHALL need no build step and SHALL reload themselves when the served file changes, by polling the file's `Last-Modified` header.

#### Scenario: Mermaid block
- **WHEN** the fork writes a flow diagram
- **THEN** `index.html` contains a `D<n>`-labelled element with a `class="mermaid"` source and a script tag loading Mermaid

#### Scenario: Reload on change
- **WHEN** `index.html` is rewritten while open in a browser
- **THEN** the page reloads within a few seconds without user action

### Requirement: Share, list and stop
`/explain share [--for <recipient>] [--ttl <dur>] [--list] [--revoke <r|id|all>]` SHALL call `expose.sh share explain …` and print the link as its last line. `/explain list` SHALL print the project's pages (id, title, created, fork id) and the server state. `/explain stop` SHALL run `expose.sh down explain`, kill the tagged window and keep every page; it SHALL exit 0 when nothing is running.

#### Scenario: Share link
- **WHEN** `/explain share --for acme --ttl 3d` runs
- **THEN** the fake `expose.sh` was called with `share explain --for acme --ttl 3d` and the last output line is the link

#### Scenario: Stop
- **WHEN** `/explain stop` runs with the server up
- **THEN** the exposure is removed, no `@opsx_explain=<project>` window remains, and the pages directory is unchanged

### Requirement: Page protocol in the brief
The brief of an explain fork SHALL instruct the child to: write the whole page with `fork.sh page` (never by editing project files), use the label scheme and keep labels stable using `manifest.tsv`, prefer Mermaid then SVG then ASCII for diagrams, write the manifest with every page, confirm the URL and labels in its first reply, and accept edits by label from the user. It SHALL state that the page is served behind the expose login and that nothing else may be written.

#### Scenario: Protocol present
- **WHEN** an explain fork's `brief.md` is read
- **THEN** it mentions `fork.sh page`, `manifest.tsv`, the label prefixes `S P D T C N` and Mermaid

### Requirement: Install and documentation
`install.sh` SHALL install `skills/explain/` (`SKILL.md`, executable `explain.sh`) to the same six skill folders as `/fork`, SHALL accept `--skip-explain`, and `--uninstall` SHALL remove the six folders without touching `agent-forks/explain/`. `README.md` SHALL document `/explain`: commands, the URL shape, labels, where pages live, that `/expose` is needed for sharing, and the component overview SHALL list it.

#### Scenario: Installed
- **WHEN** `install.sh` runs in a scratch HOME
- **THEN** `~/.claude/skills/explain/SKILL.md` and an executable `explain.sh` exist, and `--help` mentions `--skip-explain`

#### Scenario: README
- **WHEN** `README.md` is read
- **THEN** it mentions `/explain`, `explain--`, `manifest.tsv` and `fork.sh page`
