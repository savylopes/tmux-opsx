# Proposal

> Captured from the `/opsx:explore` session of 2026-10-13. Decisions confirmed there: adopt the visual system of the user's reference page (Red Hat type, 880 px rail, hero, key cards, framed inline-SVG figures, pills, callouts, terms list, footer); inline SVG before Mermaid; English only by default with Portuguese on request; the fork stays the writer. The serving layer (Python server, tmux window) is left to the companion change `expose-directory-serving`.

## Why

The two pages written so far took 1 min 38 s and 3 min 44 s from `/explain` to a readable page, and they look like a plain document: system font, one narrow column, Mermaid boxes. Three things make them slow: every page is written twice (English and Portuguese), every diagram waits for a 3 MB Mermaid bundle from a CDN before it appears, and the template gives the writer no visual vocabulary beyond paragraphs, so the result reads like notes rather than a page a client would be handed. The user has a reference page whose design they want every explain page to have, and wants pages to arrive faster.

## What Changes

- **New page template** in `skills/explain/SKILL.md`, replacing the current one: the reference design. Red Hat Display, Text and Mono from Google Fonts with `display=swap` and system fallbacks; colour tokens for light and dark (`--bg --surface --fg --muted --line --accent --warn --bad --ok` plus soft variants); an 880 px rail with 68 ch prose; a hero (eyebrow, title, lede); key cards; framed figures with optional side-by-side pairs; tables with uppercase mono headers and status pills; callouts in accent, warn and bad variants; a terms list; a sources footer. The margin labels (`S P D T C N`), click-to-copy, reload poll and language switch script are kept.
- **Inline SVG first.** The page protocol and the template put hand-drawn inline SVG (`viewBox`, `role="img"`, `aria-label`, colours from the tokens) first for diagrams, Mermaid second, ASCII last. The pinned Mermaid `<script>` tag is no longer in the template by default: the writer adds it (exact URL and integrity hash, given in the brief) only when the page contains a Mermaid block. Pages without Mermaid load no external script.
- **English only by default.** `explain.sh open` gains `--lang <en|pt|en,pt>` (default `en`). A single-language page has one `<article lang="xx">` and no EN / PT switch; a bilingual page keeps today's behaviour (two articles, identical labels, switch, `?lang=`). The brief states the requested languages; the fork can add the other language later when the user asks for it by name.
- **Fonts allowed by the server policy.** The explain server's Content-Security-Policy gains `https://fonts.googleapis.com` in `style-src` and `https://fonts.gstatic.com` in `font-src`; everything else stays as strict as today.
- **Library index and placeholder** restyled with the same tokens and type, so the library, the "being written" page and the pages look like one product.
- **Page protocol** in `fork.sh` becomes language-agnostic: it names the languages from the brief's `Languages:` line and applies the identical-labels rule when more than one is named; diagram order becomes SVG, Mermaid, ASCII.
- Not in scope: the serving layer (see `expose-directory-serving`), parent-side page writing without a fork, self-hosted font files, a table of contents or navigation beyond the labels.

## Capabilities

### New Capabilities

None.

### Modified Capabilities
- `explain-page`: "Bilingual page" becomes languages per request with English as the default; "Language switch" and "Switch keeps the reading position" apply to bilingual pages only; "Diagrams and rendering" puts inline SVG first and loads Mermaid only when used; "Page server sends a Content-Security-Policy" admits the two Google Fonts hosts; "Page protocol in the brief" states the languages and the new diagram order; new requirements "Page design" (the visual system the template must carry) and "Page languages" (`--lang`).
- `tmux-fork`: "Brief content" — the page protocol section names the languages from the brief instead of requiring English and Portuguese in every write.

## Impact

- `skills/explain/SKILL.md`: new template, usage table (`--lang`), parent steps, label section unchanged.
- `skills/explain/explain.sh`: `--lang` on `open`, brief text (languages, SVG-first, Mermaid tag on demand), CSP in `.serve.py`, `.reindex` and placeholder styling.
- `skills/fork/fork.sh`: `page_protocol` text (languages from the brief, diagram order). No launch or allow-rule changes.
- `tests/test-explain.sh`, `tests/explain-lang-sim.mjs`, `tests/explain-lang-check.mjs`: template assertions follow the new template (single-article default, bilingual with `--lang en,pt`, no Mermaid tag by default, fonts in the CSP). `tests/test-fork.sh`: page protocol assertions.
- `README.md`: Explain section (design, `--lang`, SVG-first, fonts).
- Readers' browsers fetch two stylesheet and font requests from Google; no other new external dependency. Pages already written keep their old template and still render.
