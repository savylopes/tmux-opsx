# project-init Specification

## Purpose
Sets up a repo for the harness with one command: OpenSpec folders and config, graphify ignores, and a toolchain declaration for the dev container, safely re-runnable and never committing.

## Requirements

### Requirement: opsx command
`install.sh` SHALL install an executable `opsx` into the user's bin dir (`~/.local/bin`, or `~/bin` when that is the one on PATH). `opsx init` SHALL run the init steps in the current directory. `opsx help` and an unknown subcommand SHALL print usage; an unknown subcommand SHALL exit non-zero.

#### Scenario: Installed
- **WHEN** `install.sh` runs in a scratch HOME
- **THEN** `~/.local/bin/opsx` exists, is executable, and `opsx help` lists `init`

#### Scenario: Unknown subcommand
- **WHEN** `opsx frobnicate` runs
- **THEN** it exits non-zero and prints usage

### Requirement: Git repo required
`opsx init` SHALL refuse to run outside a git work tree, exiting non-zero with a message that names `--git`, and SHALL create nothing. With `--git` it SHALL run `git init` first and continue.

#### Scenario: Not a repo
- **WHEN** `opsx init` runs in an empty directory that is not a git repo
- **THEN** it exits non-zero, mentions `--git`, and the directory stays empty

#### Scenario: --git
- **WHEN** `opsx init --git` runs in an empty directory
- **THEN** the directory becomes a git repo and contains `openspec/config.yaml`

### Requirement: OpenSpec setup
When the repo has no `openspec/` directory, `opsx init` SHALL run `openspec init --tools none` in the repo root. When `openspec/` exists it SHALL skip this step.

#### Scenario: Fresh repo
- **WHEN** `opsx init` runs in a git repo without `openspec/` and a fake `openspec` logs its arguments
- **THEN** the fake was called with `init --tools none`

#### Scenario: Already initialised
- **WHEN** `opsx init` runs in a repo that already has `openspec/`
- **THEN** `openspec init` is not called and the output reports the step as skipped

### Requirement: Config skeleton
When `openspec/config.yaml` and `openspec/config.yml` are both missing, `opsx init` SHALL write `openspec/config.yaml` with `schema: spec-driven` and a `context:` block whose first line is the marker `# opsx-init: context skeleton`. An existing config file SHALL NOT be changed.

#### Scenario: Skeleton written
- **WHEN** `opsx init` runs in a repo without a config file
- **THEN** `openspec/config.yaml` contains `schema: spec-driven` and the line `# opsx-init: context skeleton`

#### Scenario: Existing config kept
- **WHEN** `openspec/config.yaml` already exists with custom content and `opsx init` runs
- **THEN** the file is byte-for-byte unchanged

### Requirement: Graphify setup
`opsx init` SHALL add a `graphify-out/` line to `.gitignore`, creating the file if needed, unless an equivalent line is already present. With `--graphify` it SHALL also run `graphify update .` in the repo root; without it, it SHALL print that command as a hint. A missing `graphify` with `--graphify` SHALL be a warning, not a failure.

#### Scenario: Ignore added once
- **WHEN** `opsx init` runs twice in the same repo
- **THEN** `.gitignore` contains exactly one `graphify-out/` line

#### Scenario: Graph build on request
- **WHEN** `opsx init --graphify` runs with a fake `graphify` that logs its arguments
- **THEN** the fake was called with `update .`

### Requirement: Toolchain detection
When `.opsx/dev.yaml` is missing, `opsx init` SHALL detect the repo's toolchain and write `.opsx/dev.yaml` as flat `key: value` lines: `go.mod` `go X.Y` → `image: golang:X.Y`; `.python-version` or `pyproject.toml` `requires-python` → `image: python:X.Y`; `.nvmrc` or `package.json` `engines.node` major → `image: node:<major>`. With nothing detected it SHALL write no file and print a hint.

#### Scenario: Go repo
- **WHEN** the repo has `go.mod` containing `go 1.22` and `opsx init` runs
- **THEN** `.opsx/dev.yaml` contains `image: golang:1.22`

#### Scenario: Node repo
- **WHEN** the repo has `.nvmrc` containing `v20.11.0` and no other toolchain file
- **THEN** `.opsx/dev.yaml` contains `image: node:20`

#### Scenario: Nothing detected
- **WHEN** the repo has no toolchain files and `opsx init` runs
- **THEN** `.opsx/dev.yaml` does not exist and the output mentions `.opsx/dev.yaml`

### Requirement: Setup commands in dev.yaml
The generated `.opsx/dev.yaml` SHALL include one `setup:` line per detected install step: `go mod download` for Go, `pip install --user -r requirements.txt` when `requirements.txt` exists, and the lockfile's install command for Node (`npm ci`, `pnpm install --frozen-lockfile`, `yarn install --frozen-lockfile` or `bun install`).

#### Scenario: Go setup line
- **WHEN** a Go repo is initialised
- **THEN** `.opsx/dev.yaml` contains `setup: go mod download`

#### Scenario: pnpm setup line
- **WHEN** a repo with `package.json`, `.nvmrc` and `pnpm-lock.yaml` is initialised
- **THEN** `.opsx/dev.yaml` contains `setup: pnpm install --frozen-lockfile`

### Requirement: Several toolchains
When more than one toolchain is detected, `opsx init` SHALL write the first in the order Go, Python, Node as `image:`, list the others in `#` comment lines in the file, and print a warning suggesting a `dockerfile:` for multi-language repos.

#### Scenario: Go and Node
- **WHEN** the repo has both `go.mod` (`go 1.22`) and `.nvmrc` (`20`)
- **THEN** `.opsx/dev.yaml` has `image: golang:1.22`, a comment line mentioning `node:20`, and the output warns about `dockerfile:`

### Requirement: Docker check
`opsx init` SHALL warn when no `docker` command is on PATH, and SHALL NOT pull, build or run any image.

#### Scenario: No docker
- **WHEN** `opsx init` runs with no `docker` on PATH in a Go repo
- **THEN** it exits 0, prints a warning naming docker, and `.opsx/dev.yaml` is still written

#### Scenario: Docker untouched
- **WHEN** `opsx init` runs with a fake `docker` that logs its arguments
- **THEN** the fake was never called with `pull`, `build` or `run`

### Requirement: Idempotent re-run
Running `opsx init` again SHALL leave every file it or the user created unchanged and report each step as skipped. It SHALL exit 0 when every step is done or skipped.

#### Scenario: Second run
- **WHEN** `opsx init` runs twice in a Go repo
- **THEN** the second run exits 0, every step line says skipped, and no tracked or untracked file changed between the runs

### Requirement: Force one step
`opsx init --force <step>` SHALL regenerate that step's file, for `<step>` one of `config` and `dev`. Any other value SHALL be rejected with a non-zero exit before anything is written.

#### Scenario: Regenerate dev.yaml
- **WHEN** `.opsx/dev.yaml` contains `image: custom:1` in a Go repo and `opsx init --force dev` runs
- **THEN** `.opsx/dev.yaml` contains `image: golang:1.22`

#### Scenario: Bad step
- **WHEN** `opsx init --force everything` runs
- **THEN** it exits non-zero and no file is created

### Requirement: No commits
`opsx init` SHALL NOT create commits or stage files. It SHALL end with a list of the paths it created or changed and a `git add` command for them.

#### Scenario: Nothing committed
- **WHEN** `opsx init` runs in a repo with one commit
- **THEN** the repo still has one commit, nothing is staged, and the output contains `git add`

### Requirement: /opsx-init skill
The repo SHALL ship a `/opsx-init` skill, installed for every supported CLI, that runs `opsx init` with the user's flags and then, only when `openspec/config.yaml` still contains the skeleton marker, replaces the `context:` block with a description of the repo's purpose, stack, layout, conventions and test commands, removing the marker.

#### Scenario: Skill installed
- **WHEN** `install.sh` runs in a scratch HOME
- **THEN** `~/.claude/skills/opsx-init/SKILL.md` exists and mentions `opsx init` and `# opsx-init: context skeleton`

#### Scenario: User context protected
- **WHEN** the installed `opsx-init/SKILL.md` is read
- **THEN** it says to leave `context:` unchanged when the skeleton marker is absent

### Requirement: Documentation
`README.md` SHALL document `opsx init`, its flags (`--git`, `--graphify`, `--force <step>`), what each step writes, and `/opsx-init`, and the component overview SHALL list both.

#### Scenario: README
- **WHEN** `README.md` is read
- **THEN** it mentions `opsx init`, `--force`, `.opsx/dev.yaml` and `/opsx-init`
