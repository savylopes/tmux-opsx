#!/usr/bin/env bash
# expose.sh — publish a local port at a public HTTPS URL (the /expose skill).
#
# Usage:
#   expose.sh up <port> [--name <n>] [--project <p>]
#   expose.sh down <name|port> [--project <p>]
#   expose.sh list [--json]
#   expose.sh url <name> [--project <p>]
#   expose.sh help
#
# `up` publishes 127.0.0.1:<port> at https://<name>--<project>.<domain>.
#   <name>     defaults to the port number
#   <project>  defaults to the folder name of the main checkout of the current
#              git repository (the same for every worktree), or the current
#              directory's name outside git
# Both parts are lowercased and reduced to [a-z0-9-]; a label over 63
# characters has its name part cut and a 6-hex hash appended (the project part
# is cut too only when it alone is over 54 characters).
#
# Exposed URLs are PUBLIC with no authentication. Bind apps to 127.0.0.1.
#
# The URL is always the last line of standard output. It is copied to the
# terminal clipboard via OSC 52 (through tmux when reachable, else /dev/tty);
# a stderr line says whether and how it was copied. It is printed as an OSC 8
# hyperlink only when stdout is a terminal.
#
# Clipboard: tmux is found through $TMUX, or else through the environment of
# a parent process. Set TMUX= (empty) to skip that parent search, or
# OPSX_EXPOSE_NO_COPY=1 to never copy at all.
#
# Config:  ${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/expose.env
#          (written by `install.sh --expose-domain <domain>`)
# State:   ${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/expose/routes/<label>.env
# Proxy:   Caddy, driven through its admin API on a unix socket
#          ($OPSX_EXPOSE_ADMIN overrides the socket path)
#
# Exit codes: 0 ok (including idempotent no-ops), 1 other error,
#             2 usage or validation error, 3 expose not configured,
#             4 proxy not reachable.

set -uo pipefail

CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/tmux-opsx
CONFIG_FILE=$CONFIG_DIR/expose.env
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-opsx/expose
ROUTES_DIR=$STATE_DIR/routes
SERVER=expose
ROUTES_PATH=/config/apps/http/servers/$SERVER/routes

DOMAIN=""
ADMIN_SOCK=""

err()   { printf 'expose: %s\n' "$*" >&2; }
die()   { err "$1"; exit "${2:-1}"; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; }

# ---------- labels ----------

# Lowercase; every run of characters outside [a-z0-9] becomes one '-';
# leading and trailing '-' removed.
normalise() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9' '-' \
    | LC_ALL=C tr -s '-' | sed 's/^-*//; s/-*$//'
}

sha6() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-6
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-6
  fi
}

# Cut $1 to at most $2 characters and append -<hash of $3>, never leaving '--'.
cut_with_hash() {
  local s=$1 max=$2 seed=$3 cut
  cut=${s:0:$((max - 7))}
  cut=$(printf '%s' "$cut" | sed 's/-*$//')
  if [ -n "$cut" ]; then
    printf '%s-%s' "$cut" "$(sha6 "$seed")"
  else
    sha6 "$seed"
  fi
}

# Project part: --project, else the main checkout's folder, else $PWD's name.
default_project() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  if [ -z "$common" ]; then
    common=$(git rev-parse --git-common-dir 2>/dev/null) && common=$(cd -- "$common" 2>/dev/null && pwd) || common=""
  fi
  if [ -n "$common" ]; then
    basename -- "$(dirname -- "$common")"
  else
    basename -- "$PWD"
  fi
}

# Sets PROJECT_N from the raw project (normalised; cut only in make_label).
resolve_project() {
  local raw=$1
  [ -n "$raw" ] || raw=$(default_project)
  PROJECT_N=$(normalise "$raw")
  [ -n "$PROJECT_N" ] || die "project name '$raw' has no usable characters ([a-z0-9])" 2
}

# Prints the hostname label for normalised name $1 and project $2.
# Fits as is: <name>--<project>. Too long: the name is cut and gets a hash of
# the full, uncut label. Only when the project alone leaves no room for even a
# 6-hex name hash (project over 54 characters) is the project cut to 40 too.
make_label() {
  local name=$1 project=$2 full room
  full="$name--$project"
  if [ "${#full}" -le 63 ]; then
    printf '%s' "$full"
    return
  fi
  if [ "${#project}" -gt 54 ]; then
    project=$(cut_with_hash "$project" 40 "$project")
    if [ $(( ${#name} + 2 + ${#project} )) -le 63 ]; then
      printf '%s--%s' "$name" "$project"
      return
    fi
  fi
  room=$((63 - 2 - ${#project}))
  printf '%s--%s' "$(cut_with_hash "$name" "$room" "$full")" "$project"
}

valid_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ] && [ "$1" -ne 443 ]
}

# ---------- config ----------

load_config() {
  local k v
  [ -f "$CONFIG_FILE" ] || die "expose is not configured ($CONFIG_FILE is missing) — run: install.sh --expose-domain <domain>" 3
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      EXPOSE_DOMAIN)       DOMAIN=$v ;;
      EXPOSE_ADMIN_SOCKET) ADMIN_SOCK=$v ;;
    esac
  done < "$CONFIG_FILE"
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || die "expose config has no valid EXPOSE_DOMAIN ($CONFIG_FILE) — re-run: install.sh --expose-domain <domain>" 3
  ADMIN_SOCK=${OPSX_EXPOSE_ADMIN:-${ADMIN_SOCK:-$STATE_DIR/caddy-admin.sock}}
}

# ---------- admin API ----------

# api METHOD PATH [BODY] — sets API_CODE and API_BODY; returns 1 if the socket
# cannot be reached at all.
api() {
  local method=$1 path=$2 body=${3:-} out
  if [ -n "$body" ]; then
    out=$(printf '%s' "$body" | curl -sS --max-time 10 --unix-socket "$ADMIN_SOCK" -X "$method" \
      -H 'Content-Type: application/json' --data-binary @- \
      -w '\n%{http_code}' "http://127.0.0.1$path" 2>/dev/null) || return 1
  else
    out=$(curl -sS --max-time 10 --unix-socket "$ADMIN_SOCK" -X "$method" \
      -w '\n%{http_code}' "http://127.0.0.1$path" 2>/dev/null) || return 1
  fi
  API_CODE=${out##*$'\n'}
  API_BODY=${out%$'\n'*}
  [ "$API_CODE" != "000" ]
}

proxy_down() {
  err "the expose proxy is not running (cannot reach its admin socket $ADMIN_SOCK)."
  case "$(uname -s)" in
    Linux) err "start it with: sudo systemctl start tmux-opsx-caddy   (check: systemctl status tmux-opsx-caddy)" ;;
    *)     err "start it with the 'caddy run --config …' command printed by install.sh --expose-domain" ;;
  esac
  exit 4
}

require_proxy() {
  [ -S "$ADMIN_SOCK" ] || proxy_down
  api GET "$ROUTES_PATH" || proxy_down
}

# Prints the expose-<label> ids currently in the proxy, one per line.
live_ids() {
  api GET "$ROUTES_PATH" || proxy_down
  [ "$API_CODE" = 200 ] || return 0
  printf '%s' "$API_BODY" | grep -oE '"@id"[[:space:]]*:[[:space:]]*"expose-[a-z0-9-]+"' \
    | sed -E 's/.*"(expose-[a-z0-9-]+)"$/\1/'
}

route_json() {
  local label=$1 port=$2
  printf '{"@id":"expose-%s","match":[{"host":["%s.%s"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:%s"}]}],"terminal":true}' \
    "$label" "$label" "$DOMAIN" "$port"
}

# Remove any route with this label's id, then append the new one.
add_route() {
  local label=$1 port=$2 route
  route=$(route_json "$label" "$port")
  api DELETE "/id/expose-$label" || proxy_down
  api GET "$ROUTES_PATH" || proxy_down
  if [ "$API_CODE" = 200 ] && [ "$(printf '%s' "$API_BODY" | tr -d '[:space:]')" != null ]; then
    api POST "$ROUTES_PATH" "$route" || proxy_down
  else
    api POST "$ROUTES_PATH" "[$route]" || proxy_down
  fi
  case "$API_CODE" in
    2??) return 0 ;;
  esac
  # A parallel call may have added the same route between our DELETE and POST;
  # Caddy then refuses the duplicate id. That is fine if the route is there now.
  local refused_code=$API_CODE refused_body=$API_BODY
  if route_present "$label" "$port"; then
    return 0
  fi
  err "the proxy refused the route for $label (HTTP $refused_code): $refused_body"
  return 1
}

# True when the proxy has expose-<label> for <label>.<domain> -> 127.0.0.1:<port>.
route_present() {
  api GET "/id/expose-$1" || return 1
  [ "$API_CODE" = 200 ] || return 1
  local body
  body=$(printf '%s' "$API_BODY" | tr -d '[:space:]')
  [[ "$body" == *"\"$1.$DOMAIN\""* ]] && [[ "$body" == *"\"dial\":\"127.0.0.1:$2\""* ]]
}

# Serialise expose.sh calls on the state dir (best effort: needs flock(1)).
take_lock() {
  mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null
  command -v flock >/dev/null 2>&1 || return 0
  { exec 9>>"$STATE_DIR/.lock"; } 2>/dev/null || return 0
  flock -w 30 9 2>/dev/null || err "another expose.sh call holds $STATE_DIR/.lock; continuing without the lock"
}

delete_route() {
  api DELETE "/id/expose-$1" || proxy_down
  case "$API_CODE" in
    2??|404) return 0 ;;
    *) err "could not remove the route for $1 (HTTP $API_CODE): $API_BODY"; return 1 ;;
  esac
}

# ---------- state ----------

# read_record FILE — sets R_NAME R_PROJECT R_PORT R_LABEL R_URL.
read_record() {
  local k v
  R_NAME=""; R_PROJECT=""; R_PORT=""; R_LABEL=""; R_URL=""
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      NAME) R_NAME=$v ;; PROJECT) R_PROJECT=$v ;; PORT) R_PORT=$v ;;
      LABEL) R_LABEL=$v ;; URL) R_URL=$v ;;
    esac
  done < "$1"
  [[ "$R_LABEL" =~ ^[a-z0-9-]+$ ]] && valid_port "$R_PORT"
}

write_record() {
  local name=$1 project=$2 port=$3 label=$4 url=$5 tmp
  mkdir -p "$ROUTES_DIR" && chmod 700 "$STATE_DIR" 2>/dev/null
  tmp=$(mktemp "$ROUTES_DIR/.$label.XXXXXX") || die "cannot write state in $ROUTES_DIR"
  if ! printf 'NAME=%s\nPROJECT=%s\nPORT=%s\nLABEL=%s\nURL=%s\n' "$name" "$project" "$port" "$label" "$url" > "$tmp" \
     || ! mv -f "$tmp" "$ROUTES_DIR/$label.env"; then
    rm -f "$tmp"
    die "cannot write state in $ROUTES_DIR"
  fi
}

records() {
  local f
  [ -d "$ROUTES_DIR" ] || return 0
  for f in "$ROUTES_DIR"/*.env; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# Re-add every recorded route that the proxy lost (e.g. after a restart).
reconcile() {
  local ids f
  ids=$(live_ids)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    if ! printf '%s\n' "$ids" | grep -qx "expose-$R_LABEL"; then
      if add_route "$R_LABEL" "$R_PORT"; then
        err "restored $R_URL -> 127.0.0.1:$R_PORT (the proxy had lost it)"
      fi
    fi
  done < <(records)
}

port_up() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# ---------- URL handoff ----------

recover_tmux_env() {
  local pid=$$ i=0 envline sock
  [ -n "${TMUX:-}" ] && return 0
  # TMUX set but empty: the caller opted out of the parent search.
  [ -n "${TMUX+x}" ] && return 1
  [ -d /proc ] || return 1
  while [ "$pid" -gt 1 ] && [ "$i" -lt 30 ]; do
    if [ -r "/proc/$pid/environ" ]; then
      envline=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
                | awk -F= '/^TMUX=/{print substr($0,6); exit}')
      if [ -n "$envline" ]; then
        sock=${envline%%,*}
        if [ -n "$sock" ] && [ -S "$sock" ]; then
          TMUX=$envline
          export TMUX
          return 0
        fi
      fi
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] || break
    i=$((i + 1))
  done
  return 1
}

copy_url() {
  local url=$1 b64
  if [ -n "${OPSX_EXPOSE_NO_COPY:-}" ] && [ "$OPSX_EXPOSE_NO_COPY" != 0 ]; then
    err "not copied to the clipboard (OPSX_EXPOSE_NO_COPY is set)"
    return 0
  fi
  if recover_tmux_env && command -v tmux >/dev/null 2>&1; then
    if tmux set-buffer -w -- "$url" 2>/dev/null || tmux set-buffer -- "$url" 2>/dev/null; then
      err "copied to the clipboard via tmux (OSC 52)"
      return 0
    fi
  fi
  b64=$(printf '%s' "$url" | base64 | tr -d '\n')
  if { printf '\033]52;c;%s\a' "$b64" > /dev/tty; } 2>/dev/null; then
    err "copied to the clipboard via the terminal (OSC 52)"
  else
    err "not copied to the clipboard: no tmux or terminal reachable"
  fi
}

print_url() {
  local url=$1
  printf 'warning: %s is PUBLIC with no authentication — anyone with the link can reach 127.0.0.1:%s.\n' "$url" "$2"
  copy_url "$url"
  if [ -t 1 ]; then
    printf '\033]8;;%s\033\\%s\033]8;;\033\\\n' "$url" "$url"
  else
    printf '%s\n' "$url"
  fi
}

# ---------- subcommands ----------

cmd_up() {
  local port=$1 name_raw=$2 name label url
  name_raw=${name_raw:-$port}
  name=$(normalise "$name_raw")
  [ -n "$name" ] || die "name '$name_raw' has no usable characters ([a-z0-9])" 2
  label=$(make_label "$name" "$PROJECT_N")
  url="https://$label.$DOMAIN"
  add_route "$label" "$port" || exit 1
  write_record "$name" "$PROJECT_N" "$port" "$label" "$url"
  printf 'exposed 127.0.0.1:%s at %s\n' "$port" "$url"
  port_up "$port" || err "note: nothing is listening on 127.0.0.1:$port yet — start the app there"
  print_url "$url" "$port"
}

cmd_down() {
  local arg=$1 target_label="" name f n=0
  name=$(normalise "$arg")
  [ -n "$name" ] && target_label=$(make_label "$name" "$PROJECT_N")
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    if [ "$R_LABEL" = "$target_label" ] \
       || { [[ "$arg" =~ ^[0-9]+$ ]] && [ "$R_PORT" = "$arg" ] && [ "$R_PROJECT" = "$PROJECT_N" ]; }; then
      delete_route "$R_LABEL" || exit 1
      rm -f "$f"
      printf 'removed %s (127.0.0.1:%s)\n' "$R_URL" "$R_PORT"
      n=$((n + 1))
    fi
  done < <(records)
  [ "$n" -gt 0 ] || printf 'nothing matched %s in project %s — nothing to remove\n' "$arg" "$PROJECT_N"
}

json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

cmd_list() {
  local json=$1 f up first=1
  if [ "$json" -eq 1 ]; then
    printf '['
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      read_record "$f" || continue
      if port_up "$R_PORT"; then up=true; else up=false; fi
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"name":%s,"project":%s,"port":%s,"url":%s,"up":%s}' \
        "$(json_str "$R_NAME")" "$(json_str "$R_PROJECT")" "$R_PORT" "$(json_str "$R_URL")" "$up"
    done < <(records)
    printf ']\n'
    return 0
  fi
  local rows=() w1=4 w2=7 w3=4 w4=3 row a b c d e
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    if port_up "$R_PORT"; then up=yes; else up=no; fi
    rows+=("$R_NAME"$'\x1f'"$R_PROJECT"$'\x1f'"$R_PORT"$'\x1f'"$R_URL"$'\x1f'"$up")
    [ "${#R_NAME}" -le "$w1" ] || w1=${#R_NAME}
    [ "${#R_PROJECT}" -le "$w2" ] || w2=${#R_PROJECT}
    [ "${#R_PORT}" -le "$w3" ] || w3=${#R_PORT}
    [ "${#R_URL}" -le "$w4" ] || w4=${#R_URL}
  done < <(records)
  if [ "${#rows[@]}" -eq 0 ]; then
    printf '(nothing exposed)\n'
    return 0
  fi
  printf '%-*s  %-*s  %-*s  %-*s  %s\n' "$w1" NAME "$w2" PROJECT "$w3" PORT "$w4" URL UP
  for row in "${rows[@]}"; do
    IFS=$'\x1f' read -r a b c d e <<<"$row"
    printf '%-*s  %-*s  %-*s  %-*s  %s\n' "$w1" "$a" "$w2" "$b" "$w3" "$c" "$w4" "$d" "$e"
  done
}

cmd_url() {
  local arg=$1 name label f
  name=$(normalise "$arg")
  [ -n "$name" ] || die "unknown exposure '$arg'" 1
  label=$(make_label "$name" "$PROJECT_N")
  f=$ROUTES_DIR/$label.env
  if [ -f "$f" ] && read_record "$f"; then
    print_url "$R_URL" "$R_PORT"
    return 0
  fi
  die "no exposure named '$arg' in project $PROJECT_N (see: expose.sh list)" 1
}

# ---------- main ----------

main() {
  local cmd=${1:-help} pos=() name="" project="" json=0
  [ $# -gt 0 ] && shift
  case "$cmd" in
    help|-h|--help) usage; exit 0 ;;
    up|down|list|url) ;;
    *) err "unknown subcommand: $cmd"; usage >&2; exit 2 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)    [ $# -ge 2 ] || die "--name needs a value" 2; name=$2; shift 2 ;;
      --name=*)  name=${1#--name=}; shift ;;
      --project) [ $# -ge 2 ] || die "--project needs a value" 2; project=$2; shift 2 ;;
      --project=*) project=${1#--project=}; shift ;;
      --json)    json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; pos+=("$@"); break ;;
      -*) die "unknown option: $1 (try: expose.sh help)" 2 ;;
      *) pos+=("$1"); shift ;;
    esac
  done

  case "$cmd" in
    up)
      [ "${#pos[@]}" -eq 1 ] || die "usage: expose.sh up <port> [--name <n>] [--project <p>]" 2
      valid_port "${pos[0]}" || die "invalid port '${pos[0]}': use an integer from 1 to 65535, other than 443" 2
      [ "$json" -eq 0 ] || die "--json only applies to list" 2 ;;
    down|url)
      [ "${#pos[@]}" -eq 1 ] || die "usage: expose.sh $cmd <name$([ "$cmd" = down ] && printf '|port')> [--project <p>]" 2
      [ -z "$name" ] || die "--name does not apply to $cmd" 2
      [ "$json" -eq 0 ] || die "--json only applies to list" 2 ;;
    list)
      [ "${#pos[@]}" -eq 0 ] || die "usage: expose.sh list [--json]" 2
      [ -z "$name" ] && [ -z "$project" ] || die "list takes only --json" 2 ;;
  esac

  load_config
  [ "$cmd" = list ] || resolve_project "$project"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  require_proxy
  take_lock
  reconcile

  case "$cmd" in
    up)   cmd_up "${pos[0]}" "$name" ;;
    down) cmd_down "${pos[0]}" ;;
    list) cmd_list "$json" ;;
    url)  cmd_url "${pos[0]}" ;;
  esac
}

main "$@"
