#!/usr/bin/env bash
# opsx-init.sh — set up the current git repo for tmux-opsx (`opsx init`).
#
# Usage: opsx init [--git] [--graphify] [--force config|dev]
#        opsx init help
#
# Steps, in order; each one is skipped when already done:
#   git        --git: run `git init` when the directory is not a git repo yet
#   openspec   `openspec init --tools none` when there is no openspec/
#   config     openspec/config.yaml with `schema: spec-driven` and a context:
#              skeleton (marker: `# opsx-init: context skeleton`) when no config exists
#   gitignore  append `graphify-out/` to .gitignore once
#   graphify   --graphify: `graphify update .` (code graph, no LLM); else a hint
#   dev        .opsx/dev.yaml from go.mod / .python-version / pyproject.toml /
#              requirements.txt / .nvmrc / package.json
#   docker     warn when docker is missing (never pulls, builds or runs anything)
#
#   --git              run `git init` first when not inside a git repo
#   --graphify         also build the code graph with `graphify update .`
#   --force <step>     regenerate one step's file: config or dev (may repeat)
#
# Never overwrites a file it did not just create (except with --force), never
# stages or commits: it ends with the paths it created or changed and a
# `git add` line. Output lines: "✓ step: created …", "· step: skipped (…)",
# "! step: warning". Exit 0 when every step is done or skipped.

set -uo pipefail

MARKER='# opsx-init: context skeleton'

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; }
die() { printf 'opsx init: %s\n' "$*" >&2; exit 1; }
done_line() { printf '✓ %s: %s\n' "$1" "$2"; }
skip_line() { printf '· %s: skipped (%s)\n' "$1" "$2"; }
warn_line() { printf '! %s: %s\n' "$1" "$2"; }
fail_step() { printf '! %s: %s\n' "$1" "$2" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- arguments (all validated before anything is written) ----------
DO_GIT=0
DO_GRAPHIFY=0
FORCE_CONFIG=0
FORCE_DEV=0

set_force() {
  case "$1" in
    config) FORCE_CONFIG=1 ;;
    dev)    FORCE_DEV=1 ;;
    *) printf 'opsx init: --force takes config or dev, not %s\n' "'$1'" >&2; exit 2 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --git)       DO_GIT=1; shift ;;
    --graphify)  DO_GRAPHIFY=1; shift ;;
    --force)     [ $# -ge 2 ] || { echo "opsx init: --force needs a step: config or dev" >&2; exit 2; }
                 set_force "$2"; shift 2 ;;
    --force=*)   set_force "${1#--force=}"; shift ;;
    help|-h|--help) usage; exit 0 ;;
    *) printf 'opsx init: unknown argument %s (try: opsx init help)\n' "'$1'" >&2; exit 2 ;;
  esac
done

have git || die "git is not installed"

CREATED=()   # paths created or changed, relative to the repo root

# ---------- git ----------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ROOT=$(git rev-parse --show-toplevel) || die "cannot find the repo root"
  skip_line git "already a git repo"
elif [ "$DO_GIT" -eq 1 ]; then
  git init -q . || fail_step git "git init failed"
  ROOT=$(git rev-parse --show-toplevel) || die "cannot find the repo root"
  done_line git "ran git init in $ROOT"
else
  printf 'opsx init: %s is not inside a git repo — run git init first, or use: opsx init --git\n' "$PWD" >&2
  exit 1
fi
cd -- "$ROOT" || die "cannot cd to $ROOT"

# ---------- openspec ----------
config_path() {
  if [ -f openspec/config.yaml ]; then echo openspec/config.yaml
  elif [ -f openspec/config.yml ]; then echo openspec/config.yml
  fi
}
CONFIG_BEFORE=$(config_path)
OPENSPEC_RAN=0
if [ -d openspec ]; then
  skip_line openspec "openspec/ exists"
else
  have openspec || fail_step openspec "openspec CLI not found — install it (install.sh, or npm i -g @fission-ai/openspec) and re-run"
  log=$(openspec init --tools none </dev/null 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$log" >&2
    fail_step openspec "openspec init --tools none failed (exit $rc)"
  fi
  [ -d openspec ] || fail_step openspec "openspec init --tools none did not create openspec/"
  OPENSPEC_RAN=1
  CREATED+=(openspec)
  done_line openspec "created openspec/ (openspec init --tools none)"
fi

# ---------- config ----------
# The skeleton: schema, a context: block that starts with the marker, then
# whatever comment help followed the schema line in openspec's own fresh config.
write_config() {
  local dest=$1 tail_from=${2:-} tmp
  mkdir -p openspec || fail_step config "cannot create openspec/"
  tmp=$(mktemp "openspec/.config.XXXXXX") || fail_step config "cannot write in openspec/"
  {
    echo "schema: spec-driven"
    echo ""
    echo "# Project context for OpenSpec artifacts. /opsx-init replaces this skeleton"
    echo "# with a description written from the repo; edit it freely afterwards."
    echo "context: |"
    echo "  $MARKER"
    echo "  Purpose: what this project does and for whom."
    echo "  Stack: languages, frameworks, key libraries and versions."
    echo "  Layout: the main directories and what lives in each."
    echo "  Conventions: style, naming, error handling, commit rules."
    echo "  Tests: how to run the tests, lint and build."
    if [ -n "$tail_from" ] && [ -f "$tail_from" ]; then
      echo ""
      # Drop the schema line and openspec's own "Project context" help
      # paragraph (the skeleton above replaces it); keep the rest.
      awk 'BEGIN{s=0} !s && /^schema:/ {s=1; next} {print}' "$tail_from" \
        | awk '/^# Project context/ {drop=1} drop && !NF {drop=0; next} !drop' \
        | awk 'NF {p=1} p'
    fi
  } > "$tmp" || { rm -f "$tmp"; fail_step config "cannot write $dest"; }
  chmod 644 "$tmp" 2>/dev/null
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; fail_step config "cannot write $dest"; }
}

has_context_key() { grep -qE '^context:' "$1" 2>/dev/null; }

if [ "$FORCE_CONFIG" -eq 1 ]; then
  dest=$(config_path); dest=${dest:-openspec/config.yaml}
  write_config "$dest"
  CREATED+=("$dest")
  done_line config "created $dest (--force config)"
elif [ -n "$CONFIG_BEFORE" ]; then
  skip_line config "$CONFIG_BEFORE exists"
elif [ "$OPENSPEC_RAN" -eq 1 ] && [ -n "$(config_path)" ]; then
  # openspec init just wrote its own config: no user content yet. Keep its
  # comment help, add the context skeleton — unless it already set a context.
  fresh=$(config_path)
  if has_context_key "$fresh"; then
    skip_line config "$fresh from openspec init already has context:"
  else
    tmp_src=$(mktemp) || fail_step config "cannot create a temp file"
    cp "$fresh" "$tmp_src"
    write_config "$fresh" "$tmp_src"
    rm -f "$tmp_src"
    done_line config "created $fresh with a context: skeleton"
  fi
else
  write_config openspec/config.yaml
  [ "$OPENSPEC_RAN" -eq 1 ] || CREATED+=(openspec/config.yaml)
  done_line config "created openspec/config.yaml with a context: skeleton"
fi

# ---------- gitignore ----------
if [ -f .gitignore ] && grep -qE '^[[:space:]]*/?graphify-out/?[[:space:]]*$' .gitignore; then
  skip_line gitignore ".gitignore already ignores graphify-out/"
else
  if [ -s .gitignore ] && [ -n "$(tail -c1 .gitignore)" ]; then
    printf '\n' >> .gitignore || fail_step gitignore "cannot write .gitignore"
  fi
  existed=0; [ -f .gitignore ] && existed=1
  printf 'graphify-out/\n' >> .gitignore || fail_step gitignore "cannot write .gitignore"
  CREATED+=(.gitignore)
  if [ "$existed" -eq 1 ]; then done_line gitignore "added graphify-out/ to .gitignore"
  else done_line gitignore "created .gitignore with graphify-out/"; fi
fi

# ---------- graphify ----------
if [ "$DO_GRAPHIFY" -eq 1 ]; then
  if ! have graphify; then
    warn_line graphify "graphify not found — install it (install.sh) and run: graphify update ."
  else
    glog=$(graphify update . </dev/null 2>&1)
    grc=$?
    if [ "$grc" -eq 0 ]; then
      done_line graphify "built the code graph in graphify-out/ (graphify update .)"
    else
      printf '%s\n' "$glog" | tail -n 5 >&2
      warn_line graphify "graphify update . failed (exit $grc)"
    fi
  fi
else
  skip_line graphify "no --graphify; build the code graph with: graphify update ."
fi

# ---------- dev ----------
# Each detector prints "<image>|<setup line or empty>|<note>" or nothing.
first_line() { awk 'NF && $1 !~ /^#/ {print; exit}' "$1" 2>/dev/null; }

detect_go() {
  [ -f go.mod ] || return 0
  local v
  v=$(awk '$1=="go" {print $2; exit}' go.mod | sed -nE 's/^([0-9]+\.[0-9]+).*/\1/p')
  if [ -n "$v" ]; then printf 'golang:%s|go mod download|\n' "$v"
  else printf 'golang:latest|go mod download|no go directive in go.mod\n'; fi
}

detect_python() {
  local v="" src="" setup=""
  if [ -f .python-version ]; then
    v=$(first_line .python-version | sed -nE 's/^[^0-9]*([0-9]+\.[0-9]+).*/\1/p'); src=.python-version
  fi
  if [ -z "$v" ] && [ -f pyproject.toml ]; then
    v=$(sed -nE 's/^[[:space:]]*requires-python[[:space:]]*=[[:space:]]*["'\''][^0-9]*([0-9]+\.[0-9]+).*/\1/p' pyproject.toml | head -n1)
    src=pyproject.toml
  fi
  [ -f requirements.txt ] && setup="pip install --user -r requirements.txt"
  if [ -n "$v" ]; then printf 'python:%s|%s|\n' "$v" "$setup"
  elif [ -f .python-version ] || [ -f pyproject.toml ] || [ -f requirements.txt ]; then
    printf 'python:3|%s|no Python version in %s\n' "$setup" "${src:-requirements.txt}"
  fi
}

detect_node() {
  local v="" src="" setup="" engines
  if [ -f .nvmrc ]; then
    v=$(first_line .nvmrc | sed -nE 's/^[[:space:]]*v?([0-9]+).*/\1/p'); src=.nvmrc
  fi
  if [ -z "$v" ] && [ -f package.json ]; then
    engines=$(tr -d '\n\r' < package.json | grep -oE '"engines"[[:space:]]*:[[:space:]]*\{[^}]*\}' | head -n1)
    v=$(printf '%s' "$engines" | grep -oE '"node"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
        | sed -E 's/^"node"[[:space:]]*:[[:space:]]*"//' | grep -oE '[0-9]+' | head -n1)
    src=package.json
  fi
  if [ -f pnpm-lock.yaml ]; then setup="pnpm install --frozen-lockfile"
  elif [ -f yarn.lock ]; then setup="yarn install --frozen-lockfile"
  elif [ -f bun.lockb ] || [ -f bun.lock ]; then setup="bun install"
  elif [ -f package-lock.json ]; then setup="npm ci"
  fi
  if [ -n "$v" ]; then printf 'node:%s|%s|\n' "$v" "$setup"
  elif [ -f .nvmrc ] || [ -f package.json ]; then
    printf 'node:lts|%s|no Node version in %s\n' "$setup" "${src:-package.json}"
  fi
}

write_dev() {
  local tmp i img setup note
  mkdir -p .opsx || fail_step dev "cannot create .opsx/"
  tmp=$(mktemp ".opsx/.dev.XXXXXX") || fail_step dev "cannot write in .opsx/"
  IFS='|' read -r img setup note <<<"${FOUND[0]}"
  {
    echo "# .opsx/dev.yaml — toolchain for the opsx dev container, written by opsx init."
    echo "# Flat key: value lines, one value per line:"
    echo "#   image: <ref>        base image for the container"
    echo "#   dockerfile: <path>  build from a Dockerfile instead of image: (multi-language repos)"
    echo "#   setup: <command>    install step run in the repo after mounting; may repeat"
    echo "#   cache: <dir>        directory kept between runs (e.g. a package cache); may repeat"
    echo "# Regenerate after editing the toolchain files: opsx init --force dev"
    echo "image: $img"
    [ -n "$setup" ] && echo "setup: $setup"
    for ((i = 1; i < ${#FOUND[@]}; i++)); do
      IFS='|' read -r img setup note <<<"${FOUND[$i]}"
      if [ -n "$setup" ]; then echo "# also detected: $img (setup: $setup)"
      else echo "# also detected: $img"; fi
    done
  } > "$tmp" || { rm -f "$tmp"; fail_step dev "cannot write .opsx/dev.yaml"; }
  chmod 644 "$tmp" 2>/dev/null
  mv -f "$tmp" .opsx/dev.yaml || { rm -f "$tmp"; fail_step dev "cannot write .opsx/dev.yaml"; }
}

if [ -f .opsx/dev.yaml ] && [ "$FORCE_DEV" -eq 0 ]; then
  skip_line dev ".opsx/dev.yaml exists"
else
  FOUND=()
  for r in "$(detect_go)" "$(detect_python)" "$(detect_node)"; do
    [ -n "$r" ] && FOUND+=("$r")
  done
  if [ ${#FOUND[@]} -eq 0 ]; then
    skip_line dev "no go.mod, .python-version, pyproject.toml, requirements.txt, .nvmrc or package.json found; write .opsx/dev.yaml by hand (image:, setup:) if you use opsx dev"
  else
    write_dev
    CREATED+=(.opsx/dev.yaml)
    IFS='|' read -r img _ _ <<<"${FOUND[0]}"
    if [ "$FORCE_DEV" -eq 1 ]; then done_line dev "created .opsx/dev.yaml (image: $img, --force dev)"
    else done_line dev "created .opsx/dev.yaml (image: $img)"; fi
    for r in "${FOUND[@]}"; do
      IFS='|' read -r _ _ note <<<"$r"
      [ -z "$note" ] || warn_line dev "$note; check image: in .opsx/dev.yaml"
    done
    if [ ${#FOUND[@]} -gt 1 ]; then
      others=""
      for ((i = 1; i < ${#FOUND[@]}; i++)); do
        IFS='|' read -r o _ _ <<<"${FOUND[$i]}"; others="$others${others:+, }$o"
      done
      warn_line dev "several toolchains found; using $img, also $others — for a multi-language repo set dockerfile: in .opsx/dev.yaml"
    fi
  fi
fi

# ---------- docker ----------
if have docker; then
  skip_line docker "docker found; nothing is pulled or built"
else
  warn_line docker "docker not found — opsx dev needs it to run the dev container; nothing else does"
fi

# ---------- summary ----------
echo ""
if [ ${#CREATED[@]} -eq 0 ]; then
  echo "Nothing created or changed."
else
  echo "Created or changed (nothing is staged or committed):"
  for p in "${CREATED[@]}"; do
    if [ -d "$p" ]; then echo "  $p/"; else echo "  $p"; fi
  done
  printf 'Review, then: git add'
  for p in "${CREATED[@]}"; do printf ' %s' "$p"; done
  printf '\n'
fi
cfg=$(config_path)
if [ -n "$cfg" ] && grep -qF "$MARKER" "$cfg" 2>/dev/null; then
  echo "Next: /opsx-init in your agent CLI writes the context: in $cfg from the repo."
fi
[ -f .opsx/preview.yaml ] || echo "Tip: /opsx-run previews auto-detect the dev server; add .opsx/preview.yaml only to override."
exit 0
