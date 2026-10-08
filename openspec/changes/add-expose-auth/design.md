# Design

## Context

See proposal.md for the motivation and the specs (`expose-access`, `port-expose`, `opsx-preview`) for the behaviour. The current state that shapes this design:

- `expose.sh` is the only code that talks to Caddy. Each exposure is one route, `@id: expose-<label>`, matching `host` and running `reverse_proxy 127.0.0.1:<port>` (`route_json`). It is added with DELETE + POST on the admin unix socket.
- `reconcile` runs at the start of every call and re-adds routes whose `@id` is missing. It does not compare route content, so a route that exists but is outdated (pre-auth, rotated key, revoked token) would never be fixed.
- State is one `routes/<label>.env` per exposure (`KEY=value` lines, parsed with `IFS='='`) in a mode-700 dir. `mktemp` creates files with mode 600.
- `opsx-preview.sh up` runs `expose.sh up` only once the app is healthy, so the app is already listening when the bind check runs.
- Caddy v2.11.7 with the Cloudflare module is installed. Its stock modules cover everything needed. A scratch-config test confirmed each piece below: query and `header_regexp` matchers, CEL `expression` with `int({time.now.unix}) < N`, `static_response` 302 with `Location: {http.request.uri.path}` and `Set-Cookie`, `subroute`, `headers` request `replace` with `search_regexp`, and a route's `group` field surviving a round trip through `GET /id/...`.

## Goals / Non-Goals

**Goals:**
- All auth decisions are made in Caddy at request time, so expiry and revocation never depend on `expose.sh` running.
- No new binaries, plugins or daemons. Still no root at runtime.
- Secrets never appear in process arguments and are printed only on explicit request.

**Non-Goals:**
- User accounts, SSO, passwords per client, or audit logs of who visited.
- Rate limiting or lockout on the login page. A 128-bit key isn't guessable.
- A host firewall. A separate client domain to isolate client-facing apps from the owner's (both are left for later).
- Preserving other query parameters on the login redirect.

## Decisions

### One route per exposure, a subroute inside
The outer route keeps its `@id` and `host` match, so addressing, re-publishing and `down` stay as they are. Its handler is a `subroute` evaluated top to bottom:

```
1. query opsx_key == K                          -> 302 Location {path}, Set-Cookie opsx_auth (Domain=<domain>, Max-Age 30d)
2. per share token t:  query opsx_share == t
                       [+ expression now < exp] -> 302 Location {path}, Set-Cookie opsx_share=t (host-only, Expires=exp)
3. any of: cookie opsx_auth == K
           cookie opsx_share == t [+ now < exp]  (one matcher set per token)
                                                -> headers: strip opsx_auth/opsx_share from Cookie
                                                -> reverse_proxy 127.0.0.1:<port>
4. otherwise                                    -> 401, HTML login page
```

A `--public` exposure keeps today's flat route. Tokens are `[A-Za-z0-9_-]`, so they go into the regexes unescaped. Step 1 is the same on every route, so a login link works on any host.
- *Alternative: `forward_auth` to a small auth service.* That needs a daemon, its own port and its own lifecycle, which is far heavier than static matchers.
- *Alternative: Caddy `basic_auth`.* It can't scope one client to one host without a user per host, it has no expiry, and it takes over the `Authorization` header that apps use.

### Cookie values are the secrets themselves
`opsx_auth` holds K and `opsx_share` holds t. An HMAC or signed cookie would need code in the proxy. With static matchers, a stolen cookie is exactly as powerful as the link it came from anyway, and `HttpOnly` plus stripping keeps both away from app JavaScript and app servers. Share cookies are host-only (no `Domain`), which is what keeps a client on its one hostname. A browser holding both cookies sends both, and either one is enough.

### Expiry in the route, not in a timer
Each token with a deadline adds `expression: int({time.now.unix}) < <exp>` to its matcher sets (tested). `--ttl never` omits it. The share cookie gets `Expires=<exp as HTTP date>`, a fixed date written when the route is built, so the browser drops it at the same moment. A `Max-Age` would be wrong after each rebuild. Expired tokens are pruned from state (and their matchers from the route) by any later call. That's only cleanup, since Caddy already refuses them.

### Route fingerprint for reconciliation
`route_json` renders the full route from state plus the key. A fingerprint of that JSON (`sha6`) is stored in the route's `group` field as `expose-fp-<h6>`. Every route has its own group, so grouping has no effect. `reconcile` reads each live route and re-adds it when the `@id` is missing **or** the fingerprint differs. That one mechanism covers the upgrade from pre-auth routes (no `group`), key rotation, share and revoke, and pruning. Commands that change state (`share`, `--revoke`, `key rotate`) re-add the affected routes directly and need no reconcile.
- *Alternative: compare the live JSON with the rendered JSON.* Caddy may reorder or normalise fields, so that would be brittle.

### Key and token storage
- Owner key: `~/.config/tmux-opsx/expose.key`, mode 600, 32 random bytes in base64url (from `/dev/urandom` through `head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n'`). It's created with `umask 077`, a temp file and `mv`, under the expose lock, so parallel first calls can't race. It's separate from `expose.env`, so install.sh stays the only writer of that file and the installer needs no change. `key rotate` writes a new key the same way and re-adds every non-public route.
- Share tokens: `SHARE=<id>:<recipient>:<expires|never>:<token>` lines in the exposure's `routes/<label>.env` (`IFS='='` reads the rest of the line into the value, and none of the fields contain `:`). `<id>` is `sha6(token)`. A `PUBLIC=1` line marks `--public`. `write_record` keeps existing `SHARE=` lines on re-publish, and `down` removes the file, which takes the tokens with it.
- The `routes/` files now hold secrets. They're already 600 in a 700 dir, and the requirement now says so.

### Printing secrets
`up` and `url` print the plain URL. Only `url --with-key` and `share` print a secret, and `share --list` shows the links. The skill tells the agent to relay those links only when the user asked for them. Copying to the clipboard follows the existing handoff. A share link is copied like a URL because that is the point of asking for one.

### Loopback check
`listeners <port>` lists local addresses of TCP listeners: `ss -Hltn "sport = :<port>"` on Linux, `lsof -nP -iTCP:<port> -sTCP:LISTEN` elsewhere. An address is loopback when it is in `127.0.0.0/8` or is `[::1]`. `*`, `0.0.0.0`, `[::]` and anything else count as public. In `up`:

- no tool available: exit 2 (fail closed, since you asked for loopback only)
- no listener: publish, plus a note
- any public listener: exit 2 before touching the proxy

`list` calls the same function for the BIND column and treats a missing tool as `-`. Docker's `-p 3000:3000` shows up as `docker-proxy` on `0.0.0.0` and is refused, as it should be. The message suggests `-p 127.0.0.1:3000:3000`.
- *Alternative: warn only.* Rejected. You chose loopback only, and with clients holding links a public bind is a real bypass.
- *Alternative: drop or 503 the route when a late bind turns public.* That doesn't close the direct path, so `list` reports it instead.

### Preview and QA
`opsx-preview.sh share` resolves the preview's name and project as `url` does and runs `expose.sh share <name> --project <project> …`. The QA dispatch steps in `opsx-run/SKILL.md` (both `qa` and `apply --validate`) run `opsx-preview.sh share <change> --for ops-qa --ttl 1d` after `up` and pass its last line as `PREVIEW_URL`. Using `--for ops-qa` replaces the previous QA token on every run, so only one QA token is live per preview, it lasts a day, and it opens only that preview's host. That's what ends up in agent transcripts, never the owner key. `agents/opsx-qa.md` says to open `PREVIEW_URL` first and keep the same browser context, so the cookie applies to later navigation.

### Login page
A static HTML body (inline CSS, no scripts, no external assets) holds a GET form with one `opsx_key` field (`action` empty = the same path) and the line "Got this link from someone? It may have expired or been revoked — ask them for a new one." It's served with `Cache-Control: no-store`.

## Risks / Trade-offs

- [Exposed apps share a registrable domain, so `SameSite=Lax` doesn't stop one exposed app from making requests to another with your owner cookie attached] → The cookie is HttpOnly and stripped before proxying, so an app can't read it. Cross-app request forgery between your own apps remains, which is acceptable for dev previews. A separate client domain is the later fix.
- [The key appears in the login form's URL and so in browser history] → It redirects at once. Use the browser's private mode on shared machines. `key rotate` is the recovery.
- [A huge number of share tokens makes routes large] → This is linear and fine for tens of tokens. Pruning keeps expired ones out.
- [Bind check races: the app rebinds after `up`] → `list` shows BIND `PUBLIC`. No enforcement after `up` is possible without a firewall.
- [`ss` filter syntax or `lsof` output varies] → Parse only the local address column. Tests use a fake `ss`/`lsof` on `PATH` plus a real `python3 -m http.server` bound each way.
- [Breaking change: links already handed out stop working without a cookie] → Intended. Run `url --with-key` once per device, and `up --public` restores the old behaviour per exposure.
- [Caddy matcher semantics change in a future version] → An eval runs real requests against a scratch Caddy when one is available (otherwise exit 77). Pinning Caddy is still out of scope.

## Migration Plan

1. Install with `install.sh --expose-domain <domain>` (copies the new `expose.sh`). The systemd `ExecStartPost` and the next `expose.sh` call create `expose.key` and rebuild every recorded route with auth, through the fingerprint mismatch.
2. Run `expose.sh url <name> --with-key` once on each of your devices.
3. Rollback: reinstall the previous `expose.sh`. Its reconcile sees the `@id`s present and leaves the auth routes in place, so also run `expose.sh down`/`up` for each exposure, or restart the proxy, which starts with no routes, and let the old `expose.sh` restore them. `expose.key` and `SHARE=` lines are ignored by the old script.
