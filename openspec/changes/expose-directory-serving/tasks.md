# Tasks

## 1. expose.sh: directory exposures

- [x] 1.1 Parse `--dir <path>`, `--hide <glob>` (repeatable) and `--csp <policy>` on `up`; with `--dir` forbid a positional port, require `--name`, validate absolute + existing + readable directory and refuse `/` and `$HOME` (exit 2, nothing written); verify in `tests/test-expose.sh` each refusal leaves no route and no record
- [x] 1.2 Extend the record format (`DIR=`, `HIDE=` lines, `CSP=`), `read_record` (valid with a port, or with an empty port and an absolute `DIR`), `write_record_tmp`/`rewrite_record`; verify in `tests/test-expose.sh` that `up --dir` writes `DIR=` and no `PORT=`, and that a port record still reads as before
- [x] 1.3 Split `route_json` so the final handler chain is a parameter: `strip + reverse_proxy` for ports, `headers (CSP default or --csp, no-referrer, nosniff, DENY, no-cache) + file_server (root, index_names, hide [".*","*/.*", --hide…], etag_file_extensions [".sha256"])` for directories; verify in `tests/test-expose.sh` that the stored route has the `file_server` handler with the right `root` and `hide`, the headers handler with the default policy, and with `--csp` the custom one; and that the login, share and 401 branches are present as for a port
- [x] 1.4 `cmd_up` output (`exposed <dir> at <url>`, no bind note), `cmd_list`/`--json` directory rows (PORT `-`, UP from `-d -r`, BIND `dir`, `port` null, `dir` path), `cmd_down` by name, reconcile/`down` messages naming the directory; verify in `tests/test-expose.sh` the table row, the JSON object keys (`dir` present on every object, null for ports), `down explain` removing the record and route, and the restore message after a fake-proxy restart
- [x] 1.5 Add the `OPSX_EXPOSE_SERVER` override (default `expose`) and a real-Caddy serving test in `tests/test-expose.sh` (skipped with a message when no caddy binary is found): throwaway config on a loopback HTTP port, `up --dir` a scratch tree, then with the owner cookie assert 200 on `/1/`, 404 on `/.secret`, `/1/.meta`, `/1/manifest.tsv` (hidden), `/1/index.html.sha256`, and a directory without index; the redirect `/1?lang=pt` → `/1/?lang=pt`; all five headers; the ETag equals the sidecar content and changes on a same-length same-second rewrite; 401 without a cookie; a share link sets its cookie and is then served; verify the test passes on this machine
- [x] 1.6 Update `skills/expose/SKILL.md` (usage rows for `--dir`, `--hide`, `--csp`; what a directory exposure serves and hides; the sidecar ETag) and the `expose.sh` header; verify `tests/test-expose.sh`'s skill-documentation check covers the three new options and `shellcheck skills/expose/expose.sh` is clean

## 2. explain.sh: drop the server

- [x] 2.1 Remove the server, port, Host, window, record and second-tmux-server code and files (`write_server`, `.serve.py`, `launch.sh`, `.server`, `.hosts`, `pick_port`, `head_ok`, `start_server`, `server_alive`, `kill_*`, `rec_*`, `cur_socket`, `set_hosts`, `expose_server`), keep the lock for id allocation; add `ensure_exposure` calling `expose.sh up --dir "$ROOT" --name explain --hide manifest.tsv --hide '*.sha256' --csp "$EXPLAIN_CSP"` (constant built from `MERMAID_URL` and the two font hosts), with the exit-3/no-expose path setting `BASE_URL=file://$ROOT` and the hint; verify in `tests/test-explain.sh` that the fake `expose.sh` log has `up --dir <root> --name explain --hide manifest.tsv --hide *.sha256 --csp …`, that no `@opsx_explain` window and no `.server`/`launch.sh`/`.serve.py` appear, and that with the exit-3 fake the output has the `# local only` line and a `file://` page path while the fork still opens
- [x] 2.2 `.reindex` writes `index.html.sha256` (quoted sha256, atomic) for the library and every page on each run; `stop` runs `expose.sh down explain` and removes leftover `.server`, `.hosts`, `launch.sh`, `.serve.py`; `list` prints `exposed: <url>` or `exposed: no` from `expose.sh list --json`; `serve` prints the URL; verify in `tests/test-explain.sh` that after a page write `<root>/1/index.html.sha256` holds the quoted hash of `index.html`, that two same-length writes give different sidecars, that `stop` logged `down explain` and kept `1/index.html`, and that `list` shows the pages and the exposure line
- [x] 2.3 Rework `tests/test-explain.sh`: drop server, port, 421, Host and second-tmux assertions; keep brief, template, ids, library, share and stop assertions; serve `$ROOT` for the Chromium check with a test-local `python3 -m http.server` on a scratch port; verify `bash tests/test-explain.sh` and `shellcheck skills/explain/explain.sh` are clean
- [x] 2.4 Update `skills/explain/SKILL.md` (no server or window; `/explain stop` = `expose.sh down explain`; without `/expose` the page is a file path; `list` output) and the `explain.sh` header; verify the file no longer mentions `127.0.0.1`, `ox >explain` or `.serve.py`

## 3. Documentation

- [x] 3.1 README: Expose section gains `--dir`, `--hide`, `--csp` and the serving rules; Explain section loses the server, window, port and Host paragraphs and gains the directory exposure, the sidecar ETag and the no-expose behaviour; overview tree line updated; verify README mentions `up --dir`, `--hide`, `--csp`, `index.html.sha256` and no longer `ox >explain` or `.serve.py`

## 4. Integration

- [x] 4.1 Run `bash tests/test-expose.sh`, `bash tests/test-explain.sh`, `bash tests/test-fork.sh`, `shellcheck` on `expose.sh` and `explain.sh`, and `openspec validate expose-directory-serving --strict`; verify all pass
- [x] 4.2 Manual walk-through on this machine: `/explain stop` (removes the old port exposure and window), `/explain "x"`, open the URL on a phone through the owner link, confirm the page, a `manifest.tsv` 404, a rewrite reloading within a few seconds, `/explain share --ttl 1h` opening the library, `/explain list`, `/explain stop`; record the outcome in the apply report

## Workflow follow-up

- Archive `restyle-explain-page` before this change (shared CSP requirement and tests).
- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.
