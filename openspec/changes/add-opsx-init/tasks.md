# Tasks

## 1. Launcher and init steps

- [ ] 1.1 Add `skills/opsx-init/opsx-init.sh` with argument parsing (`--git`, `--graphify`, `--force config|dev`, `help`), the git-repo check (`--git` → `git init`), and the step output format (`✓`/`·`/`!` lines); verify with `bash -n`, shellcheck, and that `opsx-init.sh --force everything` exits non-zero creating nothing
- [ ] 1.2 Implement the openspec step (`openspec init --tools none` when `openspec/` is missing), the config step (skeleton with `schema: spec-driven` and the `# opsx-init: context skeleton` marker, never touching an existing `config.yaml`/`config.yml`) and the gitignore step (append `graphify-out/` once); verify by running twice in a scratch repo and diffing
- [ ] 1.3 Implement the graphify step (`--graphify` → `graphify update .`, warning when graphify is missing; otherwise print the command), the docker check (warn only, never pull/build/run) and the summary (created/changed paths plus a `git add` line, no staging or commits); verify in a scratch repo with fake `graphify` and `docker` logging their arguments
- [ ] 1.4 Add the `opsx` launcher (dispatch `init` to the first installed `opsx-init/opsx-init.sh`, `help`, non-zero usage for unknown subcommands); verify `opsx help` lists `init` and `opsx frobnicate` exits non-zero
- [ ] 1.5 Add `tests/test-init.sh` (scratch HOME and repos, fake `openspec`/`graphify`/`docker` on PATH) covering: not a repo, `--git`, fresh openspec call, already initialised, skeleton written, existing config kept, single gitignore line, `--graphify`, no docker warning, docker never pulled/built/run, second run all skipped and no file changes, nothing committed or staged, bad `--force` value; verify `bash tests/test-init.sh` passes with no FAIL lines

## 2. Toolchain detection

- [ ] 2.1 Implement the dev step: detection for Go (`go.mod`), Python (`.python-version`, `pyproject.toml` `requires-python`) and Node (`.nvmrc`, `package.json` `engines.node`), `setup:` lines (`go mod download`, `pip install --user -r requirements.txt`, lockfile install for npm/pnpm/yarn/bun), several-toolchain comments plus `dockerfile:` warning, header comment, no file and a hint when nothing is detected, and `--force dev`; verify with `bash -n` and shellcheck
- [ ] 2.2 Extend `tests/test-init.sh` with: Go `go 1.22` → `golang:1.22` and `setup: go mod download`, `.nvmrc v20.11.0` → `node:20`, pnpm setup line, Go+Node comment and warning, nothing detected, `--force dev` replacing `image: custom:1`; verify the script passes with no FAIL lines

## 3. Skill and install

- [ ] 3.1 Write `skills/opsx-init/SKILL.md` (trigger `/opsx-init`): run `opsx init` with the user's flags (or the script path when `opsx` is not on PATH), relay the summary, then replace the `context:` block only while the skeleton marker is present, covering purpose, stack, layout, conventions and test commands, and leave it unchanged otherwise; verify by grepping for `opsx init` and the marker text
- [ ] 3.2 In `install.sh`, install the `opsx-init` skill to every CLI's skills dir, install the `opsx` launcher into the user's bin dir, add `--skip-init` if the other components have skip flags, and remove both on uninstall; verify in a scratch HOME that `~/.local/bin/opsx` and `~/.claude/skills/opsx-init/SKILL.md` exist, and that uninstall removes them
- [ ] 3.3 Add install cases to `tests/test-init.sh` (scratch HOME): launcher installed and executable, skill installed for Claude; verify the script passes with no FAIL lines

## 4. Docs

- [ ] 4.1 Update `README.md`: an "Initialising a repo" section (`opsx init`, `--git`, `--graphify`, `--force config|dev`, what each step writes, no commits, `/opsx-init`), the component overview tree, the "Setting up OpenSpec in a project" section pointing to `opsx init`, and the tests list; verify the documented `opsx init` example runs as written in a scratch repo

## 5. Integration

- [ ] 5.1 Run `./install.sh` in a scratch HOME, then `opsx init --graphify` in a scratch Go repo with fake `graphify`, and confirm the summary, files and that a second run changes nothing; then run `bash tests/test-init.sh` and `bash tests/test-fork.sh` and confirm both pass
