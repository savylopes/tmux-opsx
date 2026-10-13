# explain-page Specification

## Purpose
Turns a topic from the current agent session into a clean, diagrammed, addressable web page written by a full-context fork and served from this machine through `/expose`, so the user can read it on any device, share it with a client, and refine it by talking to the fork.

## Requirements

### Requirement: Open an explain fork
`/explain "<topic>"` SHALL open a fork through `fork.sh open` with a brief containing the topic and a page protocol, passing the fork's page directory, and SHALL print the page URL (`https://explain--<project>.<domain>/<page-id>/`) and the fork line. `--window`, `--vertical`, `--cli` and `--model` SHALL pass through to `fork.sh open`. The fork pane SHALL be the only way to change the page.

#### Scenario: Open
- **WHEN** the user runs `/explain "how landing works"` with the explain server up
- **THEN** a fork opens whose `brief.md` contains the topic and a page protocol section, and the output names the page URL and the fork id

#### Scenario: Topic required
- **WHEN** `/explain` runs without a topic
- **THEN** the skill asks for one and opens nothing

### Requirement: Open arguments and notes
Everything after `--` SHALL be the topic of `explain.sh open`, even when it starts with `-`. Notes on a stdin that is not a TTY SHALL be read, but `open` SHALL NOT wait more than a few seconds for the first byte of an idle stdin.

#### Scenario: Topic after --
- **WHEN** `explain.sh open --window -- "-v is a topic"` runs
- **THEN** the page's topic is `-v is a topic`

#### Scenario: Idle stdin
- **WHEN** `explain.sh open "x"` runs with a stdin pipe that stays open and receives nothing
- **THEN** it opens the fork without notes within a few seconds and says that no notes arrived

### Requirement: Explain server and exposure per project
The explain skill SHALL publish `${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/explain/<project>/` once per project through `expose.sh up --dir <root> --name explain --hide manifest.tsv --hide '*.sha256' --csp <policy>`, on every `open` and `serve`, so a lost route is restored. `<project>` SHALL be the main checkout's folder name. The skill SHALL start no server of its own and open no tmux window.

#### Scenario: First use starts the server
- **WHEN** `/explain "x"` runs with nothing exposed for the project
- **THEN** the fake `expose.sh` was called with `up --dir <root> --name explain`, `--hide manifest.tsv`, `--hide *.sha256` and `--csp`, no tmux window tagged `@opsx_explain` exists, and nothing listens on a port

#### Scenario: Reuse
- **WHEN** `/explain "y"` runs after `/explain "x"`
- **THEN** `expose.sh up` was called again with the same directory and name, and the new page is served under the same host

#### Scenario: Expose not configured
- **WHEN** `expose.sh up` fails with its not-configured message
- **THEN** the skill prints the page's file path, names `install.sh --expose-domain`, and the fork still opens

#### Scenario: Second tmux server
- **WHEN** `/explain serve` runs from a second tmux server
- **THEN** it behaves exactly as from the first: `expose.sh up --dir` is called and the URL printed; no tmux state is involved

#### Scenario: Same project from a worktree
- **WHEN** `/explain "x"` runs inside a change worktree of project `shop`
- **THEN** the pages root and the exposure name are those of `shop`, not of the worktree folder

### Requirement: Page server sends a Content-Security-Policy
Pages are written by a fork whose context may hold untrusted text, so the proxy, not the page, SHALL confine them. The explain skill SHALL publish its root with a `--csp` that allows scripts only inline and from the one pinned Mermaid file, styles from `'self'`, inline and `https://fonts.googleapis.com`, fonts from `'self'`, `data:` and `https://fonts.gstatic.com`, with `connect-src 'self'`, `img-src 'self' data:`, `form-action 'none'`, `frame-ancestors 'none'` and no other external source; the proxy adds `Referrer-Policy: no-referrer` and `X-Content-Type-Options: nosniff`.

#### Scenario: CSP sent by the server
- **WHEN** `/explain "x"` runs
- **THEN** the `--csp` value passed to `expose.sh up` has `default-src 'none'`, `connect-src 'self'`, `img-src 'self' data:`, `form-action 'none'`, a `script-src` naming only `'unsafe-inline'` and the pinned Mermaid URL, a `style-src` naming `'self'`, `'unsafe-inline'` and `https://fonts.googleapis.com`, and a `font-src` naming `'self'`, `data:` and `https://fonts.gstatic.com`

### Requirement: Page server serves only pages
The explain root SHALL be published so that only pages and the library index are reachable: `manifest.tsv` and `.sha256` sidecars hidden through `--hide`, dotfiles (`.ids/`, `.lock`, `.reindex`, `.meta`) never served by the proxy, no directory listing, and `/<id>` redirected to `/<id>/` keeping its query. The pages root SHALL be private to the user (directory 700, files 600).

#### Scenario: Internal files not served
- **WHEN** `/.reindex`, `/1/.meta`, `/1/manifest.tsv`, `/1/index.html.sha256` or `/.ids/` is requested through the exposure
- **THEN** each answers 404

#### Scenario: Bare page path keeps the query
- **WHEN** `/1?lang=pt` is requested
- **THEN** the proxy redirects to `/1/?lang=pt`

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

### Requirement: Bilingual page
A page requested with both languages SHALL carry the whole explanation in English and in Portuguese: one `<article lang="en">` and one `<article lang="pt">`, each with its own heading and the same labelled blocks (same `data-label` and `id`, same order). Diagrams SHALL exist in both articles under the same `D<n>` label. The `<title>` SHALL hold both titles. The page protocol SHALL require both languages in every `fork.sh page` write of a bilingual page.

#### Scenario: Both languages in the template
- **WHEN** the bilingual page template in `SKILL.md` is read
- **THEN** it has an `<article lang="en">` and an `<article lang="pt">` whose `data-label` sets are identical, an EN / PT switch, and a script that reads `?lang=`, `localStorage` and `navigator.language`

#### Scenario: Library shows both titles
- **WHEN** a page's `<title>` is `Landing explained · Como o landing funciona`
- **THEN** the library index lists that text for the page

#### Scenario: Protocol asks for both languages
- **WHEN** the `brief.md` of a fork opened with `--lang en,pt` is read
- **THEN** its page protocol tells the child to write the English and the Portuguese article in the same `fork.sh page` write with identical labels, and to keep both in step on every edit

### Requirement: Language switch
A bilingual page SHALL show one language at a time with a visible EN / PT switch near the top that changes the shown language without a reload and remembers the choice in `localStorage`. The initial language SHALL be `?lang=en|pt` when present, else the remembered choice, else Portuguese when the browser language starts with `pt`, else English. A `#<label>` fragment SHALL land on that block in the shown language. The switch SHALL be inline script within the server's Content-Security-Policy. A single-language page SHALL show its one article and no switch.

#### Scenario: Switch without reload
- **WHEN** a bilingual page is open in English and the user clicks PT
- **THEN** the Portuguese article is shown, the English one is hidden, `localStorage` holds `pt`, and no request for the page is made besides the reload poll

#### Scenario: Deep link in the shown language
- **WHEN** a bilingual page is opened at `?lang=pt#P1`
- **THEN** the Portuguese article is shown, exactly one element in the live document has `id="P1"`, and it is the Portuguese `P1`

#### Scenario: Single-language page
- **WHEN** a page with only `<article lang="en">` is opened with a remembered choice of `pt`
- **THEN** the English article is shown, every labelled block keeps its id, and no switch is rendered

### Requirement: Switch keeps the reading position
On a bilingual page, without a `#<label>` fragment, a language switch SHALL keep the reader on the same block: the labelled block at the top of the screen SHALL be at the same place in the other language.

#### Scenario: Switch keeps the reading position
- **WHEN** the reader of a bilingual page has scrolled so that `P2` is at the top of the screen, with no fragment in the URL, and clicks the other language
- **THEN** `P2` of the other language is at the top of the screen at the same offset

### Requirement: Diagrams and rendering
Pages SHALL draw diagrams as inline SVG first (a `viewBox`, `role="img"`, an `aria-label`, colours from the page tokens, inside a framed figure), Mermaid second, and an ASCII `<pre>` block last, each carrying a `D<n>` label. Mermaid SHALL be loaded only by pages that contain a Mermaid block, as one exact-version file with a Subresource Integrity hash and `referrerpolicy="no-referrer"`; the template SHALL NOT load it by default. Pages SHALL need no build step and SHALL reload themselves when the served file changes, by polling the file's `Last-Modified` header.

#### Scenario: SVG diagram in the template
- **WHEN** the page template in `SKILL.md` is read
- **THEN** it contains a `D<n>`-labelled `<figure>` holding an inline `<svg>` with `viewBox`, `role="img"` and `aria-label`, and no `<script src=` tag

#### Scenario: Mermaid block
- **WHEN** the fork writes a page with a `class="mermaid"` block
- **THEN** the brief told it to add the pinned Mermaid script tag (exact URL and `integrity` hash) for that page, and the server's policy allows that URL

#### Scenario: Reload on change
- **WHEN** `index.html` is rewritten while open in a browser
- **THEN** the page reloads within a few seconds without user action

### Requirement: Reload poll
The reload poll SHALL also compare an `ETag` that changes with the file's content, so a rewrite within the same second and with the same length is seen: `.reindex` SHALL write `index.html.sha256` beside the library index and beside every page after each page write, and the exposure SHALL use it as the ETag. Only a direct 2xx answer SHALL count: an error status (421, 5xx) or a redirect SHALL never reload the page.

#### Scenario: Same-second rewrite
- **WHEN** a page is rewritten twice within one second with content of the same length
- **THEN** `<root>/<id>/index.html.sha256` differs between the two versions and so does the served `ETag`

#### Scenario: Error answers do not reload
- **WHEN** a poll of an open page gets a 421, a 5xx or a redirect
- **THEN** the page does not reload and keeps polling

### Requirement: Share, list and stop
`/explain share [--for <recipient>] [--ttl <dur>] [--list] [--revoke <r|id|all>]` SHALL call `expose.sh share explain …` and print the link as its last line; the link opens the whole page library of the project, which the skill text and the brief SHALL say. `/explain list` SHALL print the project's pages (id, title, created, fork id) and whether the root is exposed, with its URL. `/explain stop` SHALL run `expose.sh down explain` and keep every page; it SHALL exit 0 when nothing is exposed.

#### Scenario: Share link
- **WHEN** `/explain share --for acme --ttl 3d` runs
- **THEN** the fake `expose.sh` was called with `share explain --for acme --ttl 3d` and the last output line is the link

#### Scenario: Stop
- **WHEN** `/explain stop` runs with the root exposed
- **THEN** the fake `expose.sh` was called with `down explain`, and the pages directory is unchanged

### Requirement: Page protocol in the brief
The brief of an explain fork SHALL instruct the child to: write the whole page with `fork.sh page` (never by editing project files), use the label scheme and keep labels stable using `manifest.tsv`, draw diagrams as inline SVG first, Mermaid second and ASCII last, write the manifest with every page, confirm the URL and labels in its first reply, and accept edits by label from the user. It SHALL name the page's languages and the design elements the template provides. It SHALL state that the page is served behind the expose login and that nothing else may be written.

#### Scenario: Protocol present
- **WHEN** an explain fork's `brief.md` is read
- **THEN** it mentions `fork.sh page`, `manifest.tsv`, the label prefixes `S P D T C N`, inline SVG before Mermaid, and a `Languages:` line

#### Scenario: Design vocabulary in the brief
- **WHEN** an explain fork's `brief.md` is read
- **THEN** it names the hero, key cards, framed figures, pills, callouts and terms list as the elements to build the page from, and tells the child to keep the template's `<style>` and scripts

### Requirement: No secrets in pages
The page protocol SHALL forbid the child to put secrets, tokens, credentials or environment values into the page.

#### Scenario: Secrets forbidden
- **WHEN** an explain fork's `brief.md` is read
- **THEN** its page protocol tells the child never to put secrets, tokens or credentials in the page

### Requirement: Install and documentation
`install.sh` SHALL install `skills/explain/` (`SKILL.md`, executable `explain.sh`) to the same six skill folders as `/fork`, SHALL accept `--skip-explain`, and `--uninstall` SHALL remove the six folders without touching `agent-forks/explain/`. `README.md` SHALL document `/explain`: commands, the URL shape, labels, where pages live, that `/expose` is needed for sharing, and the component overview SHALL list it.

#### Scenario: Installed
- **WHEN** `install.sh` runs in a scratch HOME
- **THEN** `~/.claude/skills/explain/SKILL.md` and an executable `explain.sh` exist, and `--help` mentions `--skip-explain`

#### Scenario: README
- **WHEN** `README.md` is read
- **THEN** it mentions `/explain`, `explain--`, `manifest.tsv` and `fork.sh page`

### Requirement: Page design
The page template SHALL carry one visual system: font-family and colour tokens for light and dark with system fallbacks, an 880 px rail with 68 ch prose, a hero, key cards, framed figures, pills, callout variants, a terms list and a footer. The margin labels and their click-to-copy SHALL keep working inside it.

#### Scenario: Template carries the design
- **WHEN** the page template in `SKILL.md` is read
- **THEN** its `<style>` defines `--display`, `--body` and `--mono` font tokens with system fallbacks, a dark block under `prefers-color-scheme: dark`, and rules for `header.hero`, `.eyebrow`, `.lede`, `.key`, `figure .frame`, `.pair`, `.pill`, `.callout`, `.callout.warn`, `.callout.bad`, `dl.terms` and `footer`, and the body keeps `[data-label]::before` margin labels

#### Scenario: Phone width
- **WHEN** the template is laid out at a 390 px viewport
- **THEN** the content fits without horizontal page scroll, paired figures stack into one column and margin labels stay visible

#### Scenario: Fonts fall back
- **WHEN** the font stylesheet cannot be fetched
- **THEN** the page renders in the named system fallbacks with the same hierarchy, and nothing else on the page fails

### Requirement: Page languages
`explain.sh open` SHALL accept `--lang <en|pt|en,pt>`, default `en`, and SHALL state the requested languages in the brief. A single-language page SHALL carry one `<article lang="xx">` and no language switch; a page requested with both SHALL be bilingual as specified in "Bilingual page". Any other `--lang` value SHALL exit 2 with nothing opened.

#### Scenario: Default is English
- **WHEN** `explain.sh open "x"` runs without `--lang`
- **THEN** the brief says the page is written in English only and the template in the brief has exactly one `<article lang="en">` and no `data-set-lang` buttons

#### Scenario: Both languages on request
- **WHEN** `explain.sh open --lang en,pt "x"` runs
- **THEN** the brief says the page carries English and Portuguese with identical labels and the template in the brief has an `<article lang="en">`, an `<article lang="pt">` and the EN / PT switch

#### Scenario: Portuguese only
- **WHEN** `explain.sh open --lang pt "x"` runs
- **THEN** the brief names Portuguese as the only language and the template has exactly one `<article lang="pt">`

#### Scenario: Bad language
- **WHEN** `explain.sh open --lang de "x"` runs
- **THEN** it exits 2, names the accepted values, and no page id is allocated
