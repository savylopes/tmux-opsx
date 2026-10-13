# Spec Delta

## MODIFIED Requirements

### Requirement: Explain server and exposure per project
The explain skill SHALL publish `${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/explain/<project>/` once per project through `expose.sh up --dir <root> --name explain --hide manifest.tsv --hide '*.sha256' --csp <policy>`, on every `open` and `serve`, so a lost route is restored. `<project>` SHALL be the main checkout's folder name. The skill SHALL start no server of its own and open no tmux window.

#### Scenario: First use starts the server
- **WHEN** `/explain "x"` runs with nothing exposed for the project
- **THEN** the fake `expose.sh` was called with `up --dir <root> --name explain`, `--hide manifest.tsv`, `--hide *.sha256` and `--csp`, no tmux window tagged `@opsx_explain` exists, and nothing listens on a port

#### Scenario: Reuse
- **WHEN** `/explain "y"` runs after `/explain "x"`
- **THEN** `expose.sh up` was called again with the same directory and name, and the new page is served under the same host

#### Scenario: Expose not configured
- **WHEN** `expose.sh up` fails with its not-configured message
- **THEN** the skill prints the page's file path, names `install.sh --expose-domain`, and the fork still opens

#### Scenario: Second tmux server
- **WHEN** `/explain serve` runs from a second tmux server
- **THEN** it behaves exactly as from the first: `expose.sh up --dir` is called and the URL printed; no tmux state is involved

#### Scenario: Same project from a worktree
- **WHEN** `/explain "x"` runs inside a change worktree of project `shop`
- **THEN** the pages root and the exposure name are those of `shop`, not of the worktree folder

### Requirement: Page server sends a Content-Security-Policy
Pages are written by a fork whose context may hold untrusted text, so the proxy, not the page, SHALL confine them. The explain skill SHALL publish its root with a `--csp` that allows scripts only inline and from the one pinned Mermaid file, styles from `'self'`, inline and `https://fonts.googleapis.com`, fonts from `'self'`, `data:` and `https://fonts.gstatic.com`, with `connect-src 'self'`, `img-src 'self' data:`, `form-action 'none'`, `frame-ancestors 'none'` and no other external source; the proxy adds `Referrer-Policy: no-referrer` and `X-Content-Type-Options: nosniff`.

#### Scenario: CSP sent by the server
- **WHEN** `/explain "x"` runs
- **THEN** the `--csp` value passed to `expose.sh up` has `default-src 'none'`, `connect-src 'self'`, `img-src 'self' data:`, `form-action 'none'`, a `script-src` naming only `'unsafe-inline'` and the pinned Mermaid URL, a `style-src` naming `'self'`, `'unsafe-inline'` and `https://fonts.googleapis.com`, and a `font-src` naming `'self'`, `data:` and `https://fonts.gstatic.com`

### Requirement: Page server serves only pages
The explain root SHALL be published so that only pages and the library index are reachable: `manifest.tsv` and `.sha256` sidecars hidden through `--hide`, dotfiles (`.ids/`, `.lock`, `.reindex`, `.meta`) never served by the proxy, no directory listing, and `/<id>` redirected to `/<id>/` keeping its query. The pages root SHALL be private to the user (directory 700, files 600).

#### Scenario: Internal files not served
- **WHEN** `/.reindex`, `/1/.meta`, `/1/manifest.tsv`, `/1/index.html.sha256` or `/.ids/` is requested through the exposure
- **THEN** each answers 404

#### Scenario: Bare page path keeps the query
- **WHEN** `/1?lang=pt` is requested
- **THEN** the proxy redirects to `/1/?lang=pt`

### Requirement: Share, list and stop
`/explain share [--for <recipient>] [--ttl <dur>] [--list] [--revoke <r|id|all>]` SHALL call `expose.sh share explain …` and print the link as its last line; the link opens the whole page library of the project, which the skill text and the brief SHALL say. `/explain list` SHALL print the project's pages (id, title, created, fork id) and whether the root is exposed, with its URL. `/explain stop` SHALL run `expose.sh down explain` and keep every page; it SHALL exit 0 when nothing is exposed.

#### Scenario: Share link
- **WHEN** `/explain share --for acme --ttl 3d` runs
- **THEN** the fake `expose.sh` was called with `share explain --for acme --ttl 3d` and the last output line is the link

#### Scenario: Stop
- **WHEN** `/explain stop` runs with the root exposed
- **THEN** the fake `expose.sh` was called with `down explain`, and the pages directory is unchanged

### Requirement: Reload poll
The reload poll SHALL also compare an `ETag` that changes with the file's content, so a rewrite within the same second and with the same length is seen: `.reindex` SHALL write `index.html.sha256` beside the library index and beside every page after each page write, and the exposure SHALL use it as the ETag. Only a direct 2xx answer SHALL count: an error status (421, 5xx) or a redirect SHALL never reload the page.

#### Scenario: Same-second rewrite
- **WHEN** a page is rewritten twice within one second with content of the same length
- **THEN** `<root>/<id>/index.html.sha256` differs between the two versions and so does the served `ETag`

#### Scenario: Error answers do not reload
- **WHEN** a poll of an open page gets a 421, a 5xx or a redirect
- **THEN** the page does not reload and keeps polling

## REMOVED Requirements

### Requirement: Page server checks the Host
**Reason**: There is no loopback server any more; the proxy matches the exposure's hostname itself and nothing else can reach the files.
**Migration**: None. The `.hosts` file is no longer written; `explain.sh` deletes a stale one.
