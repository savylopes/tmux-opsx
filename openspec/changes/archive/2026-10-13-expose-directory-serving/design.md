# Design

## Context

See proposal.md for motivation and `specs/` for behaviour. What the implementation builds on, as read in the checkout:

- `expose.sh route_json <label> <port> <public> [shares…]` renders one Caddy route per exposure: host matcher, a subroute with the login-link, share-link, cookie-check and 401 branches, and `{"handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:<port>"}]}` as the final handler. The route's `group` is a hash of its body, which `reconcile` uses to rebuild outdated routes. Records are `routes/<label>.env` with `NAME PROJECT PORT LABEL URL PUBLIC SHARE…`; `read_record` validates `PORT`.
- `cmd_up` checks the port's bind (`bind_state`) and prints `exposed 127.0.0.1:<port> at <url>`; `cmd_list` builds rows from `port_up` and `bind_state`; `cmd_down` matches by label or by port in the project.
- Caddy v2.11.7 runs as the user from `tmux-opsx-caddy.service` (`User=ubuntu` here); its `file_server` handler takes `root`, `hide`, `index_names`, `etag_file_extensions` and answers 404 for a directory without an index unless `browse` is set; it sends `ETag` (mtime and size, second resolution) and `Last-Modified`, redirects `/dir` to `/dir/`, and supports HEAD.
- `explain.sh` (947 lines) spends roughly a third on the server: `write_server`, `start_server`, `server_alive`, `rec_*`, `kill_*`, `cur_socket`, `rec_elsewhere`, `head_ok`, `pick_port`, `set_hosts`, `expose_server`, `ensure_server`; `.reindex` regenerates the library index; `fork.sh page` runs `.reindex` after every page write and nothing else of explain's.
- `tests/test-expose.sh` drives `expose.sh` against `tests/fake-caddy-admin.py`, which stores routes but serves nothing; `tests/test-explain.sh` curls the Python server for CSP, redirect and Host checks and feeds its URL to the Chromium check.

## Goals / Non-Goals

**Goals:**
- One mechanism for "files behind the login": `expose.sh up --dir`, usable by `/explain` today and by anything else later (a built `dist/`, a report folder).
- `explain.sh` keeps only ids, pages, the brief, the library index and three `expose.sh` calls.
- Every safety property the Python server enforced (CSP, no listing, no internal files, no other Host) holds under Caddy, with a real-Caddy test proving it.

**Non-Goals:**
- Uploads, CGI, byte-range tuning, compression, or browse pages.
- A local port fallback when `/expose` is not configured.
- Touching `fork.sh`.

## Decisions

### 1. `--dir` is a variant of `up`, not a new subcommand

`cmd_up` gets a `dir` parameter alongside `port`; `main` parses `--dir <path>`, `--hide <glob>` (repeatable) and `--csp <policy>`. With `--dir`, the positional port is forbidden, `--name` required (a path makes no default name), `bind_state` skipped, and the record written with `DIR=`, zero or more `HIDE=` lines and an optional `CSP=` line instead of `PORT=`. `read_record` accepts a record with a valid port or with an empty port and an absolute `DIR`. Everything keyed by label (`url`, `share`, `down <name>`, reconcile, `key rotate`) works unchanged.

Alternative: `expose.sh serve <dir>`. Rejected: it would duplicate label, record, route, share and reconcile logic, or share it through a second code path for no benefit.

Validation: absolute, `-d`, `-r`, not `/`, not `$HOME` (realpath-compared). The proxy runs as the user on Linux, so readability is the user's; on macOS the user starts Caddy by hand as themselves. The directory is not canonicalised beyond trailing-slash removal, so a symlinked root is the user's choice.

### 2. The route: same subroute, `file_server` instead of `reverse_proxy`

`route_json` takes the handler chain as a parameter built by the caller: for a port, `strip + reverse_proxy` as today; for a directory, `headers + file_server`:

```
{"handler":"headers","response":{"set":{
  "Content-Security-Policy":[<csp>],"Referrer-Policy":["no-referrer"],
  "X-Content-Type-Options":["nosniff"],"X-Frame-Options":["DENY"],"Cache-Control":["no-cache"]}}},
{"handler":"file_server","root":<dir>,"index_names":["index.html"],
 "hide":[".*", "*/.*", <hide…>],"etag_file_extensions":[".sha256"]}
```

Caddy's `hide` treats a pattern without `/` as matching a base name at any depth; `.*` therefore covers dotfiles and dot-directories (`.ids/x` is inside a hidden dir and Caddy refuses it); `*/.*` is kept as belt and braces for older semantics. `*.sha256` is added by the caller, not by default, because a generic directory may legitimately publish checksums. The 401, login-link and share-link branches are untouched, so `expose-access` behaviour follows automatically. The cookie-strip handler is dropped for files (no upstream reads the request).

Alternative: `--csp` as a list of named presets. Rejected: one string is enough; `/explain` passes its own, everything else gets the strict default.

### 3. ETag that changes with content: `.sha256` sidecars written by `.reindex`

Caddy's default ETag is mtime (seconds) and size, so the spec's same-second rewrite scenario needs `etag_file_extensions`. `.reindex` already runs after every page write and already walks every page; it now writes `<n>/index.html.sha256` for each page and `index.html.sha256` for the library, each as `"<sha256>"` (quoted, a valid strong ETag), atomically (temp file and `mv`). The sidecars are hidden by `--hide '*.sha256'`. `fork.sh` is untouched.

Alternative: `fork.sh page` writes the sidecar. Rejected: it would teach `fork.sh` a Caddy detail; `.reindex` is explain's hook for exactly this.

Trade-off: between the page write and `.reindex` finishing (milliseconds), the sidecar is stale and the poll sees the old ETag; the next poll sees the new one. The `Last-Modified` and `Content-Length` comparisons stay in the poll as before.

### 4. `explain.sh` after the cut

- `ensure_exposure`: `find_expose`; if absent or `up` exits 3 → `EXPOSED=0`, `BASE_URL=file://<root>`, hint; else `BASE_URL` from the last line. The `--csp` value is one constant built from `MERMAID_URL` (and the two font hosts after `restyle-explain-page`).
- `open`: lock (id allocation only), `ensure_root` (`.ids`, `.reindex`, library index), `ensure_exposure`, allocate id, placeholder, reindex, fork. The `page <id> <url>` line and the `# local only` line keep their shape; with `file://` the URL is a path.
- `serve`: `ensure_root` + `ensure_exposure`, print the URL. `list`: pages, then `exposed: <url>` or `exposed: no`, from `expose.sh list --json` (name `explain`, this project) when expose exists. `stop`: `expose.sh down explain`; delete leftovers `.server`, `.hosts`, `launch.sh`, `.serve.py` if present.
- Removed: everything under "server" and "tmux" except `require_tmux` for `open` (the fork needs tmux) and `current_session` for `.meta`.

### 5. Tests

- `tests/test-expose.sh` (fake admin): `up --dir` record and route shape (handler `file_server`, `root`, `hide` contains `.*` and the `--hide` patterns, `etag_file_extensions`, headers handler with the default or custom CSP), refusals (relative, missing, `/`, `$HOME`, no `--name`), `list` and `list --json` rows, `down explain`, `share explain`, reconcile restore message naming the directory, directory replacing a port keeps shares.
- `tests/test-expose.sh` (real Caddy, when `caddy` is on PATH or `$OPSX_CADDY_BIN` or `~/.local/share/tmux-opsx/bin/caddy` exists; else SKIP): start `caddy run` with a throwaway JSON config (admin on a scratch unix socket, one HTTP server on a free `127.0.0.1` port, no TLS), point `OPSX_EXPOSE_ADMIN` at it and the server name at `expose`, `up --dir` a scratch tree, then `curl -H Host:` through the owner cookie: 200 on `/1/`, 404 on dotfiles, hidden names, sidecars and a directory without index, 301/308 on `/1?lang=pt` to `/1/?lang=pt`, every header, the sidecar ETag, 401 without a cookie, share cookie accepted. `expose.sh` needs a `SERVER` override for this (`OPSX_EXPOSE_SERVER`, default `expose`) — a one-line, test-only knob.
- `tests/test-explain.sh`: the fake `expose.sh` records `up --dir …` arguments; assertions on the window, port, `.server`, Host 421 and second tmux server go; the sidecar assertions come in; the Chromium check serves `$ROOT` with a test-local `python3 -m http.server` (no CSP, which that check does not test) — the CSP is proven in the Caddy test above.

## Risks / Trade-offs

- [Caddy's `hide` semantics differ between versions] → the real-Caddy test pins the behaviour on the installed binary; `.*` and `*/.*` are both listed.
- [A client with the owner cookie can read any file in the directory that is not hidden] → same as today behind the Python server, but now the user may `--dir` arbitrary folders: `up` refuses `/` and `$HOME`, hides dotfiles always, and the skill text says what gets served.
- [The sidecar is written by `.reindex`, which only runs when `fork.sh page` finds it allowed] → unchanged from today's reindex; a missing sidecar degrades to Caddy's own ETag.
- [Without `/expose`, `/explain` has no local URL any more] → the user has expose configured; the proposal names this as the accepted loss and prints the file path.
- [Two changes edit the CSP requirement and `tests/test-explain.sh`] → apply and archive `restyle-explain-page` first; this change's delta already carries the font hosts.
- [`expose-access` evals assume a port upstream to observe "the app receives no request"] → directory scenarios observe "no file served" instead; ops-eval writes them from the new scenarios.
