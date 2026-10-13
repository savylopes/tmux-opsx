# Design

## Context

See proposal.md for motivation and `specs/` for the behaviour. What the implementation builds on, as read in the checkout:

- `skills/explain/SKILL.md` holds the fenced page template after the `<!-- explain-page-template -->` marker; `explain.sh page_template()` extracts it with `awk` and `build_brief()` appends it to the brief with a fixed instruction paragraph, unless the parent's notes already contain `data-label`.
- The template's scripts already cope with one article: `show()` falls back to `arts[0]` when the chosen language has no article, and the switch buttons are plain `[data-set-lang]` elements the script looks up but never requires.
- `explain.sh .serve.py` builds the CSP string once (`CSP = …`) with `style-src 'self' 'unsafe-inline'` and `font-src 'self' data:`; `.reindex` and `write_placeholder` carry their own small inline styles.
- `fork.sh page_protocol()` has the languages hard-coded ("Two languages, one write") and the diagram order "Mermaid first".
- `tests/test-explain.sh` asserts the template shape (two articles, Mermaid in both, the switch, the one external URL), runs `explain-lang-sim.mjs` (node-only DOM stand-in driving the page scripts) and `explain-lang-check.mjs` (headless Chromium through CDP when available).
- The reference page (the user's artifact) is a single HTML file: Google Fonts link, tokens on `:root` with a dark block, `.wrap`/`.prose`, `header.hero`, `.key`, `figure .frame` with inline SVG, `.pair`, `.callout` variants, `.pill`, `dl.terms`, `footer`.

## Goals / Non-Goals

**Goals:**
- One template that is the reference design plus the explain plumbing (margin labels, click-to-copy, reload poll, language switch when bilingual).
- A page with no Mermaid block loads nothing external but the font stylesheet.
- The language set is a parameter of `open`, decided by the parent, stated once in the brief, and honoured by the protocol without `fork.sh` knowing the languages.

**Non-Goals:**
- Self-hosting fonts (would need the server to serve font files; deferred, see Risks).
- Changing how pages are served or exposed (`expose-directory-serving`).
- Re-rendering pages written with the old template.

## Decisions

### 1. One template, language set chosen at `open`

`explain.sh open --lang <en|pt|en,pt>` (default `en`). `page_template()` keeps extracting the full bilingual skeleton from `SKILL.md`; `build_brief()` then derives the variant: for one language it drops the other `<article>` and the `<nav class="opsx-lang">` block (both delimited by markers in the template, `<!-- article:pt -->` … `<!-- /article:pt -->` and `<!-- lang-switch -->` … `<!-- /lang-switch -->`), and the title placeholder becomes a single title. The brief's `Languages:` line says which; the template instruction paragraph says "one article, no switch" or "two articles, identical labels, switch".

Alternative: two templates in `SKILL.md`. Rejected: they would drift; the scripts are identical and the single-article case is already handled by them.

Alternative: always bilingual, Portuguese generated lazily by a second fork turn. Rejected: it doubles the output on every rewrite, which is the cost the user wants gone.

### 2. The design lands as the template's CSS, with the plumbing kept

The reference page's CSS is taken as is (tokens, type, rail, hero, key, figures, pairs, callouts, pills, terms, footer), with these additions from the current template: `[data-label]` margin labels (left gutter widened to 4.5 rem on the rail, 3 rem on phones), `.opsx-target` outline, `article[lang]` show/hide rules, `.opsx-lang` switch, `#opsx-toast`. `aside.note` becomes `div.callout` (N labels stay N labels; a callout keeps `id`/`data-label` on the `.callout` element). Block elements the writer may label: `section`, `p`, `figure`, `.key` (as `T<n>`, it is tabular), `table` (wrapped in `.tscroll`, label on the `table`), `pre` (`C<n>`), `.callout` (`N<n>`), `dl.terms` (`T<n>`).

The Google Fonts `<link>` goes in the template `<head>` with `display=swap` and the token fallbacks `"Segoe UI", system-ui, sans-serif` / `ui-monospace, "SF Mono", Menlo, monospace`, so a blocked fetch degrades to today's look.

### 3. Mermaid on demand

The template has no `<script src=…mermaid…>` and no `mermaid.initialize` by default. The brief's instruction paragraph carries the exact tag (URL and `integrity`, taken from `MERMAID_URL` plus a `MERMAID_SRI` constant in `explain.sh`, the one place they live now) and says: add it to `<head>` with the one-line `initialize` call only when the page has a `pre.mermaid`. The page script's `mermaid.run` call is already guarded by `if (window.mermaid)`. The CSP keeps naming the URL so a page that adds the tag works.

Alternative: keep the tag and rely on the browser cache. Rejected: first load on a phone still pays 3 MB, and the tag is a liability on pages that never use it.

### 4. CSP: two Google hosts, nothing else

`.serve.py` `CSP` gains `https://fonts.googleapis.com` in `style-src` and `https://fonts.gstatic.com` in `font-src`. `connect-src`, `img-src` and `script-src` are unchanged, so page script still cannot talk to anything but the explain host. The server's `Referrer-Policy: no-referrer` already covers the font requests.

Alternative: self-host the three families under `<root>/.fonts/` and let the server serve `/.fonts/*`. Deferred: it widens the serve allowlist and adds ~400 KB of binaries to the skill install; the companion change (Caddy `file_server`) makes this cheap later.

### 5. `fork.sh` protocol stays generic

`page_protocol()` replaces the "Two languages, one write" bullet with: "Languages: the brief's `Languages:` line is authoritative. With one language, one `<article lang>` and no switch. With two, both articles in every write, same labels, same order, same `D<n>`, `<title>` as `English · Português`." Diagram bullet becomes "inline SVG (framed figure, `viewBox`, `role="img"`, `aria-label`, token colours) first; Mermaid only when the structure is too costly to draw, adding the pinned tag from the brief; ASCII last." No launch, allow-rule or `meta` change.

### 6. Library index and placeholder

`.reindex` and `write_placeholder` reuse the template's token block and type (copied into their heredocs; they are tiny) so the library and the waiting page match. They keep inline styles only (no fonts link on the placeholder, which lives seconds; the library gets the fonts link).

### 7. Tests follow the template

`tests/test-explain.sh`: the template assertions split into "skeleton in SKILL.md" (bilingual, with markers) and "brief variant" (default `open` has one article and no `data-set-lang`; `--lang en,pt` has both). Mermaid assertions become "no `<script src=` in the template" and "the brief carries the pinned tag with `integrity`". CSP assertion adds the two font hosts and still forbids any other external source. A new node sim case runs the page scripts against a single-article page (one article, remembered `pt`, ids kept, no buttons). `explain-lang-check.mjs` keeps driving the bilingual variant (`--lang en,pt` in the test). `tests/test-fork.sh`: protocol assertions look for `Languages:` and `inline SVG` instead of "Two languages, one write".

## Risks / Trade-offs

- [Hand-drawn SVG takes more output tokens than a Mermaid line per node] → the protocol says SVG for the one or two diagrams that carry the explanation, Mermaid when a diagram has many nodes, ASCII last; English-only default more than compensates.
- [Google Fonts request reveals the reader's IP to Google] → acceptable for shared pages; fonts fall back when blocked; self-hosting noted as the follow-up once the Caddy file server exists.
- [Old pages keep the old look] → they still render and reload; the user re-runs `/explain` for a page they want restyled.
- [Evals under `evals/explain-page/` assert the old template (both articles, Mermaid tag)] → ops-eval rewrites them from the modified scenarios; this change does not touch `evals/`.
- [Writers may ignore the design vocabulary and produce plain paragraphs] → the template ships with one worked example of every element and the brief names them; the user can ask the fork by label to use a card or a pair.
