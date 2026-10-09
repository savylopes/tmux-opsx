# Tasks

## 1. opsx dev core

- [ ] 1.1 Add `skills/opsx-run/opsx-dev.sh`: checkout and project resolution (git toplevel, main checkout via `git rev-parse --git-common-dir`, `<name>` rules and sanitising), `dev.yaml` parsing (flat keys, repeatable `setup`/`cache`, image/dockerfile exclusivity, unknown-key warning), and the missing-dev.yaml / missing-docker errors; verify with `bash -n` and shellcheck
- [ ] 1.2 Implement container creation (`--entrypoint sleep … infinity`, `-d`, `--network host`, same-path checkout and main `.git` mounts, home and cache volumes, project/checkout/hash labels), one-time `chown` of volumes as root, `setup:` lines as the user with removal on failure, Dockerfile build tagged by content hash, and recreation on hash change; verify with a fake docker that records arguments
- [ ] 1.3 Implement `opsx dev <cmd>` (`exec -u uid:gid -w <cwd> -e HOME=/opsx-home`, `-it` only when stdin and stdout are TTYs, argv passed as separate words, exit status returned), `--shell`, `--status`, `--rm` (dev + preview container) and `--rm --all` (by project label, volumes kept); add `dev` to the `opsx` launcher; verify `opsx help` lists `dev`
- [ ] 1.4 Add `tests/test-dev.sh` (scratch repos with a worktree on `opsx/add-auth`, fake `docker` logging every call and failing on demand) covering: both/neither image keys, unknown key, missing dev.yaml, missing docker, naming for change/main, create once + exec twice, create arguments, exec user/workdir/argv/exit status, no `-t` when piped, setup failure removes container, setup once, Dockerfile built once, recreate on dev.yaml change, `--rm` with nothing, `--rm --all` keeps volumes; verify `bash tests/test-dev.sh` passes with no FAIL lines

## 2. Preview and cleanup integration

- [ ] 2.1 In `opsx-preview.sh`, when the checkout has `.opsx/dev.yaml`, run `install` and the launch command through a preview container (`docker run --rm --name opsx-dev-<project>-<name>-preview`, same image/mounts/user/host network, `PORT` and `HOST=127.0.0.1` inside) and make `stop`/`stop --all` remove it; leave the host path unchanged otherwise; verify with `bash -n` and shellcheck
- [ ] 2.2 Make `opsx-window.sh close <change>` / `close --all` and `opsx-land.sh` call `opsx-dev.sh --rm` (change) / `--rm --all` (project), never failing on errors or a missing docker; verify with `bash -n` and shellcheck
- [ ] 2.3 Add cases: `tests/test-preview.sh` containerised preview run arguments, stop removes the preview container, host preview never calls docker; `tests/test-dev.sh` close removes the dev container and close without docker behaves as before; verify both scripts pass with no FAIL lines

## 3. Agents and docs

- [ ] 3.1 Add a "Toolchain" paragraph to `agents/opsx-applier.md`, `opsx-eval.md`, `opsx-reviewer.md`, `opsx-security.md` and `opsx-qa.md`: with `.opsx/dev.yaml`, run builds, tests, package managers and the app through `opsx dev`, never install a toolchain on the host, and retry through `opsx dev` if a host command is missing; verify by grepping each file for `.opsx/dev.yaml` and `opsx dev`
- [ ] 3.2 Document `opsx dev` in `README.md` (commands, `dev.yaml` keys, `dockerfile:`, `cache:`, naming and lifetime, cleanup by close/land, volume cleanup, Linux host-networking assumption, tests list) and in `skills/opsx-run/SKILL.md` (Notes); verify the documented `opsx dev --status` runs as written against the fake docker

## 4. Integration

- [ ] 4.1 With real Docker available, run `opsx init` then `opsx dev go version` in a scratch Go repo (or record UNVERIFIABLE when Docker is absent), confirm the container is reused on a second call and removed by `opsx dev --rm`; then run `bash tests/test-dev.sh`, `bash tests/test-preview.sh` and `bash tests/test-init.sh` and confirm all pass
