#!/usr/bin/env bash
# opsx-preview.sh — run a change's app from its worktree and publish it
# through /expose (the `/opsx-run <change> preview` action).
#
# Usage:
#   opsx-preview.sh up   <change>|--main   start (or reuse) the preview, print its URL
#   opsx-preview.sh stop <change>|--all    remove the route, kill the app and its window
#   opsx-preview.sh url  <change>|--main   reprint (and copy) the URL of a running preview
#   opsx-preview.sh list                   previews recorded for this project
#   opsx-preview.sh help
#
# <change> runs from the worktree checked out on branch opsx/<change>; --main
# runs the main checkout and publishes it under the name `main`. The project
# is the main checkout's folder name, the same from every worktree, so the URL
# is https://<change>--<project>.<domain> and stays the same across restarts.
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
# 5 seconds, removes the route and kills the window.
#
# expose.sh: $OPSX_EXPOSE_SH, else ../expose/expose.sh next to this skill,
# else expose.sh on PATH. Without a configured expose, `up` fails before
# starting anything and names `install.sh --expose-domain`.
#
# State:  ${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/preview/<project>/
#         <name>.env (record), <name>.log, <name>.launch.sh, <name>.port
#
# Exit codes: 0 ok (stop with nothing running is ok), 1 failure, 2 usage.
# `up` and `url` print the URL as the last line of standard output.

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
WINDOW_SH=${OPSX_WINDOW_SH:-$SELF_DIR/opsx-window.sh}
STATE_ROOT=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-opsx/preview
PORT_MIN=3100
PORT_MAX=3999
STOP_GRACE=5

say()  { printf '%s\n' "$*"; }
warn() { printf 'opsx-preview: warning: %s\n' "$*" >&2; }
err()  { printf 'opsx-preview: %s\n' "$*" >&2; }
die()  { err "$1"; exit "${2:-1}"; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; }

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

# ---------- processes, ports, health ----------

group_alive() { [ -n "${1:-}" ] && [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 1 ] && kill -0 -- "-$1" 2>/dev/null; }

# TERM the group, wait up to $STOP_GRACE seconds, then KILL.
kill_group() {
  local pgid=${1:-} i
  group_alive "$pgid" || return 0
  kill -TERM -- "-$pgid" 2>/dev/null
  for ((i = 0; i < STOP_GRACE * 10; i++)); do
    group_alive "$pgid" || return 0
    sleep 0.1
  done
  kill -KILL -- "-$pgid" 2>/dev/null
  sleep 0.1
  return 0
}

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

valid_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

pick_port() {
  local last=${1:-} p
  if valid_port "$last" && ! port_in_use "$last"; then
    printf '%s' "$last"; return 0
  fi
  for ((p = PORT_MIN; p <= PORT_MAX; p++)); do
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
  out=$("$EXPOSE" list --json 2>&1); rc=$?
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

expose_down() {  # best effort
  find_expose
  [ -n "$EXPOSE" ] || return 0
  "$EXPOSE" down "$1" --project "$PROJECT" >/dev/null 2>&1 || true
}

# ---------- windows (all tmux work goes through opsx-window.sh) ----------

win() { ( cd -- "$MAIN_DIR" && "$WINDOW_SH" "$@" ); }

window_alive() {  # window_alive <name> [<expected id>]
  local id
  id=$(win preview-find "$1" 2>/dev/null) || return 1
  [ -n "$id" ] || return 1
  [ -z "${2:-}" ] || [ "$id" = "$2" ]
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
  [ -f "$hash_file" ] && have=$(cat "$hash_file" 2>/dev/null)
  if [ "$want" = "$have" ]; then
    say "install: up to date (skipped)"
    return 0
  fi
  log=$PROJECT_STATE/$NAME.install.log
  say "install: $R_INSTALL"
  ( cd -- "$dir" && PORT=$port HOST=127.0.0.1 bash -c "$R_INSTALL" ) > "$log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    err "install failed (exit $rc): $R_INSTALL — last lines of $log:"
    tail -n 20 "$log" | sed 's/^/  | /' >&2
    exit "$rc"
  fi
  printf '%s\n' "$want" > "$hash_file"
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
    printf 'export PORT=%q HOST=127.0.0.1 OPSX_PREVIEW=%q\n' "$port" "$NAME"
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

# Clean up a failed start: stop the group, close the window, drop the record.
abort_start() {
  local pgid=$1 log=$2 reason=$3
  err "$reason"
  sleep 0.3
  if [ -s "$log" ]; then
    err "last lines of $log:"
    tail -n 20 "$log" | sed 's/^/  | /' >&2
  fi
  kill_group "$pgid"
  win preview-kill "$NAME" >/dev/null 2>&1 || true
  rm -f "$(record_file "$NAME")"
  exit 1
}

# ---------- subcommands ----------

cmd_up() {
  local arg=${1:-} f last_port="" port log launch pgidf out wid pgid="" i start url rc
  resolve_target "$arg"
  mkdir -p "$PROJECT_STATE" || die "cannot create $PROJECT_STATE"
  chmod 700 "$PROJECT_STATE" 2>/dev/null || true
  f=$(record_file "$NAME")

  # Already running: window alive, group alive and healthy -> same URL.
  if read_record "$f"; then
    if [ -n "$R_URL" ] && window_alive "$NAME" "$R_WINDOW_ID" && group_alive "$R_PGID" \
       && healthy "$R_PORT" "${R_HEALTH:-/}"; then
      say "preview $NAME is already running on 127.0.0.1:$R_PORT (window $R_WINDOW_ID)"
      say "$R_URL"
      return 0
    fi
    say "preview $NAME: stale record (window, process or health gone) — restarting"
    last_port=$R_PORT
    kill_group "$R_PGID"
    win preview-kill "$NAME" >/dev/null 2>&1 || true
    rm -f "$f"
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
    if healthy "$port" "$R_HEALTH_PATH"; then break; fi
    group_alive "$pgid" \
      || abort_start "$pgid" "$log" "the app exited before http://127.0.0.1:$port$R_HEALTH_PATH became healthy"
    [ $((SECONDS - start)) -lt "$R_TIMEOUT" ] \
      || abort_start "$pgid" "$log" "http://127.0.0.1:$port$R_HEALTH_PATH not healthy after ${R_TIMEOUT}s (timeout)"
    sleep 0.5
  done
  say "healthy: http://127.0.0.1:$port$R_HEALTH_PATH"

  out=$("$EXPOSE" up "$port" --name "$NAME" --project "$PROJECT" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    abort_start "$pgid" "$log" "expose.sh up failed (exit $rc): $(printf '%s' "$out" | tail -n 3)"
  fi
  url=$(printf '%s\n' "$out" | awk 'NF { l = $0 } END { print l }')
  # Strip an OSC 8 wrapper if expose printed one.
  url=$(printf '%s' "$url" | sed -e 's/\x1b]8;;[^\x07\x1b]*\(\x07\|\x1b\\\)//g')
  write_record "$NAME" "$CHECKOUT" "$port" "$pgid" "$wid" "$log" "$url" "$R_HEALTH_PATH"
  say "preview $NAME is up (stop with: opsx-preview.sh stop ${arg})"
  say "$url"
}

stop_one() {  # stop_one <name>
  local name=$1 f
  f=$(record_file "$name")
  if ! read_record "$f"; then
    say "no preview running for $name"
    rm -f "$f"
    return 0
  fi
  kill_group "$R_PGID"
  expose_down "$name"
  win preview-kill "$name" >/dev/null 2>&1 || true
  rm -f "$f" "$PROJECT_STATE/$name.pgid"
  say "stopped preview $name (port ${R_PORT:-?})"
}

cmd_stop() {
  local arg=${1:-} f n=0
  [ -n "$arg" ] || die "usage: opsx-preview.sh stop <change>|--all" 2
  if [ "$arg" = "--all" ]; then
    for f in "$PROJECT_STATE"/*.env; do
      [ -f "$f" ] || continue
      stop_one "$(basename -- "$f" .env)"
      n=$((n + 1))
    done
    [ "$n" -gt 0 ] || say "no previews running in project $PROJECT"
    return 0
  fi
  if [ "$arg" = "--main" ]; then arg=main; fi
  valid_name "$arg" || die "invalid change name '$arg'" 2
  stop_one "$arg"
}

cmd_url() {
  local arg=${1:-} name f out rc
  [ -n "$arg" ] || die "usage: opsx-preview.sh url <change>|--main" 2
  name=$arg
  [ "$arg" = "--main" ] && name=main
  valid_name "$name" || die "invalid change name '$arg'" 2
  f=$(record_file "$name")
  if ! { read_record "$f" && [ -n "$R_URL" ] && window_alive "$name" "$R_WINDOW_ID" \
          && group_alive "$R_PGID"; }; then
    die "no preview running for $name — start one with: opsx-preview.sh up $arg"
  fi
  find_expose
  if [ -n "$EXPOSE" ]; then
    # expose.sh url reprints and copies (OSC 52); fall back to the record.
    out=$("$EXPOSE" url "$name" --project "$PROJECT" 2>/dev/null); rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
      say "$(printf '%s\n' "$out" | awk 'NF { l = $0 } END { print l }' \
             | sed -e 's/\x1b]8;;[^\x07\x1b]*\(\x07\|\x1b\\\)//g')"
      return 0
    fi
  fi
  say "$R_URL"
}

cmd_list() {
  local f status n=0
  for f in "$PROJECT_STATE"/*.env; do
    [ -f "$f" ] || continue
    read_record "$f" || continue
    if [ "$n" -eq 0 ]; then
      printf '%-24s %-6s %-9s %-7s %-48s %s\n' NAME PORT STATUS WINDOW URL 'CHECKOUT / LOG'
    fi
    if group_alive "$R_PGID" && healthy "$R_PORT" "${R_HEALTH:-/}"; then status=up
    elif group_alive "$R_PGID"; then status=unhealthy
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
    up|stop|url|list) ;;
    *) err "unknown subcommand: $cmd"; usage >&2; exit 2 ;;
  esac
  case "$cmd" in
    list) [ $# -eq 0 ] || die "list takes no arguments" 2 ;;
    *)    [ $# -le 1 ] || die "$cmd takes one argument (got: $*)" 2 ;;
  esac
  resolve_project
  case "$cmd" in
    up)   cmd_up "$@" ;;
    stop) cmd_stop "$@" ;;
    url)  cmd_url "$@" ;;
    list) cmd_list ;;
  esac
}

main "$@"
