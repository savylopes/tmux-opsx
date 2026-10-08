---
name: expose
description: "Publish a local port on this machine at an HTTPS URL (https://<name>--<project>.<domain>) behind a login, through the tmux-opsx Caddy proxy; list, reprint or remove those URLs, print the owner login link, and issue, list or revoke expiring share links for clients. Works from Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI. Use when the user types /expose, or asks to 'expose port 3000', 'share this app', 'give me a public URL', 'open this on my phone', 'list exposed ports', 'stop exposing', 'send this to a client', 'share link', 'revoke the link', or 'log me in on my phone'. Trigger: /expose"
trigger: /expose
---

# /expose

Turn `127.0.0.1:<port>` into an HTTPS URL under the wildcard domain set up by `install.sh --expose-domain <domain>`. The URL is `https://<name>--<project>.<domain>`.

**Exposed URLs require a login.** The proxy answers 401 with a small login page unless the request carries the owner cookie (set by the owner login link, valid on every exposed host for 30 days) or a share cookie (set by a share link, valid on that one host until it expires or is revoked). Both cookies are removed before the request reaches the app. `--public` turns the login off for one exposure (webhooks, OAuth callbacks); only then does `up` print a public-URL warning, which you must pass on.

**Apps must listen on `127.0.0.1`.** `up` refuses (exit 2) a port that something listens on at `0.0.0.0`, `[::]` or another non-loopback address, since that is reachable at `<server-ip>:<port>` without the login.

## Usage

| Command | What it does |
|---|---|
| `/expose <port>` | `up <port>`: publish the port; the name defaults to the port, so `/expose 3000` gives `3000--<project>.<domain>` |
| `/expose <port> --name <n>` | `up <port> --name <n>`: publish under a chosen name (`web` gives `web--<project>.<domain>`) |
| `/expose <port> --project <p>` | override the project part (default: the repo's main folder name, the same in every worktree) |
| `/expose <port> --public` | `up <port> --public`: no login for this exposure; `up` again without it requires a login again |
| `/expose list` | `list`: NAME, PROJECT, PORT, URL, UP, BIND, ACCESS (UP = something listens on the port; BIND = `loopback`, `PUBLIC` or `-`; ACCESS = `login` or `public`) |
| `/expose down <name\|port>` | `down`: remove that exposure and its share links (a port removes every exposure of it in the project) |
| `/expose url <name>` | `url`: print the URL again and copy it to the clipboard again |
| `/expose url <name> --with-key` | `url <name> --with-key`: the owner login link `<url>/?opsx_key=<key>`; open it once per device |
| `/expose share <name> [--for <recipient>] [--ttl <dur>]` | `share`: a share link `<url>/?opsx_share=<token>` for that one host; `--for` names the recipient (default `link-<id>`; sharing again with the same recipient replaces the old link), `--ttl` is `<n>m`, `<n>h`, `<n>d` or `never` (default `7d`) |
| `/expose share <name> --list` | FOR, ID, EXPIRES, LINK of every share link of that exposure |
| `/expose share <name> --revoke <recipient\|id\|all>` | delete those share links; their links and cookies stop working at once |
| `/expose key rotate` | `key rotate`: new owner key; every device is logged out (log in again with `url --with-key`), share links keep working |

## The script

All proxy work goes through `expose.sh`, next to this file (for Claude Code: `~/.claude/skills/expose/expose.sh`; other CLIs: the `expose/` folder of their skills dir). Resolve it once:

```bash
EXPOSE=$(for d in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/expose" "$HOME/.cursor/skills/expose" \
  "$HOME/.agents/skills/expose" "${CODEX_HOME:-$HOME/.codex}/skills/expose" \
  "${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}/skills/expose" "${GEMINI_HOME:-$HOME/.gemini}/skills/expose"; do
  [ -x "$d/expose.sh" ] && { printf '%s/expose.sh' "$d"; break; }; done)
```

Then map the user's request onto one subcommand:

```bash
"$EXPOSE" up 3000                       # /expose 3000
"$EXPOSE" up 3000 --name web            # /expose 3000 --name web
"$EXPOSE" up 3000 --project shop        # explicit project part
"$EXPOSE" list                          # /expose list   (add --json for machine-readable output)
"$EXPOSE" down web                      # /expose down web
"$EXPOSE" down 3000                     # /expose down 3000
"$EXPOSE" url web                       # /expose url web
"$EXPOSE" up 3000 --name hook --public  # no login (webhooks)
"$EXPOSE" url web --with-key            # owner login link (only when the user asks for it)
"$EXPOSE" share web --for acme          # share link for acme, 7 days
"$EXPOSE" share web --for acme --ttl 2d # replace acme's link, 2 days
"$EXPOSE" share web --list              # FOR, ID, EXPIRES, LINK
"$EXPOSE" share web --revoke acme       # or an id, or all
"$EXPOSE" key rotate                    # log every device out
```

Run it from the project directory so the default project name is right.

## What to tell the user

- After `up` or `url`: relay the **URL** (always the last line of output), and the **public / no-authentication warning line** when there is one (only with `--public`). Tell the user the URL needs a login, and that `expose.sh url <name> --with-key` gives them the login link for their own devices.
- **Never print the owner login link (`?opsx_key=…`) or a share link (`?opsx_share=…`) unless the user asked for it** — `url --with-key` and `share` are only run on that request, and then the link (the last line) is relayed once. Do not run `url --with-key` just to check something, and do not repeat links in summaries. `share --list` shows links too; run it only when the user asks to see them. Relay the clipboard line from stderr as is: `copied to the tmux buffer …` means the URL is in tmux's paste buffer and reaches the user's clipboard only if tmux `set-clipboard` is on, so say that rather than promising it is on the clipboard; `copied to the clipboard via the terminal …` means it was sent to the terminal by OSC 52; `not copied …` means it is not, so do not claim it was. If stderr says nothing is listening on the port yet, pass that on too. Do not try to open a browser.
- After `share`: relay the link (last line), who it is for, when it expires and the revoke command. A share link works only on that one hostname.
- After `--revoke`: say what was revoked, or that nothing matched (not an error).
- After `key rotate`: say every device is logged out and how to log in again; share links keep working.
- After `list`: show the table as-is. A BIND of `PUBLIC` means the app now listens on a non-loopback address and is reachable around the login: tell the user to restart it bound to `127.0.0.1`.
- After `down`: say what was removed (its share links go with it), or that nothing matched (that is not an error).
- When `up` exits 2 with `refusing to publish port <port>: the app listens on <address>…`: relay it and tell the user to bind the app to `127.0.0.1` (e.g. `--host 127.0.0.1`, or `-p 127.0.0.1:<port>:<port>` for Docker), then run `/expose` again. When it exits 2 saying it `cannot check which address` the port listens on, relay that `ss` (Linux) or `lsof` (macOS) is needed.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | ok (including "nothing matched") | relay the output |
| 2 | bad usage (invalid port, name, `--ttl`), or `up` refused a non-loopback bind | fix the arguments, or bind the app to `127.0.0.1` |
| 3 | expose is not configured | tell the user to run `install.sh --expose-domain <domain>` from the tmux-opsx checkout |
| 4 | the proxy is not running | relay the printed start command (e.g. `sudo systemctl start tmux-opsx-caddy`); do not run sudo yourself |
| 1 | anything else | relay the error |
