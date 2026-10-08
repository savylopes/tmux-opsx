# Proposal

## Why

Every URL published by `/expose` (and every `/opsx-run` preview) is public with no authentication: anyone who guesses or sees `web--shop.<domain>` reaches the app, debug pages and seeded admins included. That was accepted while the URLs were only for the user's own devices, but the user now sends preview links to clients, so access has to be limited, per app, and revocable. Separately, an app bound to `0.0.0.0` is reachable at `<server-ip>:<port>` without going through the proxy at all, which would defeat any auth added there.

## What Changes

- **BREAKING** Exposed URLs require a login by default. The proxy accepts a request only with a valid owner cookie or a valid share cookie for that host; otherwise it answers 401 with a small login page. Routes recorded before this change are rebuilt with auth on the next `expose.sh` call.
- An **owner key** per install, kept by `expose.sh` in a mode-600 file. `expose.sh url <name> --with-key` prints a login link (`?opsx_key=…`); opening it sets an owner cookie for every host under the domain and redirects to the same path without the key. `expose.sh key rotate` replaces the key, logging every device out. `up` and `url` print the plain URL by default, so the key stays out of agent transcripts.
- **Share links** for clients: `expose.sh share <name> [--for <recipient>] [--ttl <dur>]` issues a token valid for that one hostname only, one per recipient, expiring after 7 days by default (`--ttl never` to keep it). `share <name> --list` and `share <name> --revoke <recipient|id>` manage them. The proxy itself enforces expiry on every request.
- The owner and share cookies are removed from the request before it reaches the app.
- `expose.sh up --public` publishes a route without auth (webhooks, OAuth callbacks).
- **Loopback bind only**: `up` refuses a port that has a listener on any address other than loopback (`0.0.0.0`, `[::]`, a public IP), and `list` shows each exposure's bind so an app that binds publicly after `up` is visible.
- The "public with no authentication" warning on `up` is removed (replaced by a one-line note when `--public` is used).
- Previews: `opsx-preview.sh share <change>` passes through to `expose.sh share`, and the QA dispatcher gives ops-qa a short-lived share link for the preview instead of the bare URL.

## Capabilities

### New Capabilities
- `expose-access`: who may reach an exposed URL — owner key and login link, login page, share links with expiry and revocation, cookie handling, and the public opt-out.

### Modified Capabilities
- `port-expose`: `up` refuses non-loopback binds and drops the public warning; `list` gains a bind column; `url` gains `--with-key`; `down` deletes share links; re-publishing keeps them; reconciliation also rebuilds outdated routes; the skill documents the new subcommands.
- `opsx-preview`: a `share` subcommand, and ops-qa receives a share link for the preview.

## Impact

- `skills/expose/expose.sh` (route JSON, key and share state, `share`/`key` subcommands, bind check, reconcile), `skills/expose/SKILL.md`.
- `skills/opsx-run/opsx-preview.sh`, `skills/opsx-run/SKILL.md` (QA dispatch steps), `agents/opsx-qa.md` (a preview URL is a login link that sets a cookie).
- `README.md` expose section; `tests/test-expose.sh`, `tests/test-preview.sh`; evals for the new scenarios.
- No new dependencies: the auth uses Caddy's built-in matchers (`query`, `header_regexp`, CEL `expression`) and handlers (`static_response`, `headers`); tested on the installed Caddy v2.11.7. The bind check uses `ss` on Linux and `lsof` on macOS.
- `install.sh` is unchanged: the owner key is created by `expose.sh` on first use, so existing installs pick it up without rerunning the installer.
