# Design

## Context

See proposal.md for the motivation and `specs/opsx-preview/spec.md` for the behaviour. The relevant parts of the current code:

- `opsx-window.sh` owns all tmux work. It finds windows by `@opsx_change` (`find_window`), and `close --all` kills every window that has that tag. A preview window must therefore never carry `@opsx_change`, or lookups and bulk closes would mix it up with the agent window.
- ops-applier always makes the worktree `../wt-<change>` on branch `opsx/<change>`. `opsx-land.sh` finds the branch by the same convention and removes the worktree during cleanup, so a preview has to stop before that happens.
- The `qa` dispatcher prompt currently tells ops-qa "how to run the app if known", and ops-qa starts the app itself.
- `expose.sh` (change `add-expose`) has exit codes 0 = ok, 2 = usage, 3 = not configured, 4 = proxy down, prints the URL as its last line, and takes `--project`.
- The harness requires Node.js. `python3` and `jq` exist on the target box but are not required.

## Goals / Non-Goals

**Goals:**
- One script, `opsx-preview.sh`, that is the only code that starts, finds or stops previews. Everything else (the skill, land, close, QA prompts) calls it.
- Teardown that is deterministic: the scripts that close or land a change stop its preview, not the agent following prose instructions.
- Testable on a private tmux server with a fake `expose.sh`.

**Non-Goals:**
- Docker or compose-aware detection. Those repos declare a recipe.
- Restarting crashed apps automatically, or watching them.
- Several services per preview.
- Putting the URL in the tmux status line.

## Decisions

### `opsx-preview.sh` runs inline in the caller's session
`preview`, `preview stop` and `preview url` are mechanical, so the skill runs `opsx-preview.sh` directly, the same way it runs `merge` and `land`, and doesn't send a prompt to the change window. The agent window keeps working undisturbed, and the user gets the URL right away. Subcommands: `up <change>|--main`, `stop <change>|--all`, `url <change>|--main`, `list`.

### The app window goes through new `opsx-window.sh` subcommands
`opsx-window.sh` gains three subcommands:
- `preview-start <change> --cwd <dir> --script <file>`: creates the window with `tmux new-window -d -P -F '#{window_id}' -c <dir> 'bash <file>'`, so no keys are ever sent. It sets `remain-on-exit on`, the tag `@opsx_preview=<change>`, the title `ox ><change>` (ASCII, so non-UTF-8 clients show it as-is), and turns renaming off.
- `preview-find <change>`: prints the matching window id(s), one per line.
- `preview-kill <change>|--all`: kills the matching windows.

`preview-start` creates the window in the caller's session inside tmux, otherwise in the project session (created if missing), and also tags it `@opsx_preview_project=<main checkout path>`. Preview state is per project, not per session, so `preview-find` and `preview-kill` search every session on the tmux server for windows with that project tag: a preview started from one session can be found and stopped from another, or from outside tmux. `find_window` and `close --all` keep matching only `@opsx_change`, so they never touch a preview window.
- *Alternative: a pane split inside the change window.* Panes are harder to address once the agent window has its own layout. A separate window also lets you jump straight to the logs.

### Process lifetime: its own process group, killed explicitly
The generated launch script (`<state>/<project>/<change>.launch.sh`) runs `setsid bash -c "$cmd"` with `PORT` and `HOST=127.0.0.1` exported. It writes the process group id to the state file and pipes output through `tee -a <log>`. The launch script also exports `OPSX_PREVIEW=<change>` and `OPSX_PREVIEW_PROJECT=<project>`; before signalling a recorded group (stop, stale `up`) the script checks that a process in it still carries both, so a group id reused after a reboot is never signalled. `stop` sends TERM to the group, waits up to 5 seconds, then sends KILL, and only after that kills the window. Every path that drops a record (stop, stale `up`, a failed start) also runs `expose.sh down`, so no route outlives its record. Dev servers such as `pnpm → node → next` spawn grandchildren that survive a closed window. Killing the whole group prevents orphaned servers that keep holding the port.

### State
`${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/preview/<project>/<change>.env` holds `NAME`, `CHECKOUT`, `PORT`, `PGID`, `WINDOW_ID`, `LOG` and `URL`. A second file holds the install hash for each checkout (`<sha of checkout path>.install`). `<change>` is `main` for `--main`. A record counts as "running" only when the window still exists, the process group is alive, and the health check passes. Otherwise `up` cleans it up and starts fresh, as the spec requires. Each `up` and `stop` holds a per-preview lock (`<change>.lock` via flock, or a `<change>.lockd` directory where flock is missing) for its whole run, so a second `up` during a start waits and then reuses the preview instead of starting a duplicate app or tearing the first one down. Files of changes with no record and no worktree, and install hashes of checkouts that are gone, are pruned (by `land`, and on every `up`/`stop`/`list`).

### Recipe resolution
- **Declared:** an awk reader for flat `key: value` lines. It ignores comments and blank lines, removes one layer of matching `'` or `"` quotes, and warns on unknown keys. This follows the minimal-reader approach `opsx-eval.sh` uses for `eval.yaml`, so no YAML library is needed.
- **Detected:** `node -e` reads `package.json` (Node.js is already required) to check for `scripts.dev`. The package manager comes from the lockfile. The command is `<pm> run dev --port $PORT` for pnpm, yarn and bun, and `npm run dev -- --port $PORT` for npm, because npm needs the `--` to forward the flag. The install command is `<pm> install`. The script prints a `detected: <pm> dev script` line so you can see the guess.
- **Install hash:** `sha256` of the install command plus the lockfile's contents. The install runs only when that hash differs from the stored one, and the new hash is stored only after an install succeeds.

### Port choice
The script prefers the port the change's last record used. Otherwise it scans from 3100 to 3999 and takes the first port where a `bash /dev/tcp/127.0.0.1/<p>` connect fails. There's a small race with other processes; if one wins it, the health wait fails or the app reports the port in use, and you run `up` again. The hostname stays the same whatever the port.

### Publishing and the "not configured" case
`expose.sh` is found at `$(dirname "$0")/../expose/expose.sh` (installed skills are siblings), then on PATH, and `$OPSX_EXPOSE_SH` overrides both for tests. Before anything starts, `up` runs `expose.sh list --json` as a preflight. Exit 3, or no script found, gives the "install.sh --expose-domain" error. Exit 4 gives "proxy not running". After the health check passes, `expose.sh up <port> --name <change> --project <project>`, and the script relays the last line as the URL. The OSC 52 and OSC 8 handoff happens inside `expose.sh`.

### Teardown wiring
- `opsx-land.sh` runs `opsx-preview.sh stop <change>` before removing the worktree, ignores its exit code, and in `--dry-run` prints the call instead.
- `opsx-window.sh close <change>` and `close --all` run `opsx-preview.sh stop <change>` and `stop --all` (looked up next to the script) before killing windows. That way `/opsx-run close` and `close-all` tear down the preview even if the agent forgets to.
- `land` without `--no-close` ends up calling `close` again; `stop` is idempotent, so the second call does nothing.

### QA reuse
The `qa` and `apply --validate` window prompts get one more instruction: "run `<skills>/opsx-run/opsx-preview.sh up <change>`; on exit 0 pass its last line to ops-qa as `PREVIEW_URL`; otherwise pass the reason and let ops-qa start the app as before." `agents/opsx-qa.md` changes its "start the app" paragraph to: "If `PREVIEW_URL` is given, test that URL and don't start a server." Codex and Gemini windows do QA themselves and follow the same instruction. A QA preview is left running so you can open the same URL afterwards. It is stopped by `close` or `land`.

## Risks / Trade-offs

- [The detected `--port` flag doesn't fit every dev script, for example one that already hard-codes `-p 3000`] → The health check on the chosen port fails clearly with the log tail. The fix is a one-line `.opsx/preview.yaml`, and the README says so.
- [The dev server ignores `HOST=127.0.0.1` and binds `0.0.0.0`, which makes it reachable at `IP:PORT` without going through Caddy] → The README and recipe docs recommend binding flags (`--hostname 127.0.0.1` for Next.js, `--host 127.0.0.1` for Vite) and a host firewall. The script can't enforce it.
- [Several previews from different worktrees all running `install` at the same time load the VPS] → Installs run once per lockfile change, not on every start.
- [The QA preview is left running after the gate] → This is intended, so you can open what QA saw. close and land clean it up, and `opsx-preview.sh list` shows what's running.
- [`setsid` isn't available by default on macOS] → Fall back to `set -m` job control for a new process group when `setsid` is missing. The test suite covers the Linux path.

## Migration Plan

The change is additive. Repos with no `.opsx/preview.yaml` and no `package.json` dev script get a clear error only when someone asks for a preview. Without expose configured, QA behaves exactly as it does today. To roll back, revert the change. No persistent data needs migrating, and the state files can be deleted.
