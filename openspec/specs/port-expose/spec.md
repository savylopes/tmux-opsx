# port-expose Specification

## Purpose
Lets the user publish any local TCP port on this machine at a public HTTPS URL under their wildcard domain, and manage those URLs, through the `/expose` skill and its `expose.sh` script on every supported agent CLI.

## Requirements

### Requirement: Publish a local port
`expose.sh up <port> [--name <n>] [--project <p>]` SHALL publish `127.0.0.1:<port>` at `https://<label>.<domain>`, where `<domain>` is the configured expose domain. It SHALL print the URL as the last line of standard output and exit 0. `<port>` MUST be an integer from 1 to 65535 other than 443. Any other value SHALL be refused with a non-zero exit and no change made.

#### Scenario: Port published
- **WHEN** expose is configured for `dev.example.com` and `expose.sh up 3000 --name web --project shop` runs
- **THEN** it exits 0, its last output line is `https://web--shop.dev.example.com`, and the proxy routes that hostname to `127.0.0.1:3000`

#### Scenario: Invalid port refused
- **WHEN** `expose.sh up 70000` or `expose.sh up abc` or `expose.sh up 443` runs
- **THEN** it exits non-zero, names the invalid port, and no route or state record is created

### Requirement: Hostname label
The label SHALL be `<name>--<project>`. Both parts SHALL be lowercased, with every run of characters outside `[a-z0-9]` replaced by one `-` and leading or trailing `-` removed, so `--` occurs only as the separator. `<name>` SHALL default to the port number. `<project>` SHALL default to the folder name of the main checkout of the current git repository (the same for any of its worktrees), or to the current directory's name outside git.

#### Scenario: Defaults
- **WHEN** `expose.sh up 3000` runs inside a worktree `../wt-add-auth` of the repository checked out at `provision-admin`
- **THEN** the label is `3000--provision-admin`

#### Scenario: Characters normalised
- **WHEN** `expose.sh up 8080 --name "My_App" --project "Foo.Bar"` runs
- **THEN** the label is `my-app--foo-bar`

### Requirement: Label length limit
A label SHALL be at most 63 characters. When `<name>--<project>` would be longer, the name part SHALL be truncated and followed by `-` and the first 6 hex characters of a hash of the full, untruncated label, so that the same input always gives the same label and different inputs give different labels.

#### Scenario: Long label shortened
- **WHEN** `expose.sh up 3000 --name` followed by a 70-character name runs
- **THEN** the label is at most 63 characters, ends with `--<project>`, and running the same command again gives the identical hostname

#### Scenario: Distinct long names stay distinct
- **WHEN** two different 70-character names that share their first 60 characters are each exposed
- **THEN** they get two different hostnames

### Requirement: Re-publishing a name
Running `up` with a name that is already exposed in the same project SHALL replace its route so the hostname points at the new port. Running it with the same port again SHALL leave a single route. Neither SHALL create a second route for the same hostname. The exposure's share links SHALL keep working after a re-publish.

#### Scenario: Name moved to a new port
- **WHEN** `expose.sh up 3000 --name web` runs and then `expose.sh up 3001 --name web` runs
- **THEN** `list` shows one `web` entry on port 3001, and the hostname routes to `127.0.0.1:3001`

#### Scenario: Share links survive a re-publish
- **WHEN** `web` has a share link for `acme` and `expose.sh up 3001 --name web` runs
- **THEN** `acme`'s link is still accepted and reaches the app on port 3001

### Requirement: Remove an exposure
`expose.sh down <name|port> [--project <p>]` SHALL remove the matching route, its state record and its share links, then exit 0. A port argument SHALL match every exposure of that port in the project. When nothing matches it SHALL say so and exit 0, so teardown is safe to repeat.

#### Scenario: Removed
- **WHEN** `web` is exposed and `expose.sh down web` runs
- **THEN** the route is gone from the proxy, `list` no longer shows `web`, and the exit code is 0

#### Scenario: Nothing to remove
- **WHEN** `expose.sh down nosuch` runs
- **THEN** it prints that nothing matched and exits 0

#### Scenario: Share links do not come back
- **WHEN** `web` has a share link for `acme`, `expose.sh down web` runs and then `expose.sh up 3000 --name web` runs
- **THEN** `acme`'s old link gets 401 and `expose.sh share web --list` shows no links

### Requirement: List exposures
`expose.sh list` SHALL print one row per exposure with the columns NAME, PROJECT, PORT, URL, UP, BIND and ACCESS. UP SHALL be `yes` when something accepts TCP connections on `127.0.0.1:<port>`, otherwise `no`. BIND SHALL be `loopback`, `PUBLIC` when any listener on the port is not loopback, or `-` when nothing listens or it cannot be checked. ACCESS SHALL be `login` or `public`. `list --json` SHALL print the same data as a JSON array of objects with the keys `name`, `project`, `port`, `url`, `up`, `bind` (`"loopback"`, `"public"` or `null`) and `public` (boolean).

#### Scenario: Port with nothing listening
- **WHEN** port 3999 is exposed as `idle` and no process listens on it
- **THEN** `list` shows the `idle` row with UP `no` and BIND `-`, and `list --json` has an object with `"name":"idle"`, `"up":false` and `"bind":null`

#### Scenario: App bound publicly after up
- **WHEN** `expose.sh up 3999 --name late` runs with nothing listening, and an app then listens on `0.0.0.0:3999`
- **THEN** `list` shows the `late` row with BIND `PUBLIC`, and `list --json` has `"bind":"public"` for it

#### Scenario: Access column
- **WHEN** `web` is exposed normally and `hook` with `--public`
- **THEN** `list` shows ACCESS `login` for `web` and `public` for `hook`

### Requirement: Reprint a URL
`expose.sh url <name> [--project <p>] [--with-key]` SHALL print the URL of that exposure and copy it again, exactly as `up` does. With `--with-key` it SHALL print and copy the owner login link instead. An unknown name SHALL exit non-zero.

#### Scenario: Known name
- **WHEN** `web` is exposed in project `shop` and `expose.sh url web --project shop` runs
- **THEN** the last output line is `https://web--shop.<domain>` and the exit code is 0

#### Scenario: With key
- **WHEN** `web` is exposed in project `shop` and `expose.sh url web --project shop --with-key` runs
- **THEN** the last output line is `https://web--shop.<domain>/?opsx_key=<owner key>`

### Requirement: URL handoff to the terminal
When `up` or `url` prints a URL, the script SHALL put the URL on the user's terminal clipboard via OSC 52: through tmux's clipboard when tmux is reachable, otherwise by writing to the controlling terminal when there is one. When standard output is a terminal, the URL SHALL also be printed as an OSC 8 hyperlink. When standard output is not a terminal, the URL line SHALL be plain text with no escape sequences. The script SHALL NOT try to open a browser.

#### Scenario: Captured output is plain
- **WHEN** `expose.sh up 3000 --name web` runs with standard output redirected to a file
- **THEN** the file's last line is exactly the URL with no escape characters

#### Scenario: Copied through tmux
- **WHEN** `expose.sh up 3000 --name web` runs inside a tmux server
- **THEN** that server's newest paste buffer holds the URL

### Requirement: Routes survive a proxy restart
Each exposure SHALL be recorded in a state directory under `${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/expose/`, readable only by the user. Every `up`, `down`, `list`, `url`, `share` and `key` call SHALL first restore any recorded route that is missing from the running proxy, and rebuild any route that differs from what the state now requires (such as a route created before login was required), so neither a proxy restart nor an upgrade leaves a stale route.

#### Scenario: Restored after restart
- **WHEN** `web` is exposed, the proxy restarts with no routes, and `expose.sh list` runs
- **THEN** the proxy routes `web`'s hostname again and `list` shows `web`

#### Scenario: Pre-auth route upgraded
- **WHEN** the proxy holds a route for `web` that forwards every request without a login, and `expose.sh list` runs
- **THEN** afterwards a request to `web` without a cookie gets 401

### Requirement: Not configured
When the expose configuration is missing, every `expose.sh` subcommand except `help` SHALL exit non-zero with a message that names `install.sh --expose-domain`, and SHALL make no network call. When the proxy's admin endpoint cannot be reached, the script SHALL exit non-zero with a message saying the proxy is not running and how to start it.

#### Scenario: No config
- **WHEN** no expose config exists and `expose.sh up 3000` runs
- **THEN** it exits non-zero and its error output contains `install.sh --expose-domain`

#### Scenario: Proxy down
- **WHEN** the config exists but the proxy is not running and `expose.sh up 3000` runs
- **THEN** it exits non-zero with a message that the proxy is not running, and no state record is created

### Requirement: Skill entry point
The `/expose` skill SHALL tell the agent to run `expose.sh` with the user's port and options, relay the URL line and any warning, and use `list`, `down`, `url`, `share` and `key rotate` for the matching requests. It SHALL tell the agent not to print the owner login link or a share link unless the user asked for it. The skill and script SHALL behave the same under all five supported CLIs.

#### Scenario: Skill documents every subcommand
- **WHEN** the installed `expose/SKILL.md` is read
- **THEN** it documents `up`, `down`, `list`, `url`, `share` and `key rotate`, and the `--name`, `--project`, `--public`, `--with-key`, `--for`, `--ttl`, `--list` and `--revoke` options

### Requirement: Loopback bind only
When something listens on `<port>`, `up` SHALL publish only if every listener on that port is bound to a loopback address (`127.0.0.0/8` or `::1`). Otherwise it SHALL exit 2, name the non-loopback address, say to bind the app to `127.0.0.1`, and make no change. When the listeners cannot be inspected, `up` SHALL exit 2 saying so. When nothing listens yet, `up` SHALL publish and say the bind is checked by `list`.

#### Scenario: Wildcard bind refused
- **WHEN** an app listens on `0.0.0.0:3999` and `expose.sh up 3999 --name web` runs
- **THEN** it exits 2, its error output names `0.0.0.0` and `127.0.0.1`, and no route or state record for `web` exists

#### Scenario: Loopback bind accepted
- **WHEN** an app listens only on `127.0.0.1:3999` and `expose.sh up 3999 --name web` runs
- **THEN** it exits 0 and the last output line is the URL

#### Scenario: Refused re-publish keeps the old route
- **WHEN** `web` is exposed on port 3000 and `expose.sh up 3999 --name web` runs while an app listens on `0.0.0.0:3999`
- **THEN** it exits 2 and `web` still routes to port 3000
