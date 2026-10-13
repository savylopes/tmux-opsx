# Spec Delta

## ADDED Requirements

### Requirement: Directory exposures use the same access rules
A directory exposure SHALL be protected exactly like a port exposure: without `--public`, a request SHALL be served only with a valid owner cookie or a share cookie valid for that hostname, and any other request SHALL get the 401 login page; the owner login link, share links, `share --list`, `--revoke`, `key rotate` and `--public` SHALL apply to it unchanged.

#### Scenario: Directory needs a login
- **WHEN** `/home/u/pages` is exposed as `explain` in project `shop` and `https://explain--shop.<domain>/1/` is requested without a cookie
- **THEN** the proxy answers 401 and serves no file

#### Scenario: Share link opens the directory
- **WHEN** `expose.sh share explain --for acme` runs and a client follows the link
- **THEN** it gets a 302 setting the host-only `opsx_share` cookie, and with that cookie `/1/` is served

#### Scenario: Public directory
- **WHEN** `expose.sh up --dir /home/u/site --name docs --public` runs
- **THEN** `/index.html` is served without a cookie and `up` printed the public warning
