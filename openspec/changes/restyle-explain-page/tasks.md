# Tasks

## 1. Template and skill text

- [x] 1.1 Replace the fenced template in `skills/explain/SKILL.md` with the reference design: Google Fonts link (`display=swap`), `--display/--body/--mono` tokens with system fallbacks, light and dark colour tokens, `.wrap` 880 px and `.prose` 68 ch, `header.hero` (`.eyebrow`, `h1`, `.lede`), `.key` cards, `figure .frame` with one inline SVG example (`viewBox`, `role="img"`, `aria-label`, `var(--accent)` colours), `.pair`, `.tscroll table` with `.pill` variants, `.callout` (+ `.warn`, `.bad`), `dl.terms`, `footer`; keep the margin labels, `.opsx-target`, article show/hide, `.opsx-lang`, toast, and all three scripts; no Mermaid `<script src>`; wrap the Portuguese article in `<!-- article:pt -->`/`<!-- /article:pt -->` and the switch in `<!-- lang-switch -->`/`<!-- /lang-switch -->`; verify with `tests/explain-lang-sim.mjs lang` and `poll` on the extracted template that every check passes and `grep -c '<script src=' ` is 0
- [x] 1.2 Update the SKILL.md prose: usage table gains `--lang <en|pt|en,pt>` (default English), the "Page template" section describes the design elements and the on-demand Mermaid tag, the label table maps `N` to `.callout` and `T` to tables, key cards and terms lists; verify the file mentions `--lang`, `header.hero`, `.key`, `.pill`, `dl.terms`, `inline SVG` and `integrity`

## 2. explain.sh: languages, brief, CSP, index, placeholder

- [x] 2.1 Add `--lang` to `cmd_open` (values `en`, `pt`, `en,pt`/`pt,en`; default `en`; anything else exits 2 naming the accepted values before any id is allocated) and record `langs=` in the page `.meta`; verify in `tests/test-explain.sh` that `--lang de` exits 2 with no new `.ids` entry and that `.meta` holds `langs=en` by default
- [x] 2.2 In `build_brief`, print `- Languages: English` / `Português` / `English and Portuguese …` from `--lang`, derive the template variant (strip the other article and the switch by markers for one language, single title), and replace the instruction paragraph: keep `<style>` and scripts, build from hero, key cards, framed figures, pairs, pills, callouts, terms, footer; inline SVG first; add the pinned Mermaid tag (URL + `integrity` from `MERMAID_URL`/`MERMAID_SRI`) only when the page has a Mermaid block; verify in `tests/test-explain.sh` that the default brief has exactly one `<article lang="en">`, no `data-set-lang`, the words `inline SVG`, `hero`, `integrity=` and `Languages: English`, and that `--lang en,pt` yields both articles and the switch
- [x] 2.3 Extend the CSP in `.serve.py`: `style-src 'self' 'unsafe-inline' https://fonts.googleapis.com`, `font-src 'self' data: https://fonts.gstatic.com`, everything else unchanged; verify in `tests/test-explain.sh` that the served header names both hosts and that `script-src`, `connect-src` and `img-src` are as before
- [x] 2.4 Restyle `.reindex` (fonts link, tokens, hero-style heading, table with mono uppercase headers, dark block) and `write_placeholder` (tokens and type, no fonts link) and make the placeholder's text follow `--lang`; verify in `tests/test-explain.sh` that the library index contains `--display` and `fonts.googleapis.com`, the placeholder contains `--display` and `explain-lang-sim.mjs poll` still passes on both
- [x] 2.5 `shellcheck skills/explain/explain.sh` and `bash tests/test-explain.sh` (with the test's bilingual page opened with `--lang en,pt` so the Chromium check still exercises the switch); verify both are clean

## 3. fork.sh: language-agnostic page protocol

- [x] 3.1 Rewrite the language and diagram bullets of `page_protocol()` in `skills/fork/fork.sh`: languages from the brief's `Languages:` line (one article and no switch for one language; both articles, identical labels and `D<n>` for two), diagrams inline SVG then Mermaid (tag from the brief) then ASCII; verify in `tests/test-fork.sh` that a page fork's `brief.md` contains `Languages:` and `inline SVG` and no longer `Two languages, one write`, and `shellcheck skills/fork/fork.sh` is clean
- [x] 3.2 Update the page-fork paragraph of `skills/fork/SKILL.md` and the `fork.sh` header comment to say the languages come from the brief; verify with `grep -n "Languages" skills/fork/SKILL.md skills/fork/fork.sh`

## 4. Documentation

- [x] 4.1 README Explain section: the design (one paragraph naming the elements and the fonts), `--lang` with English as the default, SVG-first diagrams and Mermaid on demand, the CSP's two font hosts; update the overview line that says "in English and Portuguese"; verify README mentions `--lang`, `inline SVG`, `fonts.googleapis.com` and no longer promises every page in both languages

## 5. Integration

- [x] 5.1 Run `bash tests/test-fork.sh`, `bash tests/test-explain.sh`, `shellcheck` on `fork.sh` and `explain.sh`, and `openspec validate restyle-explain-page --strict`; verify all pass
- [x] 5.2 Manual walk-through in a tmux session with `/expose` configured: `/explain "how /explain pages are served"` (default English), confirm the page uses the hero, at least one framed SVG figure and a callout, opens on a phone without horizontal scroll and reloads after an "expand P2" edit; then `/explain --lang en,pt "…"` and confirm the EN / PT switch; record both outcomes in the apply report

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.
