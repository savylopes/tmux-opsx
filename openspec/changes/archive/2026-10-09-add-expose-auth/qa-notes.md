# QA notes

## 7.2 End to end through the live proxy (2026-10-08, dev.bsll.tech)

Run by ops-applier with the worktree's `expose.sh` against the running `tmux-opsx-caddy` (no exposures were recorded before; both test exposures were removed and the created `expose.key` deleted afterwards). Requests went to the public hostnames over TLS.

| Check | Result |
|---|---|
| Loopback echo app exposed as `e2eweb--opsxe2e`, request without cookie | 401 |
| `?opsx_key=<key>` login link | 302 |
| Owner cookie on the second exposure `e2eapi--opsxe2e` | 200 |
| Share link (`--for e2e --ttl 1h`) | 302; its cookie 200 on `e2eweb` |
| Share cookie on `e2eapi` (other exposure) | 401 |
| Share cookie after `--revoke e2e` | 401 |
| `<public-ip>:<port>` of the 127.0.0.1-bound app | not reachable |

Still to do by the user: log in on a phone with `url --with-key`, and open a share link in a private browser window.
