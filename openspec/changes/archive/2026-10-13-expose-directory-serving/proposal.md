# Proposal

> Captured from the `/opsx:explore` session of 2026-10-13, companion of `restyle-explain-page` (apply and archive that one first: both touch the explain page's Content-Security-Policy requirement and `tests/test-explain.sh`).

## Why

`/explain` serves its pages through a generated Python server in a tmux window, exposed as a port through the Caddy proxy. That layer exists only to put a directory of static files behind the expose login, and it costs a port range, a server record, a tmux window that `close-all` must know to skip, a Host allowlist against DNS rebinding, start, reuse, stale and stop logic, and a second-tmux-server dance. The Caddy proxy already runs as the user, so it can serve that directory itself, behind the same login and share links, with ETag and Last-Modified for free. Removing the middle layer is the simplification the user asked for ("an html file server protected via the Caddy magic link").

## What Changes

- **`/expose` learns directories.** `expose.sh up --dir <abs dir> [--name <n>] [--project <p>] [--public] [--hide <glob>]… [--csp <policy>]` publishes a directory at `https://<name>--<project>.<domain>` with Caddy's file server, behind the same owner cookie, share links, `url`, `share`, `down`, `list` and reconcile as a port exposure. Dotfiles are never served, `--hide` adds more patterns, there is no directory listing, and every response carries a strict default Content-Security-Policy (overridable with `--csp`), `Referrer-Policy: no-referrer`, `nosniff`, `X-Frame-Options: DENY` and `Cache-Control: no-cache`. A `.sha256` sidecar beside a file, when present, is used as its ETag.
- **`/explain` drops its server.** `explain.sh` no longer writes `.serve.py`, `launch.sh`, `.server` or `.hosts`, picks no port, opens no tmux window and checks no Host. It runs `expose.sh up --dir <root> --name explain --hide manifest.tsv --hide '*.sha256' --csp <the explain policy>` on every `open` and `serve`, and `expose.sh down explain` on `stop`. `.reindex` also writes the `.sha256` sidecars so the reload poll sees same-second rewrites. Without `/expose` configured, `open` prints the page's file path with the install hint and the fork still opens; nothing is served.
- **BREAKING** for `/explain`: `http://127.0.0.1:<port>/` local URLs, the `ox >explain` window and the `@opsx_explain` tag are gone; `/explain list` reports the exposure instead of a server; the second-tmux-server behaviour no longer exists.
- Not in scope: serving anything beyond static files (no CGI, no uploads), a port fallback when `/expose` is not configured, self-hosted fonts (now cheap: a later change can drop them into the root).

## Capabilities

### New Capabilities

None.

### Modified Capabilities
- `port-expose`: new requirements "Publish a directory", "Directory responses", "Directory response headers" and "Directory ETag sidecar"; "List exposures" shows directory rows; "Skill entry point" documents `--dir`, `--hide` and `--csp`.
- `expose-access`: new requirement "Directory exposures use the same access rules" (login, share links, public opt-out apply to `--dir` as to ports).
- `explain-page`: "Explain server and exposure per project" becomes a directory exposure per project; "Page server sends a Content-Security-Policy" becomes "Page responses carry a Content-Security-Policy" sent by the proxy; "Page server serves only pages" becomes "Only pages are served"; "Share, list and stop" without a window; "Page server checks the Host" is removed (the proxy matches the host, there is no loopback port).

## Impact

- `skills/expose/expose.sh`: `--dir`, `--hide`, `--csp` on `up`; record fields `DIR`, `HIDE`, `CSP`; `route_json` with a `file_server` branch (root, hide, index, `etag_file_extensions`) and a `headers` handler; `list`/`list --json` directory rows; `down`/reconcile messages. `skills/expose/SKILL.md`: the new options.
- `skills/explain/explain.sh`: about 300 lines removed (server, window, port, Host, lock-around-server, second tmux server); `ensure_exposure` replaces `ensure_server`; `.reindex` writes sidecars; `list`, `stop`, `serve` simplified. `skills/explain/SKILL.md` and `README.md`: no server, no window, no local URL.
- `tests/test-expose.sh`: directory cases against the fake admin, plus a serving test against the real `caddy` binary when one is found (hide, no listing, headers, ETag sidecar, canonical redirect with query). `tests/test-explain.sh`: the fake `expose.sh` logs `up --dir …`; server, window, Host and port assertions removed; the Chromium check serves the page with a test-local static server.
- `skills/opsx-run`: nothing to change (`close-all` already ignores `@opsx_explain`; the tag simply no longer appears). Pages already written keep working under the new exposure.
