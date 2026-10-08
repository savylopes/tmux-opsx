#!/usr/bin/env bash
# opsx-preview.sh — run a change's app from its worktree and publish it
# through /expose (the `/opsx-run <change> preview` action).
#
# Usage:
#   opsx-preview.sh up   <change>|--main   start (or reuse) the preview, print its URL
#   opsx-preview.sh stop <change>|--all    remove the route, kill the app and its window
#   opsx-preview.sh url  <change>|--main   reprint (and copy) the URL of a running preview
#   opsx-preview.sh share <change>|--main [--for <recipient>] [--ttl <dur>]
#                                          share link for a running preview (expose.sh share)
#   opsx-preview.sh share <change>|--main --list | --revoke <recipient|id|all>
#   opsx-preview.sh list                   previews recorded for this project
#   opsx-preview.sh prune                  forget state left by changes whose worktree is gone
#   opsx-preview.sh help
#
# <change> runs from the worktree checked out on branch opsx/<change>; --main
# runs the main checkout and publishes it under the name `main`. The project
# is the main checkout's folder name, the same from every worktree, so the URL
# is https://<change>--<project>.<domain> and stays the same across restarts.
# Like every exposure it needs a login: the owner's cookie, or a share link
# from `share` (one host only, expires after --ttl, default 7d). The app must
# listen on 127.0.0.1 (HOST is exported for that); `up` fails, stops the app
# and closes its window when expose.sh refuses a non-loopback bind.
#
# Recipe, from the checkout being previewed:
#   .opsx/preview.yaml   flat `key: value` lines (# comments, one layer of
#                        matching quotes stripped):
#                          cmd:     the app command (required)
#                          install: run once, and again when it or a lockfile changes
#                          health:  path polled until 2xx/3xx (default /)
#                          timeout: seconds to wait for health (default 120)
#   package.json         otherwise, a `dev` script is run with the package
#                        manager its lockfile implies (pnpm-lock.yaml -> pnpm,
#                        yarn.lock -> yarn, bun.lock[b] -> bun, else npm):
#                        `<pm> run dev --port $PORT` (npm: `npm run dev -- --port $PORT`),
#                        install `<pm> install`.
# cmd and install run through `bash -c` in the checkout with PORT (a free port
# in 3100-3999, the last one reused when free) and HOST=127.0.0.1 exported.
#
# The app runs in its own process group inside a tmux window tagged
# @opsx_preview=<change> (created by opsx-window.sh preview-start), and its
# output also goes to a log file. `stop` sends TERM to the group, KILL after
# 5 seconds, removes the route and kills the window. A recorded group is only
# signalled while one of its processes still carries OPSX_PREVIEW=<change> and
# OPSX_PREVIEW_PROJECT=<project> in its environment (a reused id is left
# alone). Every path that drops a record also removes the route. `stop` with
# no record still closes a leftover tagged window, and warns (exit 1) when a
# window could not be closed.
#
# One `up` or `stop` per preview at a time: each holds <name>.lock (flock, or
# a <name>.lockd directory where flock is missing) for its whole run,
# including the health wait. A second `up` waits for the first and then
# reuses its preview; a `stop` waits for a starting `up` to finish. The wait
# is capped by $OPSX_PREVIEW_LOCK_WAIT seconds (default 600).
#
# expose.sh: $OPSX_EXPOSE_SH, else ../expose/expose.sh next to this skill,
# else expose.sh on PATH. Without a configured expose, `up` fails before
# starting anything and names `install.sh --expose-domain`.
#
# State:  ${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/preview/<project>/
#         <name>.env (record), <name>.log, <name>.launch.sh, <name>.port,
#         <name>.install.log, <name>.lock, <sha of checkout>.install
#         Failure tails show only the current run's part of <name>.log; the
#         log is emptied before a start once it passes 1 MiB. `prune` (run by
#         land after removing the worktree, and on every up/stop/list) deletes
#         the files of changes with no record and no worktree, and install
#         hashes of checkouts that no longer exist.
#
# Exit codes: 0 ok (stop with nothing running is ok), 1 failure, 2 usage.
# `up` and `url` print the URL as the last line of standard output; `share`
# relays expose.sh share (the link is its last line) and its exit code.

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
WINDOW_SH=${OPSX_WINDOW_SH:-$SELF_DIR/opsx-window.sh}
STATE_ROOT=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-opsx/preview
PORT_MIN=3100
PORT_MAX=3999
STOP_GRACE=5
LOG_MAX_BYTES=1048576
LOCK_WAIT=${OPSX_PREVIEW_LOCK_WAIT:-600}
[[ "$LOCK_WAIT" =~ ^[0-9]+$ ]] || LOCK_WAIT=600

say()  { printf '%s\n' "$*"; }
warn() { printf 'opsx-preview: warning: %s\n' "$*" >&2; }
err()  { printf 'opsx-preview: %s\n' "$*" >&2; }
die()  { err "$1"; exit "${2:-1}"; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; }
short_usage() { err "usage: opsx-preview.sh up|stop|url|share <change>|--main, stop --all, list, prune — see: opsx-preview.sh help"; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1
  fi
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# ---------- project and checkout ----------

MAIN_DIR=""
PROJECT=""
PROJECT_STATE=""

resolve_project() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  if [ -z "$common" ]; then
    common=$(git rev-parse --git-common-dir 2>/dev/null) && common=$(cd -- "$common" 2>/dev/null && pwd) || common=""
  fi
  [ -n "$common" ] || die "not inside a git repository — run from the project (or a change worktree)."
  MAIN_DIR=$(dirname -- "$common")
  PROJECT=$(basename -- "$MAIN_DIR")
  PROJECT_STATE=$STATE_ROOT/$PROJECT
}

# Worktree path checked out on refs/heads/opsx/$1, empty when none.
change_worktree() {
  git -C "$MAIN_DIR" worktree list --porcelain 2>/dev/null \
    | awk -v b="refs/heads/opsx/$1" '
        /^worktree /{ path=substr($0,10) }
        /^branch /  { if (substr($0,8)==b) { print path; exit } }'
}

# Sets NAME and CHECKOUT from `<change>` or `--main`.
NAME=""
CHECKOUT=""
resolve_target() {
  local arg=${1:-}
  [ -n "$arg" ] || die "missing <change> (or --main)" 2
  if [ "$arg" = "--main" ]; then
    NAME=main
    CHECKOUT=$MAIN_DIR
    return 0
  fi
  case "$arg" in -*) die "unknown option: $arg" 2 ;; esac
  valid_name "$arg" || die "invalid change name '$arg'" 2
  NAME=$arg
  CHECKOUT=$(change_worktree "$arg")
  [ -n "$CHECKOUT" ] && [ -d "$CHECKOUT" ] \
    || die "no worktree is checked out on opsx/$arg — apply the change first (/opsx-run $arg apply)."
}

# ---------- state records ----------

record_file() { printf '%s/%s.env' "$PROJECT_STATE" "$1"; }

R_NAME=""; R_CHECKOUT=""; R_PORT=""; R_PGID=""; R_WINDOW_ID=""; R_LOG=""; R_URL=""; R_HEALTH=""
read_record() {
  local f=$1 k v
  R_NAME=""; R_CHECKOUT=""; R_PORT=""; R_PGID=""; R_WINDOW_ID=""; R_LOG=""; R_URL=""; R_HEALTH=""
  [ -f "$f" ] || return 1
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      NAME)      R_NAME=$v ;;
      CHECKOUT)  R_CHECKOUT=$v ;;
      PORT)      R_PORT=$v ;;
      PGID)      R_PGID=$v ;;
      WINDOW_ID) R_WINDOW_ID=$v ;;
      LOG)       R_LOG=$v ;;
      URL)       R_URL=$v ;;
      HEALTH)    R_HEALTH=$v ;;
    esac
  done < "$f"
  [ -n "$R_NAME" ]
}

write_record() {  # write_record <name> <checkout> <port> <pgid> <window> <log> <url> <health>
  local f tmp
  f=$(record_file "$1")
  tmp="$f.tmp.$$"
  printf 'NAME=%s\nCHECKOUT=%s\nPORT=%s\nPGID=%s\nWINDOW_ID=%s\nLOG=%s\nURL=%s\nHEALTH=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$tmp" && mv -f "$tmp" "$f"
}

# ---------- per-preview lock ----------

# One up/stop per preview at a time. With flock the lock lives on fd 9 and is
# dropped when this process exits, however it exits; every child that may
# outlive us (tmux server, install, expose) is started with 9>&- so it never
# keeps the lock. Without flock: a <name>.lockd directory holding our pid,
# taken over once that pid is gone.
LOCK_KIND=""; LOCK_PATH=""
use_flock() { [ -z "${OPSX_PREVIEW_NO_FLOCK:-}" ] && command -v flock >/dev/null 2>&1; }

lock_busy_note() {  # lock_busy_note <name> <holder pid>
  say "preview $1: waiting for another opsx-preview.sh run${2:+ (pid $2)} to finish (up to ${LOCK_WAIT}s)"
}

lock_acquire() {
  local name=$1 lf holder="" noted=0 left deadline
  deadline=$((SECONDS + LOCK_WAIT))
  if use_flock; then
    lf=$PROJECT_STATE/$name.lock
    while :; do
      exec 9>>"$lf" || die "cannot open $lf"
      if ! flock -n 9; then
        holder=$(head -n 1 "$lf" 2>/dev/null)
        [ "$noted" -eq 1 ] || { lock_busy_note "$name" "$holder"; noted=1; }
        left=$((deadline - SECONDS)); [ "$left" -gt 0 ] || left=0
        flock -w "$left" 9 \
          || die "preview $name is still busy after ${LOCK_WAIT}s (another opsx-preview.sh run${holder:+, pid $holder}) — try again later"
      fi
      # prune may have removed the file while we waited on it: only a lock on
      # the file that is still there counts.
      [ "$lf" -ef /dev/fd/9 ] && break
      exec 9>&-
    done
    printf '%s\n' "$$" > "$lf"
    LOCK_KIND=flock; LOCK_PATH=$lf
    return 0
  fi
  lf=$PROJECT_STATE/$name.lockd
  while ! mkdir "$lf" 2>/dev/null; do
    holder=$(cat "$lf/pid" 2>/dev/null)
    if { [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; } \
       || { [ -z "$holder" ] && [ -n "$(find "$lf" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }; then
      # Its holder is gone without releasing it: take the lock over.
      mv "$lf" "$lf.stale.$$" 2>/dev/null && rm -rf "$lf.stale.$$"
      continue
    fi
    [ "$noted" -eq 1 ] || { lock_busy_note "$name" "$holder"; noted=1; }
    [ "$SECONDS" -lt "$deadline" ] \
      || die "preview $name is still busy after ${LOCK_WAIT}s (another opsx-preview.sh run${holder:+, pid $holder}) — try again later"
    sleep 0.2
  done
  printf '%s\n' "$$" > "$lf/pid"
  LOCK_KIND=dir; LOCK_PATH=$lf
  trap lock_release EXIT
}

# The flock file is unlinked while still held (waiters re-check that they
# locked the live file), so a stop leaves no lock file behind.
lock_release() {
  case "$LOCK_KIND" in
    flock) rm -f "$LOCK_PATH"; exec 9>&- ;;
    dir)   rm -rf "$LOCK_PATH" ;;
  esac
  LOCK_KIND=""; LOCK_PATH=""
}

# True when an up/stop of preview $1 holds its lock right now.
lock_held() {
  local lf=$PROJECT_STATE/$1.lock holder
  if [ -d "$PROJECT_STATE/$1.lockd" ]; then
    holder=$(cat "$PROJECT_STATE/$1.lockd/pid" 2>/dev/null)
    [ -z "$holder" ] || kill -0 "$holder" 2>/dev/null && return 0
  fi
  [ -e "$lf" ] && command -v flock >/dev/null 2>&1 || return 1
  ( exec 8>>"$lf" && flock -n 8 ) 2>/dev/null && return 1
  return 0
}

# ---------- processes, ports, health ----------

group_alive() { [ -n "${1:-}" ] && [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 1 ] && kill -0 -- "-$1" 2>/dev/null; }

# Prints one environment variable per line for pid $1 (empty when unreadable).
proc_env() {
  if [ -r "/proc/$1/environ" ]; then
    tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null
  else
    # BSD/macOS: `ps e` appends the environment to the command line.
    ps eww -o command= -p "$1" 2>/dev/null | tr ' ' '\n'
  fi
}

# True when some process in group $2 still belongs to preview $1 of this
# project: the launch script exports OPSX_PREVIEW and OPSX_PREVIEW_PROJECT and
# every process in the group inherits them. Guards against a reused group id.
group_is_preview() {
  local name=$1 pgid=$2 pid env
  group_alive "$pgid" || return 1
  for pid in $(ps -A -o pid=,pgid= 2>/dev/null | awk -v g="$pgid" '$2==g { print $1 }'); do
    env=$(proc_env "$pid")
    printf '%s\n' "$env" | grep -Fqx "OPSX_PREVIEW=$name" \
      && printf '%s\n' "$env" | grep -Fqx "OPSX_PREVIEW_PROJECT=$PROJECT" \
      && return 0
  done
  return 1
}

# TERM the group of preview $1, wait up to $STOP_GRACE seconds, then KILL.
# A group that no longer belongs to the preview is never signalled.
kill_group() {
  local name=$1 pgid=${2:-} i
  group_alive "$pgid" || return 0
  if ! group_is_preview "$name" "$pgid"; then
    warn "process group $pgid no longer belongs to preview $name — not signalling it"
    return 0
  fi
  kill -TERM -- "-$pgid" 2>/dev/null
  for ((i = 0; i < STOP_GRACE * 10; i++)); do
    group_alive "$pgid" || return 0
    sleep 0.1
  done
  group_is_preview "$name" "$pgid" && kill -KILL -- "-$pgid" 2>/dev/null
  sleep 0.1
  return 0
}

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

valid_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# Ports held by recorded previews of any project: a starting app may not be
# listening yet, so a free-looking port can still be spoken for.
recorded_ports() {
  local f
  for f in "$STATE_ROOT"/*/*.env; do
    [ -f "$f" ] && awk -F= '$1=="PORT" { print $2 }' "$f"
  done
}

pick_port() {
  local last=${1:-} p taken
  taken=" $(recorded_ports | tr '\n' ' ') "
  if valid_port "$last" && [[ "$taken" != *" $last "* ]] && ! port_in_use "$last"; then
    printf '%s' "$last"; return 0
  fi
  for ((p = PORT_MIN; p <= PORT_MAX; p++)); do
    [[ "$taken" == *" $p "* ]] && continue
    port_in_use "$p" && continue
    printf '%s' "$p"; return 0
  done
  return 1
}

# HTTP status code of GET http://127.0.0.1:$1$2, "000" when unreachable.
http_status() {
  local port=$1 path=$2 code line
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port$path" 2>/dev/null) || true
    printf '%s' "${code:-000}"
    return 0
  fi
  line=$( { exec 3<>"/dev/tcp/127.0.0.1/$port" || exit 1
            printf 'GET %s HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nConnection: close\r\n\r\n' "$path" "$port" >&3
            timeout 3 head -n1 <&3; } 2>/dev/null) || line=""
  code=$(printf '%s' "$line" | awk '{print $2}')
  printf '%s' "${code:-000}"
}

healthy() {
  local code
  code=$(http_status "$1" "$2")
  [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

# ---------- expose ----------

EXPOSE=""
find_expose() {
  if [ -n "${OPSX_EXPOSE_SH:-}" ]; then
    [ -x "$OPSX_EXPOSE_SH" ] && EXPOSE=$OPSX_EXPOSE_SH
    return 0
  fi
  if [ -x "$SELF_DIR/../expose/expose.sh" ]; then
    EXPOSE=$(cd -- "$SELF_DIR/../expose" && pwd)/expose.sh
  elif command -v expose.sh >/dev/null 2>&1; then
    EXPOSE=$(command -v expose.sh)
  fi
}

# Returns 0 when expose is usable; otherwise prints why to stderr and returns 1.
expose_preflight() {
  local out rc
  find_expose
  if [ -z "$EXPOSE" ]; then
    err "expose is not installed — previews need it: run install.sh --expose-domain <domain>"
    return 1
  fi
  out=$("$EXPOSE" list --json 2>&1 9>&-); rc=$?
  case "$rc" in
    0) return 0 ;;
    3) [ -n "$out" ] && err "$out"
       err "expose is not configured — previews need it: run install.sh --expose-domain <domain>" ;;
    4) [ -n "$out" ] && err "$out"
       err "the expose proxy is not running — check it with expose.sh list, or re-run install.sh --expose-domain <domain>" ;;
    *) [ -n "$out" ] && err "$out"
       err "expose.sh list failed (exit $rc)" ;;
  esac
  return 1
}

# Remove the route of preview $1. Best effort: never fatal, but a failure is
# reported with the command to finish the job by hand.
expose_down() {
  local out
  find_expose
  [ -n "$EXPOSE" ] || return 0
  out=$("$EXPOSE" down "$1" --project "$PROJECT" 2>&1 9>&-) && return 0
  warn "could not remove the route for $1${out:+: $(printf '%s' "$out" | tail -n 1)} — remove it with: expose.sh down $1 --project $PROJECT"
  return 0
}

# Strip an OSC 8 hyperlink wrapper, in case expose printed one.
strip_osc8() { sed -e 's/\x1b]8;;[^\x07\x1b]*\(\x07\|\x1b\\\)//g'; }

# ---------- windows (all tmux work goes through opsx-window.sh) ----------

win() { ( cd -- "$MAIN_DIR" && "$WINDOW_SH" "$@" ) 9>&-; }

# Close every window tagged for preview $1. Returns 1, with a warning, when
# that could not be done (tmux unreachable, kill-window failed); prints the
# window helper's "closed ..." lines on stdout. Without tmux there is nothing
# to close.
CLOSED_OUT=""
close_windows() {
  local out
  CLOSED_OUT=""
  command -v tmux >/dev/null 2>&1 || return 0
  if out=$(win preview-kill "$1" 2>&1); then
    CLOSED_OUT=$(printf '%s\n' "$out" | grep '^closed ' || true)
    return 0
  fi
  warn "could not close the preview window for $1${out:+: $(printf '%s' "$out" | tail -n 1)} — close the tmux window tagged @opsx_preview=$1 (titled 'ox >$1') by hand"
  return 1
}

# preview-find looks across every session for this project's windows, so the
# answer does not depend on which session the caller is in.
window_alive() {  # window_alive <name> [<expected id>]
  local ids
  ids=$(win preview-find "$1" 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  [ -z "${2:-}" ] || printf '%s\n' "$ids" | grep -Fqx -- "$2"
}

# Running = record has a URL, its window exists, its group is the preview's,
# and the health check passes. Uses the R_* fields of the last read_record.
record_running() {
  [ -n "$R_URL" ] && window_alive "$1" "$R_WINDOW_ID" && group_is_preview "$1" "$R_PGID" \
    && healthy "$R_PORT" "${R_HEALTH:-/}"
}

# ---------- recipe ----------

RECIPE_SOURCE=""; R_CMD=""; R_INSTALL=""; R_HEALTH_PATH="/"; R_TIMEOUT=120

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

load_declared_recipe() {
  local file=$1 k v have_cmd=0
  RECIPE_SOURCE="declared (.opsx/preview.yaml)"
  while IFS=$'\t' read -r k v; do
    case "$k" in
      cmd)     R_CMD=$v; have_cmd=1 ;;
      install) R_INSTALL=$v ;;
      health)  R_HEALTH_PATH=$v ;;
      timeout) R_TIMEOUT=$v ;;
      '!bad')  warn ".opsx/preview.yaml: ignoring a line that is not a flat 'key: value' pair: $v" ;;
      *)       warn ".opsx/preview.yaml: unknown key '$k' (known: cmd, install, health, timeout)" ;;
    esac
  done < <(read_flat_yaml "$file")
  [ "$have_cmd" -eq 1 ] && [ -n "$R_CMD" ] \
    || die "$file has no 'cmd' — add a line like: cmd: npm run dev -- --port \$PORT"
  [ -n "$R_HEALTH_PATH" ] || R_HEALTH_PATH=/
  case "$R_HEALTH_PATH" in /*) ;; *) R_HEALTH_PATH="/$R_HEALTH_PATH" ;; esac
  [[ "$R_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$R_TIMEOUT" -gt 0 ] \
    || die "$file: timeout must be a whole number of seconds (got '$R_TIMEOUT')"
}

has_dev_script() {
  local pkg=$1
  if command -v node >/dev/null 2>&1; then
    node -e '
      const fs = require("fs");
      try {
        const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        process.exit(p && p.scripts && typeof p.scripts.dev === "string" && p.scripts.dev.trim() ? 0 : 1);
      } catch (e) { process.exit(1); }' "$pkg" 2>/dev/null
  else
    grep -Eq '"dev"[[:space:]]*:' "$pkg"
  fi
}

detect_recipe() {
  local dir=$1 pm lock=""
  if [ -f "$dir/package.json" ] && has_dev_script "$dir/package.json"; then
    if   [ -f "$dir/pnpm-lock.yaml" ]; then pm=pnpm; lock=pnpm-lock.yaml
    elif [ -f "$dir/yarn.lock" ];      then pm=yarn; lock=yarn.lock
    elif [ -f "$dir/bun.lock" ];       then pm=bun;  lock=bun.lock
    elif [ -f "$dir/bun.lockb" ];      then pm=bun;  lock=bun.lockb
    else pm=npm; [ -f "$dir/package-lock.json" ] && lock=package-lock.json
    fi
    if [ "$pm" = npm ]; then
      # npm needs `--` to forward the flag to the script.
      R_CMD="npm run dev -- --port \$PORT"
    else
      R_CMD="$pm run dev --port \$PORT"
    fi
    R_INSTALL="$pm install"
    RECIPE_SOURCE="detected"
    say "detected: $pm dev script (package.json${lock:+ + $lock}) — cmd: $R_CMD"
    say "  (add .opsx/preview.yaml to override)"
    return 0
  fi
  die "don't know how to run $dir — add .opsx/preview.yaml with at least a 'cmd:' line (e.g. cmd: npm run dev -- --port \$PORT), or a package.json with a \"dev\" script."
}

resolve_recipe() {
  local dir=$1
  if [ -f "$dir/.opsx/preview.yaml" ]; then
    load_declared_recipe "$dir/.opsx/preview.yaml"
  else
    detect_recipe "$dir"
  fi
}

# ---------- install ----------

LOCKFILES="pnpm-lock.yaml yarn.lock bun.lock bun.lockb package-lock.json npm-shrinkwrap.json
requirements.txt poetry.lock uv.lock Pipfile.lock Gemfile.lock composer.lock go.sum Cargo.lock"

install_hash() {
  local dir=$1 f
  {
    printf 'install:%s\n' "$R_INSTALL"
    for f in $LOCKFILES; do
      [ -f "$dir/$f" ] || continue
      printf 'lockfile:%s\n' "$f"
      cat "$dir/$f"
    done
  } | sha256
}

run_install() {  # run_install <dir> <port>
  local dir=$1 port=$2 key hash_file want have="" log rc
  [ -n "$R_INSTALL" ] || return 0
  key=$(printf '%s' "$dir" | sha256)
  hash_file=$PROJECT_STATE/$key.install
  want=$(install_hash "$dir")
  [ -f "$hash_file" ] && have=$(head -n 1 "$hash_file" 2>/dev/null)
  if [ "$want" = "$have" ]; then
    say "install: up to date (skipped)"
    return 0
  fi
  log=$PROJECT_STATE/$NAME.install.log
  say "install: $R_INSTALL"
  ( cd -- "$dir" && PORT=$port HOST=127.0.0.1 bash -c "$R_INSTALL" ) > "$log" 2>&1 9>&-
  rc=$?
  if [ "$rc" -ne 0 ]; then
    err "install failed (exit $rc): $R_INSTALL — last lines of $log:"
    tail -n 20 "$log" | sed 's/^/  | /' >&2
    exit "$rc"
  fi
  # Second line: the checkout, so prune can drop hashes of removed worktrees.
  printf '%s\n%s\n' "$want" "$dir" > "$hash_file"
  say "install: ok"
}

# ---------- launch ----------

write_launch_script() {  # write_launch_script <file> <dir> <port> <log> <pgid file>
  local file=$1 dir=$2 port=$3 log=$4 pgidf=$5
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by opsx-preview.sh for preview %s — do not edit.\n' "$NAME"
    printf 'cd -- %q || exit 1\n' "$dir"
    printf 'export PATH=%q\n' "$PATH"
    printf 'export PORT=%q HOST=127.0.0.1 OPSX_PREVIEW=%q OPSX_PREVIEW_PROJECT=%q\n' "$port" "$NAME" "$PROJECT"
    printf 'log=%q\npgidf=%q\ncmd=%q\n' "$log" "$pgidf" "$R_CMD"
    cat <<'EOF'
printf '\n=== opsx-preview %s: %s (PORT=%s) — %s\n' "$OPSX_PREVIEW" "$cmd" "$PORT" "$(date '+%F %T')" | tee -a "$log"
# The app gets its own process group so `stop` can kill dev-server grandchildren.
# The inner bash writes its pid, which is the group id (session leader).
if command -v setsid >/dev/null 2>&1; then
  setsid bash -c 'printf "%s\n" "$$" > "$1"; exec bash -c "$2"' _ "$pgidf" "$cmd" > >(tee -a "$log") 2>&1 &
  pid=$!
else
  set -m
  bash -c "$cmd" > >(tee -a "$log") 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$pgidf"
  set +m
fi
wait "$pid"
rc=$?
sleep 0.2
printf '\n=== opsx-preview %s: app exited with code %s — %s\n' "$OPSX_PREVIEW" "$rc" "$(date '+%F %T')" | tee -a "$log"
exit "$rc"
EOF
  } > "$file"
  chmod 700 "$file"
}

# Clean up a failed start: stop the group, remove any route, close the window,
# drop the record.
# Byte offset of <name>.log where this run's output starts: failure tails
# show only what this run wrote, never an earlier run's errors.
LOG_OFF=0
abort_start() {
  local pgid=$1 log=$2 reason=$3 lines
  err "$reason"
  sleep 0.3
  lines=$(tail -c "+$((LOG_OFF + 1))" "$log" 2>/dev/null | tail -n 20)
  if [ -n "$lines" ]; then
    err "last lines of this run in $log:"
    printf '%s\n' "$lines" | sed 's/^/  | /' >&2
  fi
  kill_group "$NAME" "$pgid"
  expose_down "$NAME"
  close_windows "$NAME" || true
  rm -f "$(record_file "$NAME")" "$PROJECT_STATE/$NAME.pgid"
  exit 1
}

# ---------- subcommands ----------

cmd_up() {
  local arg=${1:-} f last_port="" port log launch pgidf out errf wid pgid="" i start url rc
  resolve_target "$arg"
  mkdir -p "$PROJECT_STATE" || die "cannot create $PROJECT_STATE"
  chmod 700 "$PROJECT_STATE" 2>/dev/null || true
  # Held until we exit: a concurrent up waits here and then reuses this
  # preview instead of starting a second app or tearing this one down.
  lock_acquire "$NAME"
  f=$(record_file "$NAME")

  # Already running: window alive, group alive and healthy -> same URL.
  if read_record "$f"; then
    if record_running "$NAME"; then
      say "preview $NAME is already running on 127.0.0.1:$R_PORT (window $R_WINDOW_ID)"
      say "$R_URL"
      return 0
    fi
    say "preview $NAME: stale record (window, process or health gone) — restarting"
    last_port=$R_PORT
    kill_group "$NAME" "$R_PGID"
    expose_down "$NAME"
    close_windows "$NAME" || true
    rm -f "$f"
  else
    # No record: clear what a start killed half-way may have left behind.
    pgid=$(cat "$PROJECT_STATE/$NAME.pgid" 2>/dev/null || true)
    group_is_preview "$NAME" "$pgid" && kill_group "$NAME" "$pgid"
    pgid=""
    if window_alive "$NAME"; then close_windows "$NAME" || true; fi
  fi
  [ -n "$last_port" ] || last_port=$(cat "$PROJECT_STATE/$NAME.port" 2>/dev/null || true)

  # Both checks run before anything starts. When expose is unusable, still
  # report a recipe problem in the same run so both can be fixed at once.
  if ! expose_preflight; then
    ( resolve_recipe "$CHECKOUT" >/dev/null ) || true
    exit 1
  fi
  resolve_recipe "$CHECKOUT"

  port=$(pick_port "$last_port") || die "no free port in $PORT_MIN-$PORT_MAX"
  run_install "$CHECKOUT" "$port"

  log=$PROJECT_STATE/$NAME.log
  launch=$PROJECT_STATE/$NAME.launch.sh
  pgidf=$PROJECT_STATE/$NAME.pgid
  rm -f "$pgidf"
  : >> "$log"
  [ "$(wc -c < "$log" | tr -d ' ')" -le "$LOG_MAX_BYTES" ] || : > "$log"
  LOG_OFF=$(wc -c < "$log" | tr -d ' ')
  write_launch_script "$launch" "$CHECKOUT" "$port" "$log" "$pgidf"
  printf '%s\n' "$port" > "$PROJECT_STATE/$NAME.port"

  out=$(win preview-start "$NAME" --cwd "$CHECKOUT" --script "$launch" 2>&1) \
    || die "could not open the preview window: $out"
  wid=$(printf '%s\n' "$out" | awk '/^created /{print $2; exit}')
  printf '%s\n' "$out" | grep '^# attach' || true
  say "starting $NAME ($RECIPE_SOURCE) on 127.0.0.1:$port in window $wid — log: $log"

  for ((i = 0; i < 50; i++)); do
    [ -s "$pgidf" ] && break
    sleep 0.1
  done
  pgid=$(cat "$pgidf" 2>/dev/null || true)
  write_record "$NAME" "$CHECKOUT" "$port" "$pgid" "$wid" "$log" "" "$R_HEALTH_PATH"
  [ -n "$pgid" ] || abort_start "" "$log" "the app did not start (no process group recorded)"

  start=$SECONDS
  while :; do
    # Alive first: a healthy answer from a process that is not ours (our app
    # lost the port and is exiting) must not count.
    group_alive "$pgid" \
      || abort_start "$pgid" "$log" "the app exited before http://127.0.0.1:$port$R_HEALTH_PATH became healthy"
    if healthy "$port" "$R_HEALTH_PATH" && group_alive "$pgid"; then break; fi
    [ $((SECONDS - start)) -lt "$R_TIMEOUT" ] \
      || abort_start "$pgid" "$log" "http://127.0.0.1:$port$R_HEALTH_PATH not healthy after ${R_TIMEOUT}s (timeout)"
    sleep 0.5
  done
  say "healthy: http://127.0.0.1:$port$R_HEALTH_PATH"

  # stdout is parsed for the URL (its last line); stderr (clipboard status,
  # notes) is relayed as is. Both are shown when expose fails.
  errf=$PROJECT_STATE/$NAME.expose.err
  out=$("$EXPOSE" up "$port" --name "$NAME" --project "$PROJECT" 2>"$errf" 9>&-); rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 2 ] && grep -q "refusing to publish" "$errf" 2>/dev/null; then
      # Loopback only: the app listens on a public address. Relay expose's
      # reason (it names the address and 127.0.0.1) and clean up.
      abort_start "$pgid" "$log" "the app listens on a non-loopback address, so expose refused it — make the preview command bind to 127.0.0.1 (\$HOST) instead: $(awk 'NF' "$errf" | sed 's/^expose: //' | tail -n 2)"
    fi
    abort_start "$pgid" "$log" "expose.sh up failed (exit $rc): $( { cat "$errf"; printf '%s\n' "$out"; } 2>/dev/null | awk 'NF' | tail -n 3)"
  fi
  [ -s "$errf" ] && cat "$errf" >&2
  rm -f "$errf"
  # Relay expose's own lines (login note, ...) but not the URL itself.
  printf '%s\n' "$out" | awk 'NF { if (l != "") print l; l = $0 }' | strip_osc8
  url=$(printf '%s\n' "$out" | awk 'NF { l = $0 } END { print l }' | strip_osc8)
  write_record "$NAME" "$CHECKOUT" "$port" "$pgid" "$wid" "$log" "$url" "$R_HEALTH_PATH"
  say "preview $NAME is up (stop with: opsx-preview.sh stop ${arg})"
  say "$url"
}

# Returns 1 when a window could not be closed (the app and route are still
# stopped and the record dropped; a later stop retries the window).
stop_one() {  # stop_one <name>
  local name=$1 f pgid rc=0 did=0
  [ -d "$PROJECT_STATE" ] || { say "no preview running for $name"; return 0; }
  # Waits for a starting `up` of the same preview, so its app is recorded
  # (and stopped) rather than left running behind our back.
  lock_acquire "$name"
  f=$(record_file "$name")
  if ! read_record "$f"; then
    rm -f "$f"
    # No record, but a start killed half-way can leave a group and a window.
    pgid=$(cat "$PROJECT_STATE/$name.pgid" 2>/dev/null || true)
    if group_is_preview "$name" "$pgid"; then kill_group "$name" "$pgid"; did=1; fi
    close_windows "$name" || rc=1
    [ -z "$CLOSED_OUT" ] || did=1
    rm -f "$PROJECT_STATE/$name.pgid"
    if [ "$did" -eq 1 ]; then
      say "stopped leftovers of preview $name (no record)${CLOSED_OUT:+ — $CLOSED_OUT}"
    else
      say "no preview running for $name"
    fi
    lock_release
    return "$rc"
  fi
  kill_group "$name" "$R_PGID"
  expose_down "$name"
  close_windows "$name" || rc=1
  rm -f "$f" "$PROJECT_STATE/$name.pgid"
  if [ "$rc" -eq 0 ]; then
    say "stopped preview $name (port ${R_PORT:-?})"
  else
    say "stopped preview $name (port ${R_PORT:-?}), but its window is still open"
  fi
  lock_release
  return "$rc"
}

cmd_stop() {
  local arg=${1:-} f n=0 rc=0
  [ -n "$arg" ] || die "usage: opsx-preview.sh stop <change>|--all" 2
  if [ "$arg" = "--all" ]; then
    for f in "$PROJECT_STATE"/*.env; do
      [ -f "$f" ] || continue
      stop_one "$(basename -- "$f" .env)" || rc=1
      n=$((n + 1))
    done
    [ "$n" -gt 0 ] || say "no previews running in project $PROJECT"
    return "$rc"
  fi
  if [ "$arg" = "--main" ]; then arg=main; fi
  valid_name "$arg" || die "invalid change name '$arg'" 2
  stop_one "$arg"
}

# Names that have per-preview files in the project state directory.
state_names() {
  local f b
  for f in "$PROJECT_STATE"/*; do
    [ -e "$f" ] || continue
    b=$(basename -- "$f")
    case "$b" in
      *.install.log) b=${b%.install.log} ;;
      *.launch.sh)   b=${b%.launch.sh} ;;
      *.expose.err)  b=${b%.expose.err} ;;
      *.env|*.log|*.port|*.pgid|*.lock|*.lockd) b=${b%.*} ;;
      *) continue ;;
    esac
    valid_name "$b" && printf '%s\n' "$b"
  done | sort -u
}

# Forget per-change state of changes that have no record, no worktree and no
# up/stop running, and install hashes of checkouts that are gone. Never
# touches `main` or a change whose worktree still exists.
prune_state() {
  local quiet=${1:-} wts branches name f dir n=0
  [ -d "$PROJECT_STATE" ] || { [ -n "$quiet" ] || say "nothing to prune in project $PROJECT"; return 0; }
  # Without a reliable worktree list nothing can be called gone.
  wts=$(git -C "$MAIN_DIR" worktree list --porcelain 2>/dev/null) || return 0
  [ -n "$wts" ] || return 0
  branches=$(printf '%s\n' "$wts" | awk '/^branch refs\/heads\/opsx\//{ print substr($0, 24) }')
  while IFS= read -r name; do
    [ -n "$name" ] && [ "$name" != main ] || continue
    [ -e "$PROJECT_STATE/$name.env" ] && continue
    printf '%s\n' "$branches" | grep -Fqx -- "$name" && continue
    lock_held "$name" && continue
    rm -f "$PROJECT_STATE/$name.log" "$PROJECT_STATE/$name.launch.sh" "$PROJECT_STATE/$name.port" \
          "$PROJECT_STATE/$name.install.log" "$PROJECT_STATE/$name.pgid" "$PROJECT_STATE/$name.expose.err" \
          "$PROJECT_STATE/$name.lock"
    rm -rf "$PROJECT_STATE/$name.lockd"
    n=$((n + 1))
    [ -n "$quiet" ] || say "pruned state of $name (no worktree, no record)"
  done < <(state_names)
  for f in "$PROJECT_STATE"/*.install; do
    [ -f "$f" ] || continue
    dir=$(sed -n 2p "$f" 2>/dev/null)
    # Hashes written before the checkout line was added are left alone.
    if [ -n "$dir" ] && [ ! -d "$dir" ]; then
      rm -f "$f"; n=$((n + 1))
      [ -n "$quiet" ] || say "pruned install hash of $dir (checkout gone)"
    fi
  done
  [ -n "$quiet" ] || [ "$n" -gt 0 ] || say "nothing to prune in project $PROJECT"
  return 0
}

cmd_url() {
  local arg=${1:-} name f out errf errout rc
  [ -n "$arg" ] || die "usage: opsx-preview.sh url <change>|--main" 2
  name=$arg
  [ "$arg" = "--main" ] && name=main
  valid_name "$name" || die "invalid change name '$arg'" 2
  f=$(record_file "$name")
  if ! { read_record "$f" && [ -n "$R_URL" ] && window_alive "$name" "$R_WINDOW_ID" \
          && group_is_preview "$name" "$R_PGID"; }; then
    die "no preview running for $name — start one with: opsx-preview.sh up $arg"
  fi
  find_expose
  if [ -n "$EXPOSE" ]; then
    # expose.sh url reprints and copies (OSC 52); fall back to the record.
    # Its stderr (clipboard status) is relayed only when it succeeded.
    errf=$PROJECT_STATE/$name.expose.err
    out=$("$EXPOSE" url "$name" --project "$PROJECT" 2>"$errf" 9>&-); rc=$?
    errout=$(cat "$errf" 2>/dev/null); rm -f "$errf"
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
      [ -n "$errout" ] && printf '%s\n' "$errout" >&2
      say "$(printf '%s\n' "$out" | awk 'NF { l = $0 } END { print l }' | strip_osc8)"
      return 0
    fi
  fi
  say "$R_URL"
}

# share <change>|--main [--for <r>] [--ttl <d>] [--list] [--revoke <r|id|all>]:
# expose.sh share for the preview's exposure, output and exit code relayed.
cmd_share() {
  local arg=${1:-} name f opts=()
  [ -n "$arg" ] || die "usage: opsx-preview.sh share <change>|--main [--for <recipient>] [--ttl <dur>] [--list] [--revoke <recipient|id|all>]" 2
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --for|--ttl|--revoke)
        [ $# -ge 2 ] || die "$1 needs a value" 2
        opts+=("$1" "$2"); shift 2 ;;
      --for=*|--ttl=*|--revoke=*|--list) opts+=("$1"); shift ;;
      *) die "share: unknown argument '$1' (options: --for, --ttl, --list, --revoke)" 2 ;;
    esac
  done
  name=$arg
  [ "$arg" = "--main" ] && name=main
  valid_name "$name" || die "invalid change name '$arg'" 2
  f=$(record_file "$name")
  if ! { read_record "$f" && [ -n "$R_URL" ] && window_alive "$name" "$R_WINDOW_ID" \
          && group_is_preview "$name" "$R_PGID"; }; then
    die "no preview running for $name — start one with: opsx-preview.sh up $arg"
  fi
  find_expose
  [ -n "$EXPOSE" ] || die "expose is not installed — previews need it: run install.sh --expose-domain <domain>"
  "$EXPOSE" share "$name" --project "$PROJECT" "${opts[@]+"${opts[@]}"}" 9>&-
}

cmd_list() {
  local f status n=0
  for f in "$PROJECT_STATE"/*.env; do
    [ -f "$f" ] || continue
    read_record "$f" || continue
    if [ "$n" -eq 0 ]; then
      printf '%-24s %-6s %-9s %-7s %-48s %s\n' NAME PORT STATUS WINDOW URL 'CHECKOUT / LOG'
    fi
    if group_is_preview "$R_NAME" "$R_PGID" && healthy "$R_PORT" "${R_HEALTH:-/}"; then status=up
    elif group_is_preview "$R_NAME" "$R_PGID"; then status=unhealthy
    else status=dead
    fi
    printf '%-24s %-6s %-9s %-7s %-48s %s  %s\n' "$R_NAME" "$R_PORT" "$status" "${R_WINDOW_ID:--}" \
      "${R_URL:--}" "${R_CHECKOUT:--}" "${R_LOG:--}"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || say "(no previews in project $PROJECT)"
  return 0
}

main() {
  local cmd=${1:-help}
  [ $# -gt 0 ] && shift
  case "$cmd" in
    help|-h|--help) usage; exit 0 ;;
    up|stop|url|share|list|prune) ;;
    *) err "unknown subcommand: $cmd"; short_usage; exit 2 ;;
  esac
  case "$cmd" in
    list|prune) [ $# -eq 0 ] || die "$cmd takes no arguments" 2 ;;
    share)      ;;
    *)          [ $# -le 1 ] || die "$cmd takes one argument (got: $*)" 2 ;;
  esac
  resolve_project
  case "$cmd" in
    up|stop|list) prune_state quiet ;;
  esac
  case "$cmd" in
    up)    cmd_up "$@" ;;
    stop)  cmd_stop "$@" ;;
    url)   cmd_url "$@" ;;
    share) cmd_share "$@" ;;
    list)  cmd_list ;;
    prune) prune_state ;;
  esac
}

main "$@"
