# Shared helpers for opsx-preview checks (sourced, not a check). Everything is
# local to $EVAL_TMP: scratch HOME/XDG dirs, a per-check private tmux server
# (tmux -L), a fake expose.sh ($OPSX_EXPOSE_SH) that only records routes in
# files, and a throwaway git repo `shop` with a worktree for change add-auth.
# Never the user's tmux session, real expose config, Caddy, systemd or DNS.
fail() { echo "FAIL: $*"; exit 1; }
for t in tmux git python3 curl setsid; do
  command -v "$t" >/dev/null || { echo "$t not on PATH"; exit 77; }
done
PREVIEW="$EVAL_ROOT/skills/opsx-run/opsx-preview.sh"
WINDOW="$EVAL_ROOT/skills/opsx-run/opsx-window.sh"
LAND="$EVAL_ROOT/skills/opsx-run/opsx-land.sh"
export HOME="$EVAL_TMP/home"
export CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_HOME="$HOME/.codex"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
export GIT_CONFIG_NOSYSTEM=1 OPSX_EXPOSE_NO_COPY=1
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

# ---- private tmux server (per check) -------------------------------------
TSOCK_DIR=$(mktemp -d /tmp/oxp.XXXXXX); chmod 700 "$TSOCK_DIR"
export TMUX_TMPDIR="$TSOCK_DIR"
TSOCK="pv$$"
T() { env -u TMUX -u TMUX_PANE tmux -L "$TSOCK" -f /dev/null "$@"; }
T new-session -d -s shop -n caller -x 200 -y 50 'exec sleep 86400' || { echo "cannot start private tmux server"; exit 77; }
export TMUX="$(T display -p -t shop '#{socket_path},#{pid},0')"
export TMUX_PANE="$(T display -p -t shop:caller '#{pane_id}')"
# every window id with @opsx_preview == $1
preview_windows() {
  T list-windows -a -F '#{window_id} #{@opsx_preview}' 2>/dev/null | awk -v c="$1" '$2==c {print $1}'
}
win_opt() { T show-options -wqv -t "$1" "$2" 2>/dev/null; }

# ---- fake expose.sh ------------------------------------------------------
export FAKE_EXPOSE_DIR="$EVAL_TMP/expose"
mkdir -p "$FAKE_EXPOSE_DIR/routes"
export OPSX_EXPOSE_SH="$EVAL_TMP/fake-expose.sh"
cat > "$OPSX_EXPOSE_SH" <<'SH'
#!/usr/bin/env bash
# Fake expose.sh (ops-eval): follows the port-expose contract, records routes
# as files in $FAKE_EXPOSE_DIR/routes/<name>--<project> containing the port.
D=${FAKE_EXPOSE_DIR:?}
printf 'expose.sh %s\n' "$*" >> "$D/calls.log"
cmd=${1:-help}; shift || true
[ "$cmd" = help ] && { echo "fake expose"; exit 0; }
if [ ! -f "$D/configured" ]; then
  echo "expose: not configured — run install.sh --expose-domain <domain>" >&2; exit 3
fi
DOMAIN=$(cat "$D/configured")
name="" project="" json=0 pos=()
while [ $# -gt 0 ]; do
  case $1 in
    --name) name=$2; shift 2;; --project) project=$2; shift 2;;
    --json) json=1; shift;; *) pos+=("$1"); shift;;
  esac
done
if [ -z "$project" ]; then
  c=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && project=$(basename "$(dirname "$c")") || project=$(basename "$PWD")
fi
case $cmd in
  up)
    port=${pos[0]:-}; case $port in ''|*[!0-9]*) echo "usage" >&2; exit 2;; esac
    [ -n "$name" ] || name=$port
    echo "$port" > "$D/routes/$name--$project"
    echo "Exposed 127.0.0.1:$port (public, no auth)" >&2
    echo "https://$name--$project.$DOMAIN";;
  down)
    a=${pos[0]:-}; hit=0
    for f in "$D"/routes/*--"$project"; do
      [ -f "$f" ] || continue
      b=$(basename "$f"); n=${b%--"$project"}
      if [ "$n" = "$a" ] || [ "$(cat "$f")" = "$a" ]; then rm -f "$f"; hit=1; echo "removed $b"; fi
    done
    [ $hit = 1 ] || echo "nothing matched $a"; exit 0;;
  list)
    first=1; [ $json = 1 ] && printf '[' || echo "NAME PROJECT PORT URL UP"
    for f in "$D"/routes/*; do
      [ -f "$f" ] || continue
      b=$(basename "$f"); n=${b%%--*}; p=${b#*--}; port=$(cat "$f")
      if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then up=true; else up=false; fi
      if [ $json = 1 ]; then
        [ $first = 1 ] || printf ','; first=0
        printf '{"name":"%s","project":"%s","port":%s,"url":"https://%s.%s","up":%s}' "$n" "$p" "$port" "$b" "$DOMAIN" "$up"
      else echo "$n $p $port https://$b.$DOMAIN $up"; fi
    done
    [ $json = 1 ] && echo ']'; exit 0;;
  url)
    n=${pos[0]:-}; [ -f "$D/routes/$n--$project" ] || { echo "no exposure $n" >&2; exit 1; }
    echo "https://$n--$project.$DOMAIN";;
  *) echo "usage" >&2; exit 2;;
esac
SH
chmod +x "$OPSX_EXPOSE_SH"
expose_configure() { echo "${1:-dev.example.com}" > "$FAKE_EXPOSE_DIR/configured"; }
route_port() { cat "$FAKE_EXPOSE_DIR/routes/$1" 2>/dev/null; }   # route_port add-auth--shop
expose_list_json() { "$OPSX_EXPOSE_SH" list --json; }
expose_has() {  # expose_has <name>: true when `expose.sh list --json` has that name
  expose_list_json | python3 -I -c 'import json,sys; sys.exit(0 if any(r["name"]==sys.argv[1] for r in json.load(sys.stdin)) else 1)' "$1"
}

# ---- fixture repo: $EVAL_TMP/shop (main) + $EVAL_TMP/wt-add-auth ---------
REPO="$EVAL_TMP/shop"
WT="$EVAL_TMP/wt-add-auth"
g() { git -C "$REPO" "$@"; }
mk_repo() {
  mkdir -p "$REPO/openspec/specs" "$REPO/openspec/changes/add-auth/specs/auth"
  git init -q -b main "$REPO"
  g config user.email eval@example.invalid; g config user.name eval; g config commit.gpgsign false
  cat > "$REPO/openspec/changes/add-auth/proposal.md" <<'S'
## Why
Users need to log in so the service can tell them apart and protect their data.

## What Changes
- Add a login command.
S
  printf '## Context\nA plain login check.\n\n## Decisions\nStore the result in login.txt.\n' > "$REPO/openspec/changes/add-auth/design.md"
  printf '## 1. Login\n\n- [x] 1.1 Add login\n' > "$REPO/openspec/changes/add-auth/tasks.md"
  cat > "$REPO/openspec/changes/add-auth/specs/auth/spec.md" <<'S'
## ADDED Requirements

### Requirement: Login
The service SHALL log users in with valid credentials.

#### Scenario: Login ok
- **WHEN** valid credentials are given
- **THEN** login succeeds
S
  echo "main-checkout" > "$REPO/index.html"
  g add -A; g commit -qm "init + change proposal"
}
# mk_worktree: branch opsx/add-auth checked out at $WT, with a marker page.
mk_worktree() {
  g worktree add -q -b opsx/add-auth "$WT" main
  echo "worktree-add-auth" > "$WT/index.html"
  echo "login ok" > "$WT/login.txt"
  git -C "$WT" add -A; git -C "$WT" commit -qm "implement add-auth"
}
# recipe <dir> <yaml lines...>: write .opsx/preview.yaml (committed when in a git checkout)
recipe() {
  local d=$1; shift
  mkdir -p "$d/.opsx"; printf '%s\n' "$@" > "$d/.opsx/preview.yaml"
  git -C "$d" add .opsx >/dev/null 2>&1 && git -C "$d" commit -qm "preview recipe" >/dev/null 2>&1
  return 0
}
HTTP_CMD='cmd: python3 -m http.server $PORT --bind 127.0.0.1'
# pv <args>: run opsx-preview.sh from the main checkout; sets $out and $rc
pv() { out=$(cd "${PV_CWD:-$REPO}" && setsid -w "$PREVIEW" "$@" </dev/null 2>&1); rc=$?; }
last_line() { printf '%s\n' "$out" | awk 'NF' | tail -n1; }
http_get() { curl -s -m 3 "http://127.0.0.1:$1/${2:-}"; }

# ---- cleanup: stop previews, kill anything still running in the checkouts --------
_kill_tmp_procs() {
  local p cwd
  for p in /proc/[0-9]*; do
    cwd=$(readlink "$p/cwd" 2>/dev/null) || continue
    case $cwd in "$REPO"|"$REPO"/*|"$WT"|"$WT"/*) [ "${p#/proc/}" != $$ ] && kill -9 "${p#/proc/}" 2>/dev/null;; esac
  done
}
_preview_cleanup() {
  [ -d "$REPO" ] && ( cd "$REPO" && timeout 20 "$PREVIEW" stop --all </dev/null >/dev/null 2>&1 )
  T kill-server 2>/dev/null
  _kill_tmp_procs
  rm -rf "$TSOCK_DIR"
}
trap _preview_cleanup EXIT
