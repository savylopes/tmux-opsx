# Design

## Context

`opsx-notify.sh post` cuts the body to `BODY_MAX=500` with `${body:0:500}` and sends it as is. Finished pushes take Claude's `last_assistant_message` (Markdown); decision pushes take the question text (`pr.sh note`, Claude `AskUserQuestion`), which is mostly plain. The ntfy docs show Markdown rendering only in the web app; the user's Android app shows raw symbols.

## Goals / Non-Goals

**Goals:** readable plain-text pushes on Android; the gist in the first ~400 characters; no new dependencies.

**Non-Goals:** a full Markdown parser; summarising or choosing "the important part" of a message (the user chose the cleaned-up start); sending Markdown to the web app.

## Decisions

1. **One function `plain_body`** in `opsx-notify.sh`, applied inside `post` before the length cut, so every kind gets it and callers are unchanged. Raw text is still what `record_decision` / the answer-button records store (they are matched against the screen), so cleaning happens only at send time.
2. **awk line pass** (portable awk, no gawk-only features): track fenced blocks (```` ``` ```` / `~~~`) and emit `[code]` once per block; table rows (`^\s*\|.*\|\s*$`) → cells trimmed and joined with `: ` (header row kept as a line, separator rows `^[\s|:-]+$` dropped); headings `^#{1,6} ` stripped; bullets `^\s*[-*+] ` → `• `; numbered lists kept. Then sed on each line: `\[([^]]*)\]\([^)]*\)` → `\1`, remove `**`, `__`, backticks; leave single `*`/`_` (too ambiguous, appear in identifiers). Collapse runs of blank lines to one, trim leading/trailing blank lines.
3. **Cut** to `CUT_AT=400` characters (character-based, `${s:0:n}` under a UTF-8 locale like the existing cut): find the last `. `/`! `/`? ` or newline in the window, use it if it is past 40% of the window, else the last space; append `…`. Hard cap `BODY_MAX=500` stays as a backstop. Title keeps its existing one-line handling and also gets the inline-marker pass (`**`, backticks).
4. **No `Markdown` header**, unchanged.

## Risks / Trade-offs

- [Identifiers with `__`] e.g. `__init__` loses underscores → acceptable for a phone glance.
- [Locale] `${s:0:n}` counts bytes under `LC_ALL=C`; the function sets a UTF-8 locale when available so `…` and `•` are not split, falling back to byte cut plus trimming an incomplete trailing sequence.
- [Test runtime] `tests/test-notify.sh` already takes ~8.5 min; new cases call `plain_body` through a sourced/`--plain` debug entry to stay fast.
