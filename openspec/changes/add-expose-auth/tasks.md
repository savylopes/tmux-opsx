# Tasks

## 1. Test harness for real proxy behaviour

- [x] 1.1 Add a real-Caddy helper to `tests/test-expose.sh` that starts the installed Caddy (or `$OPSX_CADDY_BIN`) on a scratch admin socket and a high HTTP port with a `*.ex.test` server (no TLS) and skips with a notice when no binary is available; verify a smoke request through it gets an answer and the helper tears Caddy down
- [x] 1.2 Teach `tests/fake-caddy-admin.py` to store and return the `group` field and to serve `GET /id/<id>` bodies verbatim; verify the existing `tests/test-expose.sh` still passes

## 2. Owner key and authenticated routes

- [x] 2.1 Add owner key handling to `expose.sh` (create `expose.key` with mode 600 under the lock, read it, never print it) per design "Key and token storage"; verify with a test that two `list` calls leave one unchanged 600 key and that `up`/`url` output does not contain it
- [x] 2.2 Render the subroute from design "One route per exposure, a subroute inside" in `route_json` (owner login, cookie check, cookie strip, 401 login page with `Cache-Control: no-store`) and keep the flat route for `PUBLIC=1`; verify against real Caddy: no cookie gives 401 with an `opsx_key` form, `?opsx_key=<K>` gives 302 to the path with the specified `Set-Cookie`, a wrong key gives 401, the owner cookie reaches the app on a second exposure, and the app sees `Cookie` without `opsx_auth`
- [x] 2.3 Add the route fingerprint (`group: expose-fp-<h6>`) and make `reconcile` re-add routes whose fingerprint differs or is missing; verify a hand-inserted pre-auth route is rebuilt by `expose.sh list` (fake admin), and that a request to it then gets 401 (real Caddy)
- [x] 2.4 Add `up --public` (state `PUBLIC=1`, public warning line only in that case) and drop the unconditional warning; verify `--public` lets a cookie-less request through, a later `up` without it gives 401, and `list` shows ACCESS `public`/`login`
- [x] 2.5 Add `url --with-key` printing `<url>/?opsx_key=<K>` as the last line through the existing handoff; verify the last line, and that plain `url` is unchanged
- [x] 2.6 Add `key rotate` (new key, re-add every non-public route); verify the old owner cookie gets 401, the new link works, and an existing share link still works (after group 3, re-run)

## 3. Share links

- [x] 3.1 Store share tokens as `SHARE=` lines (keep them in `write_record` on re-publish, drop them with the record on `down`) and render their query and cookie matchers with a CEL deadline unless `never`; verify re-publishing to a new port keeps a link working and `down` then `up` invalidates it
- [x] 3.2 Implement `share <name> [--for] [--ttl] [--project]` with recipient normalisation, `link-<id>` default, replace-per-recipient, ttl parsing (`<n>m|h|d|never`, default `7d`, exit 2 otherwise), and refusal for unknown or public exposures; verify each `expose-access` "Share links" and "Share link expiry" scenario with real Caddy, including a `--ttl 1m` link refused after its deadline (use a short deadline injected through a test hook such as `OPSX_EXPOSE_NOW` for the stored expiry, not by sleeping minutes)
- [x] 3.3 Implement `share <name> --list` (FOR, ID, EXPIRES, LINK) and `--revoke <recipient|id|all>`, plus pruning of expired tokens on every call; verify a revoked cookie gets 401 while another recipient's link works, `--revoke nosuch` exits 0, and an expired token disappears from `--list` after the next call
- [x] 3.4 Verify share scope with real Caddy: a `web` token (query or cookie) gives 401 on `api`, and the share cookie has no `Domain` attribute and `Expires` at the token deadline

## 4. Loopback bind

- [x] 4.1 Add the listener check (`ss` on Linux, `lsof` elsewhere, loopback = `127.0.0.0/8` or `::1`) and make `up` refuse public or uninspectable binds with exit 2 before touching the proxy; verify with `python3 -m http.server` bound to `0.0.0.0` (refused, names `0.0.0.0` and `127.0.0.1`, no state), bound to `127.0.0.1` (accepted), a refused re-publish keeping the old port, and a fake `ss` absent from `PATH` (refused)
- [x] 4.2 Add BIND to `list` and `bind`/`public` to `list --json`; verify the nothing-listening row (`-`, `null`) and a late `0.0.0.0` bind showing `PUBLIC`/`"public"`

## 5. Skill and docs for expose

- [x] 5.1 Update `skills/expose/SKILL.md` and the `expose.sh` header/usage for every new subcommand and option, the rule not to relay login or share links unless asked, and the loopback refusal message; verify the skill lists `up`, `down`, `list`, `url`, `share`, `key rotate` and all options named in the spec, and `expose.sh help` shows them
- [x] 5.2 Update the README expose section (login by default, owner link per device, share links for clients with expiry and revoke, `--public`, loopback-only binds, migration note for existing links) and the component overview if it mentions public access; verify every command in the README runs as written against the test proxy

## 6. Previews and QA

- [x] 6.1 Add `opsx-preview.sh share <change>|--main` passing options through to `expose.sh share` with the preview's name and project, and failing when no preview is recorded; verify in `tests/test-preview.sh` (both scenarios of "Share a preview")
- [x] 6.2 Make `opsx-preview.sh up` relay a bind refusal from `expose.sh up` and clean up; verify the `--bind 0.0.0.0` recipe scenario (non-zero, `127.0.0.1` in output, no window, no exposure) in `tests/test-preview.sh`
- [x] 6.3 Update both QA dispatch prompts in `skills/opsx-run/SKILL.md` to run `opsx-preview.sh share <change> --for ops-qa --ttl 1d` after `up` and pass its last line as `PREVIEW_URL`, document `/opsx-run <change> preview share`, and update `agents/opsx-qa.md` to open `PREVIEW_URL` first and keep the browser context; verify by reading the installed files after `install.sh` in a scratch HOME

## 7. Integration

- [x] 7.1 Run `tests/test-expose.sh`, `tests/test-preview.sh`, `tests/test-eval.sh` and `shellcheck` on every changed script; verify all pass (real-Caddy sections run, not skipped, on this host)
- [ ] 7.2 End to end on this VPS through the real proxy: expose a loopback app, confirm 401 without a cookie from outside, log in on a phone with `url --with-key`, issue a share link and open it in a private window, confirm it fails on another exposure and after `--revoke`; record the outcome in the change's QA notes

## Workflow follow-up

- ops-eval writes checks for the new `expose-access` scenarios and the changed `port-expose`/`opsx-preview` scenarios, and retires `evals/port-expose/warning-shown.check` (its requirement is removed).
- Archive the change after review, security and QA gates pass.
