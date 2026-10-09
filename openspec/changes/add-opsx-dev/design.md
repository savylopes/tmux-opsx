# Design

## Context

See proposal.md for why. Relevant current state:

- add-opsx-init ships the `opsx` launcher (dispatching to skill scripts) and writes `.opsx/dev.yaml` with `image:` and `setup:` lines.
- Changes are applied in worktrees `../wt-<change>` on branch `opsx/<change>`; a worktree's `.git` is a file pointing into the main repo's `.git/worktrees/`.
- `opsx-preview.sh` runs the app in a tmux window as a process group (killed by `stop`), with a launch script that exports `PORT` and `HOST=127.0.0.1`; `expose.sh` requires loopback binds.
- `opsx-window.sh close` and `opsx-land.sh` already stop previews before removing windows or worktrees; that is the hook point for container cleanup.

## Goals / Non-Goals

**Goals:**
- Toolchain parity without host installs: same paths, same file ownership, same ports.
- Fast repeated commands (long-lived container, cached volumes).
- Zero effect on repos without `.opsx/dev.yaml`.

**Non-Goals:**
- Isolation or sandboxing of agents (they stay on the host).
- Running agent CLIs, tmux or the browser MCP in containers.
- macOS/Windows parity: host networking is assumed (Linux Docker).
- Forcing agents to use the container (instructions only; a hook can come later).
- `devcontainer.json` support.

## Decisions

**1. Long-lived container + `docker exec`.** Created with `--entrypoint sleep <image> infinity` so any image works, then each command is an `exec`. *Alternative:* `docker run --rm` per command. Rejected: pays start-up and setup on every call.

**2. Same-path mounts.** Mount the checkout at its absolute host path and the main repo's `.git` at its absolute host path. Tool output, test failures and `go build` VCS stamping then refer to real host paths, and the worktree's `.git` file resolves.

**3. Host uid/gid, writable home volume.** The container runs as root only for setup plumbing (`chown` of the home and cache volumes, once at creation); every user command, including `setup:` lines, runs with `-u <uid>:<gid>` and `HOME=/opsx-home` on a per-project volume `opsx-dev-<project>-home`. Files written to the bind mount are owned by the user; `pip install --user`, npm and Go caches persist across changes of the same project.

**4. Host networking.** `--network host` makes an app bound to `127.0.0.1:$PORT` in the container reachable on the host loopback, which is exactly what `/expose` requires, and avoids port-mapping bookkeeping for previews.

**5. Config hash label.** Label `opsx.dev.hash` = sha256 of `dev.yaml` (+ Dockerfile). Mismatch → `rm -f` + recreate + setup. Dockerfile images are tagged `opsx-dev/<project>:<sha256(Dockerfile)[:12]>` and built only when `docker image inspect` fails.

**6. Preview as its own container.** The preview app runs via a foreground `docker run --rm --name opsx-dev-<project>-<name>-preview …` inside the existing preview window, so logs still reach the window and log file. Killing the window's process group does not stop the container, so `stop` also runs `docker rm -f` on it. *Alternative:* `exec` inside the dev container. Rejected: an exec'd process cannot be stopped reliably from the host.

**7. One script, launcher dispatch.** `skills/opsx-run/opsx-dev.sh` holds everything; `opsx dev` dispatches to it; `opsx-preview.sh`, `opsx-window.sh` and `opsx-land.sh` call it by path next to themselves for cleanup (`--rm`) and for the container-name and image helpers.

## Risks / Trade-offs

- [Agents ignore the instruction and call `go` on the host] → it fails fast without the toolchain; the agent files say to retry with `opsx dev`. A PreToolUse hook is a possible follow-up.
- [Images without `sh`, `chown` or `sleep` (distroless)] → documented: use a dev image or a `dockerfile:`.
- [Host networking unavailable (Docker Desktop on macOS)] → out of scope; the docs state the Linux assumption.
- [Named volumes grow over time] → `--rm` keeps them on purpose; the README shows `docker volume rm` for cleanup.
- [uid without a passwd entry in the image confuses some tools] → `HOME` is set explicitly; most toolchains only need `HOME`.

## Migration Plan

Additive. Repos without `.opsx/dev.yaml` are untouched. After landing, re-run `./install.sh` so the launcher and scripts are updated. Rollback: delete `.opsx/dev.yaml` in a repo (previews and agents fall back to the host) and `opsx dev --rm --all`.
