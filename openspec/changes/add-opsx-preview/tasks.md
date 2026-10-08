# Tasks

## 1. Preview windows in opsx-window.sh

- [x] 1.1 Add `preview-start <change> --cwd <dir> --script <file>` (`new-window -d -P` running `bash <file>`, no send-keys, `remain-on-exit on`, tag `@opsx_preview=<change>`, title `ox ▶<change>`, rename off), plus `preview-find <change>` and `preview-kill <change>|--all`, using the existing session resolution, and document them in the header usage; verify on a private tmux server (`tmux -L`) in a new `tests/test-preview.sh` that the window gets the tag, has no `@opsx_change`, and that `find_window`/`close --all` still match only agent windows

## 2. opsx-preview.sh core

- [x] 2.1 Create `skills/opsx-run/opsx-preview.sh` with a header usage comment, `help`, and the subcommands `up <change>|--main`, `stop <change>|--all`, `url <change>|--main` and `list`; resolve the project (main checkout folder through the git common dir) and the checkout (the worktree on `opsx/<change>` from `git worktree list --porcelain`, or the main checkout for `--main`), and exit non-zero with "apply the change first" when there's no worktree; verify `bash -n`, `shellcheck`, and a test against a scratch repo with and without an `opsx/x` worktree
- [x] 2.2 Implement recipe resolution: the flat `.opsx/preview.yaml` reader (`cmd` required, `install`, `health` default `/`, `timeout` default 120, quote stripping, a warning on unknown keys) and package.json detection through `node -e` (lockfile → pm, `run dev --port $PORT` with npm's `--` form, a `detected:` line); verify with test cases for a declared recipe, missing `cmd` (exit non-zero, no window), a pnpm fixture (the command uses `pnpm run dev --port`), an npm fixture (uses `-- --port`), and nothing to detect (exit non-zero, asks for `.opsx/preview.yaml`)
- [x] 2.3 Implement the expose preflight (`$OPSX_EXPOSE_SH`, else the sibling `../expose/expose.sh`, else PATH; exit 3 or a missing script → a message naming `install.sh --expose-domain`; exit 4 → proxy not running) before anything starts; verify with a fake `expose.sh` that returns 3 that `up` exits non-zero with that text and creates no window

## 3. Starting and stopping

- [x] 3.1 Implement the install step with a stored hash (install command + lockfile contents; rerun only when it changes; save the hash only on success; a failed install exits with its code and output tail); verify with a recipe whose `install` appends to a counter file: start/stop/start runs it once, and changing the lockfile runs it again
- [x] 3.2 Implement port choice (reuse the last port, else 3100–3999 via `/dev/tcp`), the generated launch script (`setsid` with a `set -m` fallback, `PORT` and `HOST=127.0.0.1`, `tee -a` log, PGID written to state), `preview-start`, and the health wait (curl on `127.0.0.1:<port><health>` until 2xx/3xx; on timeout or process exit, print the log tail, stop the group, publish nothing); verify with a `python3 -m http.server $PORT --bind 127.0.0.1` recipe that becomes healthy, and with a `cmd: exit 1` recipe that fails with log lines and no `expose.sh up` call recorded by the fake
- [x] 3.3 Implement publishing (`expose.sh up <port> --name <change> --project <project>`, relaying its last line as the URL), the state record, the "already running" check (window alive + group alive + healthy → reprint the URL; otherwise clean up and restart), `url`, `list`, and `stop` (TERM the group, KILL after 5s, `expose.sh down`, `preview-kill`, delete the record; exit 0 when nothing is running; `--all` for every preview in the project); verify with test cases: two `up` runs give the same URL and one window, `stop` leaves no window, no process on the port and a recorded `down`, a second `stop` exits 0, and `up --main` publishes under the name `main`

## 4. Lifecycle wiring

- [x] 4.1 Call `opsx-preview.sh stop <change>` from `opsx-land.sh` before the worktree is removed (exit code ignored; printed under `--dry-run`), and from `opsx-window.sh close <change>` / `close --all` (`stop --all`) before windows are killed, ignoring failures when the script is missing; verify with test cases that land in a scratch repo with a running preview leaves no preview window and records a `down`, and that land and close without a preview behave as before (the existing `tests/test-eval.sh` land cases still pass)
- [x] 4.2 Update `skills/opsx-run/SKILL.md`: usage lines for `preview`, `preview stop` and `preview url`; `preview` as a reserved first token with the omitted-change picker that also offers the main checkout; an Actions row (inline `opsx-preview.sh`, relay the URL and warning); the `qa` and `apply --validate` prompts gain the "run `opsx-preview.sh up <change>`, pass `PREVIEW_URL`, otherwise state the reason and fall back" instruction; close and close-all mention preview teardown; verify by grepping the file for each of these
- [x] 4.3 Update `agents/opsx-qa.md`: add `PREVIEW_URL` to the inputs, and change the start-the-app paragraph so that a given preview URL is tested without starting a server, with the old behaviour as the fallback; verify by grepping for `PREVIEW_URL`, and that a scratch-HOME `install.sh` still converts the agent for all five CLIs (the Codex TOML and the OpenCode/Gemini/Cursor files contain the new text)

## 5. Docs

- [x] 5.1 Update the README: the preview lines in the `/opsx-run` usage block and the overview, a Preview section (the `.opsx/preview.yaml` keys and an example, detection rules, binding to `127.0.0.1` with Next.js/Vite flags, the dependency on `--expose-domain`, teardown on close/land, QA using the preview URL), and `opsx-preview.sh` in the Contents table; verify that the example recipe runs with `opsx-preview.sh up` against the fake `expose.sh`

## 6. Integration

- [x] 6.1 Run `bash tests/test-preview.sh`, `bash tests/test-eval.sh`, `bash tests/test-fork.sh` and `shellcheck skills/opsx-run/*.sh tests/test-preview.sh`; verify that all pass with no FAIL lines

## Workflow follow-up

- Requires `add-expose` to be landed first.
- On the real VPS, after landing: add `.opsx/preview.yaml` to `provision-admin` (for example `cmd: pnpm dev --port $PORT --hostname 127.0.0.1`), run `/opsx-run <change> preview` on one of its changes, open the URL from a phone, then `close` the change and confirm the URL stops answering.
