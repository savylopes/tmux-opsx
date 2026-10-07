# Proposal

## Why

`/opsx-run` puts each change into its own worktree, but nothing in the harness knows how to run that worktree's app or give it a URL. ops-qa starts its own dev server whenever it needs one, and you can't open or share a change's running app from outside the VPS. With `/expose` (change `add-expose`) in place, the harness can run any change's app on demand and publish it at a stable public URL.

## What Changes

- New `/opsx-run <change> preview` action, plus `preview stop` and `preview url`:
  - It resolves a run recipe from `.opsx/preview.yaml` in the change's worktree: `install` (run once per worktree), `cmd` (started with `$PORT` exported), and `health` (a path polled until it returns 2xx/3xx, or a timeout).
  - When there is no `.opsx/preview.yaml`, it falls back to detection. A `package.json` with a `dev` script is run with the package manager its lockfile implies, with `PORT` injected. For anything else it fails with a clear message asking for `.opsx/preview.yaml`, and it says what it detected when detection is used.
  - It picks a free local port, runs the app in its own tmux window, and waits for the health check. A timeout fails and shows the last log lines. The window is created through `opsx-window.sh`, never raw `send-keys`. It carries its own `@opsx_preview` tag and never `@opsx_change`, so it is never mistaken for the change's agent window.
  - It publishes the app with `expose.sh up <port> --name <change>`, giving `https://<change>--<project>.<domain>`. The hostname stays the same across restarts.
  - Running `preview` while a preview is up reports the existing URL and does not start a second one.
  - `/opsx-run preview` with no change follows the existing rule for an omitted change (ask the user to pick), and also offers the main checkout, which is previewed as `main--<project>`.
  - When expose is not configured, it fails with a message naming `install.sh --expose-domain`.
- `close` and `land` always stop a change's preview: the route is removed and the app process is killed. `close-all` also stops every preview in the project.
- ops-qa uses the change's preview URL when expose is configured, starting the preview if needed, so the gate tests exactly what would be shared. When expose is not configured it falls back to its current behaviour (starting the app locally).
- README: the preview action in the `/opsx-run` usage block, the `.opsx/preview.yaml` format, and the component overview.
- Out of scope: showing the preview URL in the tmux status line.

## Capabilities

### New Capabilities

- `opsx-preview`: running a change's app from its worktree and publishing it through `/expose`, covering recipe resolution (declared, then detected), port choice, the tmux window, the health wait, preview/stop/url, teardown on close and land, and ops-qa using the preview URL with a fallback.

### Modified Capabilities

None. ops-qa has no spec today, so its preview reuse is specified under `opsx-preview`. `opsx-validate-pipeline` keeps its gate order and verdict rules unchanged.

## Impact

- `skills/opsx-run/SKILL.md`: the new `preview` action and teardown in `close` and `land`.
- New `skills/opsx-run/opsx-preview.sh`, which handles recipe resolution, the port, the health wait, and calling `expose.sh`. It calls `opsx-window.sh` for tmux work.
- `skills/opsx-run/opsx-window.sh`: a way to start, find and kill a tagged non-agent window that runs a command.
- `skills/opsx-run/opsx-land.sh` and the close / close-all path: preview teardown.
- `agents/opsx-qa.md`: use the preview URL when expose is configured, otherwise fall back.
- `README.md`: usage, the `.opsx/preview.yaml` reference, and the overview.
- Depends on change `add-expose` (`expose.sh` and the install-time config).
- Target repos can add `.opsx/preview.yaml`. Repos without it still work through detection when they have a `package.json` `dev` script.
