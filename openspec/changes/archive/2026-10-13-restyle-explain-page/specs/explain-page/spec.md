# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Page server sends a Content-Security-Policy
Pages are written by a fork whose context may hold untrusted text, so the explain server, not the page, SHALL confine them. Every response SHALL carry a `Content-Security-Policy` that allows scripts only inline and from the one pinned Mermaid file, styles from `'self'`, inline and `https://fonts.googleapis.com`, fonts from `'self'`, `data:` and `https://fonts.gstatic.com`, with `connect-src 'self'`, `img-src 'self' data:`, `form-action 'none'`, `frame-ancestors 'none'` and no other external source, plus `Referrer-Policy: no-referrer` and `X-Content-Type-Options: nosniff`.

#### Scenario: CSP sent by the server
- **WHEN** a page is fetched from the explain server
- **THEN** the response has a `Content-Security-Policy` with `default-src 'none'`, `connect-src 'self'`, `img-src 'self' data:`, `form-action 'none'`, a `script-src` naming only `'unsafe-inline'` and the pinned Mermaid URL, a `style-src` naming `'self'`, `'unsafe-inline'` and `https://fonts.googleapis.com`, a `font-src` naming `'self'`, `data:` and `https://fonts.gstatic.com`, and `Referrer-Policy: no-referrer`

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

### Requirement: Page protocol in the brief
The brief of an explain fork SHALL instruct the child to: write the whole page with `fork.sh page` (never by editing project files), use the label scheme and keep labels stable using `manifest.tsv`, draw diagrams as inline SVG first, Mermaid second and ASCII last, write the manifest with every page, confirm the URL and labels in its first reply, and accept edits by label from the user. It SHALL name the page's languages and the design elements the template provides. It SHALL state that the page is served behind the expose login and that nothing else may be written.

#### Scenario: Protocol present
- **WHEN** an explain fork's `brief.md` is read
- **THEN** it mentions `fork.sh page`, `manifest.tsv`, the label prefixes `S P D T C N`, inline SVG before Mermaid, and a `Languages:` line

#### Scenario: Design vocabulary in the brief
- **WHEN** an explain fork's `brief.md` is read
- **THEN** it names the hero, key cards, framed figures, pills, callouts and terms list as the elements to build the page from, and tells the child to keep the template's `<style>` and scripts
