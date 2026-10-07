---
name: expose
description: "Publish a local port on this machine at a public HTTPS URL (https://<name>--<project>.<domain>) through the tmux-opsx Caddy proxy, and list, reprint or remove those URLs. Works from Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI. Use when the user types /expose, or asks to 'expose port 3000', 'share this app', 'give me a public URL', 'open this on my phone', 'list exposed ports', or 'stop exposing'. Trigger: /expose"
trigger: /expose
---

# /expose

Turn `127.0.0.1:<port>` into a public HTTPS URL under the wildcard domain set up by `install.sh --expose-domain <domain>`. The URL is `https://<name>--<project>.<domain>`.

**Exposed URLs are public, with no authentication.** Anyone who has the link can reach the app. Always pass that warning on to the user.

## Usage

| Command | What it does |
|---|---|
| `/expose <port>` | `up <port>`: publish the port; the name defaults to the port, so `/expose 3000` gives `3000--<project>.<domain>` |
| `/expose <port> --name <n>` | `up <port> --name <n>`: publish under a chosen name (`web` gives `web--<project>.<domain>`) |
| `/expose <port> --project <p>` | override the project part (default: the repo's main folder name, the same in every worktree) |
| `/expose list` | `list`: NAME, PROJECT, PORT, URL, UP (UP = something listens on the port) |
| `/expose down <name\|port>` | `down`: remove that exposure (a port removes every exposure of it in the project) |
| `/expose url <name>` | `url`: print the URL again and copy it to the clipboard again |

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
```

Run it from the project directory so the default project name is right.

## What to tell the user

- After `up` or `url`: relay the **public / no-authentication warning line** and the **URL** (always the last line of output). Relay the clipboard line from stderr as is: `copied to the clipboard via tmux …` / `… via the terminal …` means the URL is on the user's clipboard; `not copied …` means it is not, so do not claim it was. If stderr says nothing is listening on the port yet, pass that on too. Do not try to open a browser.
- After `list`: show the table as-is.
- After `down`: say what was removed, or that nothing matched (that is not an error).
- Remind the user to bind dev servers to `127.0.0.1`, not `0.0.0.0`; otherwise the app may also be reachable directly at `<server-ip>:<port>`, bypassing the proxy.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | ok (including "nothing matched") | relay the output |
| 2 | bad usage, e.g. invalid port (1–65535, not 443) or name | fix the arguments |
| 3 | expose is not configured | tell the user to run `install.sh --expose-domain <domain>` from the tmux-opsx checkout |
| 4 | the proxy is not running | relay the printed start command (e.g. `sudo systemctl start tmux-opsx-caddy`); do not run sudo yourself |
| 1 | anything else | relay the error |
