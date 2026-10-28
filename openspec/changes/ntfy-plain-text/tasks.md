# Tasks

## 1. Plain text

- [ ] 1.1 Add `plain_body` to `skills/opsx-run/opsx-notify.sh` per design Decision 2 and apply it in `post` before the cut, plus the inline-marker pass on the title; keep `record_decision` and answer-button records on the raw text; verify with fake `curl` test cases: headings/bold/backticks/links/bullets stripped, table → `eval: PASS` with no `|`/`---`, 20-line fenced block → `[code]` only, `pr-29 is waiting for your answer.` unchanged, no `Markdown` header
- [ ] 1.2 Cut per design Decision 3 (`CUT_AT=400`, sentence/line end else word boundary, `…`, `BODY_MAX` backstop, UTF-8 safe); verify: ten 60-char sentences → ends right after a sentence end with `…`, ≤ 500 chars, no split word; a 120-char body has no `…`; a body of `•`/`é` characters is never cut inside a character

## 2. Docs and checks

- [ ] 2.1 Update the `opsx-notify.sh` header comment and the README notifications paragraph (plain text, cut on a boundary, no Markdown on Android)
- [ ] 2.2 Run `tests/test-notify.sh`, `opsx-eval.sh --change ntfy-plain-text` and `openspec validate ntfy-plain-text --strict`, all passing
