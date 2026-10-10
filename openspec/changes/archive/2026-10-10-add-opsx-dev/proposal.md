# Proposal

## Why

Working on a Go, Python or Node project today means installing that toolchain, at the right version, on the host, for the user and for every agent that builds or tests a change. The user wants the host to stay clean: each repo declares its toolchain once (`.opsx/dev.yaml`, written by add-opsx-init) and everything that needs it runs in a container, while the agents themselves stay on the host with their logins, MCP and tmux.

## What Changes

- New `opsx dev` subcommand (on the `opsx` launcher from add-opsx-init) that runs a command in the checkout's dev container: `opsx dev <cmd> [args]`, `opsx dev --shell`, `opsx dev --status`, `opsx dev --rm [--all]`.
- One long-lived container per checkout (change worktree or main checkout), created on first use from `.opsx/dev.yaml`: either `image:` or `dockerfile:` (built and tagged by content hash, rebuilt only when it changes). `setup:` lines run once at creation; `cache:` paths and a per-project home are named volumes.
- The checkout is mounted at the same absolute path, the main repo's `.git` too, the command runs as the user's uid/gid with host networking, so paths, file ownership, git and `127.0.0.1` ports behave as on the host.
- A changed `dev.yaml` or Dockerfile recreates the container on next use.
- Previews: when the previewed checkout has `.opsx/dev.yaml`, the recipe's `install` and `cmd` run in a preview container from the same image; `stop` removes it.
- `opsx-run` cleanup: `close`, `close-all` and `land` remove the change's dev and preview containers; failures never fail them.
- Agent definitions (applier, eval, reviewer, security, qa) tell agents to run builds, tests, package managers and the app through `opsx dev` when `.opsx/dev.yaml` exists, and never to install a toolchain on the host.
- Docker is optional: without `.opsx/dev.yaml` nothing changes; with it but no `docker`, `opsx dev` fails with a clear message.

## Capabilities

### New Capabilities
- `dev-container`: the per-checkout toolchain container — `opsx dev` commands, `dev.yaml` keys, image/Dockerfile handling, mounts, user, networking, caches, recreation on config change, cleanup from opsx-run, and agent instructions.

### Modified Capabilities
- `opsx-preview`: a checkout with `.opsx/dev.yaml` runs its preview install and app in a container from the dev image, removed by `stop`.

## Impact

- New `skills/opsx-run/opsx-dev.sh`; the `opsx` launcher gains `dev`.
- `skills/opsx-run/opsx-preview.sh`: container path for install/cmd and stop.
- `skills/opsx-run/opsx-window.sh` (`close`) and `opsx-land.sh`: remove the change's containers.
- `agents/opsx-*.md`: toolchain instructions.
- `skills/opsx-run/SKILL.md`, `README.md`: document `opsx dev` and `.opsx/dev.yaml`.
- `tests/test-dev.sh` (new) with a fake `docker` that records calls; `tests/test-preview.sh` gains a container case.
- Depends on add-opsx-init for the `opsx` launcher.
