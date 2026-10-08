#!/usr/bin/env bash
# expose.sh — publish a local port at an HTTPS URL behind a login (the /expose skill).
#
# Usage:
#   expose.sh up <port> [--name <n>] [--project <p>] [--public]
#   expose.sh down <name|port> [--project <p>]
#   expose.sh list [--json]
#   expose.sh url <name> [--project <p>] [--with-key]
#   expose.sh share <name> [--for <recipient>] [--ttl <dur>] [--project <p>]
#   expose.sh share <name> --list [--project <p>]
#   expose.sh share <name> --revoke <recipient|id|all> [--project <p>]
#   expose.sh key rotate
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
# Login: every exposed URL requires a login unless published with --public.
# The proxy lets a request through only with the owner cookie (opsx_auth, any
# host under the domain) or a share cookie (opsx_share, that one host);
# anything else gets a 401 login page. Both cookies are stripped before the
# request reaches the app.
#   url <name> --with-key     prints the owner login link <url>/?opsx_key=<key>
#                             (open it once per device; sets a 30-day cookie)
#   share <name>              prints a share link <url>/?opsx_share=<token> for
#                             that one host. --for <recipient> (default
#                             link-<id>; sharing again with the same recipient
#                             replaces the token), --ttl <n>m|<n>h|<n>d|never
#                             (default 7d; the proxy refuses it afterwards)
#   share <name> --list       FOR, ID, EXPIRES, LINK of every share link
#   share <name> --revoke <r> deletes the link of recipient or id <r> (or all)
#   key rotate                new owner key: every device is logged out, share
#                             links keep working
#   up --public               no login (webhooks, OAuth callbacks); up again
#                             without it requires a login again
# The owner cookie is sent to every host under the domain, so use a domain
# (e.g. dev.example.com) that serves nothing but /expose.
# The owner key lives in ${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/expose.key
# (mode 600, created on first use) and is printed only by `url --with-key`.
#
# Loopback only: `up` refuses (exit 2) a port with a listener on any address
# other than 127.0.0.0/8 or ::1 — bind the app to 127.0.0.1 — and also when the
# listeners cannot be inspected (needs ss on Linux, lsof elsewhere). `list`
# shows each exposure's BIND (loopback, PUBLIC, or - when nothing listens).
#
# The URL (or link) is always the last line of standard output. It is copied to the
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
# Key:     ${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/expose.key
# State:   ${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/expose/routes/<label>.env
#          (mode 600 in a mode-700 dir; holds the share tokens)
# Proxy:   Caddy, driven through its admin API on a unix socket
#          ($OPSX_EXPOSE_ADMIN overrides the socket path)
#
# Exit codes: 0 ok (including idempotent no-ops), 1 other error,
#             2 usage or validation error, 3 expose not configured,
#             4 proxy not reachable.

set -uo pipefail

CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/tmux-opsx
CONFIG_FILE=$CONFIG_DIR/expose.env
KEY_FILE=$CONFIG_DIR/expose.key
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-opsx/expose
ROUTES_DIR=$STATE_DIR/routes
SERVER=expose
ROUTES_PATH=/config/apps/http/servers/$SERVER/routes

DOMAIN=""
ADMIN_SOCK=""
OWNER_KEY=""
# Seconds since the epoch; OPSX_EXPOSE_NOW overrides it (tests only).
NOW=${OPSX_EXPOSE_NOW:-$(date +%s)}

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

# sha256 of $1 as 64 hex characters.
sha256hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-64
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-64
  fi
}

sha6() { sha256hex "$1" | cut -c1-6; }

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
  DOMAIN=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')
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
  printf '%s' "$LIVE_ROUTES" | grep -oE '"@id":"expose-[a-z0-9-]+"' \
    | sed -E 's/.*"(expose-[a-z0-9-]+)"$/\1/'
}

# Reads the proxy's routes into LIVE_ROUTES (whitespace removed).
fetch_routes() {
  api GET "$ROUTES_PATH" || proxy_down
  LIVE_ROUTES=""
  [ "$API_CODE" = 200 ] || return 0
  LIVE_ROUTES=$(printf '%s' "$API_BODY" | tr -d '[:space:]')
}

# ---------- owner key ----------

# 32 random bytes as base64url without padding (43 characters, [A-Za-z0-9_-]).
new_secret() {
  head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
}

valid_secret() { [[ "$1" =~ ^[A-Za-z0-9_-]{22,}$ ]]; }

# write_key — replace expose.key atomically (mode 600). Call under the lock.
write_key() {
  local tmp key
  key=$(new_secret)
  valid_secret "$key" || die "could not generate a random key (head, base64 and /dev/urandom are required)"
  tmp=$( (umask 077 && mktemp "$CONFIG_DIR/.expose.key.XXXXXX") ) || die "cannot write $KEY_FILE"
  if ! printf '%s\n' "$key" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$KEY_FILE"; then
    rm -f "$tmp"
    die "cannot write $KEY_FILE"
  fi
}

# Sets OWNER_KEY, creating expose.key on first use. Call under the lock.
load_key() {
  [ -f "$KEY_FILE" ] || write_key
  chmod 600 "$KEY_FILE" 2>/dev/null
  OWNER_KEY=$(head -n1 "$KEY_FILE" 2>/dev/null | tr -d '[:space:]')
  valid_secret "$OWNER_KEY" \
    || die "the owner key in $KEY_FILE is unreadable or malformed — replace it with: expose.sh key rotate"
}

# ---------- routes ----------

# HTTP date (for a cookie's Expires) of epoch seconds $1.
http_date() {
  LC_ALL=C date -u -d "@$1" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null \
    || LC_ALL=C date -u -r "$1" '+%a, %d %b %Y %H:%M:%S GMT'
}

# Short UTC date of epoch seconds $1 (for share --list).
short_date() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%MZ'
}

json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

LOGIN_PAGE='<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><title>Login required</title></head><body style="font-family: system-ui, sans-serif; max-width: 28rem; margin: 4rem auto; padding: 0 1rem; color: #222; line-height: 1.5"><h1 style="font-size: 1.4rem">Login required</h1><form method="get" action=""><label for="opsx_key">Owner key</label><br><input id="opsx_key" name="opsx_key" type="password" autocomplete="current-password" required style="width: 100%; padding: .5rem; margin: .5rem 0; box-sizing: border-box"><button type="submit" style="padding: .5rem 1rem">Log in</button></form><p>Got this link from someone? It may have expired or been revoked — ask them for a new one.</p></body></html>'

# route_json <label> <port> <public 0|1> [<id>:<recipient>:<expires|never>:<token> ...]
# Prints the full route for one exposure. Every route holds a subroute. A
# public one: owner login link -> 302 with the owner cookie; any other
# opsx_key or opsx_share query -> 302 to the path without the query (a key or
# token never reaches a public app, whose request log may be read by others);
# anything else -> strip both cookies, proxy. A private one: owner
# login link -> 302 with the owner cookie; each share link -> 302 with its
# host-only cookie; a valid owner or share cookie -> strip both cookies,
# proxy; anything else -> 401 login page. Its "group" is the full sha256 of
# the rest, so reconcile can tell an outdated route (pre-auth, rotated key,
# revoked or pruned token).
route_json() {
  local label=$1 port=$2 public=$3; shift 3
  local host="$label.$DOMAIN" proxy strip body sub="" auth sh id rec exp tok expr cookie
  proxy='{"handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:'"$port"'"}]}'
  # Removes opsx_auth and opsx_share from the Cookie header. Every route, the
  # public ones included, applies it: the owner cookie is sent to every host
  # under the domain and must never reach an app.
  strip='{"handler":"headers","request":{"replace":{"Cookie":[{"search_regexp":"(^|;) *opsx_(auth|share)=[^;]*","replace":""},{"search_regexp":"^[; ]+","replace":""}]}}}'
  sub='{"match":[{"query":{"opsx_key":["'"$OWNER_KEY"'"]}}],"handle":[{"handler":"static_response","status_code":302,"headers":{"Location":["https://'"$host"'{http.request.uri.path}"],"Cache-Control":["no-store"],"Set-Cookie":["opsx_auth='"$OWNER_KEY"'; Domain='"$DOMAIN"'; Path=/; Max-Age=2592000; Secure; HttpOnly; SameSite=Lax"]}}],"terminal":true}'
  if [ "$public" = 1 ]; then
    sub="$sub"',{"match":[{"query":{"opsx_key":["*"]}},{"query":{"opsx_share":["*"]}}],"handle":[{"handler":"static_response","status_code":302,"headers":{"Location":["https://'"$host"'{http.request.uri.path}"],"Cache-Control":["no-store"]}}],"terminal":true}'
    sub="$sub"',{"handle":['"$strip"','"$proxy"']}'
    body='"match":[{"host":["'"$host"'"]}],"handle":[{"handler":"subroute","routes":['"$sub"']}],"terminal":true}'
  else
    auth='{"header_regexp":{"Cookie":{"pattern":"(^|;) *opsx_auth='"$OWNER_KEY"' *(;|$)"}}}'
    for sh in "$@"; do
      IFS=: read -r id rec exp tok <<<"$sh"
      valid_secret "$tok" || continue
      expr=""; cookie="opsx_share=$tok; Path=/"
      if [ "$exp" != never ]; then
        expr=',"expression":"int({time.now.unix}) < '"$exp"'"'
        cookie="$cookie; Expires=$(http_date "$exp")"
      fi
      cookie="$cookie; Secure; HttpOnly; SameSite=Lax"
      sub="$sub"',{"match":[{"query":{"opsx_share":["'"$tok"'"]}'"$expr"'}],"handle":[{"handler":"static_response","status_code":302,"headers":{"Location":["https://'"$host"'{http.request.uri.path}"],"Cache-Control":["no-store"],"Set-Cookie":["'"$cookie"'"]}}],"terminal":true}'
      auth="$auth"',{"header_regexp":{"Cookie":{"pattern":"(^|;) *opsx_share='"$tok"' *(;|$)"}}'"$expr"'}'
    done
    sub="$sub"',{"match":['"$auth"'],"handle":['"$strip"','"$proxy"'],"terminal":true}'
    sub="$sub"',{"handle":[{"handler":"static_response","status_code":401,"headers":{"Content-Type":["text/html; charset=utf-8"],"Cache-Control":["no-store"]},"body":'"$(json_str "$LOGIN_PAGE")"'}]}'
    body='"match":[{"host":["'"$host"'"]}],"handle":[{"handler":"subroute","routes":['"$sub"']}],"terminal":true}'
  fi
  printf '{"@id":"expose-%s","group":"expose-fp-%s",%s' "$label" "$(sha256hex "$body")" "$body"
}

# route_for_record — route_json for the record last read by read_record.
route_for_record() {
  route_json "$R_LABEL" "$R_PORT" "$R_PUBLIC" "${R_SHARES[@]+"${R_SHARES[@]}"}"
}

# add_route <label> <route json> — remove any route with this label's id, then
# append the new one.
add_route() {
  local label=$1 route=$2
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
  if route_present "$label" "$route"; then
    return 0
  fi
  err "the proxy refused the route for $label (HTTP $refused_code): $refused_body"
  return 1
}

# fp_of <route json> — the "group" fingerprint value of a rendered route.
fp_of() { printf '%s' "$1" | grep -oE '"group":"expose-fp-[0-9a-f]+"' | head -n1 | cut -d'"' -f4; }

# True when the proxy has expose-<label> with the fingerprint of <route json>.
route_present() {
  api GET "/id/expose-$1" || return 1
  [ "$API_CODE" = 200 ] || return 1
  local body
  body=$(printf '%s' "$API_BODY" | tr -d '[:space:]')
  [[ "$body" == *"\"group\":\"$(fp_of "$2")\""* ]]
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

# read_record FILE — sets R_NAME R_PROJECT R_PORT R_LABEL R_URL R_PUBLIC and
# the array R_SHARES (<id>:<recipient>:<expires|never>:<token> per entry).
read_record() {
  local k v
  R_NAME=""; R_PROJECT=""; R_PORT=""; R_LABEL=""; R_URL=""; R_PUBLIC=0; R_SHARES=()
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      NAME) R_NAME=$v ;; PROJECT) R_PROJECT=$v ;; PORT) R_PORT=$v ;;
      LABEL) R_LABEL=$v ;; URL) R_URL=$v ;;
      PUBLIC) [ "$v" = 1 ] && R_PUBLIC=1 ;;
      SHARE) valid_share "$v" && R_SHARES+=("$v") ;;
    esac
  done < "$1"
  [[ "$R_LABEL" =~ ^[a-z0-9-]+$ ]] && valid_port "$R_PORT"
}

valid_share() { [[ "$1" =~ ^[0-9a-f]{6}:[a-z0-9-]+:([0-9]+|never):[A-Za-z0-9_-]{22,}$ ]]; }

# write_record_tmp <name> <project> <port> <label> <url> <public> [shares...]
# Writes a record to a new temp file in ROUTES_DIR and prints its path; the
# caller moves it into place with commit_record (or removes it).
write_record_tmp() {
  local name=$1 project=$2 port=$3 label=$4 url=$5 public=$6 tmp sh; shift 6
  mkdir -p "$ROUTES_DIR" && chmod 700 "$STATE_DIR" 2>/dev/null
  tmp=$(mktemp "$ROUTES_DIR/.$label.XXXXXX") || die "cannot write state in $ROUTES_DIR"
  {
    printf 'NAME=%s\nPROJECT=%s\nPORT=%s\nLABEL=%s\nURL=%s\n' "$name" "$project" "$port" "$label" "$url"
    [ "$public" = 1 ] && printf 'PUBLIC=1\n'
    for sh in "$@"; do printf 'SHARE=%s\n' "$sh"; done
    true
  } > "$tmp" || { rm -f "$tmp"; die "cannot write state in $ROUTES_DIR"; }
  printf '%s' "$tmp"
}

commit_record() {
  local tmp=$1 label=$2
  mv -f "$tmp" "$ROUTES_DIR/$label.env" || { rm -f "$tmp"; die "cannot write state in $ROUTES_DIR"; }
}

# rewrite_record — write the record last read by read_record back with the
# shares in R_SHARES (atomic).
rewrite_record() {
  local tmp
  tmp=$(write_record_tmp "$R_NAME" "$R_PROJECT" "$R_PORT" "$R_LABEL" "$R_URL" "$R_PUBLIC" \
        "${R_SHARES[@]+"${R_SHARES[@]}"}") || exit 1
  commit_record "$tmp" "$R_LABEL"
}

records() {
  local f
  [ -d "$ROUTES_DIR" ] || return 0
  for f in "$ROUTES_DIR"/*.env; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# Drop expired share tokens from every record (the proxy already refuses
# them; reconcile then rebuilds the routes without their matchers).
prune_expired() {
  local f sh exp keep changed
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    [ "${#R_SHARES[@]}" -gt 0 ] || continue
    keep=(); changed=0
    for sh in "${R_SHARES[@]}"; do
      exp=$(printf '%s' "$sh" | cut -d: -f3)
      if [ "$exp" != never ] && [ "$exp" -le "$NOW" ]; then changed=1; else keep+=("$sh"); fi
    done
    [ "$changed" -eq 1 ] || continue
    R_SHARES=("${keep[@]+"${keep[@]}"}")
    rewrite_record
  done < <(records)
}

# Re-add every recorded route that the proxy lost (e.g. after a restart) or
# that differs from what its record now requires (fingerprint mismatch: a
# pre-auth route, a rotated key, a changed or pruned share token).
# Labels whose route the proxy refused are collected in RECONCILE_FAILED.
RECONCILE_FAILED=()
reconcile() {
  local ids f route fp
  RECONCILE_FAILED=()
  fetch_routes
  ids=$(live_ids)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    route=$(route_for_record)
    fp=$(fp_of "$route")
    if ! printf '%s\n' "$ids" | grep -qx "expose-$R_LABEL"; then
      if add_route "$R_LABEL" "$route"; then
        err "restored $R_URL -> 127.0.0.1:$R_PORT (the proxy had lost it)"
      else
        RECONCILE_FAILED+=("$R_LABEL")
      fi
    elif [[ "$LIVE_ROUTES" != *"\"group\":\"$fp\""* ]]; then
      if add_route "$R_LABEL" "$route"; then
        err "updated the route for $R_URL (it was out of date)"
      else
        RECONCILE_FAILED+=("$R_LABEL")
      fi
    fi
  done < <(records)
}

port_up() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# ---------- bind check ----------

# listeners <port> — prints the local address of every TCP listener on the
# port, one per line (no port, no brackets, no %iface). Returns 2 when the
# listeners cannot be inspected (no ss on Linux, no lsof elsewhere).
listeners() {
  local port=$1 out
  if [ "$(uname -s)" = Linux ]; then
    command -v ss >/dev/null 2>&1 || return 2
    out=$(ss -Hltn "sport = :$port" 2>/dev/null) || return 2
    printf '%s\n' "$out" | awk 'NF >= 4 { print $4 }'
  else
    command -v lsof >/dev/null 2>&1 || return 2
    out=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fn 2>/dev/null)
    printf '%s\n' "$out" | sed -n 's/^n//p'
  fi | sed -E 's/:[0-9*]+$//; s/^\[//; s/\]$//; s/%.*$//' | awk 'NF'
}

is_loopback() {
  case "$1" in
    127.*|::1|::ffff:127.*|0:0:0:0:0:0:0:1) return 0 ;;
  esac
  return 1
}

# bind_state <port> — sets BIND_STATE to loopback, public, none (nothing
# listens) or unknown (cannot inspect), and BIND_PUBLIC to the first
# non-loopback address.
bind_state() {
  local addrs a rc
  BIND_PUBLIC=""
  addrs=$(listeners "$1"); rc=$?
  if [ "$rc" -ne 0 ]; then BIND_STATE=unknown; return; fi
  if [ -z "$addrs" ]; then
    # Something answers on 127.0.0.1 but no listener is visible: unknown.
    if port_up "$1"; then BIND_STATE=unknown; else BIND_STATE=none; fi
    return
  fi
  BIND_STATE=loopback
  while IFS= read -r a; do
    if ! is_loopback "$a"; then
      BIND_STATE=public
      BIND_PUBLIC=$a
      [ "$a" = "*" ] && BIND_PUBLIC="* (all addresses, 0.0.0.0 / [::])"
      return
    fi
  done <<<"$addrs"
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
    # Through stdin, never argv: the link may carry the owner key or a share
    # token, and process arguments are visible to every local user.
    if printf '%s' "$url" | tmux load-buffer -w - 2>/dev/null \
       || printf '%s' "$url" | tmux load-buffer - 2>/dev/null; then
      err "copied to the tmux buffer (forwarded to the clipboard via OSC 52 when tmux set-clipboard is on)"
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
  copy_url "$url"
  if [ -t 1 ]; then
    printf '\033]8;;%s\033\\%s\033]8;;\033\\\n' "$url" "$url"
  else
    printf '%s\n' "$url"
  fi
}

# ---------- subcommands ----------

# find_record <name> — reads the record of <name> in PROJECT_N, or dies.
find_record() {
  local arg=$1 name f
  name=$(normalise "$arg")
  [ -n "$name" ] || die "unknown exposure '$arg'" 1
  f=$ROUTES_DIR/$(make_label "$name" "$PROJECT_N").env
  [ -f "$f" ] && read_record "$f" && return 0
  die "no exposure named '$arg' in project $PROJECT_N (see: expose.sh list)" 1
}

cmd_up() {
  local port=$1 name_raw=$2 public=$3 name label url tmp shares=()
  name_raw=${name_raw:-$port}
  name=$(normalise "$name_raw")
  [ -n "$name" ] || die "name '$name_raw' has no usable characters ([a-z0-9])" 2
  label=$(make_label "$name" "$PROJECT_N")
  url="https://$label.$DOMAIN"
  # Re-publishing keeps the exposure's share links.
  if [ -f "$ROUTES_DIR/$label.env" ] && read_record "$ROUTES_DIR/$label.env"; then
    shares=("${R_SHARES[@]+"${R_SHARES[@]}"}")
  fi
  tmp=$(write_record_tmp "$name" "$PROJECT_N" "$port" "$label" "$url" "$public" "${shares[@]+"${shares[@]}"}") || exit 1
  read_record "$tmp"
  if ! add_route "$label" "$(route_for_record)"; then
    rm -f "$tmp"
    exit 1
  fi
  commit_record "$tmp" "$label"
  printf 'exposed 127.0.0.1:%s at %s\n' "$port" "$url"
  if [ "$public" = 1 ]; then
    printf 'warning: %s is PUBLIC with no authentication — anyone with the link can reach 127.0.0.1:%s.\n' "$url" "$port"
  else
    printf 'login required: log in once per device with: expose.sh url %s --with-key (or give someone a link: expose.sh share %s)\n' "$name" "$name"
  fi
  [ "$BIND_STATE" = none ] \
    && err "note: nothing is listening on 127.0.0.1:$port yet — start the app there, bound to 127.0.0.1 (expose.sh list shows its bind)"
  print_url "$url"
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
      printf 'removed %s (127.0.0.1:%s)' "$R_URL" "$R_PORT"
      [ "${#R_SHARES[@]}" -eq 0 ] || printf ' and its %s share link(s)' "${#R_SHARES[@]}"
      printf '\n'
      n=$((n + 1))
    fi
  done < <(records)
  [ "$n" -gt 0 ] && return 0
  # Hint at other projects that have this name or port exposed.
  local others="" p
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    [ "$R_PROJECT" != "$PROJECT_N" ] || continue
    if { [ -n "$name" ] && [ "$R_NAME" = "$name" ]; } \
       || { [[ "$arg" =~ ^[0-9]+$ ]] && [ "$R_PORT" = "$arg" ]; }; then
      case " $others " in *" $R_PROJECT "*) ;; *) others="${others:+$others }$R_PROJECT" ;; esac
    fi
  done < <(records)
  printf 'nothing matched %s in project %s — nothing to remove' "$arg" "$PROJECT_N"
  if [ -n "$others" ]; then
    for p in $others; do printf ' (exposed in project %s; use --project %s)' "$p" "$p"; done
  fi
  printf '\n'
}

cmd_list() {
  local json=$1 f up first=1 bind access
  if [ "$json" -eq 1 ]; then
    printf '['
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      read_record "$f" || continue
      if port_up "$R_PORT"; then up=true; else up=false; fi
      bind_state "$R_PORT"
      case "$BIND_STATE" in loopback) bind='"loopback"' ;; public) bind='"public"' ;; *) bind=null ;; esac
      if [ "$R_PUBLIC" = 1 ]; then access=true; else access=false; fi
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"name":%s,"project":%s,"port":%s,"url":%s,"up":%s,"bind":%s,"public":%s}' \
        "$(json_str "$R_NAME")" "$(json_str "$R_PROJECT")" "$R_PORT" "$(json_str "$R_URL")" "$up" "$bind" "$access"
    done < <(records)
    printf ']\n'
    return 0
  fi
  local rows=() w1=4 w2=7 w3=4 w4=3 row a b c d e g h
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    if port_up "$R_PORT"; then up=yes; else up=no; fi
    bind_state "$R_PORT"
    case "$BIND_STATE" in loopback) bind=loopback ;; public) bind=PUBLIC ;; *) bind=- ;; esac
    if [ "$R_PUBLIC" = 1 ]; then access=public; else access=login; fi
    rows+=("$R_NAME"$'\x1f'"$R_PROJECT"$'\x1f'"$R_PORT"$'\x1f'"$R_URL"$'\x1f'"$up"$'\x1f'"$bind"$'\x1f'"$access")
    [ "${#R_NAME}" -le "$w1" ] || w1=${#R_NAME}
    [ "${#R_PROJECT}" -le "$w2" ] || w2=${#R_PROJECT}
    [ "${#R_PORT}" -le "$w3" ] || w3=${#R_PORT}
    [ "${#R_URL}" -le "$w4" ] || w4=${#R_URL}
  done < <(records)
  if [ "${#rows[@]}" -eq 0 ]; then
    printf '(nothing exposed)\n'
    return 0
  fi
  printf '%-*s  %-*s  %-*s  %-*s  %-3s  %-8s  %s\n' "$w1" NAME "$w2" PROJECT "$w3" PORT "$w4" URL UP BIND ACCESS
  for row in "${rows[@]}"; do
    IFS=$'\x1f' read -r a b c d e g h <<<"$row"
    printf '%-*s  %-*s  %-*s  %-*s  %-3s  %-8s  %s\n' "$w1" "$a" "$w2" "$b" "$w3" "$c" "$w4" "$d" "$e" "$g" "$h"
  done
}

cmd_url() {
  local arg=$1 with_key=$2
  find_record "$arg"
  if [ "$with_key" -eq 1 ]; then
    printf 'owner login link for %s: opening it once logs this browser in to every *.%s URL for 30 days. Do not share it; for others use: expose.sh share %s\n' "$R_URL" "$DOMAIN" "$R_NAME"
    [ "$R_PUBLIC" = 1 ] && printf 'note: %s is public (--public); it needs no login. The proxy still takes the key out of the link, so the app never sees it.\n' "$R_URL"
    err "note: the login cookie holds the owner key and is sent to every host under $DOMAIN — use a domain that serves nothing but /expose"
    print_url "$R_URL/?opsx_key=$OWNER_KEY"
    return 0
  fi
  print_url "$R_URL"
}

# parse_ttl <dur> — prints the number of seconds, or "never"; returns 1 when
# the value is not <n>m, <n>h, <n>d or never.
parse_ttl() {
  local n
  case "$1" in
    never) printf never; return 0 ;;
  esac
  [[ "$1" =~ ^([1-9][0-9]{0,5})([mhd])$ ]] || return 1
  n=${BASH_REMATCH[1]}
  case "${BASH_REMATCH[2]}" in
    m) printf '%s' $((n * 60)) ;;
    h) printf '%s' $((n * 3600)) ;;
    d) printf '%s' $((n * 86400)) ;;
  esac
}

share_expiry_text() {
  local exp=$1
  if [ "$exp" = never ]; then printf never
  elif [ "$exp" -le "$NOW" ]; then printf expired
  else short_date "$exp"
  fi
}

cmd_share_list() {
  local sh id rec exp tok rows=() w1=3 w3=7 row a b c d
  for sh in "${R_SHARES[@]+"${R_SHARES[@]}"}"; do
    IFS=: read -r id rec exp tok <<<"$sh"
    c=$(share_expiry_text "$exp")
    rows+=("$rec"$'\x1f'"$id"$'\x1f'"$c"$'\x1f'"$R_URL/?opsx_share=$tok")
    [ "${#rec}" -le "$w1" ] || w1=${#rec}
    [ "${#c}" -le "$w3" ] || w3=${#c}
  done
  if [ "${#rows[@]}" -eq 0 ]; then
    printf '(no share links for %s)\n' "$R_URL"
    return 0
  fi
  printf '%-*s  %-6s  %-*s  %s\n' "$w1" FOR ID "$w3" EXPIRES LINK
  for row in "${rows[@]}"; do
    IFS=$'\x1f' read -r a b c d <<<"$row"
    printf '%-*s  %-6s  %-*s  %s\n' "$w1" "$a" "$b" "$w3" "$c" "$d"
  done
}

cmd_share_revoke() {
  local target=$1 t sh id rec exp tok keep=() gone=()
  t=$(normalise "$target")
  for sh in "${R_SHARES[@]+"${R_SHARES[@]}"}"; do
    IFS=: read -r id rec exp tok <<<"$sh"
    if [ "$target" = all ] || [ "$rec" = "$t" ] || [ "$id" = "$target" ]; then
      gone+=("$rec ($id)")
    else
      keep+=("$sh")
    fi
  done
  if [ "${#gone[@]}" -eq 0 ]; then
    printf 'no share link of %s matched %s — nothing to revoke\n' "$R_URL" "$target"
    return 0
  fi
  R_SHARES=("${keep[@]+"${keep[@]}"}")
  # State first: even if the proxy update fails, the token never comes back.
  rewrite_record
  add_route "$R_LABEL" "$(route_for_record)" || exit 1
  for t in "${gone[@]}"; do printf 'revoked the share link of %s for %s\n' "$t" "$R_URL"; done
}

cmd_share_new() {
  local for_raw=$1 ttl_s=$2 rec tok id exp sh keep=() tmp
  if [ "$R_PUBLIC" = 1 ]; then
    die "$R_URL is public (--public) and needs no share link; publish it without --public first: expose.sh up $R_PORT --name $R_NAME" 1
  fi
  tok=$(new_secret)
  valid_secret "$tok" || die "could not generate a random token (head, base64 and /dev/urandom are required)"
  id=$(sha6 "$tok")
  if [ -n "$for_raw" ]; then
    rec=$(normalise "$for_raw")
    [ -n "$rec" ] || die "recipient '$for_raw' has no usable characters ([a-z0-9])" 2
  else
    rec="link-$id"
  fi
  if [ "$ttl_s" = never ]; then exp=never; else exp=$((NOW + ttl_s)); fi
  # One token per recipient: sharing again replaces the old one.
  for sh in "${R_SHARES[@]+"${R_SHARES[@]}"}"; do
    [ "$(printf '%s' "$sh" | cut -d: -f2)" = "$rec" ] || keep+=("$sh")
  done
  keep+=("$id:$rec:$exp:$tok")
  tmp=$(write_record_tmp "$R_NAME" "$R_PROJECT" "$R_PORT" "$R_LABEL" "$R_URL" "$R_PUBLIC" "${keep[@]}") || exit 1
  read_record "$tmp"
  if ! add_route "$R_LABEL" "$(route_for_record)"; then
    rm -f "$tmp"
    exit 1
  fi
  commit_record "$tmp" "$R_LABEL"
  printf 'share link for %s on %s (id %s), expires %s; valid on this host only. Revoke with: expose.sh share %s --revoke %s\n' \
    "$rec" "$R_URL" "$id" "$(share_expiry_text "$exp")" "$R_NAME" "$rec"
  print_url "$R_URL/?opsx_share=$tok"
}

cmd_key_rotate() {
  local f n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    read_record "$f" || continue
    n=$((n + 1))
  done < <(records)
  if [ "${#RECONCILE_FAILED[@]}" -gt 0 ]; then
    err "rotated the owner key in $KEY_FILE, but the proxy refused to rebuild ${#RECONCILE_FAILED[@]} route(s): ${RECONCILE_FAILED[*]}"
    err "those routes may still accept the OLD key (or be offline) — fix the proxy, then run any expose.sh command (e.g. expose.sh list) to retry, or take them down with: expose.sh down <name>"
    exit 1
  fi
  printf 'rotated the owner key: every device is logged out and old login links no longer work (%s route(s) rebuilt; share links still work).\n' "$n"
  printf 'log in again on each device with: expose.sh url <name> --with-key\n'
}

# ---------- main ----------

main() {
  local cmd=${1:-help} pos=() name="" project="" json=0 public=0 with_key=0
  local for_raw="" ttl="" have_for=0 have_ttl=0 list=0 revoke="" have_revoke=0 ttl_s=""
  [ $# -gt 0 ] && shift
  case "$cmd" in
    help|-h|--help) usage; exit 0 ;;
    up|down|list|url|share|key) ;;
    *) err "unknown subcommand: $cmd"; usage >&2; exit 2 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)    [ $# -ge 2 ] || die "--name needs a value" 2; name=$2; shift 2 ;;
      --name=*)  name=${1#--name=}; shift ;;
      --project) [ $# -ge 2 ] || die "--project needs a value" 2; project=$2; shift 2 ;;
      --project=*) project=${1#--project=}; shift ;;
      --json)    json=1; shift ;;
      --public)  public=1; shift ;;
      --with-key) with_key=1; shift ;;
      --for)     [ $# -ge 2 ] || die "--for needs a value" 2; for_raw=$2; have_for=1; shift 2 ;;
      --for=*)   for_raw=${1#--for=}; have_for=1; shift ;;
      --ttl)     [ $# -ge 2 ] || die "--ttl needs a value" 2; ttl=$2; have_ttl=1; shift 2 ;;
      --ttl=*)   ttl=${1#--ttl=}; have_ttl=1; shift ;;
      --list)    list=1; shift ;;
      --revoke)  [ $# -ge 2 ] || die "--revoke needs a recipient, an id or all" 2; revoke=$2; have_revoke=1; shift 2 ;;
      --revoke=*) revoke=${1#--revoke=}; have_revoke=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; pos+=("$@"); break ;;
      -*) die "unknown option: $1 (try: expose.sh help)" 2 ;;
      *) pos+=("$1"); shift ;;
    esac
  done

  # Options that belong to one subcommand only.
  [ "$json" -eq 0 ] || [ "$cmd" = list ] || die "--json only applies to list" 2
  [ "$public" -eq 0 ] || [ "$cmd" = up ] || die "--public only applies to up" 2
  [ "$with_key" -eq 0 ] || [ "$cmd" = url ] || die "--with-key only applies to url" 2
  if [ "$cmd" != share ]; then
    [ "$have_for$have_ttl$list$have_revoke" = 0000 ] || die "--for, --ttl, --list and --revoke only apply to share" 2
  fi
  case "$cmd" in
    up)
      [ "${#pos[@]}" -eq 1 ] || die "usage: expose.sh up <port> [--name <n>] [--project <p>] [--public]" 2
      valid_port "${pos[0]}" || die "invalid port '${pos[0]}': use an integer from 1 to 65535, other than 443" 2 ;;
    down)
      [ "${#pos[@]}" -eq 1 ] || die "usage: expose.sh down <name|port> [--project <p>]" 2
      [ -z "$name" ] || die "--name does not apply to down" 2 ;;
    url)
      [ "${#pos[@]}" -eq 1 ] || die "usage: expose.sh url <name> [--project <p>] [--with-key]" 2
      [ -z "$name" ] || die "--name does not apply to url" 2 ;;
    share)
      [ "${#pos[@]}" -eq 1 ] || die "usage: expose.sh share <name> [--for <recipient>] [--ttl <n>m|<n>h|<n>d|never] [--project <p>] | --list | --revoke <recipient|id|all>" 2
      [ -z "$name" ] || die "--name does not apply to share (give the name as the argument)" 2
      [ $((list + have_revoke)) -le 1 ] || die "use either --list or --revoke" 2
      if [ $((list + have_revoke)) -eq 1 ] && [ "$have_for$have_ttl" != 00 ]; then
        die "--for and --ttl only apply when creating a share link" 2
      fi
      [ "$have_revoke" -eq 0 ] || [ -n "$revoke" ] || die "--revoke needs a recipient, an id or all" 2
      if [ "$list" -eq 0 ] && [ "$have_revoke" -eq 0 ]; then
        [ "$have_ttl" -eq 1 ] || ttl=7d
        ttl_s=$(parse_ttl "$ttl") || die "invalid --ttl '$ttl': use <n>m, <n>h, <n>d (n a positive integer) or never" 2
      fi ;;
    key)
      [ "${#pos[@]}" -eq 1 ] && [ "${pos[0]}" = rotate ] || die "usage: expose.sh key rotate" 2
      [ -z "$name" ] && [ -z "$project" ] || die "key rotate takes no options" 2 ;;
    list)
      [ "${#pos[@]}" -eq 0 ] || die "usage: expose.sh list [--json]" 2
      [ -z "$name" ] && [ -z "$project" ] || die "list takes only --json" 2 ;;
  esac
  [[ "$NOW" =~ ^[0-9]+$ ]] || die "OPSX_EXPOSE_NOW must be seconds since the epoch" 2

  load_config
  case "$cmd" in list|key) ;; *) resolve_project "$project" ;; esac
  command -v curl >/dev/null 2>&1 || die "curl is required"

  # Loopback only: refuse before touching the proxy or the state.
  BIND_STATE=none
  if [ "$cmd" = up ]; then
    bind_state "${pos[0]}"
    case "$BIND_STATE" in
      public)
        die "refusing to publish port ${pos[0]}: the app listens on $BIND_PUBLIC, so it is reachable at <server-ip>:${pos[0]} without the proxy's login. Bind it to 127.0.0.1 instead (e.g. --host 127.0.0.1, or for Docker -p 127.0.0.1:${pos[0]}:${pos[0]}), then run up again." 2 ;;
      unknown)
        if [ "$(uname -s)" = Linux ]; then
          die "cannot check which address port ${pos[0]} listens on (needs ss from iproute2); refusing to publish it — install ss and run up again" 2
        else
          die "cannot check which address port ${pos[0]} listens on (needs lsof); refusing to publish it — install lsof and run up again" 2
        fi ;;
    esac
  fi

  require_proxy
  take_lock
  if [ "$cmd" = key ]; then write_key; fi
  load_key
  prune_expired
  reconcile

  case "$cmd" in
    up)   cmd_up "${pos[0]}" "$name" "$public" ;;
    down) cmd_down "${pos[0]}" ;;
    list) cmd_list "$json" ;;
    url)  cmd_url "${pos[0]}" "$with_key" ;;
    share)
      find_record "${pos[0]}"
      if [ "$list" -eq 1 ]; then cmd_share_list
      elif [ "$have_revoke" -eq 1 ]; then cmd_share_revoke "$revoke"
      else cmd_share_new "$for_raw" "$ttl_s"
      fi ;;
    key)  cmd_key_rotate ;;
  esac
}

main "$@"
