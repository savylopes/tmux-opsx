## Why

Push bodies are sent as raw text cut at 500 characters. A finished push carries the agent's final message, which is Markdown, and the ntfy Android app does not render Markdown (only the web app does, behind a `Markdown: yes` header), so the phone shows `**`, backticks, `##` and table pipes, cut mid-word.

## What Changes

- Every push body (finished, decision, Claude question, silence, info) is turned into plain text before it is sent: emphasis and code markers removed, heading markers dropped, `[text](url)` becomes `text`, list bullets become `•`, table rows become `a: b` lines with separator rows dropped, fenced code blocks become `[code]`, blank-line runs collapsed.
- The body is cut at the last sentence or line end before about 400 characters and ends with `…`, never mid-word; a body that already fits is not cut.
- No `Markdown: yes` header is sent (Android would show the raw symbols); links stay on the existing action buttons.
- Answer-button bookkeeping (the recorded question text matched against the screen) keeps the raw text.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `mobile-notify`: the push body is plain text converted from Markdown and cut on a word, sentence or line boundary.

## Impact

- `skills/opsx-run/opsx-notify.sh` (one plain-text function applied in `post`), `tests/test-notify.sh`, `evals/mobile-notify/`, README notifications paragraph.
- No new dependency (sed/awk only).
