#!/usr/bin/env bash
# opsx-dev.sh — run a repo's toolchain in a per-checkout Docker container
# declared in .opsx/dev.yaml (the `opsx dev` command).
#
# Usage:
#   opsx dev <cmd> [args...]   run <cmd> in this checkout's dev container
#   opsx dev -- <cmd> [args]   same, for a command that starts with "-"
#   opsx dev --shell           interactive shell in the container
#   opsx dev --status          container name, image and state (or none)
#   opsx dev --rm              remove this checkout's dev and preview containers
#   opsx dev --rm --all        remove every opsx container of this project
#   opsx dev help
#
# Run from anywhere inside a checkout: the main checkout or a worktree. One
# container per checkout, named opsx-dev-<project>-<name>: <project> is the
# main checkout's folder name, <name> is <change> for a worktree on branch
# opsx/<change>, `main` for the main checkout, else the worktree folder name
# (both lowercased, characters outside [a-z0-9_.-] replaced by "-"). It is
# created on first use and reused afterwards; `--rm` (or close / land in
# /opsx-run) removes it. Volumes are always kept.
#
# .opsx/dev.yaml — flat `key: value` lines, # comments:
#   image: <ref>          base image (exactly one of image / dockerfile)
#   dockerfile: <path>    build from this Dockerfile (relative to the checkout
#                         root, which is the build context); tagged
#                         opsx-dev/<project>:<sha256 of the file, 12 chars>
#                         and built only when that tag does not exist
#   setup: <command>      run once after the container is created, as you, in
#                         the checkout root, through `sh -c`; may repeat
#   cache: <abs path>     a named volume opsx-dev-<project>-cache-<path> on
#                         that path, shared by the project's checkouts; may repeat
# Unknown keys are warned about. A changed dev.yaml or Dockerfile recreates
# the container (and runs setup again) on next use.
#
# Container shape: `docker run -d --network host --entrypoint sleep <image>
# infinity`, the checkout mounted read-write at its own absolute path, the
# main repo's .git at its own absolute path (a worktree's .git file then
# resolves), the volume opsx-dev-<project>-home as HOME=/opsx-home, one volume
# per cache path, labels opsx.dev.project / .checkout / .name / .hash / .kind.
# Commands run with `docker exec -u <your uid>:<gid> -w <current directory>
# -e HOME=/opsx-home`; a TTY only when stdin and stdout are terminals. The
# command's exit status is returned. Host networking assumes a Linux host:
# an app bound to 127.0.0.1:$PORT in the container is on the host loopback.
#
# Internal (used by opsx-preview.sh, opsx-window.sh, opsx-land.sh):
#   opsx-dev.sh --rm --change <name>     dev + preview containers of <name>
#   opsx-dev.sh --rm-preview <name>      only the preview container of <name>
#   opsx-dev.sh --preview-run <port> <shell command>
#       run <shell command> in a foreground container
#       opsx-dev-<project>-<name>-preview (same image, mounts, user and host
#       network, PORT=<port> and HOST=127.0.0.1 set, removed on exit)
#
# Exit codes: the command's own status for `opsx dev <cmd>`; otherwise 0 ok,
# 1 failure, 2 usage.

set -uo pipefail

STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-opsx/dev
LOCK_WAIT=${OPSX_DEV_LOCK_WAIT:-600}
[[ "$LOCK_WAIT" =~ ^[0-9]+$ ]] || LOCK_WAIT=600
HOME_IN=/opsx-home

say()  { printf '%s\n' "$*"; }
note() { printf 'opsx dev: %s\n' "$*" >&2; }
warn() { printf 'opsx dev: warning: %s\n' "$*" >&2; }
die()  { printf 'opsx dev: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1
  fi
}

# Lowercase; characters outside [a-z0-9_.-] become "-".
sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-'; }

# Image repository component: [a-z0-9] runs joined by single "-".
image_component() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
  s=${s#-}; s=${s%-}
  printf '%s' "${s:-project}"
}

# ---------- checkout and project ----------

MAIN_DIR=""; GIT_COMMON=""; PROJECT=""; CHECKOUT=""; NAME=""; CNAME=""

resolve_project() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  [ -n "$common" ] || common=$(git rev-parse --git-common-dir 2>/dev/null) || common=""
  [ -n "$common" ] || die "not inside a git repository — run opsx dev from a checkout"
  common=$(cd -- "$common" 2>/dev/null && pwd -P) || die "cannot resolve the git directory"
  MAIN_DIR=$(dirname -- "$common")
  GIT_COMMON=$common
  PROJECT=$(sanitize "$(basename -- "$MAIN_DIR")")
}

resolve_checkout() {
  local top branch
  resolve_project
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a checkout (a bare repository or the .git directory?)"
  CHECKOUT=$(cd -- "$top" && pwd -P) || die "cannot resolve $top"
  if [ "$CHECKOUT" = "$MAIN_DIR" ]; then
    NAME=main
  else
    branch=$(git -C "$CHECKOUT" symbolic-ref -q --short HEAD 2>/dev/null) || branch=""
    case "$branch" in
      opsx/?*) NAME=${branch#opsx/} ;;
      *)       NAME=$(basename -- "$CHECKOUT") ;;
    esac
  fi
  NAME=$(sanitize "$NAME")
  CNAME=opsx-dev-$PROJECT-$NAME
}

need_docker() {
  command -v docker >/dev/null 2>&1 \
    || die "docker is not installed (no docker on PATH) — opsx dev runs the toolchain in Docker; install Docker, or remove .opsx/dev.yaml to use the host toolchain"
}

# ---------- dev.yaml ----------

DEV_YAML=""; IMAGE=""; DOCKERFILE=""; SETUP=(); CACHE=()

# Prints "key<TAB>value" lines from a flat `key: value` file; "!bad<TAB>line"
# for lines that are not flat key/value pairs.
read_flat_yaml() {
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]/ || line !~ /^[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*:/) {
        print "!bad\t" line; next
      }
      key = line; sub(/[[:space:]]*:.*/, "", key)
      val = line; sub(/^[^:]*:[[:space:]]*/, "", val); sub(/[[:space:]]+$/, "", val)
      if (length(val) >= 2) {
        f = substr(val, 1, 1); l = substr(val, length(val), 1)
        if ((f == "\"" || f == "\047") && f == l) val = substr(val, 2, length(val) - 2)
      }
      print key "\t" val
    }' "$1"
}

load_dev_yaml() {
  local k v n_image=0 n_df=0
  DEV_YAML=$CHECKOUT/.opsx/dev.yaml
  [ -f "$DEV_YAML" ] \
    || die "no .opsx/dev.yaml in $CHECKOUT — run 'opsx init' to write one (or create it with an image: line)"
  IMAGE=""; DOCKERFILE=""; SETUP=(); CACHE=()
  while IFS=$'\t' read -r k v; do
    case "$k" in
      image)      IMAGE=$v; n_image=$((n_image + 1)) ;;
      dockerfile) DOCKERFILE=$v; n_df=$((n_df + 1)) ;;
      setup)      [ -n "$v" ] && SETUP+=("$v") ;;
      cache)
        case "$v" in
          /*) CACHE+=("$v") ;;
          *)  die ".opsx/dev.yaml: cache: needs an absolute path inside the container (got '$v')" ;;
        esac ;;
      '!bad') warn ".opsx/dev.yaml: ignoring a line that is not a flat 'key: value' pair: $v" ;;
      *)      warn ".opsx/dev.yaml: unknown key '$k' ignored (known: image, dockerfile, setup, cache)" ;;
    esac
  done < <(read_flat_yaml "$DEV_YAML")
  if [ "$n_image" -gt 0 ] && [ "$n_df" -gt 0 ]; then
    die ".opsx/dev.yaml sets both image and dockerfile — keep exactly one of them"
  fi
  if [ "$n_image" -eq 0 ] && [ "$n_df" -eq 0 ]; then
    die ".opsx/dev.yaml sets neither image nor dockerfile — add exactly one (e.g. image: golang:1.22)"
  fi
  if [ "$n_image" -gt 1 ] || [ "$n_df" -gt 1 ]; then
    die ".opsx/dev.yaml repeats image or dockerfile — keep exactly one line"
  fi
  if [ "$n_image" -eq 1 ]; then
    [ -n "$IMAGE" ] || die ".opsx/dev.yaml: image is empty"
  else
    [ -n "$DOCKERFILE" ] || die ".opsx/dev.yaml: dockerfile is empty"
    case "$DOCKERFILE" in /*) ;; *) DOCKERFILE=$CHECKOUT/$DOCKERFILE ;; esac
    [ -f "$DOCKERFILE" ] || die ".opsx/dev.yaml: dockerfile $DOCKERFILE does not exist"
  fi
}

# Hash of dev.yaml (+ the Dockerfile): the opsx.dev.hash label.
config_hash() {
  { printf 'dev.yaml\n'; cat "$DEV_YAML"
    if [ -n "$DOCKERFILE" ]; then printf '\ndockerfile\n'; cat "$DOCKERFILE"; fi
  } | sha256
}

# Sets IMAGE_REF; builds the Dockerfile image when its tag is missing.
IMAGE_REF=""
resolve_image() {
  local tag
  if [ -z "$DOCKERFILE" ]; then IMAGE_REF=$IMAGE; return 0; fi
  tag=opsx-dev/$(image_component "$(basename -- "$MAIN_DIR")"):$(sha256 < "$DOCKERFILE" | cut -c1-12)
  IMAGE_REF=$tag
  docker image inspect "$tag" >/dev/null 2>&1 && return 0
  note "building $tag from ${DOCKERFILE#"$CHECKOUT"/}"
  docker build -t "$tag" -f "$DOCKERFILE" "$CHECKOUT" >&2 \
    || die "docker build of $DOCKERFILE failed — no container was created"
}

# ---------- container ----------

USER_ID=$(id -u); GROUP_ID=$(id -g)

home_volume() { printf 'opsx-dev-%s-home' "$PROJECT"; }
cache_volume() {
  local p
  p=$(sanitize "${1#/}"); p=$(printf '%s' "$p" | tr '/' '-')
  printf 'opsx-dev-%s-cache-%s' "$PROJECT" "${p:-root}"
}

# Mount, user and label arguments shared by the dev and preview containers.
shape_args() {  # shape_args <kind>
  SHAPE=(--network host
         --label "opsx.dev.project=$PROJECT" --label "opsx.dev.checkout=$CHECKOUT"
         --label "opsx.dev.name=$NAME" --label "opsx.dev.kind=$1"
         -v "$CHECKOUT:$CHECKOUT")
  # The main repo's .git: already inside the mount for the main checkout.
  case "$GIT_COMMON/" in
    "$CHECKOUT"/*) ;;
    *) SHAPE+=(-v "$GIT_COMMON:$GIT_COMMON") ;;
  esac
  SHAPE+=(-v "$(home_volume):$HOME_IN")
  local c
  for c in "${CACHE[@]+"${CACHE[@]}"}"; do SHAPE+=(-v "$(cache_volume "$c"):$c"); done
  SHAPE+=(-e "HOME=$HOME_IN")
}

lock_dev() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>>"$STATE_DIR/$CNAME.lock" || return 0
  flock -w "$LOCK_WAIT" 9 || die "$CNAME is busy (another opsx dev is creating it) — try again"
}
unlock_dev() { exec 9>&- 2>/dev/null; return 0; }

CREATING=""
abort_create() {
  [ -n "$CREATING" ] && docker rm -f "$CREATING" >/dev/null 2>&1
  exit 130
}

# Create (or recreate on a config change, or start when stopped) the dev
# container. Progress and setup output go to stderr.
ensure_container() {
  local hash info running have line rc c
  hash=$(config_hash)
  lock_dev
  info=$(docker container inspect -f '{{.State.Running}} {{index .Config.Labels "opsx.dev.hash"}}' "$CNAME" 2>/dev/null) || info=""
  if [ -n "$info" ]; then
    running=${info%% *}; have=${info#* }
    if [ "$have" = "$hash" ]; then
      if [ "$running" != true ]; then
        docker start "$CNAME" >/dev/null || die "cannot start $CNAME"
      fi
      return 0
    fi
    note ".opsx/dev.yaml changed — recreating $CNAME"
    docker rm -f "$CNAME" >/dev/null || die "cannot remove $CNAME to recreate it"
  fi
  resolve_image
  shape_args dev
  note "creating $CNAME from $IMAGE_REF"
  CREATING=$CNAME
  trap abort_create INT TERM HUP
  docker run -d --name "$CNAME" --entrypoint sleep "${SHAPE[@]}" \
    --label "opsx.dev.hash=$hash" "$IMAGE_REF" infinity >/dev/null \
    || { docker rm -f "$CNAME" >/dev/null 2>&1; die "could not create $CNAME from $IMAGE_REF (docker run failed)"; }
  # Volumes start out owned by root: hand them to the user once.
  local own=("$HOME_IN")
  for c in "${CACHE[@]+"${CACHE[@]}"}"; do own+=("$c"); done
  docker exec -u 0:0 "$CNAME" chown -R "$USER_ID:$GROUP_ID" "${own[@]}" >&2 \
    || warn "could not chown ${own[*]} in $CNAME (the image needs chown) — writes to HOME may fail"
  for line in "${SETUP[@]+"${SETUP[@]}"}"; do
    note "setup: $line"
    docker exec -u "$USER_ID:$GROUP_ID" -w "$CHECKOUT" -e "HOME=$HOME_IN" "$CNAME" sh -c "$line" >&2
    rc=$?
    if [ "$rc" -ne 0 ]; then
      docker rm -f "$CNAME" >/dev/null 2>&1
      die "setup failed (exit $rc): $line — removed $CNAME; fix .opsx/dev.yaml and retry"
    fi
  done
  trap - INT TERM HUP
  CREATING=""
  return 0
}

tty_flags() {
  TTY=(-i)
  if [ -t 0 ] && [ -t 1 ]; then TTY+=(-t -e "TERM=${TERM:-xterm}"); fi
}

cmd_exec() {
  local cwd
  resolve_checkout
  load_dev_yaml
  need_docker
  ensure_container
  unlock_dev
  cwd=$(pwd -P)
  tty_flags
  exec docker exec "${TTY[@]}" -u "$USER_ID:$GROUP_ID" -w "$cwd" -e "HOME=$HOME_IN" "$CNAME" "$@"
}

cmd_shell() {
  local cwd
  resolve_checkout
  load_dev_yaml
  need_docker
  ensure_container
  unlock_dev
  cwd=$(pwd -P)
  tty_flags
  # shellcheck disable=SC2016
  exec docker exec "${TTY[@]}" -u "$USER_ID:$GROUP_ID" -w "$cwd" -e "HOME=$HOME_IN" "$CNAME" \
    sh -c 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'
}

cmd_status() {
  local info img state hash have=""
  resolve_checkout
  need_docker
  info=$(docker container inspect -f '{{.Config.Image}}|{{.State.Status}}|{{index .Config.Labels "opsx.dev.hash"}}' "$CNAME" 2>/dev/null) || info=""
  if [ -z "$info" ]; then
    say "no dev container for $CHECKOUT ($CNAME would be created by: opsx dev <cmd>)"
    return 0
  fi
  IFS='|' read -r img state hash <<<"$info"
  say "container: $CNAME"
  say "image:     $img"
  say "state:     $state"
  if [ -f "$CHECKOUT/.opsx/dev.yaml" ]; then
    have=$( (load_dev_yaml && config_hash) 2>/dev/null) || have=""
    if [ -n "$have" ] && [ "$have" != "$hash" ]; then
      say "config:    .opsx/dev.yaml changed — recreated on next opsx dev"
    fi
  fi
  return 0
}

# Remove one container; prints "removed <name>" when it existed. Returns 1
# (with a warning) only when an existing container could not be removed.
rm_container() {
  local name=$1 existed=0 out
  docker container inspect "$name" >/dev/null 2>&1 && existed=1
  if ! out=$(docker rm -f "$name" 2>&1); then
    case "$out" in
      *"No such container"*|*"no such container"*) return 0 ;;
    esac
    [ "$existed" -eq 1 ] || return 0
    warn "could not remove $name: $(printf '%s' "$out" | tail -n 1)"
    return 1
  fi
  [ "$existed" -eq 1 ] && say "removed container $name"
  return 0
}

cmd_rm() {
  local all=0 change="" rc=0 n names name out outp
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)    all=1; shift ;;
      --change) [ $# -ge 2 ] || die "--change needs a name" 2; change=$2; shift 2 ;;
      *) die "--rm: unknown argument '$1' (use: --rm [--all])" 2 ;;
    esac
  done
  if ! command -v docker >/dev/null 2>&1; then
    note "docker is not installed — no containers to remove"
    return 0
  fi
  if [ "$all" -eq 1 ]; then
    resolve_project
    names=$(docker ps -a --filter "label=opsx.dev.project=$PROJECT" --format '{{.Names}}' 2>/dev/null) || names=""
    n=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      rm_container "$name" || rc=1
      n=$((n + 1))
    done <<<"$names"
    [ "$n" -gt 0 ] || say "no opsx containers in project $PROJECT"
    return "$rc"
  fi
  if [ -n "$change" ]; then
    resolve_project
    NAME=$(sanitize "$change"); CNAME=opsx-dev-$PROJECT-$NAME
  else
    resolve_checkout
  fi
  out=$(rm_container "$CNAME") || rc=1
  [ -n "$out" ] && say "$out"
  outp=$(rm_container "$CNAME-preview") || rc=1
  [ -n "$outp" ] && say "$outp"
  [ -n "$out$outp" ] || [ "$rc" -ne 0 ] || say "no containers to remove ($CNAME)"
  return "$rc"
}

cmd_rm_preview() {
  local name=${1:-}
  [ -n "$name" ] || die "usage: opsx-dev.sh --rm-preview <name>" 2
  command -v docker >/dev/null 2>&1 || return 0
  resolve_project
  rm_container "opsx-dev-$PROJECT-$(sanitize "$name")-preview"
}

cmd_preview_run() {
  local port=${1:-} cmd=${2:-}
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ -z "$cmd" ]; then
    die "usage: opsx-dev.sh --preview-run <port> <shell command>" 2
  fi
  resolve_checkout
  load_dev_yaml
  need_docker
  ensure_container
  unlock_dev
  [ -n "$IMAGE_REF" ] || resolve_image
  shape_args preview
  docker rm -f "$CNAME-preview" >/dev/null 2>&1
  exec docker run --rm --init --name "$CNAME-preview" "${SHAPE[@]}" \
    -u "$USER_ID:$GROUP_ID" -w "$CHECKOUT" -e "PORT=$port" -e HOST=127.0.0.1 \
    --entrypoint sh "$IMAGE_REF" -c "$cmd"
}

main() {
  [ $# -gt 0 ] || { usage >&2; exit 2; }
  case "$1" in
    help|-h|--help) usage; exit 0 ;;
    --shell)        shift; [ $# -eq 0 ] || die "--shell takes no arguments" 2; cmd_shell ;;
    --status)       shift; [ $# -eq 0 ] || die "--status takes no arguments" 2; cmd_status ;;
    --rm)           shift; cmd_rm "$@" ;;
    --rm-preview)   shift; cmd_rm_preview "$@" ;;
    --preview-run)  shift; [ $# -eq 2 ] || die "usage: opsx-dev.sh --preview-run <port> <shell command>" 2
                    cmd_preview_run "$@" ;;
    --)             shift; [ $# -gt 0 ] || die "missing command after --" 2; cmd_exec "$@" ;;
    -*)             die "unknown option: $1 (to run a command that starts with -, use: opsx dev -- $1 ...)" 2 ;;
    *)              cmd_exec "$@" ;;
  esac
}

main "$@"
