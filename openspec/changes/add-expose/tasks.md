# Tasks

## 1. expose.sh core (no proxy yet)

- [ ] 1.1 Create `skills/expose/expose.sh` with a header usage comment, `help`, argument parsing for `up|down|list|url`, `--name`, `--project`, `--json`, and the exit codes 0/1/2/3/4 from design.md; verify `bash -n`, `shellcheck`, and that `expose.sh help` lists every subcommand and option
- [ ] 1.2 Implement config loading from `${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/expose.env`, exiting 3 with a message naming `install.sh --expose-domain` when it is missing, before any network call; verify with a scratch HOME that `expose.sh up 3000` exits 3 and prints that text
- [ ] 1.3 Implement port validation (integer 1–65535, not 443; exit 2) and hostname labelling: per-part normalisation, the default name is the port, the default project comes from the git common dir or else `$PWD`, `--project` overrides, and the 63-character cap with a `sha256` 6-hex suffix; verify with `tests/test-expose.sh` cases for defaults, the worktree project name, `My_App`/`Foo.Bar` → `my-app--foo-bar`, long-name truncation, determinism, and two distinct long names
- [ ] 1.4 Implement state records in `${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/expose/routes/<label>.env` (written with `mv`) and `list` / `list --json` with an UP probe through `bash /dev/tcp`; verify with test cases for a port with no listener (`up` no/false) and one with a `python3 -m http.server` listener (yes/true)

## 2. Proxy integration

- [ ] 2.1 Add a fake Caddy admin server for tests (`tests/fake-caddy-admin.py`, a unix-socket HTTP server that keeps routes in memory and supports `GET /config/...`, `POST .../routes`, `GET/DELETE /id/<id>`); verify it starts, and that `curl --unix-socket` can add, read and delete a route
- [ ] 2.2 Implement the admin client with `curl --unix-socket` (`$OPSX_EXPOSE_ADMIN` overrides the socket): `up` adds a route with `@id` `expose-<label>` that matches the host `<label>.<domain>` and reverse-proxies to `127.0.0.1:<port>`, replacing any route with the same id; `down` deletes routes by name or by port; exit 4 with a "proxy not running" message, writing no state, when the socket can't be reached; verify with test cases for publish, name moved to a new port (one route), down by name, down by port, down of nothing (exit 0), and proxy down (exit 4, no state file)
- [ ] 2.3 Implement reconciliation: at the start of every subcommand, re-add each recorded label whose route id is missing; verify with a test that clears the fake server's routes, runs `list`, and finds the route restored
- [ ] 2.4 Implement the URL handoff: the public-access warning line, then the URL as the last line, as an OSC 8 link only when stdout is a terminal, copied with `tmux set-buffer -w` when tmux is reachable (recovering `$TMUX` the way `opsx-window.sh` does) or else raw OSC 52 to a writable `/dev/tty`; `url <name>` reprints; verify that redirected output has no ESC bytes, and that on a private tmux server (`tmux -L`) `show-buffer` returns the URL after `up`

## 3. Skill

- [ ] 3.1 Write `skills/expose/SKILL.md` (frontmatter name `expose`, a trigger description, `/expose <port> [--name n]`, `list`, `down`, `url`): it tells the agent to run the script, relay the warning and the URL, and mentions binding apps to `127.0.0.1`; verify by grepping for `up`, `down`, `list`, `url`, `--name` and `--project`

## 4. install.sh `--expose-domain`

- [ ] 4.1 Add `--expose-domain <d>` parsing and validation (strip a leading `*.`, refuse invalid names), add the token intake (`$CLOUDFLARE_API_TOKEN`, else a hidden `read -s` prompt on a terminal, else keep the stored token, else exit) to the prerequisites step so that failures happen before anything is installed, and document the flag in the header comment and `--help`; verify in a scratch HOME that an invalid domain and a missing token each exit non-zero with nothing installed, and that `--help` shows the flag
- [ ] 4.2 Verify the token with Cloudflare's `/user/tokens/verify` (header sent through `curl -H @-`, skipped when `OPSX_EXPOSE_SKIP_VERIFY=1`), then write `expose.env` with `umask 077` through a temporary file and `mv`, in a mode-700 directory, with no `.bak`; verify the mode is 600, that a rerun without a token keeps the stored one, and that the token never appears in install.sh's output
- [ ] 4.3 Get Caddy: reuse `$OPSX_CADDY_BIN` or an installed binary that lists `dns.providers.cloudflare`, otherwise download from the Caddy build endpoint for the detected OS and arch into `~/.local/share/tmux-opsx/bin/caddy`, check the module, and remove the binary and fail if it's missing; verify with a fake `caddy` on `$OPSX_CADDY_BIN` that nothing is downloaded, and with a fake that lacks the module that install fails
- [ ] 4.4 Write the base Caddy JSON config (`*.<domain>` automation policy with the Cloudflare DNS challenge, an `expose` server on `:443` only, redirects off, the admin API on the unix socket in a mode-700 state dir) and the systemd unit; as root, install and enable the unit; otherwise print the exact `sudo` command; on macOS print the `caddy run` command; verify with `jq` that the config has only `:443`, the wildcard subject and a unix admin socket, that a non-root run makes no `sudo` or `systemctl` call (PATH shims that log any call), and that the command is printed
- [ ] 4.5 Add the DNS check (`getent ahosts probe-<random>.<domain>` compared against this host's addresses; a warning on a missing or foreign record that mentions the DNS-only wildcard record, never fatal); verify with an unresolvable test domain that the warning is printed and install exits 0
- [ ] 4.6 Install `skills/expose/` into the six skill folders with an `install_expose_skill` helper modelled on `install_fork_skill` (`.bak` on overwrite, `chmod +x`), only when `--expose-domain` is set, and add item 9 to the header comment; verify that a scratch-HOME run creates all six `expose/` folders, that a rerun leaves identical files, and that a run without the flag creates none

## 5. Docs

- [ ] 5.1 Update the README: add `/expose` to the overview tree and Contents table, and add an Expose section covering setup (`--expose-domain`, the token scope `Zone:DNS:Edit`, the DNS-only `*.<domain>` record, the printed systemd step, port 443 in the provider firewall), usage, the public/no-auth warning, binding to `127.0.0.1`, the tmux `hyperlinks` hint for OSC 8, and the manual removal steps; verify that every command shown in the section runs as written against the fake admin server

## 6. Integration

- [ ] 6.1 Run `bash tests/test-expose.sh`, `bash tests/test-fork.sh` and `shellcheck skills/expose/expose.sh install.sh tests/test-expose.sh`, and a full scratch-HOME `install.sh --expose-domain dev.example.com` with `OPSX_EXPOSE_SKIP_VERIFY=1` and a fake `OPSX_CADDY_BIN`; verify that all pass and that a run without the flag shows no expose output

## Workflow follow-up

- On the real VPS: create the Cloudflare token and the DNS-only `*.<domain>` record, run `install.sh --expose-domain <domain>`, run the printed systemd command, open 443 in the provider firewall, then `/expose 8000` against `python3 -m http.server` and open the URL from another network.
- Land `add-expose` before applying `add-opsx-preview`.
