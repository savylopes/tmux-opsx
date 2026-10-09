# Design

## Context

See proposal.md for why. Constraints from the current harness:

- `install.sh` is global-only; graphify's always-on wiring is deliberately kept out of checkouts. `opsx init` is the first thing that writes into a repo, and only into the repo it runs in.
- OpenSpec skills and `/opsx:*` commands are installed globally, so the README already recommends `openspec init --tools none` per project.
- `.opsx/preview.yaml` is the existing per-repo config; it is flat `key: value` lines parsed in bash by `opsx-preview.sh`.
- `graphify update <path>` re-extracts code with no LLM; `graphify extract` adds the semantic (LLM) pass.
- Skills live in `skills/<name>/` with helper scripts and are copied to every CLI's skills dir by `install.sh`.

## Goals / Non-Goals

**Goals:**
- One deterministic shell command that a person or an agent can run, plus a thin agent skill for the part that needs judgement (`context:`).
- Safe to run on any repo at any time: never overwrite, never commit.

**Non-Goals:**
- Running containers (add-opsx-dev).
- Writing `.opsx/preview.yaml`: an empty or comment-only recipe would make preview fail instead of auto-detecting, so init only prints a hint.
- The semantic graphify pass, git hooks (`graphify hook install`), or global graphify changes.
- Project-local OpenSpec tool copies (`--tools <cli>`).

## Decisions

**1. A launcher `opsx` plus per-skill scripts.** `~/.local/bin/opsx` is a small dispatcher: `opsx init` runs `<skills>/opsx-init/opsx-init.sh`, and add-opsx-dev adds `opsx dev` → `<skills>/opsx-run/opsx-dev.sh`. It finds the skills dir the same way other scripts do (first of the installed skill dirs that has the script). Logic stays inside skills, which `install.sh` already copies to every CLI.
*Alternative:* a monolithic `bin/opsx`. Rejected: duplicates the install paths and keeps logic outside the skill the agent loads.

**2. Steps as independent idempotent functions.** Each step checks its own "done" condition and prints one line: `✓ <step>: created <path>`, `· <step>: skipped (<reason>)` or `! <step>: <warning>`. Order: git → openspec → config → gitignore → graphify → dev → docker → summary. A failing step stops the run with a non-zero exit; warnings do not.

**3. `--force` covers only generated files.** `config` and `dev` are the two files init fully owns. `openspec init` and `.gitignore` are never forced: re-running `openspec init` is OpenSpec's business, and `.gitignore` is only appended to.

**4. Detection reads files, never runs toolchains.** `go.mod` `go` directive (major.minor); `.python-version` (major.minor) else `requires-python` lower bound in `pyproject.toml`; `.nvmrc` (strip `v`, keep major) else `package.json` `engines.node` (first number). Order Go, Python, Node when several match. Parsing with `awk`/`sed`, no `jq` or Python required.

**5. dev.yaml shape.** Flat `key: value`, same parser style as preview.yaml; `setup:` and `cache:` may repeat, one value per line. Init writes `image:` and `setup:` lines with a header comment explaining `dockerfile:` and `cache:`. The keys are consumed by add-opsx-dev.

**6. Context skeleton marker.** The skeleton `context:` starts with `# opsx-init: context skeleton` and lists headings to fill in (purpose, stack, layout, conventions, tests). `/opsx-init` replaces the whole block only while the marker is present, so a re-run never clobbers a user-written context.

## Risks / Trade-offs

- [Detection picks the wrong version, e.g. a `go` directive older than the module actually needs] → the file is a starting point, printed in the summary, and `--force dev` regenerates after edits to the source files.
- [`pip install --user` needs a writable, persistent HOME in the container] → add-opsx-dev gives each project a home volume; until then the line is only text.
- [`~/.local/bin` not on PATH] → `install.sh` already warns about this for `openspec`; the same note covers `opsx`.
- [Two changes ship one `opsx` launcher] → this change creates it with only `init`; add-opsx-dev extends the dispatch table.

## Migration Plan

New files only. Existing repos are unaffected until `opsx init` is run in them. Rollback: `install.sh --uninstall` removes the launcher and skill; files written into repos are the user's to keep or delete.
