# Spec Delta

## Purpose

Lets `/opsx-run` run any change's app from its worktree, or the main checkout, and publish it at a stable public URL through `/expose`, so you can open or share the change and ops-qa tests exactly what you would share.

## ADDED Requirements

### Requirement: Start a preview
`opsx-preview.sh up <change>` SHALL start the app from the worktree of branch `opsx/<change>` on a free local port, wait for it to become healthy, publish it with `expose.sh up <port> --name <change> --project <project>`, print the URL as its last output line, and exit 0. `<project>` SHALL be the main checkout's folder name. When the change has no worktree it SHALL exit non-zero and say to apply the change first.

#### Scenario: Preview started
- **WHEN** change `add-auth` has a worktree with a valid recipe and expose is configured for `dev.example.com` in project `shop`
- **THEN** `opsx-preview.sh up add-auth` exits 0, its last line is `https://add-auth--shop.dev.example.com`, and that hostname routes to the port the app listens on

#### Scenario: No worktree
- **WHEN** `opsx-preview.sh up add-auth` runs and no worktree is checked out on `opsx/add-auth`
- **THEN** it exits non-zero, says to apply the change first, and starts nothing

### Requirement: Preview the main checkout
`opsx-preview.sh up --main` SHALL preview the main checkout, published under the name `main`. When `/opsx-run preview` is given without a change, the skill SHALL ask the user to pick one of the active changes or the main checkout, and SHALL NOT guess.

#### Scenario: Main preview
- **WHEN** `opsx-preview.sh up --main` runs in project `shop` with a valid recipe
- **THEN** its last line is `https://main--shop.<domain>`

### Requirement: Declared recipe
When `.opsx/preview.yaml` exists in the checkout being previewed, it SHALL be the recipe. It SHALL be read as flat `key: value` lines with the keys `cmd` (required), `install`, `health` (default `/`) and `timeout` (seconds, default 120). `cmd` and `install` SHALL run through `bash -c` in the checkout with `PORT` and `HOST=127.0.0.1` exported. An unknown key SHALL print a warning. A missing `cmd` SHALL fail before anything starts.

#### Scenario: Recipe used
- **WHEN** `.opsx/preview.yaml` contains `cmd: python3 -m http.server $PORT --bind 127.0.0.1`
- **THEN** the preview runs that command with `PORT` set to the chosen port and becomes healthy

#### Scenario: Missing cmd
- **WHEN** `.opsx/preview.yaml` has no `cmd` key
- **THEN** `opsx-preview.sh up` exits non-zero naming `cmd`, and no window or route is created

### Requirement: Detected recipe
Without `.opsx/preview.yaml`, a `package.json` with a `scripts.dev` entry SHALL be run with the package manager its lockfile implies (`pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `bun.lock` or `bun.lockb` → bun, otherwise npm). The dev script SHALL be passed `--port $PORT`, with `PORT` and `HOST=127.0.0.1` exported, and its install command SHALL be the package manager's install. The script SHALL print which recipe it detected. Anything else SHALL exit non-zero asking for `.opsx/preview.yaml`.

#### Scenario: pnpm project detected
- **WHEN** the checkout has `package.json` with a `dev` script and `pnpm-lock.yaml`, but no `.opsx/preview.yaml`
- **THEN** the output names the detected recipe, and the app is started with `pnpm run dev --port <port>`

#### Scenario: Nothing to detect
- **WHEN** the checkout has neither `.opsx/preview.yaml` nor a `package.json` with a `dev` script
- **THEN** `opsx-preview.sh up` exits non-zero with a message asking for `.opsx/preview.yaml`, and nothing starts

### Requirement: Install step
The recipe's install command SHALL run in the checkout before the first start, and again only when the install command or the checkout's lockfile has changed since the last successful install. A failed install SHALL fail the preview with the install's exit code and output tail, and SHALL start nothing.

#### Scenario: Install not repeated
- **WHEN** a preview is started, stopped and started again with an unchanged lockfile and recipe
- **THEN** the install command runs only once

#### Scenario: Install repeated after lockfile change
- **WHEN** the lockfile changes between two starts
- **THEN** the install command runs again before the second start

### Requirement: Preview window
The app SHALL run in its own tmux window in the project's session, created without typing into any pane. The window SHALL be tagged `@opsx_preview=<change>` and SHALL NOT carry `@opsx_change`, and its output SHALL also go to a log file. When the app exits, the window SHALL stay open showing its last output.

#### Scenario: Window tagged separately
- **WHEN** a preview for `add-auth` is running alongside its agent window
- **THEN** exactly one window has `@opsx_preview` set to `add-auth`, that window has no `@opsx_change`, and `opsx-window.sh` lookups for `add-auth` still find the agent window

### Requirement: Health wait
After starting, the script SHALL poll `http://127.0.0.1:<port><health>` until it returns a 2xx or 3xx status. If the timeout passes or the app process exits first, it SHALL fail with the last log lines, stop the app, and SHALL NOT publish a route.

#### Scenario: App never healthy
- **WHEN** the recipe's `cmd` exits immediately with an error
- **THEN** `opsx-preview.sh up` exits non-zero, prints the app's last output lines, and `expose.sh list` has no entry for the change

### Requirement: Already running
When the change's preview window is alive and its health check passes, `up` SHALL print the existing URL and exit 0 without starting a second instance. When a preview record exists but its window or process is gone, `up` SHALL clean it up and start fresh.

#### Scenario: Second up
- **WHEN** `opsx-preview.sh up add-auth` runs twice in a row
- **THEN** both runs print the same URL, and only one `@opsx_preview=add-auth` window exists

### Requirement: Stop and URL
`opsx-preview.sh stop <change>` SHALL remove the change's exposure, kill its preview window, and delete its record. It SHALL exit 0 even when there is no preview. `stop --all` SHALL do this for every preview in the project. `url <change>` SHALL reprint and copy the URL of a running preview, and SHALL exit non-zero when none is running.

#### Scenario: Stopped
- **WHEN** `add-auth` has a running preview and `opsx-preview.sh stop add-auth` runs
- **THEN** its window is gone, `expose.sh list` has no `add-auth` entry, and a second `stop add-auth` also exits 0

### Requirement: Teardown with the change
`/opsx-run <change> close` and `opsx-land.sh` SHALL stop the change's preview, and `/opsx-run close-all` SHALL stop every preview in the project. A failed or missing preview SHALL NOT make close, close-all or land fail.

#### Scenario: Land stops preview
- **WHEN** `add-auth` has a running preview and `opsx-land.sh add-auth` completes
- **THEN** no `@opsx_preview=add-auth` window remains and `expose.sh list` has no `add-auth` entry

#### Scenario: Land without preview
- **WHEN** `add-auth` has no preview and `opsx-land.sh add-auth` runs
- **THEN** landing's result is the same as it was before this change

### Requirement: Not configured
When expose is not configured or not installed, `opsx-preview.sh up` SHALL exit non-zero with a message naming `install.sh --expose-domain`, before starting anything.

#### Scenario: No expose
- **WHEN** no expose config exists and `opsx-preview.sh up add-auth` runs
- **THEN** it exits non-zero with `install.sh --expose-domain` in the message, and no preview window is created

### Requirement: ops-qa uses the preview
Before dispatching ops-qa (in `/opsx-run <change> qa` and in the `apply --validate` QA step), the dispatcher SHALL run `opsx-preview.sh up <change>` and, on success, pass the printed URL to ops-qa as the app URL. ops-qa SHALL test a given preview URL and SHALL NOT start its own server. When the script exits non-zero (expose not configured, or the preview failed), ops-qa SHALL keep its current behaviour, with the reason stated in its inputs.

#### Scenario: QA prompts start the preview
- **WHEN** the installed `opsx-run/SKILL.md` and ops-qa definition are read
- **THEN** both the `qa` and the `apply --validate` dispatcher prompts tell the window to run `opsx-preview.sh up <change>` before ops-qa and to pass its URL, and the ops-qa definition says to use a given preview URL rather than starting the app

#### Scenario: QA fallback
- **WHEN** expose is not configured and `/opsx-run add-auth qa` runs
- **THEN** ops-qa is dispatched without a preview URL and starts the app as before
