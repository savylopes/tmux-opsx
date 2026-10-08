# Proposal

## Why

The harness runs on a VPS, and the apps it builds can only be reached on `127.0.0.1` there. Sharing a running app, or opening it from a phone or laptop, means hand-rolling SSH tunnels or opening ports. There is no single command that turns a local port into a public HTTPS URL. This change adds that command as a standalone layer. The `/opsx-run` preview (change `add-opsx-preview`) and any ad-hoc use build on it.

## What Changes

- New `/expose` skill with `skills/expose/expose.sh`, installed into the skill dirs of all five CLIs, like `/fork`:
  - `up <port> [--name <n>]`: publishes `127.0.0.1:<port>` at `https://<name>--<project>.<domain>`, where `<project>` is the repo folder name. `<name>` defaults to the port, so `/expose 3000` gives `3000--<project>.<domain>`.
  - `down <name|port>`, `list` (NAME, PORT, URL, UP? from a port probe), and `url <name>` (reprints the URL and copies it again).
  - Hostname labels are lowercased and limited to `[a-z0-9-]`. A label longer than 63 characters has its name part truncated and a short stable hash appended, so the same input always gives the same hostname.
  - On print, the URL goes to the clipboard of the user's local terminal via OSC 52 (through tmux when available, so it also works when an agent runs the script without a terminal). On a terminal it is shown as a clickable OSC 8 hyperlink. Nothing tries to open a browser.
  - Routes are added and removed live through Caddy's admin API, which listens on a unix socket only the user can reach (not a TCP port other local users could call). No config file is rewritten, and no reload is needed.
  - Routes are recorded in a state file under `~/.local/state/tmux-opsx/expose/` and put back if Caddy has restarted, so URLs do not silently disappear.
  - Exposed URLs are public with no authentication. The skill says so when it prints a URL.
- `install.sh --expose-domain <domain>`. Without this flag, nothing expose-related is installed. With it:
  - The Cloudflare API token is read from `$CLOUDFLARE_API_TOKEN`, or from a hidden prompt when that variable is unset. It is never taken as a CLI argument. A rerun without a token keeps the existing config.
  - The domain and token are stored in a user config file with mode 600, outside the repo.
  - install.sh fetches a Caddy binary built with the `caddy-dns/cloudflare` plugin and writes a base config: a wildcard site `*.<domain>` on `:443` only, with one certificate via ACME DNS-01, and the admin API on a user-only unix socket.
  - The token is verified against the Cloudflare API. The script fails fast with a clear message if it is invalid.
  - install.sh checks that `*.<domain>` resolves to this host and only warns if it does not. The user creates the wildcard record themselves, DNS-only (grey cloud). install.sh never changes DNS.
  - install.sh does not use sudo. On Linux it writes a systemd unit that lets Caddy bind `:443` and prints the one privileged command to enable it. When install.sh already runs as root (the VPS login case), it enables the unit itself. On macOS it prints how to start Caddy; this is a documented gap, with no service setup.
- When expose is not configured, `expose.sh` fails with a message naming `install.sh --expose-domain`.
- README: a new component in the overview tree, an Expose section, and a tmux.conf hint for OSC 8 (`terminal-features ',*:hyperlinks'`), documented rather than applied.
- Out of scope: basic auth or any other access control, `--uninstall` support for expose, and creating DNS records.

## Capabilities

### New Capabilities

- `port-expose`: the `/expose` skill and `expose.sh`, covering publishing a local port at a hostname under the wildcard domain, the hostname rules, list/down/url, putting routes back after a Caddy restart, OSC 52/OSC 8 output, and failure when not configured.
- `expose-install`: the `install.sh --expose-domain` opt-in, covering token intake and storage, fetching and configuring Caddy, token and DNS checks, the printed privileged step, and installing the skill into all five CLIs.

### Modified Capabilities

None.

## Impact

- New: `skills/expose/SKILL.md`, `skills/expose/expose.sh`.
- `install.sh`: the `--expose-domain` flag, token intake, Caddy download and base config, checks, and skill install for each CLI.
- `README.md`: component overview, Expose section, tmux OSC 8 hint.
- New runtime dependencies, only when opted in: a Caddy binary with `caddy-dns/cloudflare`, plus a Cloudflare API token scoped to `Zone:DNS:Edit` on that zone.
- Host: port 443 needs to be reachable, which may mean opening it in the VPS provider's firewall. Port 80 is not needed, because DNS-01 does not use it. The user adds `*.<domain>` as a DNS-only record pointing at the host.
- Security surface: any local port can be made public with no auth, and the Cloudflare token is stored on disk with mode 600.
