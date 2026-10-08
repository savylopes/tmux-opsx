# Design

## Context

See proposal.md for the motivation. The specs (`port-expose`, `expose-install`) define the behaviour. The constraints that shape this design:

- The target host is a VPS with a public IPv4 address, no host firewall, and only `:22` listening. `docker`, `python3`, `jq` and `curl` are present. No reverse proxy or tunnel tool is installed.
- The harness is all bash, kept shellcheck clean. install.sh is idempotent, keeps `.bak` copies, and installs each skill into six folders (`install_fork_skill` is the model to follow).
- Agents call skill scripts through a Bash tool, which usually has no terminal and sometimes no `$TMUX`. `opsx-window.sh` already has `recover_tmux_env` for that case.
- tmux 3.4 with `set-clipboard on` is in use. The `terminal-features` setting has `clipboard` but not `hyperlinks`.
- `add-opsx-preview` will call `expose.sh` in the background, so its output and exit codes are an interface, not only for humans.

## Goals / Non-Goals

**Goals:**
- One script, `expose.sh`, that is the only code talking to Caddy, so later layers (preview, ops-qa) never touch the proxy.
- No root at runtime: exposing and removing a port never needs sudo.
- Testable offline: every Caddy and Cloudflare dependency can be swapped out in tests.

**Non-Goals:**
- Authentication, IP allow-lists, or rate limiting on exposed URLs.
- Managing DNS records, the Cloudflare proxy (orange cloud) mode, or the VPS provider's firewall.
- Exposing anything other than HTTP on `127.0.0.1` (no raw TCP or UDP, no remote hosts).
- An `--uninstall` path for expose.

## Decisions

### Caddy, driven live through its admin API
Routes are added and removed with JSON calls to Caddy's admin API, and the config file is never rewritten. Each route gets an `@id` of `expose-<label>`, so `GET/DELETE /id/expose-<label>` addresses it directly, and `POST /config/apps/http/servers/expose/routes` appends one.
- *Alternative: rewrite a Caddyfile and reload.* That means a file to keep in sync, reload races between parallel `up` calls, and orphan entries when a script dies halfway.
- *Alternative: nginx + certbot.* It has no live API and no built-in ACME client. This was discussed and rejected during exploration.

### Admin API on a unix socket, not `localhost:2019`
The base config sets `admin.listen` to `unix/<state>/caddy-admin.sock`, inside a directory with mode 700. A TCP admin port on localhost would let any local user or container add routes or rewrite the TLS config. `expose.sh` calls it with `curl --unix-socket`. `$OPSX_EXPOSE_ADMIN` overrides the socket path, and tests point it at a fake admin server.

### One wildcard certificate via DNS-01, `:443` only
The base config declares `*.<domain>` under `tls.automation` with the `cloudflare` DNS provider, reading the token from `{env.CLOUDFLARE_API_TOKEN}`, which the systemd unit loads from `expose.env` with `EnvironmentFile=`. One HTTP server, `expose`, listens on `:443`. Automatic HTTP→HTTPS redirects are turned off, so nothing binds `:80`. DNS-01 needs no inbound port, and serving fewer ports means less exposure.
- *Alternative: on-demand TLS over HTTP-01.* The user rejected it (option 1a). It would also need `:80` and an `ask` endpoint.

### Getting Caddy
install.sh downloads from Caddy's official build endpoint (`https://caddyserver.com/api/download?os=<os>&arch=<arch>&p=github.com/caddy-dns/cloudflare`) into `~/.local/share/tmux-opsx/bin/caddy`. It then checks that `caddy list-modules` includes `dns.providers.cloudflare`, and on failure it removes the download and stops. When the binary already lists the module it is reused. `$OPSX_CADDY_BIN` points install.sh at an existing binary and skips the download. Tests use that with a fake `caddy`.
- *Alternative: build with `xcaddy`.* That needs a Go toolchain on the VPS, which is a heavy prerequisite for one binary.
- *Alternative: the Docker image.* Docker is present, but a container adds network and socket plumbing, and it would put a Docker requirement on machines that don't have Docker.

### Running Caddy: a systemd system unit run as the user
The unit (`tmux-opsx-caddy.service`) is written to `~/.config/tmux-opsx/`. It has `User=<installing user>`, `AmbientCapabilities=CAP_NET_BIND_SERVICE`, `EnvironmentFile=<expose.env>`, and `ExecStart=<caddy> run --config <base.json>` plus `ExecStartPost=-<skills>/expose/expose.sh list --json` (puts the recorded routes back right after start). A non-root install prints `sudo install -m 644 <unit> /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now tmux-opsx-caddy`. A root install runs those steps itself. That fits the existing "root is the login user" support (commit 12ac0fe) and the no-sudo rule.
- *Alternative: a systemd `--user` unit with `setcap`.* `setcap` needs root anyway, and user units stop when you log out unless lingering is on, which needs root too.
- *macOS:* binding ports below 1024 needs no root there, but service setup is left out. install.sh prints `caddy run --config …` and the README notes the gap.

### Restart safety: reconciliation from state, no `--resume`
Caddy is started from the base config only, without `--resume`. With `--resume`, Caddy would prefer its autosave over the base config, so a rerun of `install.sh` with a new domain or token would not take effect on the next start. Instead `expose.sh` keeps its own state, one file per exposure, `<state>/routes/<label>.env` with `NAME`, `PROJECT`, `PORT`, `LABEL` and `URL`, and treats it as the source of truth. On every subcommand it lists the route ids in Caddy and re-adds any recorded label that is missing; the unit's `ExecStartPost` runs `expose.sh list` so this also happens right after every start. The state files are also what `list` reads, so no data has to be parsed back out of Caddy's JSON. Calls are serialised with `flock` on the state dir where available, and a refused duplicate route id counts as success when the route is present afterwards.

A rerun that changes `caddy.json` loads it into a running proxy through `POST /load` on the admin socket and then runs `expose.sh list` to put the routes back; a domain change also rewrites `URL=` in every state file. A changed token or unit needs a restart: done as root, printed (`sudo … systemctl restart tmux-opsx-caddy`) otherwise.

### Hostname rules
The label is `<name>--<project>`. Each part is normalised separately (lowercase, every run of characters outside `[a-z0-9]` becomes one `-`, then leading and trailing `-` are trimmed), so `--` can only be the separator. When the label is over 63 characters, the name part is cut so that `<cut>-<h6>--<project>` fits, where `h6` is the first 6 hex characters of `sha256(<full label>)`. Only if the project alone leaves no room for even a hash-only name part (a project over 54 characters) is the project part cut too, to 40 characters with its own hash. The project comes from `basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"`, so every worktree of a repo maps to its main folder name. Outside git it's `basename "$PWD"`. `--project` overrides both, and `add-opsx-preview` uses it.

### Clipboard and link handoff
- **Copy:** when tmux is reachable (`$TMUX`, or recovered the way `opsx-window.sh` does it), the script runs `tmux set-buffer -w -- "$url"`. With `set-clipboard on`, tmux sends OSC 52 to every attached client, which works even with no terminal attached, the usual case for an agent's Bash tool. Otherwise, if `/dev/tty` can be written, it writes the raw OSC 52 sequence there. Otherwise nothing is copied.
- **Link:** when stdout is a terminal, the script prints `ESC]8;;URL ESC\ URL ESC]8;; ESC\`. Otherwise it prints the plain URL. The URL is always the last line, so callers can use `tail -n1`.
- install.sh doesn't touch the user's tmux.conf. The README documents `set -as terminal-features ',*:hyperlinks'` for OSC 8 through tmux.

### Token handling
`expose.env` is written through a temporary file created in the same mode-700 directory with `umask 077`, then `mv`'d into place, and no `.bak` is ever made of it. The verify call passes the `Authorization` header to curl on stdin (`curl -H @-`), so the token never shows up in `ps`. The DNS check resolves `probe-<random>.<domain>` with `getent ahosts` and compares the result with `hostname -I` (on Linux) or `ifconfig` addresses. Any mismatch is only a warning, because a NATed host can legitimately differ.

### Interface for callers
`expose.sh` returns exit 0 for success and for an idempotent no-op, 2 for usage or validation errors, 3 when expose isn't configured, 4 when the proxy is unreachable, and 1 for anything else. `add-opsx-preview` uses exit 3 to fall back cleanly. `list --json` is the machine-readable view.

## Risks / Trade-offs

- [Dev servers often bind `0.0.0.0`, so an app might be reachable directly at `IP:PORT` and bypass Caddy] → Documented in the README and the skill: bind apps to `127.0.0.1`, or turn on a host firewall that allows only 22 and 443. expose.sh can't enforce how apps bind.
- [Public URLs with no auth can expose debug pages, seeded admins, or real data] → The user accepted this for now. `up` warns every time, and the wildcard cert keeps individual hostnames out of Certificate Transparency logs.
- [The Caddy download endpoint is a moving target (latest Caddy with the plugin), so builds aren't reproducible] → The module check after download catches a broken build, and a rerun reuses the working binary. Pinning a version can come later.
- [The Cloudflare token stored on disk can edit DNS for the zone] → Mode 600 in a 700 directory, never on a command line, never printed. The README tells you to scope the token to `Zone:DNS:Edit` for that one zone.
- [Parallel `up` calls racing on the admin API] → Each route has a unique `@id`. Adding one deletes any old route with that id first, and Caddy applies config changes atomically. State files are written with `mv`.
- [The DNS check could give a false warning behind NAT] → It only warns.

## Migration Plan

This is a new opt-in component, so nothing existing changes. Rollback is manual for now, because `--uninstall` is out of scope: stop and disable `tmux-opsx-caddy`, then delete the unit, `~/.config/tmux-opsx/expose.env`, the six `expose/` skill folders and `~/.local/share/tmux-opsx/bin/caddy`. The README lists these steps.
