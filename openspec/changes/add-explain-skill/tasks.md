# Tasks

## 1. fork.sh: page directory and the `page` command

- [x] 1.1 Add `--page-dir <dir>` to `fork.sh open`: validate it is an absolute path, record `page_dir=` in `meta` (empty without the flag), pass `FORK_PAGE_DIR` in the child env; verify in `tests/test-fork.sh` that `meta` has `page_dir=/x/3` and the fake CLI log has `FORK_PAGE_DIR=/x/3`, and that a fork opened without the flag has `page_dir=` and no such env line
- [x] 1.2 Implement `fork.sh page [--manifest]`: resolve the page dir from `$FORK_PAGE_DIR`, the process chain, or `meta`; refuse empty stdin (exit 2), non-fork (exit 1), no page dir (exit 4, message names `--page-dir`), unwritable target (exit 3); write via temp file + `mv -f` to `index.html` or `manifest.tsv`; print the path; verify in `tests/test-fork.sh` each exit code and that `index.html` is unchanged after a refused call
- [x] 1.3 After a successful `index.html` write, run `<page_dir>/../.reindex` when it exists and is executable, ignoring its exit status; document it in the `fork.sh` header; verify in `tests/test-fork.sh` with a `.reindex` that touches a marker file
- [x] 1.4 Add the page protocol section to the brief when `--page-dir` is set (write commands, label scheme `S P D T C N` and stability rules, manifest, Mermaid then SVG then ASCII, whole-page rewrites, first-reply confirmation, "report and stop when `page` is blocked", no markers); verify in `tests/test-fork.sh` that `brief.md` contains `fork.sh page`, `manifest.tsv` and the prefixes only when `--page-dir` was given
- [x] 1.5 Extend the Claude launch with a second allow rule `Bash(<fork.sh> page:*)` and a carve-out sentence naming both commands, keeping plan mode and no bypass flags; verify in `tests/test-fork.sh` that `launch.sh` has both rules for a page fork and only `return` otherwise, then verify with the real `claude` in a scratch dir that a plan-mode child can run `fork.sh page <<'EOF' … EOF` without a prompt (record the outcome in the apply report; if two rules fail, use one `Bash(<fork.sh>:*)` rule and update this task's note)
- [x] 1.6 Update `skills/fork/SKILL.md` (child-side `page` instructions, `--page-dir` in the open synopsis, the header comment's state layout with `page_dir`) and run `shellcheck skills/fork/fork.sh` plus the full `bash tests/test-fork.sh`; verify both are clean

## 2. explain.sh: project root, server, exposure, library

- [x] 2.1 Create `skills/explain/explain.sh` with the usage header, `die`/`say` helpers, project resolution identical to `expose.sh` (basename of the dir holding the common git dir), and the pages root `${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/explain/<project>/`; verify with a scratch repo and a worktree that both resolve the same root
- [x] 2.2 Implement the server: `pick_port` (free loopback port), `launch.sh` running `python3 -m http.server --bind 127.0.0.1 <port> --directory <root>` (replaced by `.serve.py` in 6.1), a detached tmux window named `ox >explain` tagged `@opsx_explain=<project>`, the `.server` record, and a readiness wait (HEAD `/` up to 10 s); reuse when the recorded window exists with the tag and the port answers, else restart; verify in `tests/test-explain.sh` (private tmux server, scratch state) that a first call creates one tagged window and a listening port, a second call creates nothing new, and a stale record is replaced
- [x] 2.3 Implement the exposure step: `expose.sh up <port> --name explain` (found like `opsx-preview.sh` finds it: `$OPSX_EXPOSE_SH`, sibling skill dir, PATH), URL taken from its last line; on exit 3 print the local URL and the `install.sh --expose-domain` hint and continue; verify in `tests/test-explain.sh` with a fake `expose.sh` that logs `up <port> --name explain` and with a fake that exits 3
- [x] 2.4 Implement page ids (`.ids/<n>` with noclobber, never reused), `<n>/.meta` (topic, created, fork id, tmux session) and the `.reindex` script written into the root that regenerates `index.html` (id, title from `<title>`, created, fork, link to `/<n>/`); verify in `tests/test-explain.sh` that two pages yield ids 1 and 2, `.reindex` lists both titles, and a deleted page's id is not reused
- [x] 2.5 Implement `explain.sh open "<topic>" [--window] [--vertical] [--cli <c>] [--model <m>] [--parent-model <m>]`: allocate the id, assemble the brief from stdin (the parent's text, written by the skill) plus the page URL line, call `fork.sh open --page-dir <root>/<n> …` with the brief on stdin, print the page URL and relay the fork line; refuse an empty topic; verify in `tests/test-explain.sh` with the fake CLIs that the fork's `meta` has the page dir, `brief.md` contains the topic and the URL, and the output names `/<n>/`
- [x] 2.6 Implement `explain.sh share …` (pass-through to `expose.sh share explain …`, link last), `explain.sh list` (table of pages + server state + URL) and `explain.sh stop` (`expose.sh down explain` ignoring failure, kill the recorded window, remove `.server`, keep pages, exit 0 when nothing runs); verify in `tests/test-explain.sh` the share arguments reach the fake, `list` shows both pages, and after `stop` the window is gone and `<root>/1/index.html` still exists
- [x] 2.7 `shellcheck skills/explain/explain.sh` and the full `bash tests/test-explain.sh`; verify both are clean

## 3. Skill text and page template

- [x] 3.1 Write `skills/explain/SKILL.md`: trigger `/explain`, usage table (`"<topic>"`, `share`, `list`, `stop`, pass-through flags), the parent steps (resolve `explain.sh` like `fork.sh` is resolved, write the brief with the topic and the HTML template, run `explain.sh open`, report the URL and fork line in one sentence), the fenced HTML template (CSS margin labels via `data-label`, click-to-copy, 2 s `Last-Modified` polling reload, Mermaid CDN script tag, example blocks for `S P D T C N`), and the rules for talking to the page by label; verify the file mentions `explain.sh open`, `manifest.tsv`, `fork.sh page`, `Last-Modified` and `mermaid`
- [ ] 3.2 Verify the template end to end by hand: open a page with the real `claude` in a tmux session, confirm labels render in the margin, a click copies `#P1`, a rewrite through `fork.sh page` reloads the browser within a few seconds, and a Mermaid block renders; record the outcome in the apply report

## 4. Install and documentation

- [x] 4.1 Add `install_explain_skill` to `install.sh` (six skill dirs, `SKILL.md` + executable `explain.sh`), `--skip-explain` in the header, `--help` and the flag parser, uninstall removal of the six dirs without touching `agent-forks/`, and the `explain.sh parses` check; verify in a scratch HOME that `install.sh` creates `~/.claude/skills/explain/explain.sh` executable, `--skip-explain` leaves it absent, and `--uninstall` removes it while a pre-created `agent-forks/explain/x/1/index.html` survives
- [x] 4.2 README: overview tree line under `context`, component table row, a new "Explain" section (commands, URL shape `explain--<project>.<domain>/<id>/`, labels, where pages live, `/expose` needed for sharing, `explain stop` keeps pages), and a `page` mention in the Fork section; verify README mentions `/explain`, `explain--`, `manifest.tsv` and `fork.sh page`

## 5. Integration

- [x] 5.1 Run `bash tests/test-fork.sh`, `bash tests/test-explain.sh`, `shellcheck` on `fork.sh`, `explain.sh` and `install.sh`, and `openspec validate add-explain-skill --strict`; verify all pass
- [ ] 5.2 Manual walk-through on this machine with `/expose` configured: `/explain "how /opsx-run land works"`, open the URL on a second device via the owner link, ask the fork to expand one `P` label and fix one `D` label, confirm the page updates and labels stay stable, `/explain share --ttl 1h`, `/explain list`, `/explain stop`; record the outcome in the apply report

## 6. Security review fixes

- [x] 6.1 F1/F2/F4: replace `python3 -m http.server` with `.serve.py` written by `explain.sh` (server-side CSP and security headers, `/`, `/<n>/` and `index.html` only, GET/HEAD, Host allowlist from `.hosts`), root 700 and files 600; verify in `tests/test-explain.sh` (CSP and headers, 421 for a foreign Host, 404 for internal files, modes)
- [x] 6.2 F3: pin Mermaid to `11.17.2/dist/mermaid.min.js` with SRI and `referrerpolicy="no-referrer"` in the template; verify the brief carries the hash
- [x] 6.3 F5: page protocol forbids secrets, tokens and credentials; verify in `tests/test-fork.sh`
- [x] 6.4 F6: `fork.sh page` runs `.reindex` only under `<state root>/explain/<project>/`, never a symlink; verify in `tests/test-fork.sh`

## 7. Bilingual pages (EN + PT)

- [x] 7.1 Update proposal, design (5a), `specs/explain-page` (requirement "Bilingual page", protocol scenario) and `specs/tmux-fork` ("Brief content"); verify `openspec validate add-explain-skill --strict`
- [x] 7.2 Template in `skills/explain/SKILL.md`: `<article lang="en">` and `<article lang="pt">` with identical labelled blocks, EN / PT switch, head script choosing `?lang=` → `localStorage` → `navigator.language` → `en`, id hand-over to the shown article, `#<label>` landing, per-article `mermaid.run`, `<title>` with both titles; document the scheme in SKILL.md; verify the switch logic headless with node (jsdom-free DOM stub) and in `tests/test-explain.sh`
- [x] 7.3 Page protocol in `fork.sh` and the brief text in `explain.sh`: both languages in one write, identical labels, diagrams duplicated per language, both titles in `<title>`; bilingual placeholder page; verify in `tests/test-fork.sh` and `tests/test-explain.sh`
- [x] 7.4 README "Explain" section: bilingual pages, the switch, `?lang=`; verify the full test suites, shellcheck and the library index with a bilingual title

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.
