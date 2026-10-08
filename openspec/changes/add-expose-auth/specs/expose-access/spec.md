# Spec Delta

## Purpose

Controls who may reach a URL published by `/expose`: the owner through a per-install key, clients through per-host share links that expire and can be revoked, and nobody else unless an exposure is explicitly made public.

## ADDED Requirements

### Requirement: Login required
Every exposure SHALL require a login unless it was published with `--public`. The proxy SHALL pass a request to the app only when it carries a valid owner cookie (`opsx_auth`) or a share cookie (`opsx_share`) valid for that hostname. Any other request SHALL get HTTP 401 and SHALL NOT reach the app.

#### Scenario: No cookie
- **WHEN** `web` is exposed in project `shop` and a request for `https://web--shop.<domain>/` carries no cookie
- **THEN** the proxy answers 401 and the app receives no request

#### Scenario: Wrong cookie
- **WHEN** a request for an exposure carries `opsx_auth=wrong`
- **THEN** the proxy answers 401

### Requirement: Owner key
`expose.sh` SHALL keep one owner key per install in `${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/expose.key` with mode 600, creating it on first use with at least 128 bits of randomness in the characters `[A-Za-z0-9_-]`. The key SHALL stay the same across calls and reinstalls until rotated, and SHALL NOT be printed by any subcommand except `url --with-key`.

#### Scenario: Created once
- **WHEN** expose is configured, no `expose.key` exists, and `expose.sh list` runs twice
- **THEN** `expose.key` exists with mode 600 after the first call and has the same content after the second

#### Scenario: Key not printed
- **WHEN** `expose.sh up 3000 --name web` and `expose.sh url web` run
- **THEN** neither output contains the owner key

### Requirement: Owner login link
`expose.sh url <name> --with-key` SHALL print `<url>/?opsx_key=<key>` as its last line. A request carrying the right `opsx_key` query value SHALL get a 302 redirect to the same path without the query, setting `opsx_auth=<key>` with `Domain=<domain>`, `Path=/`, `Secure`, `HttpOnly`, `SameSite=Lax` and a 30-day `Max-Age`. A wrong key SHALL get 401.

#### Scenario: Login link sets owner cookie
- **WHEN** `web` and `api` are exposed in project `shop` and a client requests `https://web--shop.<domain>/admin?opsx_key=<key>`
- **THEN** it gets a 302 to `/admin` with a `Set-Cookie: opsx_auth=<key>` header for `Domain=<domain>`, and sending that cookie to `https://api--shop.<domain>/` reaches the `api` app

#### Scenario: Wrong key
- **WHEN** a client requests an exposure with `?opsx_key=wrong`
- **THEN** the proxy answers 401 and sets no cookie

### Requirement: Login page
A 401 answer SHALL be an HTML page with a form that submits the owner key as the `opsx_key` query parameter to the requested path, and that tells a visitor who followed a share link that the link may have expired or been revoked.

#### Scenario: Page shown
- **WHEN** a request without a valid cookie reaches an exposure
- **THEN** the 401 body is HTML containing a form field named `opsx_key` and text saying the link may have expired

### Requirement: Share links
`expose.sh share <name> [--for <recipient>] [--ttl <dur>] [--project <p>]` SHALL create a share token for that exposure (at least 128 bits, `[A-Za-z0-9_-]`) and print `<url>/?opsx_share=<token>` as its last line. The recipient SHALL be normalised like a hostname part and default to `link-<id>`, where `<id>` is 6 hex characters identifying the token. Sharing again with the same recipient SHALL replace that recipient's token. An unknown exposure or a `--public` one SHALL exit non-zero.

#### Scenario: Link issued
- **WHEN** `web` is exposed in project `shop` and `expose.sh share web --for Acme` runs
- **THEN** it exits 0 and its last line is `https://web--shop.<domain>/?opsx_share=<token>`

#### Scenario: Same recipient replaced
- **WHEN** `expose.sh share web --for acme` runs twice
- **THEN** the two links have different tokens, the first link gets 401 and the second is accepted

#### Scenario: Unknown exposure
- **WHEN** `expose.sh share nosuch` runs
- **THEN** it exits non-zero and no token is stored

### Requirement: Share link scope
A request carrying a valid `opsx_share` query value SHALL get a 302 to the same path without the query, setting a host-only `opsx_share=<token>` cookie (no `Domain` attribute) with `Path=/`, `Secure`, `HttpOnly`, `SameSite=Lax` and `Expires` at the token's expiry, if any. A share token or cookie SHALL be accepted only on the hostname it was issued for.

#### Scenario: Link works on its host
- **WHEN** a client follows the share link for `web` and then requests `https://web--shop.<domain>/` with the cookie it was given
- **THEN** the first response is a 302 with a host-only `opsx_share` cookie, and the second reaches the app

#### Scenario: Link refused on another host
- **WHEN** `web` and `api` are exposed and a request for `https://api--shop.<domain>/` carries the `web` share token, as query or cookie
- **THEN** the proxy answers 401

### Requirement: Share link expiry
`--ttl` SHALL accept `<n>m`, `<n>h`, `<n>d` (n a positive integer) or `never`, and SHALL default to `7d`. Any other value SHALL exit 2 with no token created. The proxy SHALL refuse a share token or cookie after its expiry on every request, without any `expose.sh` call in between.

#### Scenario: Default expiry
- **WHEN** `expose.sh share web --for acme` runs without `--ttl`
- **THEN** `expose.sh share web --list` shows `acme` expiring 7 days from now

#### Scenario: Expired link refused
- **WHEN** a share link was issued with `--ttl 1m` and is used 2 minutes later, with no `expose.sh` call in between
- **THEN** the proxy answers 401

#### Scenario: Invalid ttl
- **WHEN** `expose.sh share web --ttl 3weeks` runs
- **THEN** it exits 2 naming the ttl, and no token is created

### Requirement: List share links
`expose.sh share <name> --list` SHALL print one row per share token of that exposure with the columns FOR, ID, EXPIRES and LINK, where EXPIRES is a date, `never`, or `expired`. Expired tokens SHALL be removed from the state and the proxy by any later `expose.sh` call.

#### Scenario: Listed
- **WHEN** `web` has share links for `acme` and `globex`
- **THEN** `expose.sh share web --list` prints a row for each with its ID, expiry and link

### Requirement: Revoke share links
`expose.sh share <name> --revoke <recipient|id>` SHALL delete the matching token and update the proxy, so the link and any cookie it set are refused at once. `--revoke all` SHALL delete every token of that exposure. When nothing matches it SHALL say so and exit 0.

#### Scenario: Revoked
- **WHEN** `acme` holds a share cookie for `web` and `expose.sh share web --revoke acme` runs
- **THEN** the next request with that cookie gets 401, and `globex`'s link for `web` still works

### Requirement: Rotate the owner key
`expose.sh key rotate` SHALL replace the owner key and rebuild every route, so every existing owner cookie and old login link is refused. Share links SHALL keep working.

#### Scenario: Rotated
- **WHEN** a browser holds an owner cookie and `expose.sh key rotate` runs
- **THEN** that cookie gets 401, `url --with-key` prints a link with the new key, and existing share links are still accepted

### Requirement: Credentials not forwarded
Before a request reaches the app, the proxy SHALL remove the `opsx_auth` and `opsx_share` cookies from its `Cookie` header and SHALL keep every other cookie unchanged.

#### Scenario: App sees only its own cookies
- **WHEN** an authorised request carries `Cookie: sid=1; opsx_auth=<key>; theme=dark`
- **THEN** the app receives a `Cookie` header with `sid=1` and `theme=dark` and without `opsx_auth`

### Requirement: Public opt-out
`expose.sh up <port> --public` SHALL publish the exposure without a login, and `up` SHALL then print a line saying the URL is public with no authentication. Running `up` again for the same name without `--public` SHALL make it require a login again.

#### Scenario: Public route
- **WHEN** `expose.sh up 3000 --name hook --public` runs
- **THEN** a request with no cookie reaches the app, and the output says the URL is public with no authentication

#### Scenario: Back to private
- **WHEN** `hook` was published with `--public` and `expose.sh up 3000 --name hook` runs
- **THEN** a request with no cookie gets 401
