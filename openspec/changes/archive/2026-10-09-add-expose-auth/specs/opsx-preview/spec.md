# Spec Delta

## ADDED Requirements

### Requirement: Share a preview
`opsx-preview.sh share <change>|--main [--for <recipient>] [--ttl <dur>] [--list] [--revoke <recipient|id>]` SHALL run `expose.sh share` for that preview's exposure with the same options and relay its output and exit code. It SHALL exit non-zero, saying no preview is running, when the preview has no record.

#### Scenario: Preview shared
- **WHEN** `add-auth` has a running preview in project `shop` and `opsx-preview.sh share add-auth --for acme` runs
- **THEN** it exits 0 and its last line is `https://add-auth--shop.<domain>/?opsx_share=<token>`

#### Scenario: No preview
- **WHEN** `add-auth` has no running preview and `opsx-preview.sh share add-auth` runs
- **THEN** it exits non-zero saying no preview is running, and no token is created

### Requirement: Publicly bound app fails the preview
When `expose.sh up` refuses the preview's port because the app listens on a non-loopback address, `opsx-preview.sh up` SHALL stop the app, close its window, exit non-zero and relay the refusal, which names the address and says to bind to `127.0.0.1`.

#### Scenario: App binds 0.0.0.0
- **WHEN** `.opsx/preview.yaml` has `cmd: python3 -m http.server $PORT --bind 0.0.0.0` and `opsx-preview.sh up add-auth` runs
- **THEN** it exits non-zero with `127.0.0.1` in its output, no `@opsx_preview=add-auth` window remains, and `expose.sh list` has no `add-auth` entry

## MODIFIED Requirements

### Requirement: ops-qa uses the preview
Before dispatching ops-qa (in `/opsx-run <change> qa` and in the `apply --validate` QA step), the dispatcher SHALL run `opsx-preview.sh up <change>` and, on success, `opsx-preview.sh share <change> --for ops-qa --ttl 1d`, and pass that share link to ops-qa as the app URL. ops-qa SHALL test a given preview URL, opening it first so its browser keeps the login cookie, and SHALL NOT start its own server. When either script exits non-zero (expose not configured, or the preview failed), ops-qa SHALL keep its current behaviour, with the reason stated in its inputs.

#### Scenario: QA prompts start the preview
- **WHEN** the installed `opsx-run/SKILL.md` and ops-qa definition are read
- **THEN** both the `qa` and the `apply --validate` dispatcher prompts tell the window to run `opsx-preview.sh up <change>` and then `opsx-preview.sh share <change> --for ops-qa --ttl 1d` before ops-qa and to pass the share link, and the ops-qa definition says to use a given preview URL rather than starting the app

#### Scenario: QA fallback
- **WHEN** expose is not configured and `/opsx-run add-auth qa` runs
- **THEN** ops-qa is dispatched without a preview URL and starts the app as before
