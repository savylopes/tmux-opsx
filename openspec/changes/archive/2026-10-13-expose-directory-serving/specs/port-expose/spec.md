# Spec Delta

## ADDED Requirements

### Requirement: Publish a directory
`expose.sh up --dir <dir> [--name <n>] [--project <p>] [--public]` SHALL publish the files under `<dir>` at `https://<label>.<domain>`, printing the URL as the last line and exiting 0. `<dir>` MUST be an absolute path to an existing directory other than `/` or the user's home; anything else SHALL be refused with exit 2 and no change. `--name` SHALL be required with `--dir`. Re-publishing a name with another directory SHALL replace the route and keep its share links.

#### Scenario: Directory published
- **WHEN** expose is configured for `dev.example.com` and `expose.sh up --dir /home/u/pages --name explain --project shop` runs
- **THEN** it exits 0, its last line is `https://explain--shop.dev.example.com`, the proxy route for that hostname serves files from `/home/u/pages`, and the state record holds `DIR=/home/u/pages` and no port

#### Scenario: Relative or missing directory refused
- **WHEN** `expose.sh up --dir pages --name x` or `expose.sh up --dir /nonexistent --name x` runs
- **THEN** it exits 2, names the problem, and no route or state record is created

#### Scenario: Root and home refused
- **WHEN** `expose.sh up --dir / --name x` or `expose.sh up --dir "$HOME" --name x` runs
- **THEN** it exits 2 and no route or state record is created

#### Scenario: Name required
- **WHEN** `expose.sh up --dir /home/u/pages` runs without `--name`
- **THEN** it exits 2 saying `--dir` needs `--name`

#### Scenario: Directory replaces a port
- **WHEN** `web` is exposed on port 3000 with a share link for `acme`, and `expose.sh up --dir /home/u/site --name web` runs
- **THEN** one route for `web` exists, it serves `/home/u/site`, and `acme`'s link is still accepted

### Requirement: Directory responses
A directory exposure SHALL serve regular files only: no directory listing (a directory without `index.html` SHALL answer 404), never a file or directory whose name starts with `.`, and never a file matching a `--hide <glob>` pattern (repeatable; a pattern without `/` matches a name at any depth). A request for a directory without a trailing `/` SHALL redirect to the path with `/`, keeping the query.

#### Scenario: Hidden names
- **WHEN** `/home/u/pages` holds `.secret`, `1/.meta`, `1/manifest.tsv` and `1/index.html`, published with `--hide manifest.tsv`
- **THEN** `/1/` and `/1/index.html` answer 200, and `/.secret`, `/1/.meta` and `/1/manifest.tsv` answer 404

#### Scenario: No listing
- **WHEN** `/home/u/pages/2/` exists without `index.html` and `/2/` is requested
- **THEN** the answer is 404 and the body lists no file names

#### Scenario: Canonical directory path
- **WHEN** `/1?lang=pt` is requested
- **THEN** the answer redirects to `/1/?lang=pt`

### Requirement: Directory response headers
Every response of a directory exposure SHALL carry `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Cache-Control: no-cache` and a `Content-Security-Policy`: the value given with `--csp`, else `default-src 'none'; script-src 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'`.

#### Scenario: Default headers
- **WHEN** a file is fetched from a directory exposure published without `--csp`
- **THEN** the response carries the default `Content-Security-Policy` above, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` and `Cache-Control: no-cache`

#### Scenario: Custom policy
- **WHEN** a directory is published with `--csp "default-src 'self'"`
- **THEN** every response carries exactly `Content-Security-Policy: default-src 'self'` and the other headers unchanged

### Requirement: Directory ETag sidecar
A file served from a directory exposure SHALL carry `Last-Modified` and an `ETag`. When a regular file `<file>.sha256` exists beside `<file>`, its content SHALL be the `ETag`; sidecars SHALL never be served themselves.

#### Scenario: Sidecar used
- **WHEN** `/1/index.html` is rewritten twice within one second with content of the same length and `/1/index.html.sha256` holds the hash of each version in turn
- **THEN** the served `ETag` differs between the two versions and `/1/index.html.sha256` answers 404

#### Scenario: No sidecar
- **WHEN** a file has no `.sha256` beside it
- **THEN** it is served with an `ETag` and `Last-Modified` derived from the file

## MODIFIED Requirements

### Requirement: List exposures
`expose.sh list` SHALL print one row per exposure with the columns NAME, PROJECT, PORT, URL, UP, BIND and ACCESS. For a port exposure, UP SHALL be `yes` when something accepts TCP connections on `127.0.0.1:<port>`, otherwise `no`; BIND SHALL be `loopback`, `PUBLIC` when any listener on the port is not loopback, or `-` when nothing listens or it cannot be checked. For a directory exposure, PORT SHALL be `-`, UP SHALL be `yes` when the directory exists and is readable, otherwise `no`, and BIND SHALL be `dir`. ACCESS SHALL be `login` or `public`. `list --json` SHALL print the same data as a JSON array of objects with the keys `name`, `project`, `port` (integer, or `null` for a directory), `dir` (string, or `null` for a port), `url`, `up`, `bind` (`"loopback"`, `"public"`, `"dir"` or `null`) and `public` (boolean).

#### Scenario: Port with nothing listening
- **WHEN** port 3999 is exposed as `idle` and no process listens on it
- **THEN** `list` shows the `idle` row with UP `no` and BIND `-`, and `list --json` has an object with `"name":"idle"`, `"up":false`, `"bind":null` and `"dir":null`

#### Scenario: App bound publicly after up
- **WHEN** `expose.sh up 3999 --name late` runs with nothing listening, and an app then listens on `0.0.0.0:3999`
- **THEN** `list` shows the `late` row with BIND `PUBLIC`, and `list --json` has `"bind":"public"` for it

#### Scenario: Access column
- **WHEN** `web` is exposed normally and `hook` with `--public`
- **THEN** `list` shows ACCESS `login` for `web` and `public` for `hook`

#### Scenario: Directory row
- **WHEN** `/home/u/pages` is exposed as `explain` and exists
- **THEN** `list` shows the `explain` row with PORT `-`, UP `yes` and BIND `dir`, and `list --json` has `"port":null`, `"dir":"/home/u/pages"`, `"up":true` and `"bind":"dir"` for it

### Requirement: Skill entry point
The `/expose` skill SHALL tell the agent to run `expose.sh` with the user's port or directory and options, relay the URL line and any warning, and use `list`, `down`, `url`, `share` and `key rotate` for the matching requests. It SHALL tell the agent not to print the owner login link or a share link unless the user asked for it. The skill and script SHALL behave the same under all five supported CLIs.

#### Scenario: Skill documents every subcommand
- **WHEN** the installed `expose/SKILL.md` is read
- **THEN** it documents `up`, `down`, `list`, `url`, `share` and `key rotate`, and the `--name`, `--project`, `--public`, `--dir`, `--hide`, `--csp`, `--with-key`, `--for`, `--ttl`, `--list` and `--revoke` options
