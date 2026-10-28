## MODIFIED Requirements

### Requirement: Send a push without breaking the caller
The push helper SHALL send one ntfy message to the configured topic, authenticated with the token, with a timeout of at most 5 seconds. The body SHALL be plain text (no Markdown rendering, no `Markdown: yes` header), converted from Markdown as described in Push body is plain text for the phone, at most 500 characters, and the helper SHALL never print the token.

#### Scenario: Long body is capped
- **WHEN** the body is 2000 characters
- **THEN** the fake `curl` receives a body of at most 500 characters and no `Markdown: yes` header

## ADDED Requirements

### Requirement: Push body is plain text for the phone
Before sending, the push helper SHALL convert the body from Markdown to plain text: remove `**`, `__` and backtick markers, drop heading `#` markers, turn `[text](url)` into `text`, list bullets into `•`, table rows into `a: b` lines without separator rows, fenced code blocks into `[code]`, and collapse runs of blank lines. Plain text without Markdown SHALL pass through unchanged.

#### Scenario: Markdown is stripped
- **WHEN** `opsx-notify.sh finished "t" -` runs with a body holding `## Done`, `**Landed** as \`9e08d6b\``, `[PR](https://x/1)` and `- item`
- **THEN** the fake `curl` body contains `Done`, `Landed as 9e08d6b`, `PR` and `• item`, and no `**`, backtick, `##` or `](`

#### Scenario: Table becomes lines
- **WHEN** the body holds a Markdown table with header `| gate | verdict |`, a `|---|---|` row and a row `| eval | PASS |`
- **THEN** the fake `curl` body contains `eval: PASS`, and no `|` and no `---`

#### Scenario: Code block replaced
- **WHEN** the body holds a fenced code block of 20 lines
- **THEN** the fake `curl` body contains `[code]` and none of the block's lines

#### Scenario: Plain text unchanged
- **WHEN** the body is `pr-29 is waiting for your answer.`
- **THEN** the fake `curl` body is exactly that text

### Requirement: Long bodies cut on a boundary
A plain-text body longer than about 400 characters SHALL be cut at the last sentence end or line end before that length, else at the last word boundary, and SHALL end with `…`. A body that fits SHALL not be cut and SHALL not end with `…`.

#### Scenario: Cut at a sentence
- **WHEN** the plain-text body is ten 60-character sentences
- **THEN** the fake `curl` body ends with `.…` or `…` right after a sentence end, is at most 500 characters, and no word is split

#### Scenario: Short body not cut
- **WHEN** the body is 120 characters
- **THEN** the fake `curl` body has no `…`
