#!/usr/bin/env bash
# Scripted tests for `opsx init` (bin/opsx + skills/opsx-init/opsx-init.sh)
# and its install.sh wiring.
#
# Everything runs in scratch dirs: a scratch HOME, scratch git repos, and fake
# `openspec`, `graphify` and `docker` on PATH that log their arguments. Your
# real HOME, repos, openspec, graphify and docker are never touched.
# Usage: bash tests/test-init.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016,SC2086
set -u
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
SELF=$REPO/tests/test-init.sh
OPSX=$REPO/bin/opsx
INIT=$REPO/skills/opsx-init/opsx-init.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/init-test.XXXXXX")
trap 'rm -rf "$SP"' EXIT
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

# ---------------------------------------------------------------- fakes
# sysbin: every system command except docker/graphify/openspec, so "no docker"
# really means no docker even when the host has one.
mkdir -p "$SP/sysbin" "$SP/fake" "$SP/fake-nodocker" "$SP/home"
for f in /usr/local/bin/* /usr/bin/* /bin/*; do
  n=${f##*/}
  case "$n" in docker|graphify|openspec|opsx) continue ;; esac
  [ -e "$SP/sysbin/$n" ] || ln -s "$f" "$SP/sysbin/$n" 2>/dev/null
done
cat > "$SP/fake/openspec" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SP/openspec.log"
if [ "\$1" = init ]; then
  mkdir -p openspec/specs openspec/changes/archive
  printf 'schema: spec-driven\n\n# Project context (optional)\n# Example:\n#   context: |\n#     x\n\n# Per-artifact rules (optional)\n#   rules:\n' > openspec/config.yaml
fi
exit 0
EOF
for c in graphify docker; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/%s.log"\nexit 0\n' "$SP" "$c" > "$SP/fake/$c"
done
cp "$SP/fake/openspec" "$SP/fake/graphify" "$SP/fake-nodocker/"
chmod +x "$SP"/fake/* "$SP"/fake-nodocker/*
FULL_PATH=$SP/fake:$SP/sysbin
NODOCKER_PATH=$SP/fake-nodocker:$SP/sysbin

# opsx_in <dir> [args...]: run the checkout's launcher in <dir> with the fakes.
opsx_in() {
  local d=$1; shift
  (cd "$d" && env -u OPSX_SKILLS_DIR -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_HOME -u OPENCODE_CONFIG_DIR \
     HOME="$SP/home" PATH="${RUN_PATH:-$FULL_PATH}" GIT_CONFIG_GLOBAL=/dev/null \
     GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
     bash "$OPSX" init "$@" 2>&1)
}
N=0
new_repo() { N=$((N+1)); R=$SP/r$N; mkdir -p "$R"; git -C "$R" init -q; rm -f "$SP"/*.log; }
snapshot() { (cd "$1" && find . -path ./.git -prune -o -type f -print | sort | while read -r f; do printf '%s %s\n' "$(cksum < "$f")" "$f"; done); }
go_repo() { new_repo; printf 'module example.com/x\n\ngo 1.22\n' > "$R/go.mod"; }

# ---------------------------------------------------------------- 1.1 basics
ok "bash -n opsx-init.sh and bin/opsx" 'bash -n "$INIT" && bash -n "$OPSX"'
ok "shellcheck (if installed)" '! command -v shellcheck >/dev/null || shellcheck -S warning "$INIT" "$OPSX" "$SELF"'
out=$(PATH=$FULL_PATH bash "$OPSX" help); rc=$?
ok "opsx help lists init" '[ $rc -eq 0 ] && printf "%s\n" "$out" | grep -qE "^ +init "'
out=$(PATH=$FULL_PATH bash "$OPSX" frobnicate 2>&1); rc=$?
ok "opsx frobnicate exits non-zero with usage" '[ $rc -ne 0 ] && [[ "$out" == *"Usage: opsx"* ]]'
out=$(opsx_in "$SP" help); rc=$?
ok "opsx init help" '[ $rc -eq 0 ] && [[ "$out" == *"--force"* ]]'

# bad --force: rejected before anything is written (even outside a repo)
mkdir -p "$SP/bad"; out=$(opsx_in "$SP/bad" --git --force everything); rc=$?
ok "bad --force exits non-zero, creates nothing" '[ $rc -ne 0 ] && [ -z "$(ls -A "$SP/bad")" ] && [[ "$out" == *"config or dev"* ]]'
new_repo; out=$(opsx_in "$R" --force everything); rc=$?
ok "bad --force in a repo: nothing written, openspec not called" '[ $rc -ne 0 ] && [ "$(ls -A "$R")" = .git ] && [ ! -e "$SP/openspec.log" ]'
out=$(opsx_in "$R" --frob); rc=$?
ok "unknown option exits non-zero" '[ $rc -ne 0 ] && [ "$(ls -A "$R")" = .git ]'

# not a repo
mkdir -p "$SP/plain"; out=$(opsx_in "$SP/plain"); rc=$?
ok "not a repo: non-zero, mentions --git, dir stays empty" '[ $rc -ne 0 ] && [[ "$out" == *"--git"* ]] && [ -z "$(ls -A "$SP/plain")" ]'

# --git
mkdir -p "$SP/gitme"; rm -f "$SP"/*.log; out=$(opsx_in "$SP/gitme" --git); rc=$?
ok "--git: repo created with openspec/config.yaml" '[ $rc -eq 0 ] && git -C "$SP/gitme" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -f "$SP/gitme/openspec/config.yaml" ]'

# ---------------------------------------------------------------- 1.2 openspec / config / gitignore
new_repo; out=$(opsx_in "$R"); rc=$?; echo "$out"
ok "fresh: exits 0" '[ $rc -eq 0 ]'
ok "fresh: openspec called with init --tools none" 'grep -qx "init --tools none" "$SP/openspec.log"'
ok "skeleton: schema + marker" 'grep -qx "schema: spec-driven" "$R/openspec/config.yaml" && grep -qF "# opsx-init: context skeleton" "$R/openspec/config.yaml"'
ok "skeleton: one schema line, one context key" '[ "$(grep -c "^schema:" "$R/openspec/config.yaml")" -eq 1 ] && [ "$(grep -c "^context:" "$R/openspec/config.yaml")" -eq 1 ]'
ok "skeleton: marker is the first line of the context block" '[ "$(awk "/^context:/{getline; print; exit}" "$R/openspec/config.yaml")" = "  # opsx-init: context skeleton" ]'
ok "skeleton: keeps openspec's other help" 'grep -q "Per-artifact rules" "$R/openspec/config.yaml"'
ok "skeleton parses as YAML (if python yaml)" '! python3 -c "import yaml" 2>/dev/null || python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert d[\"schema\"]==\"spec-driven\" and \"opsx-init: context skeleton\" in d[\"context\"]" "$R/openspec/config.yaml"'
ok "step lines use the ✓/·/! format" '! printf "%s\n" "$out" | sed -n "1,/^$/p" | grep -v "^$" | grep -vE "^(✓|·|!) [a-z]+: "'
ok "gitignore: graphify-out/ once" '[ "$(grep -cx "graphify-out/" "$R/.gitignore")" -eq 1 ]'
rm -f "$SP/openspec.log"; out=$(opsx_in "$R"); rc=$?
ok "already initialised: openspec not called, skipped" '[ $rc -eq 0 ] && [ ! -e "$SP/openspec.log" ] && printf "%s\n" "$out" | grep -q "^· openspec: skipped"'
ok "gitignore: still one line after second run" '[ "$(grep -cx "graphify-out/" "$R/.gitignore")" -eq 1 ]'

new_repo; mkdir -p "$R/openspec"; printf 'schema: spec-driven\ncontext: |\n  my own words\n' > "$R/openspec/config.yaml"
cp "$R/openspec/config.yaml" "$SP/cfg.orig"; printf 'node_modules\n/graphify-out\n' > "$R/.gitignore"
out=$(opsx_in "$R"); rc=$?
ok "existing config kept byte-for-byte" '[ $rc -eq 0 ] && cmp -s "$SP/cfg.orig" "$R/openspec/config.yaml"'
ok "equivalent gitignore line respected" '[ "$(cat "$R/.gitignore")" = "node_modules
/graphify-out" ]'
new_repo; mkdir -p "$R/openspec"; printf 'schema: spec-driven\n' > "$R/openspec/config.yml"; cp "$R/openspec/config.yml" "$SP/cfg.orig"
out=$(opsx_in "$R"); rc=$?
ok "existing config.yml kept, no config.yaml added" '[ $rc -eq 0 ] && cmp -s "$SP/cfg.orig" "$R/openspec/config.yml" && [ ! -e "$R/openspec/config.yaml" ]'
new_repo; printf 'node_modules' > "$R/.gitignore"; out=$(opsx_in "$R")
ok "gitignore without trailing newline appended cleanly" '[ "$(cat "$R/.gitignore")" = "node_modules
graphify-out/" ]'
new_repo; mkdir -p "$R/openspec"; out=$(opsx_in "$R")
ok "openspec/ without config: skeleton written" 'grep -qF "# opsx-init: context skeleton" "$R/openspec/config.yaml"'
new_repo; out=$(RUN_PATH=$SP/sysbin opsx_in "$R"); rc=$?
ok "openspec CLI missing: fails, names openspec" '[ $rc -ne 0 ] && [[ "$out" == *"openspec"* ]] && [ ! -e "$R/openspec" ]'

# --force config
new_repo; mkdir -p "$R/openspec"; printf 'schema: spec-driven\ncontext: |\n  mine\n' > "$R/openspec/config.yaml"
out=$(opsx_in "$R" --force config); rc=$?
ok "--force config regenerates the skeleton" '[ $rc -eq 0 ] && grep -qF "# opsx-init: context skeleton" "$R/openspec/config.yaml" && ! grep -q mine "$R/openspec/config.yaml"'

# ---------------------------------------------------------------- 1.3 graphify / docker / summary
go_repo; out=$(opsx_in "$R" --graphify); rc=$?
ok "--graphify: graphify update . called" '[ $rc -eq 0 ] && grep -qx "update ." "$SP/graphify.log"'
go_repo; out=$(opsx_in "$R")
ok "no --graphify: graphify not called, command hinted" '[ ! -e "$SP/graphify.log" ] && [[ "$out" == *"graphify update ."* ]]'
go_repo; out=$(RUN_PATH=$SP/sysbin:$SP/fake-nodocker opsx_in "$R" --graphify); rc=$?
ok "docker missing: still exits 0 with graphify fake" '[ $rc -eq 0 ]'
go_repo; mkdir -p "$SP/osonly"; cp "$SP/fake/openspec" "$SP/osonly/"
out=$(RUN_PATH=$SP/osonly:$SP/sysbin opsx_in "$R" --graphify); rc=$?
ok "--graphify without graphify: warning, exit 0" '[ $rc -eq 0 ] && printf "%s\n" "$out" | grep -q "^! graphify:"'
go_repo; out=$(RUN_PATH=$NODOCKER_PATH opsx_in "$R"); rc=$?
ok "no docker: exit 0, warning names docker, dev.yaml written" '[ $rc -eq 0 ] && printf "%s\n" "$out" | grep -q "^! docker:.*docker" && [ -f "$R/.opsx/dev.yaml" ]'
go_repo; out=$(opsx_in "$R" --graphify); out=$(opsx_in "$R" --force dev)
ok "docker never pulled/built/run" '[ ! -e "$SP/docker.log" ] || ! grep -Eq "(^| )(pull|build|run)( |$)" "$SP/docker.log"'

go_repo; git -C "$R" add go.mod; git -C "$R" -c user.name=t -c user.email=t@t commit -qm one
out=$(opsx_in "$R"); rc=$?
ok "nothing committed or staged" '[ $rc -eq 0 ] && [ "$(git -C "$R" rev-list --count HEAD)" -eq 1 ] && git -C "$R" diff --cached --quiet'
ok "summary lists paths and a git add line" '[[ "$out" == *"git add openspec .gitignore .opsx/dev.yaml"* ]]'

# second run: all skipped, nothing changed
go_repo; out=$(opsx_in "$R"); before=$(snapshot "$R"); st1=$(git -C "$R" status --porcelain)
out2=$(opsx_in "$R"); rc=$?; echo "$out2"
ok "second run exits 0" '[ $rc -eq 0 ]'
ok "second run: every step line says skipped" 'steps=$(printf "%s\n" "$out2" | grep -E "^(✓|·|!) "); [ -n "$steps" ] && ! printf "%s\n" "$steps" | grep -vq ": skipped ("'
ok "second run: no file changed" '[ "$before" = "$(snapshot "$R")" ] && [ "$st1" = "$(git -C "$R" status --porcelain)" ]'

# ---------------------------------------------------------------- 2.x toolchain detection
go_repo; out=$(opsx_in "$R")
ok "Go: image golang:1.22" 'grep -qx "image: golang:1.22" "$R/.opsx/dev.yaml"'
ok "Go: setup go mod download" 'grep -qx "setup: go mod download" "$R/.opsx/dev.yaml"'
ok "dev.yaml header mentions dockerfile: and cache:" 'grep -q "^#.*dockerfile:" "$R/.opsx/dev.yaml" && grep -q "^#.*cache:" "$R/.opsx/dev.yaml"'
new_repo; printf 'module x\n\ngo 1.21.5\n\ntoolchain go1.22.0\n' > "$R/go.mod"; out=$(opsx_in "$R")
ok "Go: patch version trimmed to major.minor" 'grep -qx "image: golang:1.21" "$R/.opsx/dev.yaml"'
new_repo; printf 'v20.11.0\n' > "$R/.nvmrc"; out=$(opsx_in "$R")
ok "Node: .nvmrc v20.11.0 -> node:20" 'grep -qx "image: node:20" "$R/.opsx/dev.yaml"'
new_repo; printf '{\n  "name": "x",\n  "engines": {\n    "node": ">=18.17"\n  }\n}\n' > "$R/package.json"; : > "$R/package-lock.json"; out=$(opsx_in "$R")
ok "Node: package.json engines.node -> node:18, npm ci" 'grep -qx "image: node:18" "$R/.opsx/dev.yaml" && grep -qx "setup: npm ci" "$R/.opsx/dev.yaml"'
new_repo; printf '{"name":"x"}\n' > "$R/package.json"; printf '20\n' > "$R/.nvmrc"; : > "$R/pnpm-lock.yaml"; out=$(opsx_in "$R")
ok "pnpm setup line" 'grep -qx "setup: pnpm install --frozen-lockfile" "$R/.opsx/dev.yaml"'
new_repo; printf '{"name":"x"}\n' > "$R/package.json"; printf '20\n' > "$R/.nvmrc"; : > "$R/yarn.lock"; out=$(opsx_in "$R")
ok "yarn setup line" 'grep -qx "setup: yarn install --frozen-lockfile" "$R/.opsx/dev.yaml"'
new_repo; printf '{"name":"x"}\n' > "$R/package.json"; printf '20\n' > "$R/.nvmrc"; : > "$R/bun.lockb"; out=$(opsx_in "$R")
ok "bun setup line" 'grep -qx "setup: bun install" "$R/.opsx/dev.yaml"'
new_repo; printf '3.12.1\n' > "$R/.python-version"; printf 'flask\n' > "$R/requirements.txt"; out=$(opsx_in "$R")
ok "Python: .python-version -> python:3.12 + pip setup" 'grep -qx "image: python:3.12" "$R/.opsx/dev.yaml" && grep -qx "setup: pip install --user -r requirements.txt" "$R/.opsx/dev.yaml"'
new_repo; printf '[project]\nname = "x"\nrequires-python = ">=3.10"\n' > "$R/pyproject.toml"; out=$(opsx_in "$R")
ok "Python: pyproject requires-python -> python:3.10, no pip line" 'grep -qx "image: python:3.10" "$R/.opsx/dev.yaml" && ! grep -q "^setup:" "$R/.opsx/dev.yaml"'
new_repo; printf 'module x\n\ngo 1.22\n' > "$R/go.mod"; printf '20\n' > "$R/.nvmrc"; out=$(opsx_in "$R")
ok "Go+Node: golang image, node comment, dockerfile warning" 'grep -qx "image: golang:1.22" "$R/.opsx/dev.yaml" && grep -q "^#.*node:20" "$R/.opsx/dev.yaml" && [ "$(grep -c "^image:" "$R/.opsx/dev.yaml")" -eq 1 ] && printf "%s\n" "$out" | grep -q "^!.*dockerfile:"'
new_repo; out=$(opsx_in "$R"); rc=$?
ok "nothing detected: no dev.yaml, hint mentions it" '[ $rc -eq 0 ] && [ ! -e "$R/.opsx/dev.yaml" ] && [[ "$out" == *".opsx/dev.yaml"* ]]'
go_repo; mkdir -p "$R/.opsx"; printf 'image: custom:1\n' > "$R/.opsx/dev.yaml"; out=$(opsx_in "$R")
ok "existing dev.yaml kept without --force" 'grep -qx "image: custom:1" "$R/.opsx/dev.yaml"'
out=$(opsx_in "$R" --force dev); rc=$?
ok "--force dev replaces image: custom:1" '[ $rc -eq 0 ] && grep -qx "image: golang:1.22" "$R/.opsx/dev.yaml" && ! grep -q custom "$R/.opsx/dev.yaml"'
out=$(cd "$R" && mkdir -p sub && cd sub && HOME="$SP/home" PATH=$FULL_PATH bash "$OPSX" init 2>&1); rc=$?
ok "run from a subdirectory works on the repo root" '[ $rc -eq 0 ] && [ ! -e "$R/sub/openspec" ]'

# ---------------------------------------------------------------- 3.x install
IH=$SP/ihome; mkdir -p "$IH" "$SP/ibin"
for b in claude node npm; do printf '#!/bin/sh\necho 1.0.0\n' > "$SP/ibin/$b"; chmod +x "$SP/ibin/$b"; done
run_install(){
  (cd "$REPO" && env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_HOME -u OPENCODE_CONFIG_DIR -u TMUX -u TMUX_PANE \
     -u SUDO_USER -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u OPSX_MODELS_CONF NO_COLOR=1 \
     HOME="$IH" PATH="$IH/.local/bin:$SP/ibin:/usr/bin:/bin" bash ./install.sh --skip-openspec --skip-graphify \
     --skip-commands --skip-mcp --skip-memory --skip-fork --no-backup "$@" </dev/null 2>&1)
}
out=$(run_install); rc=$?
ok "install exits 0" '[ $rc -eq 0 ] || { printf "%s\n" "$out" | tail -20; false; }'
ok "install: ~/.local/bin/opsx executable" '[ -x "$IH/.local/bin/opsx" ]'
ok "install: opsx help lists init" 'HOME="$IH" "$IH/.local/bin/opsx" help | grep -qE "^ +init "'
ok "install: skill for Claude mentions opsx init + marker" 'grep -q "opsx init" "$IH/.claude/skills/opsx-init/SKILL.md" && grep -qF "# opsx-init: context skeleton" "$IH/.claude/skills/opsx-init/SKILL.md"'
ok "install: skill says to leave a user context unchanged" 'grep -q "leave \`context:\` unchanged" "$IH/.claude/skills/opsx-init/SKILL.md"'
ok "install: opsx-init.sh in all six skill dirs, executable" 'for d in .claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills; do [ -f "$IH/$d/opsx-init/SKILL.md" ] && [ -x "$IH/$d/opsx-init/opsx-init.sh" ] || exit 1; done'
go_repo; out=$(cd "$R" && HOME="$IH" PATH="$SP/fake:$SP/sysbin" "$IH/.local/bin/opsx" init 2>&1); rc=$?
ok "installed opsx runs the installed init script" '[ $rc -eq 0 ] && grep -qx "image: golang:1.22" "$R/.opsx/dev.yaml"'
out=$(run_install --uninstall); rc=$?
ok "uninstall removes launcher and skill" '[ $rc -eq 0 ] && [ ! -e "$IH/.local/bin/opsx" ] && [ ! -e "$IH/.claude/skills/opsx-init" ] && [ ! -e "$IH/.gemini/skills/opsx-init" ]'
mkdir -p "$IH/.local/bin"; printf '#!/bin/sh\necho mine\n' > "$IH/.local/bin/opsx"; chmod +x "$IH/.local/bin/opsx"
out=$(run_install); rc=$?
ok "install leaves a foreign ~/.local/bin/opsx alone" '[ $rc -eq 0 ] && [ "$("$IH/.local/bin/opsx")" = mine ]'
out=$(run_install --uninstall)
ok "uninstall leaves a foreign ~/.local/bin/opsx alone" '[ "$("$IH/.local/bin/opsx")" = mine ]'
rm -f "$IH/.local/bin/opsx"
out=$(run_install --skip-init); rc=$?
ok "--skip-init installs neither" '[ $rc -eq 0 ] && [ ! -e "$IH/.local/bin/opsx" ] && [ ! -e "$IH/.claude/skills/opsx-init" ]'

# ---------------------------------------------------------------- 4.x docs
RD=$REPO/README.md
ok "readme: opsx init, --force, .opsx/dev.yaml, /opsx-init" 'grep -q "opsx init" "$RD" && grep -q -- "--force" "$RD" && grep -q ".opsx/dev.yaml" "$RD" && grep -q "/opsx-init" "$RD"'
ok "readme: tests list has test-init.sh" 'grep -q "tests/test-init.sh" "$RD"'

echo ""
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
