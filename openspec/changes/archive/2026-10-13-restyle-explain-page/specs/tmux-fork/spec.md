# Spec Delta

## MODIFIED Requirements

### Requirement: Brief content
The parent agent SHALL write a brief containing: the question (or "general exploration" if none), a statement that the child answers questions and must not modify files, and instructions to run `/fork return` when the user asks. In brief mode it SHALL also contain 5–15 lines of context from the current conversation (goal, relevant files, current state or hypothesis); in full-context mode (see "Native fork") the context section SHALL be omitted. When `open` is given `--page-dir`, `fork.sh` SHALL append a page protocol section naming the exact `fork.sh page` command, requiring the page in the language or languages the brief names (its `Languages:` line) and, when more than one is named, identical labels in every write, after the fork protocol. The brief SHALL be stored as `brief.md` in the fork's state directory and used as the child's first prompt.

#### Scenario: Brief seeded
- **WHEN** a fork is opened with a question
- **THEN** `brief.md` contains the question, a context section and the read-only role, and the child's first turn responds to it

#### Scenario: Short brief in full-context mode
- **WHEN** `fork.sh native` reported `full` and the parent opens the fork
- **THEN** `brief.md` contains the question, the read-only role and the fork protocol, and no context section

#### Scenario: Page protocol appended
- **WHEN** `fork.sh open --page-dir <dir>` runs
- **THEN** `brief.md` ends with a page protocol section containing the literal `fork.sh page` command, the rule that the page is written in the languages the brief's `Languages:` line names with identical labels when there are two, and inline SVG before Mermaid for diagrams; a fork opened without `--page-dir` has no such section
