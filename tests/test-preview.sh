#!/usr/bin/env bash
# Scripted tests for skills/opsx-run/opsx-preview.sh, the preview-* window
# subcommands in opsx-window.sh, and preview teardown in close / land.
#
# Runs in a scratch HOME/XDG with scratch git repos. tmux work goes to a
# private server (tmux -L opsx-preview-test-$$) that $TMUX/$TMUX_PANE point
# at, expose.sh is a fake that records its calls ($OPSX_EXPOSE_SH), and
# `openspec`, `pnpm`, `npm` are fakes on PATH. Apps are python3 http.server on
# 127.0.0.1. Never touches your tmux session, expose config, Caddy or DNS.
# Usage: bash tests/test-preview.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016
set -u
for t in tmux python3 curl git; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t is required"; exit 1; }
done
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
P=$REPO/skills/opsx-run/opsx-preview.sh
W=$REPO/skills/opsx-run/opsx-window.sh
LAND=$REPO/skills/opsx-run/opsx-land.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/preview-test.XXXXXX")
SOCK_NAME=opsx-preview-test-$$
L="tmux -L $SOCK_NAME"

export HOME=$SP/home XDG_CONFIG_HOME=$SP/home/.config XDG_STATE_HOME=$SP/home/.local/state
mkdir -p "$HOME"
export NO_COLOR=1 OPSX_EXPOSE_NO_COPY=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PS_DIR=$XDG_STATE_HOME/tmux-opsx/preview

# Kill every app process group the previews recorded, then the private server.
cleanup() {
  local f g
  for f in "$PS_DIR"/*/*.pgid "$PS_DIR"/*/*.env; do
    [ -f "$f" ] || continue
    case "$f" in
      *.pgid) g=$(cat "$f" 2>/dev/null) ;;
      *)      g=$(awk -F= '$1=="PGID"{print $2}' "$f") ;;
    esac
    [[ "$g" =~ ^[0-9]+$ ]] && [ "$g" -gt 1 ] && kill -KILL -- "-$g" 2>/dev/null
  done
  [ -n "${ADMIN_PID:-}" ] && kill "$ADMIN_PID" 2>/dev/null
  $L kill-server 2>/dev/null
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK_NAME"
  rm -rf "$SP"
}
trap cleanup EXIT

# ---------------------------------------------------------------- fakes
mkdir -p "$SP/bin"
EXPOSE_LOG=$SP/expose.log
: > "$EXPOSE_LOG"
cat > "$SP/bin/fake-expose.sh" <<'EOF'
#!/usr/bin/env bash
# Fake expose.sh: records calls; $FAKE_EXPOSE_DIR/rc forces the exit of `list`.
d=$FAKE_EXPOSE_DIR
printf '%s\n' "$*" >> "$d/expose.log"
cmd=$1; shift
name=""; project=""; pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name=$2; shift 2 ;;
    --project) project=$2; shift 2 ;;
    --json) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
mkdir -p "$d/routes"
case "$cmd" in
  list)
    if [ -f "$d/rc" ]; then
      rc=$(cat "$d/rc")
      [ "$rc" = 3 ] && echo "expose: expose is not configured — run: install.sh --expose-domain <domain>" >&2
      [ "$rc" = 4 ] && echo "expose: proxy not reachable" >&2
      exit "$rc"
    fi
    printf '['; first=1
    for f in "$d/routes"/*; do
      [ -f "$f" ] || continue
      [ $first -eq 1 ] || printf ','; first=0
      printf '{"name":"%s","port":%s}' "$(basename "$f")" "$(cat "$f")"
    done
    printf ']\n' ;;
  up)
    name=${name:-${pos[0]}}
    printf '%s\n' "${pos[0]}" > "$d/routes/$name--$project"
    echo "expose: copied to clipboard (fake)" >&2
    echo "https://$name--$project.dev.example.com" ;;
  down)
    rm -f "$d/routes/${pos[0]}--$project" ;;
  url)
    [ -f "$d/routes/${pos[0]}--$project" ] || exit 1
    echo "https://${pos[0]}--$project.dev.example.com" ;;
esac
exit 0
EOF
chmod +x "$SP/bin/fake-expose.sh"
export FAKE_EXPOSE_DIR=$SP OPSX_EXPOSE_SH=$SP/bin/fake-expose.sh

# Fake package managers: record argv, `install` bumps a counter, `run dev`
# serves on the --port it was given.
for pm in pnpm npm; do
  cat > "$SP/bin/$pm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$pm \$*" >> "$SP/pm.log"
if [ "\$1" = install ]; then echo x >> "$SP/$pm-install.count"; exit 0; fi
port=""
while [ \$# -gt 0 ]; do [ "\$1" = --port ] && port=\$2; shift; done
exec python3 -m http.server "\$port" --bind 127.0.0.1
EOF
  chmod +x "$SP/bin/$pm"
done
cat > "$SP/bin/openspec" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  validate) exit 0 ;;
  status)   echo '{"isComplete": true}' ;;
  archive)  mkdir -p openspec/changes/archive && mv "openspec/changes/$2" "openspec/changes/archive/$2" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SP/bin/openspec"
# A stand-in agent CLI for agent windows.
printf '#!/usr/bin/env bash\nexec sleep 3000\n' > "$SP/bin/fakecli"
chmod +x "$SP/bin/fakecli"
export PATH=$SP/bin:$PATH

# ---------------------------------------------------------------- private tmux
$L -f /dev/null new-session -d -s pt -x 160 -y 40 'exec sleep 3000'
TMUX="$($L display -p '#{socket_path}'),$($L display -p '#{pid}'),0"
TMUX_PANE=$($L display -p -t pt '#{pane_id}')
export TMUX TMUX_PANE

pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

nwin()      { $L list-windows -a -F '#{@opsx_preview}' | grep -cx "$1"; }
win_tag()   { $L show-options -wv -t "$1" "$2" 2>/dev/null; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
rec()       { awk -F= -v k="$2" '$1==k{print $2}' "$PS_DIR/$PROJ/$1.env" 2>/dev/null; }
last()      { printf '%s\n' "$1" | awk 'NF{l=$0} END{print l}'; }
# Distinct process groups of http.server apps carrying OPSX_PREVIEW=$1 (Linux /proc).
napps() {
  local e p
  for e in /proc/[0-9]*/environ; do
    tr '\0' '\n' < "$e" 2>/dev/null | grep -qx "OPSX_PREVIEW=$1" || continue
    p=${e#/proc/}; p=${p%/environ}
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "http.server" || continue
    ps -o pgid= -p "$p" 2>/dev/null | tr -d ' '
  done 2>/dev/null | sort -u | grep -c .
}

# ---------------------------------------------------------------- scratch repo
PROJ=shop
R=$SP/$PROJ
mkdir -p "$R"; git -C "$R" init -q -b main
mkdir -p "$R/openspec/changes/add-auth" "$R/.opsx"
printf -- '- [x] done\n' > "$R/openspec/changes/add-auth/tasks.md"
printf 'cmd: python3 -m http.server $PORT --bind 127.0.0.1\n' > "$R/.opsx/preview.yaml"
echo hi > "$R/index.html"
git -C "$R" add -A; git -C "$R" commit -qm init

# addwt <change>: a worktree at $SP/wt-<change> on opsx/<change>
addwt() { git -C "$R" worktree add -q "$SP/wt-$1" -b "opsx/$1" >/dev/null 2>&1; }
pv() { ( cd "$R" && "$P" "$@" ) 2>&1; }

# ================================================================ 1.1 windows
printf 'echo preview-script-ran; exec sleep 3000\n' > "$SP/raw.sh"
out=$(cd "$R" && "$W" preview-start rawprev --cwd "$R" --script "$SP/raw.sh"); rc=$?
WID=$(awk '/^created /{print $2}' <<<"$out")
ok "preview-start creates a window"            '[ "$rc" -eq 0 ] && [ -n "$WID" ]'
ok "window tagged @opsx_preview"               '[ "$(win_tag "$WID" @opsx_preview)" = rawprev ]'
ok "window has no @opsx_change"                '[ -z "$(win_tag "$WID" @opsx_change)" ]'
ok "window title ox ><change> (ASCII)"         '[ "$($L display -p -t "$WID" "#{window_name}")" = "ox >rawprev" ]'
ok "window tagged with the project path"       '[ "$(win_tag "$WID" @opsx_preview_project)" = "$R" ]'
ok "remain-on-exit on, rename off"             '[ "$(win_tag "$WID" remain-on-exit)" = on ] && [ "$(win_tag "$WID" automatic-rename)" = off ]'
sleep 0.5
ok "script ran without send-keys"              '$L capture-pane -p -t "$WID" | grep -q preview-script-ran'
ok "preview-find returns the id"               '[ "$(cd "$R" && "$W" preview-find rawprev)" = "$WID" ]'
ok "preview-find unknown -> non-zero"          '! (cd "$R" && "$W" preview-find nope >/dev/null 2>&1)'
printf 'apply\n' > "$SP/prompt.txt"
(cd "$R" && "$W" ensure rawprev --prompt-file "$SP/prompt.txt" --agent-cli fakecli --model default) >/dev/null 2>&1
AW=$($L list-windows -t pt -F '#{window_id} #{@opsx_change}' | awk '$2=="rawprev"{print $1}')
ok "agent window created next to preview"      '[ -n "$AW" ] && [ "$AW" != "$WID" ]'
ok "agent lookup finds the agent window"       '(cd "$R" && "$W" status rawprev --lines 1) | head -1 | grep -q "($AW)"'
out=$(cd "$R" && "$W" close --all --force 2>&1)
ok "close --all kills only agent windows"      '! $L list-windows -t pt -F "#{window_id}" | grep -qx "$AW" && $L list-windows -t pt -F "#{window_id}" | grep -qx "$WID"'
(cd "$R" && "$W" preview-kill rawprev) >/dev/null
ok "preview-kill removes the window"           '[ "$(nwin rawprev)" -eq 0 ]'
ok "preview-kill with nothing -> exit 0"       '(cd "$R" && "$W" preview-kill rawprev) >/dev/null'

# ================================================================ 2.1 CLI
ok "bash -n"                                   'bash -n "$P"'
h=$("$P" help); rc=$?
ok "help lists subcommands"                    '[ $rc -eq 0 ] && for w in up stop url share list --main --all --for --ttl --list --revoke preview.yaml; do [[ "$h" == *"$w"* ]] || exit 1; done'
"$P" bogus >/dev/null 2>&1; rc=$?
ok "unknown subcommand -> exit 2"              '[ $rc -eq 2 ]'
eout=$("$P" bogus 2>&1 >/dev/null)
ok "unknown subcommand -> short hint (QA F6)"  '[ "$(printf "%s\n" "$eout" | wc -l)" -le 2 ] && [[ "$eout" == *"unknown subcommand: bogus"* ]] && [[ "$eout" == *"opsx-preview.sh help"* ]]'
out=$(pv up add-auth); rc=$?
ok "no worktree -> non-zero, apply first"      '[ $rc -ne 0 ] && [[ "$out" == *"apply the change first"* ]] && [ "$(nwin add-auth)" -eq 0 ]'
ok "no worktree -> no expose call"             '! grep -q "^up" "$EXPOSE_LOG"'

# ================================================================ 2.3 not configured
addwt add-auth
echo 3 > "$SP/rc"
out=$(pv up add-auth); rc=$?
ok "expose not configured -> install.sh --expose-domain" '[ $rc -ne 0 ] && [[ "$out" == *"install.sh --expose-domain"* ]]'
ok "not configured -> no window, no up"        '[ "$(nwin add-auth)" -eq 0 ] && ! grep -q "^up" "$EXPOSE_LOG"'
echo 4 > "$SP/rc"
out=$(pv up add-auth); rc=$?
ok "proxy down -> proxy not running"           '[ $rc -ne 0 ] && [[ "$out" == *"proxy is not running"* ]] && [ "$(nwin add-auth)" -eq 0 ]'
rm -f "$SP/rc"
out=$(cd "$R" && OPSX_EXPOSE_SH=$SP/bin/missing "$P" up add-auth 2>&1); rc=$?
ok "expose missing -> install.sh --expose-domain" '[ $rc -ne 0 ] && [[ "$out" == *"install.sh --expose-domain"* ]] && [ "$(nwin add-auth)" -eq 0 ]'

# ================================================================ 3.2/3.3 start, reuse, stop
out=$(pv up add-auth); rc=$?
URL1=$(last "$out")
PORT1=$(rec add-auth PORT)
ok "up exits 0 with URL as last line"          '[ $rc -eq 0 ] && [ "$URL1" = "https://add-auth--shop.dev.example.com" ]'
ok "up called expose up <port> --name --project" 'grep -qx "up $PORT1 --name add-auth --project shop" "$EXPOSE_LOG"'
ok "app listens on the chosen port"            '[ "$PORT1" -ge 3100 ] && [ "$PORT1" -le 3999 ] && curl -sf "http://127.0.0.1:$PORT1/index.html" | grep -q hi'
ok "app served from the worktree"              '[ "$(rec add-auth CHECKOUT)" = "$SP/wt-add-auth" ]'
PW=$($L list-windows -t pt -F '#{window_id} #{@opsx_preview}' | awk '$2=="add-auth"{print $1}')
ok "one preview window, no @opsx_change"       '[ "$(nwin add-auth)" -eq 1 ] && [ -z "$(win_tag "$PW" @opsx_change)" ]'
ok "log file gets app output"                  '[ -s "$(rec add-auth LOG)" ] && grep -q "opsx-preview add-auth" "$(rec add-auth LOG)"'
ok "launch script uses setsid, PORT and HOST"  'L1=$PS_DIR/shop/add-auth.launch.sh; grep -q setsid "$L1" && grep -q "HOST=127.0.0.1" "$L1" && grep -q "PORT=$PORT1" "$L1"'
ok "app runs in its own process group"         'g=$(rec add-auth PGID); [ -n "$g" ] && [ "$(ps -o pgid= -p "$g" | tr -d " ")" = "$g" ] && [ "$g" != "$(ps -o pgid= -p $$ | tr -d " ")" ]'
out=$(pv up add-auth); rc=$?
ok "second up -> same URL"                     '[ $rc -eq 0 ] && [ "$(last "$out")" = "$URL1" ] && [[ "$out" == *"already running"* ]]'
ok "second up -> still one window"             '[ "$(nwin add-auth)" -eq 1 ] && [ "$(grep -c "^up .*--name add-auth" "$EXPOSE_LOG")" -eq 1 ]'
out=$(pv url add-auth); rc=$?
ok "url prints the running URL"                '[ $rc -eq 0 ] && [ "$(last "$out")" = "$URL1" ]'
out=$(pv list)
ok "list shows the preview"                    'grep -E "^add-auth +$PORT1 +up " <<<"$out" | grep -q "$URL1"'

# Stale record: the app is killed behind our back -> up restarts it.
kill -KILL -- "-$(rec add-auth PGID)"; sleep 0.5
out=$(pv up add-auth); rc=$?
ok "stale record -> cleaned and restarted"     '[ $rc -eq 0 ] && [[ "$out" == *"stale record"* ]] && [ "$(last "$out")" = "$URL1" ] && [ "$(nwin add-auth)" -eq 1 ]'
ok "restart reuses the last port"              '[ "$(rec add-auth PORT)" = "$PORT1" ]'

# F2: preview state is per project, not per tmux session.
$L new-session -d -s pt2 -x 160 -y 40 'exec sleep 3000'
PANE_B=$($L display -p -t pt2 '#{pane_id}')
WA=$(rec add-auth WINDOW_ID)
out=$(TMUX_PANE=$PANE_B pv up add-auth); rc=$?
ok "up from another session -> already running" '[ $rc -eq 0 ] && [[ "$out" == *"already running"* ]] && [ "$(last "$out")" = "$URL1" ] && [ "$(rec add-auth WINDOW_ID)" = "$WA" ] && [ "$(nwin add-auth)" -eq 1 ]'
out=$(TMUX_PANE=$PANE_B pv url add-auth); rc=$?
ok "url from another session"                  '[ $rc -eq 0 ] && [ "$(last "$out")" = "$URL1" ]'
# A leftover preview window (listed first in the session) must not turn a
# healthy preview into a "stale" one.
(cd "$R" && "$W" preview-start add-auth --cwd "$R" --script "$SP/raw.sh") >/dev/null
$L swap-window -d -s "$($L list-windows -a -F '#{window_id} #{@opsx_preview}' | awk '$2=="add-auth"{print $1}' | grep -vx "$WA" | head -1)" -t pt:0
ok "leftover window listed before the live one" '[ "$($L list-windows -a -F "#{window_id} #{@opsx_preview}" | awk "\$2==\"add-auth\"{print \$1; exit}")" != "$WA" ]'
out=$(pv up add-auth); rc=$?
ok "leftover window -> still already running"  '[ $rc -eq 0 ] && [[ "$out" == *"already running"* ]] && [ "$(rec add-auth WINDOW_ID)" = "$WA" ]'
out=$(TMUX_PANE=$PANE_B pv stop add-auth); rc=$?
ok "stop from another session removes windows" '[ $rc -eq 0 ] && [ "$(nwin add-auth)" -eq 0 ] && [ ! -e "$SP/routes/add-auth--shop" ]'
$L kill-session -t pt2
out=$(pv up add-auth); rc=$?
ok "up again after cross-session stop"         '[ $rc -eq 0 ] && [ "$(last "$out")" = "$URL1" ] && [ "$(nwin add-auth)" -eq 1 ]'
ok "launch script exports OPSX_PREVIEW_PROJECT" 'grep -q "OPSX_PREVIEW_PROJECT=shop" "$PS_DIR/shop/add-auth.launch.sh"'
ok "up relays expose stderr (clipboard status)" '[[ "$out" == *"copied to clipboard (fake)"* ]]'

G=$(rec add-auth PGID)
out=$(pv stop add-auth); rc=$?
sleep 0.3
ok "stop exits 0"                              '[ $rc -eq 0 ] && [[ "$out" == *"stopped preview add-auth"* ]]'
ok "stop: no window"                           '[ "$(nwin add-auth)" -eq 0 ]'
ok "stop: no process on the port"              '! port_open "$PORT1" && ! kill -0 -- "-$G" 2>/dev/null'
ok "stop: expose down recorded"                'grep -qx "down add-auth --project shop" "$EXPOSE_LOG" && [ ! -e "$SP/routes/add-auth--shop" ]'
ok "stop: record deleted"                      '[ ! -e "$PS_DIR/shop/add-auth.env" ]'
out=$(pv stop add-auth); rc=$?
ok "second stop exits 0"                       '[ $rc -eq 0 ]'
out=$(pv url add-auth); rc=$?
ok "url with nothing running -> non-zero"      '[ $rc -ne 0 ]'

# F1: a failed restart must not leave the old route behind.
pv up add-auth >/dev/null
kill -KILL -- "-$(rec add-auth PGID)"; sleep 0.5
cp "$SP/wt-add-auth/.opsx/preview.yaml" "$SP/f1-recipe.yaml"
printf 'cmd: exit 1\ntimeout: 10\n' > "$SP/wt-add-auth/.opsx/preview.yaml"
: > "$EXPOSE_LOG"
out=$(pv up add-auth); rc=$?
ok "failed restart -> non-zero"                '[ $rc -ne 0 ] && [[ "$out" == *"stale record"* ]] && [[ "$out" == *"exited before"* ]]'
ok "failed restart -> old route removed"       '[ ! -e "$SP/routes/add-auth--shop" ] && grep -qx "down add-auth --project shop" "$EXPOSE_LOG" && ! grep -q "^up " "$EXPOSE_LOG"'
out=$(pv stop add-auth); rc=$?
ok "stop after failed restart -> no route"     '[ $rc -eq 0 ] && [ ! -e "$SP/routes/add-auth--shop" ] && [ "$(nwin add-auth)" -eq 0 ]'
cp "$SP/f1-recipe.yaml" "$SP/wt-add-auth/.opsx/preview.yaml"
# A failed first start also removes a route left by an earlier run.
printf '4000\n' > "$SP/routes/broken--shop"

# F3: a recorded group id that now belongs to someone else is never signalled.
( setsid sleep 300 </dev/null >/dev/null 2>&1 & )
sleep 0.3
FG=$(ps -A -o pid=,pgid=,args= | awk '$3=="sleep" && $4=="300" && $1==$2 {print $1; exit}')
mkdir -p "$PS_DIR/shop"
printf 'NAME=add-auth\nCHECKOUT=%s\nPORT=3999\nPGID=%s\nWINDOW_ID=@999\nLOG=/dev/null\nURL=https://x\nHEALTH=/\n' "$SP/wt-add-auth" "$FG" > "$PS_DIR/shop/add-auth.env"
out=$(pv stop add-auth); rc=$?
ok "stop: foreign group id left alone"         '[ -n "$FG" ] && [ $rc -eq 0 ] && kill -0 "$FG" 2>/dev/null && [[ "$out" == *"no longer belongs"* ]]'
printf 'NAME=add-auth\nCHECKOUT=%s\nPORT=3999\nPGID=%s\nWINDOW_ID=@999\nLOG=/dev/null\nURL=https://x\nHEALTH=/\n' "$SP/wt-add-auth" "$FG" > "$PS_DIR/shop/add-auth.env"
out=$(pv list)
ok "list: foreign group id reads as dead"      'grep -E "^add-auth +3999 +dead " <<<"$out" >/dev/null'
out=$(pv up add-auth); rc=$?
ok "stale up: foreign group id left alone"     '[ $rc -eq 0 ] && kill -0 "$FG" 2>/dev/null && [ "$(rec add-auth PGID)" != "$FG" ]'
pv stop add-auth >/dev/null
[ -n "$FG" ] && kill -KILL "$FG" 2>/dev/null

# --main
out=$(pv up --main); rc=$?
ok "up --main publishes under main"            '[ $rc -eq 0 ] && [ "$(last "$out")" = "https://main--shop.dev.example.com" ] && grep -q "^up [0-9]* --name main --project shop" "$EXPOSE_LOG"'
ok "main preview runs the main checkout"       '[ "$(rec main CHECKOUT)" = "$R" ]'
out=$(cd "$SP/wt-add-auth" && "$P" url --main 2>&1); rc=$?
ok "url --main from a worktree (same project)" '[ $rc -eq 0 ] && [ "$(last "$out")" = "https://main--shop.dev.example.com" ]'
pv stop --main >/dev/null
ok "stop --main"                               '[ "$(nwin main)" -eq 0 ]'

# ================================================================ 3.2 never healthy
addwt broken
mkdir -p "$SP/wt-broken/.opsx"
printf 'cmd: "echo boom-marker-1; echo boom-marker-2; exit 1"\ntimeout: 20\n' > "$SP/wt-broken/.opsx/preview.yaml"
out=$(pv up broken); rc=$?
ok "app exits -> non-zero with log lines"      '[ $rc -ne 0 ] && [[ "$out" == *"boom-marker-2"* ]] && [[ "$out" == *"exited before"* ]]'
ok "app exits -> no expose up, no window"      '! grep -q "^up .*--name broken" "$EXPOSE_LOG" && [ "$(nwin broken)" -eq 0 ] && [ ! -e "$PS_DIR/shop/broken.env" ]'
ok "app exits -> no route left (F1)"           '[ ! -e "$SP/routes/broken--shop" ]'
printf 'cmd: exec sleep 30\ntimeout: 2\n' > "$SP/wt-broken/.opsx/preview.yaml"
out=$(pv up broken); rc=$?
ok "health timeout -> non-zero, app stopped"   '[ $rc -ne 0 ] && [[ "$out" == *"timeout"* ]] && [ "$(nwin broken)" -eq 0 ] && ! grep -q "^up .*--name broken" "$EXPOSE_LOG"'
ok "failure tail: this run only (QA F2)"       '[[ "$out" != *"boom-marker"* ]] && grep -q "boom-marker-2" "$PS_DIR/shop/broken.log"'

# ================================================================ 2.2 recipes
addwt nocmd
mkdir -p "$SP/wt-nocmd/.opsx"
printf '# no cmd here\ninstall: echo hi\nport: 1\n' > "$SP/wt-nocmd/.opsx/preview.yaml"
out=$(pv up nocmd); rc=$?
ok "missing cmd -> non-zero naming cmd"        '[ $rc -ne 0 ] && [[ "$out" == *"cmd"* ]] && [ "$(nwin nocmd)" -eq 0 ] && ! grep -q "name nocmd" "$EXPOSE_LOG"'
ok "unknown key -> warning"                    '[[ "$out" == *"unknown key '\''port'\''"* ]]'

addwt quoted
mkdir -p "$SP/wt-quoted/.opsx"
printf "cmd: 'python3 -m http.server \$PORT --bind 127.0.0.1'\nhealth: \"/index.html\"\n" > "$SP/wt-quoted/.opsx/preview.yaml"
echo q > "$SP/wt-quoted/index.html"
out=$(pv up quoted); rc=$?
ok "quoted values + health path"               '[ $rc -eq 0 ] && [ "$(rec quoted HEALTH)" = /index.html ] && [ "$(last "$out")" = "https://quoted--shop.dev.example.com" ]'
pv stop quoted >/dev/null

addwt pn
rm -f "$SP/wt-pn/.opsx/preview.yaml"
printf '{"scripts":{"dev":"next dev"}}\n' > "$SP/wt-pn/package.json"
printf 'lockfileVersion: 9\n' > "$SP/wt-pn/pnpm-lock.yaml"
out=$(pv up pn); rc=$?
PNP=$(rec pn PORT)
ok "pnpm detected and named"                   '[ $rc -eq 0 ] && grep -q "^detected: pnpm" <<<"$out"'
ok "pnpm started with run dev --port <port>"   'grep -qx "pnpm run dev --port $PNP" "$SP/pm.log"'
ok "pnpm install ran"                          '[ "$(wc -l < "$SP/pnpm-install.count")" -eq 1 ]'
pv stop pn >/dev/null

addwt np
rm -f "$SP/wt-np/.opsx/preview.yaml"
printf '{"scripts":{"dev":"vite"}}\n' > "$SP/wt-np/package.json"
out=$(pv up np); rc=$?
NPP=$(rec np PORT)
ok "npm detected (no lockfile)"                '[ $rc -eq 0 ] && grep -q "^detected: npm" <<<"$out"'
ok "npm started with run dev -- --port"        'grep -qx "npm run dev -- --port $NPP" "$SP/pm.log"'
pv stop np >/dev/null

addwt none
rm -f "$SP/wt-none/.opsx/preview.yaml"
printf '{"scripts":{"build":"x"}}\n' > "$SP/wt-none/package.json"
out=$(pv up none); rc=$?
ok "nothing to detect -> asks for .opsx/preview.yaml" '[ $rc -ne 0 ] && [[ "$out" == *".opsx/preview.yaml"* ]] && [ "$(nwin none)" -eq 0 ]'
echo 3 > "$SP/rc"
out=$(pv up none); rc=$?
ok "no expose + nothing to detect -> both messages" '[ $rc -ne 0 ] && [[ "$out" == *"install.sh --expose-domain"* ]] && [[ "$out" == *".opsx/preview.yaml"* ]]'
rm -f "$SP/rc"

# ================================================================ 3.1 install once
addwt inst
printf 'cmd: python3 -m http.server $PORT --bind 127.0.0.1\ninstall: echo x >> %s/inst.count\n' "$SP" > "$SP/wt-inst/.opsx/preview.yaml"
echo "a==1" > "$SP/wt-inst/requirements.txt"
pv up inst >/dev/null; pv stop inst >/dev/null; pv up inst >/dev/null
ok "install runs once across start/stop/start" '[ "$(wc -l < "$SP/inst.count")" -eq 1 ]'
pv stop inst >/dev/null
echo "a==2" > "$SP/wt-inst/requirements.txt"
out=$(pv up inst)
ok "lockfile change -> install runs again"     '[ "$(wc -l < "$SP/inst.count")" -eq 2 ] && [[ "$out" == *"install: echo"* ]]'
pv stop inst >/dev/null
printf 'cmd: python3 -m http.server $PORT --bind 127.0.0.1\ninstall: echo install-broke; exit 7\n' > "$SP/wt-inst/.opsx/preview.yaml"
out=$(pv up inst); rc=$?
ok "failed install -> its exit code + tail, nothing started" '[ $rc -eq 7 ] && [[ "$out" == *"install-broke"* ]] && [ "$(nwin inst)" -eq 0 ] && [ ! -e "$PS_DIR/shop/inst.env" ]'
out=$(pv up inst); rc=$?
ok "failed install is not remembered"          '[ $rc -eq 7 ]'

# ================================================================ 5.1 README example
sed -n '/^<!-- preview-example -->/,/^```$/p' "$REPO/README.md" | sed '1,2d;$d' > "$SP/readme-example.yaml"
addwt readme
cp "$SP/readme-example.yaml" "$SP/wt-readme/.opsx/preview.yaml"
printf '{"scripts":{"dev":"next dev"}}\n' > "$SP/wt-readme/package.json"
out=$(pv up readme); rc=$?
ok "README example recipe is non-empty"        'grep -q "^cmd:" "$SP/readme-example.yaml"'
ok "README example recipe runs with up"        '[ $rc -eq 0 ] && [ "$(last "$out")" = "https://readme--shop.dev.example.com" ]'
pv stop readme >/dev/null

# ================================================================ QA round: races, teardown, state
# F1: two `up` at once -> one app, one window, one route, same URL.
addwt race
printf 'cmd: python3 -m http.server $PORT --bind 127.0.0.1\n' > "$SP/wt-race/.opsx/preview.yaml"
: > "$EXPOSE_LOG"
pv up race > "$SP/race1.out" & r1=$!
pv up race > "$SP/race2.out" & r2=$!
wait "$r1"; rc1=$?; wait "$r2"; rc2=$?
RP=$(rec race PORT)
ok "concurrent up: both exit 0, same URL"      '[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ "$(last "$(cat "$SP/race1.out")")" = "https://race--shop.dev.example.com" ] && [ "$(last "$(cat "$SP/race2.out")")" = "https://race--shop.dev.example.com" ]'
ok "concurrent up: one window, one app, one up" '[ "$(nwin race)" -eq 1 ] && [ "$(napps race)" -eq 1 ] && [ "$(grep -c "^up .*--name race" "$EXPOSE_LOG")" -eq 1 ]'
ok "concurrent up: second one reused the first" 'cat "$SP/race1.out" "$SP/race2.out" | grep -q "already running"'
out=$(pv stop race); rc=$?
sleep 0.3
ok "concurrent up: stop leaves nothing behind" '[ $rc -eq 0 ] && [ "$(nwin race)" -eq 0 ] && [ "$(napps race)" -eq 0 ] && ! port_open "$RP"'

# F1b: a second up (and a stop) during the first one's health wait waits
# for it instead of tearing it down.
printf 'cmd: sleep 2; exec python3 -m http.server $PORT --bind 127.0.0.1\ntimeout: 20\n' > "$SP/wt-race/.opsx/preview.yaml"
pv up race > "$SP/race1.out" & r1=$!
sleep 0.8
out=$(pv up race); rc=$?
wait "$r1"; rc1=$?
ok "up during startup waits, then reuses"      '[ $rc1 -eq 0 ] && [ $rc -eq 0 ] && [[ "$out" == *"waiting for another"* ]] && [[ "$out" == *"already running"* ]] && [ "$(nwin race)" -eq 1 ] && [ "$(napps race)" -eq 1 ]'
pv stop race >/dev/null
pv up race > "$SP/race1.out" & r1=$!
sleep 0.8
out=$(pv stop race); rc=$?
wait "$r1"
sleep 0.3
ok "stop during startup waits, then stops it"  '[ $rc -eq 0 ] && [[ "$out" == *"stopped preview race"* ]] && [ "$(nwin race)" -eq 0 ] && [ "$(napps race)" -eq 0 ] && [ ! -e "$PS_DIR/shop/race.env" ]'
# Same without flock (the mkdir lock used where flock is missing).
printf 'cmd: python3 -m http.server $PORT --bind 127.0.0.1\n' > "$SP/wt-race/.opsx/preview.yaml"
: > "$EXPOSE_LOG"
OPSX_PREVIEW_NO_FLOCK=1 pv up race > "$SP/race1.out" & r1=$!
OPSX_PREVIEW_NO_FLOCK=1 pv up race > "$SP/race2.out" & r2=$!
wait "$r1"; rc1=$?; wait "$r2"; rc2=$?
ok "concurrent up without flock: one app"      '[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ "$(nwin race)" -eq 1 ] && [ "$(napps race)" -eq 1 ] && [ "$(grep -c "^up .*--name race" "$EXPOSE_LOG")" -eq 1 ] && [ ! -e "$PS_DIR/shop/race.lockd" ]'
OPSX_PREVIEW_NO_FLOCK=1 pv stop race >/dev/null
ok "stop without flock releases the lock"      '[ "$(nwin race)" -eq 0 ] && [ ! -e "$PS_DIR/shop/race.lockd" ]'

# F3: tmux unreachable -> stop warns and fails; a later stop (no record)
# still closes the leftover window.
pv up race >/dev/null
RP=$(rec race PORT)
# A socket we may not connect to: tmux reports "Permission denied".
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$SP/dead.sock"
chmod 000 "$SP/dead.sock"
out=$(cd "$R" && TMUX="$SP/dead.sock,1,0" "$P" stop race 2>&1); rc=$?
sleep 0.3
ok "stop, tmux unreachable -> warning, exit 1" '[ $rc -eq 1 ] && [[ "$out" == *"could not close the preview window for race"* ]] && [[ "$out" == *"its window is still open"* ]] && ! port_open "$RP" && [ "$(nwin race)" -eq 1 ]'
out=$(pv stop race); rc=$?
ok "stop without record closes leftover window" '[ $rc -eq 0 ] && [[ "$out" == *"stopped leftovers of preview race"* ]] && [ "$(nwin race)" -eq 0 ]'
out=$(pv stop race); rc=$?
ok "stop with nothing left -> no preview running" '[ $rc -eq 0 ] && [[ "$out" == "no preview running for race" ]]'

# F4: close / close --all from outside the project still stops the preview.
mkdir -p "$SP/outside"
pv up race >/dev/null
(cd "$R" && "$W" ensure race --prompt-file "$SP/prompt.txt" --agent-cli fakecli --model default) >/dev/null 2>&1
out=$(cd "$SP/outside" && "$W" close --all --force 2>&1); rc=$?
ok "close --all outside the repo stops previews" '[ $rc -eq 0 ] && [ "$(nwin race)" -eq 0 ] && [ ! -e "$PS_DIR/shop/race.env" ] && [ ! -e "$SP/routes/race--shop" ]'
$L new-window -d -t pt: 'exec sleep 3000'
pv up race >/dev/null
(cd "$R" && "$W" ensure race --prompt-file "$SP/prompt.txt" --agent-cli fakecli --model default) >/dev/null 2>&1
out=$(cd "$SP/outside" && "$W" close race --force 2>&1); rc=$?
ok "close <c> outside the repo stops its preview" '[ $rc -eq 0 ] && [ "$(nwin race)" -eq 0 ] && [ ! -e "$PS_DIR/shop/race.env" ]'
pv up race >/dev/null
out=$(cd "$SP/outside" && "$W" close --all --force 2>&1)
ok "close --all, no project found -> says so"  '[[ "$out" == *"previews were NOT stopped"* ]] && [ "$(nwin race)" -eq 1 ]'
pv stop race >/dev/null
$L new-window -d -t pt: 'exec sleep 3000'

# F5: prune forgets state of changes whose worktree is gone.
printf 'cmd: python3 -m http.server $PORT --bind 127.0.0.1\ninstall: true\n' > "$SP/wt-race/.opsx/preview.yaml"
pv up race >/dev/null; pv stop race >/dev/null
IH_RACE=$PS_DIR/shop/$(printf '%s' "$SP/wt-race" | sha256sum | cut -d' ' -f1).install
ok "install hash names its checkout"           '[ "$(sed -n 2p "$IH_RACE")" = "$SP/wt-race" ]'
out=$(pv prune); rc=$?
ok "prune keeps a change that has a worktree"  '[ $rc -eq 0 ] && [ -e "$PS_DIR/shop/race.log" ] && [ -e "$IH_RACE" ]'
git -C "$R" worktree remove --force "$SP/wt-race"
out=$(pv prune); rc=$?
ok "prune drops files of a removed worktree"   '[ $rc -eq 0 ] && [ -z "$(ls "$PS_DIR/shop/" | grep "^race\.")" ] && [ ! -e "$IH_RACE" ] && [[ "$out" == *"pruned state of race"* ]]'
ok "prune keeps other previews' state"         '[ -e "$PS_DIR/shop/main.port" ] && [ -e "$PS_DIR/shop/add-auth.log" ]'

# ================================================================ share + bind refusal (real expose.sh, fake admin)
# The real expose.sh against tests/fake-caddy-admin.py on a private socket.
mkdir -p "$XDG_CONFIG_HOME/tmux-opsx"; chmod 700 "$XDG_CONFIG_HOME/tmux-opsx"
printf 'EXPOSE_DOMAIN=dev.example.com\n' > "$XDG_CONFIG_HOME/tmux-opsx/expose.env"
ASOCK=$SP/admin.sock
python3 "$REPO/tests/fake-caddy-admin.py" "$ASOCK" & ADMIN_PID=$!
for _ in $(seq 1 50); do [ -S "$ASOCK" ] && break; sleep 0.1; done
REAL_E=$REPO/skills/expose/expose.sh
rpv() { ( cd "$R" && OPSX_EXPOSE_SH=$REAL_E OPSX_EXPOSE_ADMIN=$ASOCK "$P" "$@" ) 2>&1; }
rex() { OPSX_EXPOSE_ADMIN=$ASOCK "$REAL_E" "$@" 2>/dev/null; }
addwt shareme
out=$(rpv up shareme); rc=$?
ok "real expose: preview up"                    '[ $rc -eq 0 ] && [ "$(last "$out")" = "https://shareme--shop.dev.example.com" ]'
out=$(rpv share shareme --for Acme); rc=$?
ok "share: exit 0, last line is the share link" '[ $rc -eq 0 ] && [[ "$(last "$out")" =~ ^https://shareme--shop\.dev\.example\.com/\?opsx_share=[A-Za-z0-9_-]{22,}$ ]]'
out=$(rpv share shareme --list); rc=$?
ok "share --list passes through"                '[ $rc -eq 0 ] && printf "%s\n" "$out" | grep -Eq "^acme +[0-9a-f]{6} "'
out=$(rpv share shareme --ttl 3weeks); rc=$?
ok "share relays expose exit code (bad ttl -> 2)" '[ $rc -eq 2 ] && [[ "$out" == *3weeks* ]]'
out=$(rpv share shareme --revoke acme); rc=$?
ok "share --revoke passes through"              '[ $rc -eq 0 ] && [[ "$out" == *"revoked"* ]] && ! grep -q "^SHARE=" "$XDG_STATE_HOME/tmux-opsx/expose/routes/shareme--shop.env"'
out=$(rpv share nosuch --for acme); rc=$?
ok "share with no preview: non-zero, says no preview running, no token" '[ $rc -ne 0 ] && [[ "$out" == *"no preview running"* ]] && ! grep -rqs "^SHARE=" "$XDG_STATE_HOME/tmux-opsx/expose/routes/"'
out=$(rpv share shareme --name x); rc=$?
ok "share: unknown option -> exit 2"            '[ $rc -eq 2 ]'
rpv stop shareme >/dev/null
if [ "$(uname -s)" = Linux ] && command -v ss >/dev/null 2>&1; then
  addwt wild
  mkdir -p "$SP/wt-wild/.opsx"
  printf 'cmd: python3 -m http.server $PORT --bind 0.0.0.0\ntimeout: 20\n' > "$SP/wt-wild/.opsx/preview.yaml"
  out=$(rpv up wild); rc=$?
  ok "0.0.0.0 recipe: non-zero, 127.0.0.1 and 0.0.0.0 in the output" '[ $rc -ne 0 ] && [[ "$out" == *"127.0.0.1"* ]] && [[ "$out" == *"0.0.0.0"* ]]'
  ok "0.0.0.0 recipe: no window, no record, no exposure" '[ "$(nwin wild)" -eq 0 ] && [ ! -e "$PS_DIR/shop/wild.env" ] && ! rex list | grep -q "^wild "'
  WP=$(cat "$PS_DIR/shop/wild.port" 2>/dev/null)
  ok "0.0.0.0 recipe: app stopped"              '[ -n "$WP" ] && ! port_open "$WP"'
else
  echo "note: not Linux or no ss; bind refusal untested here"
fi
kill "$ADMIN_PID" 2>/dev/null; wait "$ADMIN_PID" 2>/dev/null
rm -f "$XDG_CONFIG_HOME/tmux-opsx/expose.env"

# ================================================================ 4.1 close / close-all / land
out=$(pv up add-auth)
(cd "$R" && "$W" ensure add-auth --prompt-file "$SP/prompt.txt" --agent-cli fakecli --model default) >/dev/null 2>&1
out=$(cd "$R" && "$W" close add-auth 2>&1); rc=$?
ok "close <change> stops its preview"          '[ $rc -eq 0 ] && [ "$(nwin add-auth)" -eq 0 ] && [ ! -e "$PS_DIR/shop/add-auth.env" ] && [ ! -e "$SP/routes/add-auth--shop" ]'
# A close that refuses to close the caller's own window leaves the preview up.
pv up add-auth >/dev/null
(cd "$R" && "$W" ensure add-auth --prompt-file "$SP/prompt.txt" --agent-cli fakecli --model default) >/dev/null 2>&1
AP=$($L list-windows -a -F '#{pane_id} #{@opsx_change}' | awk '$2=="add-auth"{print $1; exit}')
out=$(cd "$R" && TMUX_PANE=$AP "$W" close add-auth 2>&1); rc=$?
ok "refused self-close keeps the preview"      '[ -n "$AP" ] && [ $rc -eq 0 ] && [[ "$out" == *"skipped"* ]] && [ "$(nwin add-auth)" -eq 1 ] && [ -e "$PS_DIR/shop/add-auth.env" ]'
(cd "$R" && "$W" close add-auth) >/dev/null 2>&1
pv up add-auth >/dev/null; pv up --main >/dev/null
(cd "$R" && "$W" ensure add-auth --prompt-file "$SP/prompt.txt" --agent-cli fakecli --model default) >/dev/null 2>&1
out=$(cd "$R" && "$W" close --all --force 2>&1); rc=$?
ok "close --all stops every preview"           '[ $rc -eq 0 ] && [ "$(nwin add-auth)" -eq 0 ] && [ "$(nwin main)" -eq 0 ] && [ -z "$(ls "$PS_DIR/shop/"*.env 2>/dev/null)" ]'
$L new-window -d -t pt: 'exec sleep 3000'   # keep the private session alive
pv stop --all >/dev/null
out=$(pv stop --all); rc=$?
ok "stop --all with nothing -> exit 0"         '[ $rc -eq 0 ]'

# land with a running preview: commit the change, start the preview, land.
echo feature > "$SP/wt-add-auth/feature.txt"
git -C "$SP/wt-add-auth" add -A; git -C "$SP/wt-add-auth" commit -qm feature
pv up add-auth >/dev/null
LP=$(rec add-auth PORT)
: > "$EXPOSE_LOG"
out=$(cd "$R" && "$LAND" add-auth 2>&1); rc=$?
ok "land with preview succeeds"                '[ $rc -eq 0 ] && [[ "$out" == *"Landed add-auth"* ]]'
ok "land: no preview window, down recorded"    '[ "$(nwin add-auth)" -eq 0 ] && grep -qx "down add-auth --project shop" "$EXPOSE_LOG" && ! port_open "$LP"'
ok "land: worktree removed"                    '[ ! -d "$SP/wt-add-auth" ]'
ok "land: preview state pruned (QA F5)"        '[ -z "$(ls "$PS_DIR/shop/" | grep "^add-auth\.")" ]'

# land --dry-run prints the stop call
R2=$SP/dry; mkdir -p "$R2"; git -C "$R2" init -q -b main
mkdir -p "$R2/openspec/changes/c2"; printf -- '- [x] d\n' > "$R2/openspec/changes/c2/tasks.md"
git -C "$R2" add -A; git -C "$R2" commit -qm init; git -C "$R2" checkout -q -b opsx/c2
echo y > "$R2/y"; git -C "$R2" add -A; git -C "$R2" commit -qm y; git -C "$R2" checkout -q main
out=$(cd "$R2" && "$LAND" c2 --dry-run 2>&1); rc=$?
ok "land --dry-run prints the preview stop"    '[ $rc -eq 0 ] && grep -q "would run: .*opsx-preview.sh stop c2" <<<"$out"'
# land without a preview behaves as before (no preview output, success)
out=$(cd "$R2" && "$LAND" c2 --no-close 2>&1); rc=$?
ok "land without preview: unchanged result"    '[ $rc -eq 0 ] && [[ "$out" == *"Landed c2"* ]] && ! grep -qi "preview" <<<"$out"'

# ================================================================ 4.2 skill text
SK=$REPO/skills/opsx-run/SKILL.md
ok "skill: preview usage lines"                'grep -q "^/opsx-run <change> preview " "$SK" && grep -q "^/opsx-run <change> preview stop" "$SK" && grep -q "^/opsx-run <change> preview url" "$SK"'
ok "skill: preview reserved + main checkout"   'grep -q "\*\*\`preview\`\*\* as the first token" "$SK" && grep -q "main checkout" "$SK"'
ok "skill: Actions row runs it inline"         'grep -q "^| \`preview\` / \`preview stop\` / \`preview url\` / \`preview share\` | Runs \`opsx-preview.sh up" "$SK"'
ok "skill: qa + validate prompts start preview, then share" '[ "$(grep -c "opsx-preview.sh up <change>\` from \`<cwd>\`, then on exit 0 \`<skills>/opsx-run/opsx-preview.sh share <change> --for ops-qa --ttl 1d\`. On exit 0 of both pass the share command.s last stdout line (a share link) to ops-qa as \`PREVIEW_URL\`" "$SK")" -eq 2 ]'
ok "skill: preview share documented"           'grep -q "^/opsx-run <change> preview share" "$SK" && grep -q "^opsx-preview.sh share" "$SK"'
ok "ops-qa: opens PREVIEW_URL first, keeps the browser context" 'grep -q "open it \*\*first\*\*" "$REPO/agents/opsx-qa.md" && grep -q "keep the same browser context" "$REPO/agents/opsx-qa.md"'
ok "skill: close / close-all stop previews"    'grep -q "^/opsx-run <change> close .*stop its preview" "$SK" && grep -q "close --all\` also stops every preview" "$SK"'

# ================================================================ 4.3 ops-qa + install
QA=$REPO/agents/opsx-qa.md
ok "ops-qa: PREVIEW_URL input + no server"     'grep -q "^- \`PREVIEW_URL\`" "$QA" && grep -q "If \`PREVIEW_URL\` is given, test that URL and do not start a server" "$QA"'
IH=$SP/ihome; mkdir -p "$IH" "$SP/ibin"
for b in claude node npm; do printf '#!/bin/sh\necho 1.0.0\n' > "$SP/ibin/$b"; chmod +x "$SP/ibin/$b"; done
out=$(cd "$REPO" && env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_HOME -u OPENCODE_CONFIG_DIR -u TMUX -u TMUX_PANE \
        -u SUDO_USER -u REAL_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
        HOME="$IH" PATH="$SP/ibin:/usr/bin:/bin" bash ./install.sh --skip-openspec --skip-graphify \
        --skip-commands --skip-mcp --skip-memory --skip-fork --no-backup 2>&1); rc=$?
ok "install.sh (scratch HOME) succeeds"        '[ $rc -eq 0 ]'
ok "install.sh ships opsx-preview.sh"          'for d in .claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills; do [ -x "$IH/$d/opsx-run/opsx-preview.sh" ] || exit 1; done'
ok "ops-qa converted for all five CLIs"        'for f in .claude/agents/opsx-qa.md .cursor/agents/opsx-qa.md .codex/agents/ops-qa.toml .config/opencode/agents/ops-qa.md .gemini/agents/opsx-qa.md; do grep -q "PREVIEW_URL" "$IH/$f" && grep -q "keep the same browser context" "$IH/$f" || exit 1; done'
ok "installed opsx-run skill: QA prompts share the preview" 'for d in .claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills; do [ "$(grep -c "opsx-preview.sh share <change> --for ops-qa --ttl 1d" "$IH/$d/opsx-run/SKILL.md")" -eq 2 ] || exit 1; done'

ok "shellcheck (if installed)"                 '! command -v shellcheck >/dev/null || shellcheck "$P" "$W" "$LAND" "$0"'

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
