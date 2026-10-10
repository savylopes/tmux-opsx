# dev-container Specification

## Purpose
Runs a repo's toolchain (Go, Python, Node, or a custom image) in a per-checkout Docker container declared in `.opsx/dev.yaml`, so neither the user nor the agents need that toolchain installed on the host.

## Requirements

### Requirement: dev.yaml keys
`.opsx/dev.yaml` SHALL be read as flat `key: value` lines with `#` comments. Keys: `image` or `dockerfile` (exactly one required), `setup` and `cache` (each may repeat, one value per line). Both or neither of `image`/`dockerfile` SHALL fail with a non-zero exit naming the problem; unknown keys SHALL be a warning.

#### Scenario: Both image and dockerfile
- **WHEN** `.opsx/dev.yaml` has `image: golang:1.22` and `dockerfile: .opsx/Dockerfile` and `opsx dev true` runs
- **THEN** it exits non-zero, the message names `image` and `dockerfile`, and the fake docker was not called with `run`

#### Scenario: Unknown key
- **WHEN** `.opsx/dev.yaml` has `image: golang:1.22` and `colour: blue`
- **THEN** `opsx dev true` warns about `colour` and still runs the command

### Requirement: No dev.yaml or no docker
`opsx dev` SHALL exit non-zero with a message naming `opsx init` when the checkout has no `.opsx/dev.yaml`, and with a message naming docker when no `docker` command is on PATH. Neither case SHALL create anything.

#### Scenario: Missing dev.yaml
- **WHEN** `opsx dev go version` runs in a checkout without `.opsx/dev.yaml`
- **THEN** it exits non-zero and the message mentions `opsx init`

#### Scenario: Missing docker
- **WHEN** `.opsx/dev.yaml` exists and no `docker` is on PATH
- **THEN** `opsx dev go version` exits non-zero and the message mentions docker

### Requirement: One container per checkout
The container for a checkout SHALL be named `opsx-dev-<project>-<name>`, where `<project>` is the main checkout's folder name and `<name>` is `<change>` for a worktree on branch `opsx/<change>`, `main` for the main checkout, and the worktree folder name otherwise, lowercased with characters outside `[a-z0-9_.-]` replaced by `-`. It SHALL be created on first use and reused afterwards.

#### Scenario: Change worktree
- **WHEN** `opsx dev true` runs twice in the worktree of branch `opsx/add-auth` of project `shop`
- **THEN** the fake docker created `opsx-dev-shop-add-auth` once and ran `exec` in it twice

#### Scenario: Main checkout
- **WHEN** `opsx dev true` runs in the main checkout of `shop`
- **THEN** the container name is `opsx-dev-shop-main`

### Requirement: Container shape
The container SHALL be created detached with host networking, the checkout mounted read-write at its own absolute path, the main repo's `.git` directory mounted at its own absolute path, a per-project named volume as `HOME`, one named volume per `cache:` path, labels identifying the project and checkout, and a command that keeps it running regardless of the image's entrypoint.

#### Scenario: Create arguments
- **WHEN** `opsx dev true` creates the container for checkout `/w/wt-add-auth` with `cache: /go/pkg/mod`
- **THEN** the recorded `docker run` has `-d`, `--network host`, a `-v /w/wt-add-auth:/w/wt-add-auth` mount, a mount of the main repo's `.git` at the same path, a named volume on `/go/pkg/mod`, and a label with the checkout path

### Requirement: Commands run as the user in the same directory
`opsx dev <cmd> [args]` SHALL run the command with `docker exec` as the host user's uid:gid, in the container path equal to the host current directory, with `HOME` set to the home volume, attaching a TTY only when stdin and stdout are terminals. Arguments SHALL be passed without shell re-interpretation and the command's exit status SHALL be returned.

#### Scenario: Exit status and workdir
- **WHEN** the fake docker's `exec` exits 3 and `opsx dev go test ./pkg` runs from `/w/wt-add-auth/pkg`
- **THEN** `opsx dev` exits 3 and the recorded `exec` has `-u <uid>:<gid>`, `-w /w/wt-add-auth/pkg`, and the arguments `go test ./pkg` as separate words

#### Scenario: Not a terminal
- **WHEN** `opsx dev true` runs with stdout redirected to a file
- **THEN** the recorded `exec` has no `-t` flag

### Requirement: Setup on creation
After creating a container, `opsx dev` SHALL make the home and cache volumes writable by the user and run each `setup:` line, in order, as the user in the checkout root. A failing setup line SHALL remove the container and exit non-zero naming the line. Setup SHALL NOT run again for a reused container.

#### Scenario: Setup failure
- **WHEN** `dev.yaml` has `setup: go mod download` and the fake docker fails that exec
- **THEN** `opsx dev true` exits non-zero, mentions `go mod download`, and the fake docker recorded `rm -f` for the container

#### Scenario: Setup once
- **WHEN** `opsx dev true` runs twice
- **THEN** the setup command was executed once

### Requirement: Dockerfile builds
With `dockerfile: <path>`, the image SHALL be built from that file with the checkout root as context and tagged `opsx-dev/<project>:<hash>`, where the hash covers the Dockerfile's contents. An image with that tag that already exists SHALL NOT be rebuilt. A failed build SHALL exit non-zero and create no container.

#### Scenario: Build once
- **WHEN** `dev.yaml` has `dockerfile: .opsx/Dockerfile` and `opsx dev true` runs twice
- **THEN** the fake docker recorded one `build` with a tag starting `opsx-dev/<project>:`

### Requirement: Recreate on config change
Each container SHALL carry a label with a hash of `.opsx/dev.yaml` and the Dockerfile (when used). When the current hash differs, `opsx dev` SHALL remove the container and create a new one, running setup again, before running the command.

#### Scenario: dev.yaml edited
- **WHEN** a container exists for the checkout and `.opsx/dev.yaml` changes from `golang:1.22` to `golang:1.23`
- **THEN** the next `opsx dev true` records `rm -f` for the old container and a `run` with `golang:1.23`

### Requirement: Shell, status and removal
`opsx dev --shell` SHALL open an interactive shell in the checkout's container. `opsx dev --status` SHALL print the container name, image and state, or that none exists. `opsx dev --rm` SHALL remove the checkout's dev and preview containers, and `opsx dev --rm --all` every opsx container of the project; both SHALL exit 0 when nothing exists. Volumes SHALL be kept.

#### Scenario: Remove when none
- **WHEN** no container exists and `opsx dev --rm` runs
- **THEN** it exits 0

#### Scenario: Remove keeps volumes
- **WHEN** `opsx dev --rm --all` runs
- **THEN** the fake docker recorded no `volume rm`

### Requirement: Cleanup from opsx-run
`opsx-window.sh close <change>` and `opsx-land.sh` SHALL remove the change's dev and preview containers, and `opsx-window.sh close --all` every opsx container of the project. A failure to remove, or a missing docker, SHALL NOT make them fail.

#### Scenario: Close removes container
- **WHEN** a dev container exists for change `c1` and `opsx-window.sh close c1` runs with the fake docker
- **THEN** the fake docker recorded `rm -f opsx-dev-<project>-c1`

#### Scenario: No docker on close
- **WHEN** no `docker` is on PATH and `opsx-window.sh close c1` runs
- **THEN** it exits as it would without this feature

### Requirement: Agents use the dev container
The applier, eval, reviewer, security and qa agent definitions SHALL instruct the agent, when the checkout has `.opsx/dev.yaml`, to run builds, tests, package managers and the app through `opsx dev`, and never to install a language toolchain on the host.

#### Scenario: Agent text
- **WHEN** each `agents/opsx-*.md` is read
- **THEN** it mentions `.opsx/dev.yaml` and `opsx dev`

### Requirement: Documentation
`README.md` and `skills/opsx-run/SKILL.md` SHALL document `opsx dev` (commands, container naming and lifetime), the `dev.yaml` keys, `dockerfile:` builds, and that a Linux host with Docker is assumed for host networking.

#### Scenario: Docs
- **WHEN** `README.md` is read
- **THEN** it mentions `opsx dev --shell`, `dockerfile:` and `cache:`
