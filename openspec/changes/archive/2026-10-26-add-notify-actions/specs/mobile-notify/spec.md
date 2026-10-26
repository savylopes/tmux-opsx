## MODIFIED Requirements

### Requirement: ntfy credentials
`install.sh` SHALL create one ntfy user `opsx` with a generated password, a random topic the user may read and write, and a publish token, and SHALL keep them on a re-run while they still work. It SHALL also create a reply topic `<topic>-reply` that `opsx` may read, and a user `opsx-reply` with write-only access to that topic and a token, kept the same way.

#### Scenario: Re-run keeps the credentials
- **WHEN** `install.sh --expose-domain dev.example.com` runs a second time
- **THEN** `notify.env` has the same `NTFY_TOKEN` and `NTFY_TOPIC`, and no second ntfy user is created

#### Scenario: Reply user is write-only
- **WHEN** `install.sh --expose-domain dev.example.com` runs in a scratch HOME with a fake `ntfy` that logs its calls
- **THEN** the log grants `opsx-reply` write-only (`wo`) access to the reply topic and nothing else, and grants `opsx` read access to it

#### Scenario: Re-run keeps the reply credentials
- **WHEN** `install.sh --expose-domain dev.example.com` runs a second time
- **THEN** `notify.env` has the same `NTFY_REPLY_TOPIC` and `NTFY_REPLY_TOKEN`, and no second `opsx-reply` user is created

### Requirement: Notification config
The push helper SHALL read its settings only from `~/.config/tmux-opsx/notify.env` (`NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`, and optionally `NTFY_REPLY_TOPIC`, `NTFY_REPLY_TOKEN`), which `install.sh` writes with mode 600. The file SHALL also work when written by hand for any ntfy server. The tokens and the ntfy password SHALL never be written to the repository, to a window prompt, or to stdout, except `opsx notify info --show-password` prints the password.

#### Scenario: Private file
- **WHEN** `install.sh --expose-domain dev.example.com` writes `notify.env`
- **THEN** the file's mode is `600`

#### Scenario: Info hides the password
- **WHEN** `opsx notify info` runs
- **THEN** it prints the ntfy URL, the user `opsx` and the topic, and does not print the password or the token

#### Scenario: Info hides the reply token
- **WHEN** `opsx notify info` runs with `NTFY_REPLY_TOKEN` set
- **THEN** it prints the reply topic and does not print the reply token

## ADDED Requirements

### Requirement: Reply listener unit
`install.sh --expose-domain <d>` on Linux SHALL install and enable a systemd user unit `tmux-opsx-notify-listen` that runs `opsx-notify.sh listen` as the user and restarts it on failure. `--skip-notify` and `--uninstall` SHALL stop and remove it. On macOS it SHALL print the command to run the listener instead.

#### Scenario: Unit installed
- **WHEN** `install.sh --expose-domain dev.example.com` runs in a scratch HOME with a fake `systemctl`
- **THEN** `~/.config/systemd/user/tmux-opsx-notify-listen.service` exists, its `ExecStart` runs the installed `opsx-notify.sh listen`, and the fake `systemctl` was called with `--user enable --now tmux-opsx-notify-listen`

#### Scenario: Unit removed
- **WHEN** `install.sh --uninstall` runs after that install
- **THEN** the unit file is gone and the fake `systemctl` was called with `--user disable --now tmux-opsx-notify-listen`
