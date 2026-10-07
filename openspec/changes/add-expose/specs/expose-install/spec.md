# Spec Delta

## Purpose

Defines how `install.sh` sets up public port exposure when, and only when, the user asks for it with `--expose-domain`: Cloudflare token intake, the Caddy proxy and its config, setup checks, and installing the `/expose` skill for every supported CLI.

## ADDED Requirements

### Requirement: Opt-in flag
`install.sh` SHALL accept `--expose-domain <domain>`. Without it, install.sh SHALL NOT install the `/expose` skill, fetch Caddy, write expose config, or contact Cloudflare, and SHALL leave any existing expose setup untouched. The flag SHALL appear in the header comment and `--help`.

#### Scenario: Not passed
- **WHEN** `install.sh` runs without `--expose-domain` in a scratch HOME
- **THEN** no `expose/` skill folder, expose config file or Caddy binary is created, and no request is made to Cloudflare

#### Scenario: Documented
- **WHEN** `install.sh --help` runs
- **THEN** its output contains `--expose-domain`

### Requirement: Domain validation
The domain SHALL be a lowercase DNS name of at least two labels, each label made of `[a-z0-9-]` and not starting or ending with `-`. A leading `*.` SHALL be stripped. An invalid domain SHALL make install.sh exit non-zero before it installs anything.

#### Scenario: Wildcard prefix accepted
- **WHEN** `install.sh --expose-domain '*.dev.example.com'` runs
- **THEN** the stored domain is `dev.example.com`

#### Scenario: Invalid domain
- **WHEN** `install.sh --expose-domain 'not a domain'` runs
- **THEN** it exits non-zero naming the domain, before any skill, agent or config is installed

### Requirement: Token intake
The Cloudflare API token SHALL come from `$CLOUDFLARE_API_TOKEN` when set, otherwise from a prompt that does not echo the input, and SHALL NOT be accepted as a command-line argument. When there is no token source but a stored token exists, the stored one SHALL be kept. With no token from any source, install.sh SHALL exit non-zero before installing anything.

#### Scenario: Token from environment
- **WHEN** `CLOUDFLARE_API_TOKEN=t1 install.sh --expose-domain dev.example.com` runs with no terminal
- **THEN** the stored token is `t1` and no prompt is shown

#### Scenario: No token anywhere
- **WHEN** `install.sh --expose-domain dev.example.com` runs with no terminal, no `$CLOUDFLARE_API_TOKEN` and no stored config
- **THEN** it exits non-zero with a message naming `CLOUDFLARE_API_TOKEN`, and nothing is installed

#### Scenario: Rerun keeps token
- **WHEN** expose is configured with token `t1` and `install.sh --expose-domain dev.example.com` runs again with no terminal and no `$CLOUDFLARE_API_TOKEN`
- **THEN** the stored token is still `t1`

### Requirement: Config storage
The domain and token SHALL be stored in `${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/expose.env` with mode 600, inside a directory only the user can read. No backup, temporary file or other copy of the token SHALL be left readable by other users, and the token SHALL NOT appear in install.sh's output.

#### Scenario: File permissions
- **WHEN** install.sh has configured expose
- **THEN** `expose.env` exists with mode 600, contains the domain and token, and no other file under the config directory contains the token

#### Scenario: Token not printed
- **WHEN** `CLOUDFLARE_API_TOKEN=secret-t1 install.sh --expose-domain dev.example.com` runs
- **THEN** its output does not contain `secret-t1`

### Requirement: Token verification
Before writing the config, install.sh SHALL verify the token with Cloudflare's token verification API, without putting the token on any process's command line. A token Cloudflare rejects SHALL make install.sh exit non-zero with a message that it is invalid, and no expose config SHALL be written. `$OPSX_EXPOSE_SKIP_VERIFY=1` SHALL skip this check, for offline tests.

#### Scenario: Rejected token
- **WHEN** Cloudflare reports the token as invalid
- **THEN** install.sh exits non-zero saying the token is invalid, and `expose.env` is not created or changed

### Requirement: Caddy proxy
install.sh SHALL fetch a Caddy binary that includes the `dns.providers.cloudflare` module, unless one with that module is already installed, and SHALL write a base config. The config SHALL serve `*.<domain>` on port 443 only, get one wildcard certificate via the ACME DNS-01 challenge through Cloudflare, and expose the admin API only on a unix socket the user alone can reach.

#### Scenario: Base config
- **WHEN** install.sh has configured expose for `dev.example.com`
- **THEN** the Caddy config lists `*.dev.example.com` for certificate management with the Cloudflare DNS challenge, listens on `:443` and on no other TCP port, and its admin endpoint is a unix socket in a directory with mode 700

#### Scenario: Binary reused
- **WHEN** install.sh runs again and the installed Caddy already lists `dns.providers.cloudflare`
- **THEN** no new Caddy binary is downloaded

### Requirement: Privileged step
install.sh SHALL NOT call `sudo`. On Linux it SHALL write a systemd unit that runs Caddy as the installing user with the right to bind port 443. As root it SHALL enable and start that unit itself; otherwise it SHALL print the exact command for the user to run. On macOS it SHALL print how to start Caddy and note that no service is installed.

#### Scenario: Non-root Linux
- **WHEN** a non-root user runs `install.sh --expose-domain dev.example.com` on Linux
- **THEN** a systemd unit file is written under the user's config, install.sh does not invoke `sudo` or `systemctl`, and its output contains the command that installs and starts the unit

### Requirement: DNS check
install.sh SHALL resolve a random name under the domain and compare the addresses with this host's addresses. When the name does not resolve, or resolves only to addresses that are not this host's, it SHALL print a warning that says the wildcard record must be a DNS-only record pointing at this host, and SHALL continue. install.sh SHALL NOT create or change DNS records.

#### Scenario: Record missing
- **WHEN** the wildcard name does not resolve
- **THEN** install.sh prints a warning about the missing `*.<domain>` record and still exits 0

### Requirement: Install the expose skill for every CLI
With `--expose-domain`, install.sh SHALL copy `skills/expose/` (`SKILL.md` and an executable `expose.sh`) to the same six skill folders used for the `fork` skill, each as an `expose/` subfolder, keeping the usual `.bak` backups on overwrite. Running it again with unchanged sources SHALL leave identical files and create no duplicates.

#### Scenario: Fresh install
- **WHEN** `install.sh --expose-domain dev.example.com` runs with `OPSX_EXPOSE_SKIP_VERIFY=1` in a scratch HOME
- **THEN** each of the six skill folders contains `expose/SKILL.md` and an executable `expose/expose.sh`
