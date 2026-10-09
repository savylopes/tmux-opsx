# Spec Delta

## ADDED Requirements

### Requirement: Preview in the dev container
When the previewed checkout has `.opsx/dev.yaml`, `opsx-preview.sh` SHALL run the recipe's `install` and `cmd` in a container `opsx-dev-<project>-<name>-preview` started from the dev image with the same mounts, user and host networking as the dev container, with `PORT` and `HOST=127.0.0.1` set inside. `stop` SHALL remove that container. Without `.opsx/dev.yaml` the preview SHALL run on the host as before.

#### Scenario: Containerised preview
- **WHEN** a checkout with `.opsx/dev.yaml` (`image: node:20`) and `.opsx/preview.yaml` (`cmd: npm run dev`) is previewed with a fake docker
- **THEN** the fake docker recorded a `run` for `opsx-dev-<project>-<name>-preview` with image `node:20`, `--network host`, `PORT` in its environment and `npm run dev` as the command

#### Scenario: Stop removes it
- **WHEN** that preview is stopped with `opsx-preview.sh stop <change>`
- **THEN** the fake docker recorded `rm -f opsx-dev-<project>-<name>-preview`

#### Scenario: Host preview unchanged
- **WHEN** a checkout without `.opsx/dev.yaml` is previewed
- **THEN** the fake docker was not called
