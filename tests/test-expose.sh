#!/usr/bin/env bash
# Scripted tests for skills/expose/expose.sh.
#
# Runs entirely offline in a scratch HOME: the Caddy admin API is the fake
# server in tests/fake-caddy-admin.py on a private unix socket, and clipboard
# copies go to a private tmux server (tmux -L expose-test-$$). Nothing touches
# your real config, proxy, tmux session or clipboard.
# Usage: bash tests/test-expose.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016
set -u
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required"; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "tmux is required"; exit 1; }
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
REAL_HOME=$HOME
E=$REPO/skills/expose/expose.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/expose-test.XXXXXX")
L="tmux -L expose-test-$$"
FAKE_PID=""; HTTP_PID=""; CADDY_PID=""; APP_PIDS=()
cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  [ -n "${CADDY_PID:-}" ] && kill "$CADDY_PID" 2>/dev/null
  [ "${#APP_PIDS[@]}" -gt 0 ] && kill "${APP_PIDS[@]}" 2>/dev/null
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
  $L kill-server 2>/dev/null
  rm -rf "$SP"
}
trap cleanup EXIT

export HOME=$SP/home XDG_CONFIG_HOME=$SP/home/.config XDG_STATE_HOME=$SP/home/.local/state
mkdir -p "$HOME"
SOCK=$SP/admin.sock
export OPSX_EXPOSE_ADMIN=$SOCK
# Never copy unless a test asks for it (and then only to the private tmux
# below); never write the real /etc/systemd/system.
export OPSX_EXPOSE_NO_COPY=1
export OPSX_SYSTEMD_DIR=$SP/systemd-scratch
mkdir -p "$OPSX_SYSTEMD_DIR"

# Private tmux server; $TMUX points at it so expose.sh never finds your real one.
$L -f /dev/null new-session -d -s et -x 120 -y 30 'exec sleep 3000'
TMUX="$($L display -p '#{socket_path}'),$($L display -p '#{pid}'),0"
export TMUX
unset TMUX_PANE

pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

start_fake() {
  python3 "$REPO/tests/fake-caddy-admin.py" "$SOCK" & FAKE_PID=$!
  for _ in $(seq 1 50); do [ -S "$SOCK" ] && return 0; sleep 0.1; done
  echo "fake admin server did not start"; exit 1
}
stop_fake() { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=""; rm -f "$SOCK"; }
adm() { curl -sS --unix-socket "$SOCK" "http://127.0.0.1$1"; }
routes() { adm /config/apps/http/servers/expose/routes; }
nroutes() { routes | python3 -c 'import json,sys; v=json.load(sys.stdin); print(len(v or []))'; }
# The upstream dial anywhere in the route (flat for --public, else inside the subroute).
dial_of() { adm "/id/expose-$1" | python3 -c '
import json,sys
def walk(n):
    if isinstance(n,dict):
        if n.get("handler")=="reverse_proxy": print(n["upstreams"][0]["dial"]); sys.exit(0)
        for v in n.values(): walk(v)
    elif isinstance(n,list):
        for v in n: walk(v)
walk(json.load(sys.stdin))' 2>/dev/null; }
group_of() { adm "/id/expose-$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("group",""))' 2>/dev/null; }
host_of() { adm "/id/expose-$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["match"][0]["host"][0])' 2>/dev/null; }
RD=$XDG_STATE_HOME/tmux-opsx/expose/routes

# ---- 1.1 help / usage ----
h=$($E help); rc=$?
ok "help exits 0" '[ $rc -eq 0 ]'
ok "help lists subcommands and options" 'for w in up down list url share "key rotate" help --name --project --json --public --with-key --for --ttl --list --revoke; do [[ "$h" == *"$w"* ]] || exit 1; done'
$E bogus >/dev/null 2>&1; rc=$?
ok "unknown subcommand exits 2" '[ $rc -eq 2 ]'
SKILL=$REPO/skills/expose/SKILL.md
ok "skill documents every subcommand and option" 'for w in "up " "down " "list" "url " "share " "key rotate" --name --project --public --with-key --for --ttl --list --revoke; do grep -qF -- "$w" "$SKILL" || exit 1; done'
ok "skill: no login/share link unless asked; loopback refusal" 'grep -q "Never print the owner login link" "$SKILL" && grep -q "refusing to publish port" "$SKILL"'

# ---- 1.2 not configured ----
o=$($E up 3000 2>&1); rc=$?
ok "no config: up exits 3 naming install.sh --expose-domain" '[ $rc -eq 3 ] && [[ "$o" == *"install.sh --expose-domain"* ]]'
for c in "down 3000" "list" "url web"; do
  # shellcheck disable=SC2086
  $E $c >/dev/null 2>&1; rc=$?
  ok "no config: $c exits 3" '[ $rc -eq 3 ]'
done

mkdir -p "$XDG_CONFIG_HOME/tmux-opsx"; chmod 700 "$XDG_CONFIG_HOME/tmux-opsx"
printf 'EXPOSE_DOMAIN=dev.example.com\nCLOUDFLARE_API_TOKEN=fake-token\n' > "$XDG_CONFIG_HOME/tmux-opsx/expose.env"
chmod 600 "$XDG_CONFIG_HOME/tmux-opsx/expose.env"

# ---- proxy down ----
o=$($E up 3000 --name web --project shop 2>&1); rc=$?
ok "proxy down: exit 4 + message" '[ $rc -eq 4 ] && [[ "$o" == *"not running"* ]]'
ok "proxy down: no state record" '[ -z "$(ls -A "$RD" 2>/dev/null)" ]'

start_fake

# ---- 1.3 validation + labels ----
for p in 70000 abc 443 0 -1 03000; do
  o=$($E up -- "$p" 2>&1); rc=$?
  ok "invalid port $p refused (exit 2, named)" '[ $rc -eq 2 ] && [[ "$o" == *"$p"* ]]'
done
ok "invalid ports: no route, no state" '[ "$(nroutes)" -eq 0 ] && [ -z "$(ls -A "$RD" 2>/dev/null)" ]'
o=$($E list); rc=$?
ok "empty list says (nothing exposed)" '[ $rc -eq 0 ] && [ "$o" = "(nothing exposed)" ]'
# F1: messages printed after the lock is taken still reach stderr
command -v flock >/dev/null 2>&1 || echo "note: flock not on PATH; lock path untested"
e=$($E url nosuch --project shop 2>&1 >/dev/null); rc=$?
ok "url nosuch: exit 1 with a message on stderr" '[ $rc -eq 1 ] && [[ "$e" == *"no exposure named"* ]]'
e=$($E up 3000 --name "***" --project shop 2>&1 >/dev/null); rc=$?
ok "unusable name: exit 2 with a message on stderr" '[ $rc -eq 2 ] && [[ "$e" == *"no usable characters"* ]]'

o=$(OPSX_EXPOSE_NO_COPY='' $E up 3000 --name web --project shop 2>"$SP/up.err"); rc=$?
ok "publish: exit 0, last line is URL" '[ $rc -eq 0 ] && [ "$(printf "%s\n" "$o" | tail -n1)" = "https://web--shop.dev.example.com" ]'
ok "publish: route host + dial" '[ "$(host_of web--shop)" = "web--shop.dev.example.com" ] && [ "$(dial_of web--shop)" = "127.0.0.1:3000" ]'
ok "publish: no public warning without --public" '! printf "%s\n" "$o" | grep -qi "public with no authentication"'
ok "publish: state record" 'grep -qx "PORT=3000" "$RD/web--shop.env" && grep -qx "URL=https://web--shop.dev.example.com" "$RD/web--shop.env"'
ok "copied through tmux" '[ "$($L show-buffer)" = "https://web--shop.dev.example.com" ]'
ok "publish: stderr says copied to the tmux buffer, clipboard only via set-clipboard" 'grep -q "copied to the tmux buffer (forwarded to the clipboard via OSC 52 when tmux set-clipboard is on)" "$SP/up.err" && ! grep -q "copied to the clipboard via tmux" "$SP/up.err"'
if (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null; then
  ok "publish: no idle-port note when 3000 listens" '! grep -q "nothing is listening" "$SP/up.err"'
else
  ok "publish: stderr notes nothing listens on the port" 'grep -q "nothing is listening on 127.0.0.1:3000" "$SP/up.err"'
fi
# F3: opt-outs
$L set-buffer -- placeholder
e=$($E url web --project shop 2>&1 >/dev/null)
ok "OPSX_EXPOSE_NO_COPY=1: no copy, says so" '[ "$($L show-buffer)" = placeholder ] && [[ "$e" == *"not copied"* ]]'
e=$(TMUX='' OPSX_EXPOSE_NO_COPY='' setsid -w "$E" url web --project shop 2>&1 >/dev/null </dev/null)
ok "TMUX= (empty): no parent tmux search, says not copied" '[ "$($L show-buffer)" = placeholder ] && [[ "$e" == *"not copied to the clipboard: no tmux or terminal"* ]]'
ok "redirected output has no ESC bytes" '! printf "%s" "$o" | grep -q $'"'"'\033'"'"''

o=$($E up 8080 --name "My_App" --project "Foo.Bar" | tail -n1)
ok "normalised label my-app--foo-bar" '[ "$o" = "https://my-app--foo-bar.dev.example.com" ]'

# default project: main checkout folder name, also from a worktree
G=$SP/provision-admin
git init -q "$G" && git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$G" worktree add -q "$SP/wt-add-auth" -b opsx/add-auth 2>/dev/null
o=$(cd "$SP/wt-add-auth" && $E up 3000 | tail -n1)
ok "default name+project from worktree" '[ "$o" = "https://3000--provision-admin.dev.example.com" ]'
o=$(cd "$G" && $E url 3000 | tail -n1)
ok "same project from main checkout" '[ "$o" = "https://3000--provision-admin.dev.example.com" ]'
mkdir -p "$SP/Plain Dir"
o=$(cd "$SP/Plain Dir" && $E up 4000 | tail -n1)
ok "outside git: \$PWD name" '[ "$o" = "https://4000--plain-dir.dev.example.com" ]'

N70=$(printf 'a%.0s' $(seq 1 60))bbbbbbbbbb
N70B=$(printf 'a%.0s' $(seq 1 60))cccccccccc
o1=$($E up 3001 --name "$N70" --project shop | tail -n1)
o1b=$($E up 3001 --name "$N70" --project shop | tail -n1)
o2=$($E up 3002 --name "$N70B" --project shop | tail -n1)
lab1=${o1#https://}; lab1=${lab1%.dev.example.com}
lab2=${o2#https://}; lab2=${lab2%.dev.example.com}
ok "long label <= 63 and ends --project" '[ "${#lab1}" -le 63 ] && [[ "$lab1" == *"--shop" ]] && [[ "$lab1" =~ -[0-9a-f]{6}--shop$ ]]'
ok "long label deterministic" '[ "$o1" = "$o1b" ]'
ok "distinct long names stay distinct" '[ "$o1" != "$o2" ] && [ "${#lab2}" -le 63 ]'
ok "single -- separator in long label" '[ "$(grep -o -- "--" <<<"$lab1" | wc -l)" -eq 1 ]'
LP=$(printf 'p%.0s' $(seq 1 70))
o=$($E up 3003 --name web --project "$LP" | tail -n1); lab=${o#https://}; lab=${lab%.dev.example.com}
ok "very long project still <= 63" '[ "${#lab}" -le 63 ] && [[ "$lab" == web--* ]]'
# F2: a project over 40 chars is kept whole when the label fits
P42=$(printf 'p%.0s' $(seq 1 42))
o=$($E up 3004 --project "$P42" | tail -n1)
ok "42-char project kept whole when label fits" '[ "$o" = "https://3004--$P42.dev.example.com" ]'
P50=$(printf 'q%.0s' $(seq 1 50))
o=$($E up 3005 --name "longishname-0123456789" --project "$P50" | tail -n1); lab=${o#https://}; lab=${lab%.dev.example.com}
ok "50-char project kept, name cut instead" '[ "${#lab}" -le 63 ] && [[ "$lab" == *"--$P50" ]] && [[ "$lab" =~ ^[a-z0-9-]*[0-9a-f]{6}--q ]]'
$E down 3004 --project "$P42" >/dev/null; $E down 3005 --project "$P50" >/dev/null

# ---- 2.2 republish / down ----
$E up 3000 --name api --project shop >/dev/null
$E up 3001 --name api --project shop >/dev/null
ok "name moved: one route on new port" '[ "$(routes | grep -o "\"expose-api--shop\"" | wc -l)" -eq 1 ] && [ "$(dial_of api--shop)" = "127.0.0.1:3001" ]'
$E up 3001 --name api --project shop >/dev/null
ok "same port again: still one route" '[ "$(routes | grep -o "\"expose-api--shop\"" | wc -l)" -eq 1 ]'
l=$($E list)
ok "list shows one api entry on 3001" '[ "$(printf "%s\n" "$l" | grep -c "^api ")" -eq 1 ] && printf "%s\n" "$l" | grep -Eq "^api +shop +3001 "'

o=$($E down api --project shop); rc=$?
ok "down by name" '[ $rc -eq 0 ] && [ -z "$(dial_of api--shop)" ] && [ ! -f "$RD/api--shop.env" ] && ! $E list | grep -q "^api "'
$E up 5000 --name one --project shop >/dev/null; $E up 5000 --name two --project shop >/dev/null
o=$($E down 5000 --project shop); rc=$?
ok "down by port removes every match" '[ $rc -eq 0 ] && [ -z "$(dial_of one--shop)" ] && [ -z "$(dial_of two--shop)" ] && [ "$(printf "%s\n" "$o" | grep -c removed)" -eq 2 ]'
o=$($E down nosuch --project shop); rc=$?
ok "down of nothing: exit 0, says so" '[ $rc -eq 0 ] && [[ "$o" == *"nothing matched"* ]]'
# QA F3: down in the wrong project hints at the project that has it
$E up 8080 --name hinted --project shop-app >/dev/null
o=$($E down 8080 --project other-proj); rc=$?
ok "down by port in wrong project: exit 0, hints other project" '[ $rc -eq 0 ] && [[ "$o" == *"nothing matched 8080 in project other-proj"* ]] && [[ "$o" == *"(exposed in project shop-app; use --project shop-app)"* ]] && [ "$(dial_of hinted--shop-app)" = "127.0.0.1:8080" ]'
o=$($E down hinted --project other-proj); rc=$?
ok "down by name in wrong project: hints other project" '[ $rc -eq 0 ] && [[ "$o" == *"use --project shop-app"* ]]'
o=$($E down 8999 --project other-proj); rc=$?
ok "down of nothing anywhere: no project hint" '[ $rc -eq 0 ] && [[ "$o" != *"exposed in project"* ]]'
$E down hinted --project shop-app >/dev/null
# QA F1: an uppercase EXPOSE_DOMAIN in a hand-edited config is lowercased
CF=$XDG_CONFIG_HOME/tmux-opsx/expose.env
cp "$CF" "$SP/expose.env.bak"
printf 'EXPOSE_DOMAIN=Dev.Example.com\nCLOUDFLARE_API_TOKEN=fake-token\n' > "$CF"
$E list >/dev/null 2>"$SP/uc.err"; rc=$?
o=$($E url web --project shop | tail -n1)
ok "uppercase EXPOSE_DOMAIN in config: list works, URL lowercased" '[ $rc -eq 0 ] && [ "$o" = "https://web--shop.dev.example.com" ]'
cp "$SP/expose.env.bak" "$CF"; chmod 600 "$CF"

# ---- url ----
o=$($E url web --project shop); rc=$?
ok "url reprints" '[ $rc -eq 0 ] && [ "$(printf "%s\n" "$o" | tail -n1)" = "https://web--shop.dev.example.com" ]'
$L set-buffer -- placeholder
OPSX_EXPOSE_NO_COPY='' $E url web --project shop >/dev/null 2>&1
ok "url copies again" '[ "$($L show-buffer)" = "https://web--shop.dev.example.com" ]'
$E url nosuch --project shop >/dev/null 2>&1; rc=$?
ok "url unknown exits non-zero" '[ $rc -ne 0 ]'

# ---- 1.4 list / UP probe ----
e=$($E up 3999 --name idle --project shop 2>&1 >/dev/null)
(exec 3<>/dev/tcp/127.0.0.1/3999) 2>/dev/null || ok "up on an idle port: stderr note, URL still last stdout line" '[[ "$e" == *"nothing is listening on 127.0.0.1:3999 yet"* ]] && [ "$($E url idle --project shop 2>/dev/null | tail -n1)" = "https://idle--shop.dev.example.com" ]'
l=$($E list); j=$($E list --json)
ok "list header" 'printf "%s\n" "$l" | head -1 | grep -Eq "^NAME +PROJECT +PORT +URL +UP +BIND +ACCESS$"'
ok "idle row UP no, BIND -, ACCESS login" 'printf "%s\n" "$l" | grep -Eq "^idle +shop +3999 +https://idle--shop.dev.example.com +no +- +login$"'
ok "json idle up false" 'printf "%s" "$j" | python3 -c "import json,sys; d=[o for o in json.load(sys.stdin) if o[\"name\"]==\"idle\"]; assert d and d[0][\"up\"] is False and d[0][\"port\"]==3999 and d[0][\"bind\"] is None and d[0][\"public\"] is False and set(d[0])=={\"name\",\"project\",\"port\",\"url\",\"up\",\"bind\",\"public\"}"'
HP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
(cd "$SP" && exec python3 -m http.server "$HP" --bind 127.0.0.1 >/dev/null 2>&1) & HTTP_PID=$!
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$HP") 2>/dev/null && break; sleep 0.1; done
$E up "$HP" --name live --project shop >/dev/null
l=$($E list); j=$($E list --json)
ok "live row UP yes, BIND loopback" 'printf "%s\n" "$l" | grep -Eq "^live +shop +$HP +.* yes +loopback +login$"'
LN=$(printf 'n%.0s' $(seq 1 40))
$E up 3998 --name "$LN" --project shop >/dev/null 2>&1
l=$($E list)
ok "list columns fit the widest value" 'printf "%s\n" "$l" | grep -Eq "^$LN  +shop  +3998  +https://$LN--shop.dev.example.com  +no +- +login$" && [ "$(printf "%s\n" "$l" | head -1 | grep -o "URL" | wc -l)" -eq 1 ]'
$E down 3998 --project shop >/dev/null
ok "json live up true" 'printf "%s" "$j" | python3 -c "import json,sys; d=[o for o in json.load(sys.stdin) if o[\"name\"]==\"live\"]; assert d and d[0][\"up\"] is True and d[0][\"bind\"]==\"loopback\""'

# ---- 2.3 reconciliation after a proxy restart ----
stop_fake; start_fake
ok "restarted proxy has no routes" '[ "$(nroutes)" -eq 0 ]'
l=$($E list 2>"$SP/restore.err")
ok "list: restore message on stderr" 'grep -q "restored https://web--shop.dev.example.com -> 127.0.0.1:3000" "$SP/restore.err"'
ok "list restores web route" '[ "$(dial_of web--shop)" = "127.0.0.1:3000" ] && printf "%s\n" "$l" | grep -q "^web "'
ok "all recorded routes restored once" '[ "$(nroutes)" -eq "$(ls "$RD"/*.env | wc -l)" ]'

# F4: parallel calls right after a restart restore each route once, no errors
par_calls() {
  local i pids=() rc=0
  for i in 1 2 3 4 5 6; do
    PATH="$1" $E list >/dev/null 2>"$SP/par.$i.err" & pids+=($!)
  done
  for i in "${pids[@]}"; do wait "$i" || rc=1; done
  return $rc
}
stop_fake; start_fake
par_calls "$PATH"; rc=$?
ok "parallel lists after restart: all exit 0" '[ $rc -eq 0 ]'
ok "parallel lists: no refused-route errors" '! cat "$SP"/par.*.err | grep -q "refused"'
ok "parallel lists: each route once" '[ "$(nroutes)" -eq "$(ls "$RD"/*.env | wc -l)" ] && [ "$(routes | grep -o "\"expose-web--shop\"" | wc -l)" -eq 1 ]'
# A racing call that adds the same route between our DELETE and POST: a curl
# shim sends every route POST twice, so the second is refused as a duplicate id.
mkdir -p "$SP/racecurl"
cat > "$SP/racecurl/curl" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *"-X POST"*/routes*) body=\$(cat); printf '%s' "\$body" | "$(command -v curl)" "\$@" >/dev/null 2>&1
                       printf '%s' "\$body" | "$(command -v curl)" "\$@"; exit ;;
esac
exec "$(command -v curl)" "\$@"
SHIM
chmod +x "$SP/racecurl/curl"
stop_fake; start_fake
o=$(PATH="$SP/racecurl:$PATH" $E up 3000 --name web --project shop 2>"$SP/race.err"); rc=$?
ok "duplicate-id refusal from a racing call: exit 0, no error" '[ $rc -eq 0 ] && ! grep -q "refused" "$SP/race.err" && [ "$(printf "%s\n" "$o" | tail -n1)" = "https://web--shop.dev.example.com" ]'
ok "duplicate-id refusal: route present once, all routes restored once" '[ "$(routes | grep -o "\"expose-web--shop\"" | wc -l)" -eq 1 ] && [ "$(nroutes)" -eq "$(ls "$RD"/*.env | wc -l)" ]'

# ---- 2.4 OSC 8 on a terminal (script(1) gives stdout a pty) ----
if command -v script >/dev/null 2>&1 && script -qc true /dev/null >/dev/null 2>&1; then
  script -qc "$E url web --project shop" "$SP/tty.out" >/dev/null 2>&1
  ok "terminal stdout gets OSC 8 link" 'grep -q $'"'"'\033\]8;;https://web--shop.dev.example.com'"'"' "$SP/tty.out"'
fi

# ---- owner key (fake admin) ----
KF=$XDG_CONFIG_HOME/tmux-opsx/expose.key
rm -f "$KF"
$E list >/dev/null 2>&1; k1=$(cat "$KF" 2>/dev/null); m1=$(stat -c %a "$KF" 2>/dev/null)
$E list >/dev/null 2>&1; k2=$(cat "$KF" 2>/dev/null); m2=$(stat -c %a "$KF" 2>/dev/null)
ok "owner key created once, mode 600, unchanged by a second list" '[ -n "$k1" ] && [ "$k1" = "$k2" ] && [ "$m1" = 600 ] && [ "$m2" = 600 ]'
ok "owner key: >=128 bits of [A-Za-z0-9_-]" '[[ "$k1" =~ ^[A-Za-z0-9_-]{22,}$ ]]'
o=$($E up 3000 --name web --project shop 2>&1; $E url web --project shop 2>&1; $E list 2>&1; $E list --json 2>&1)
ok "owner key not printed by up/url/list" '[[ "$o" != *"$k1"* ]]'
o=$($E url web --project shop --with-key 2>/dev/null); rc=$?
ok "url --with-key: last line is <url>/?opsx_key=<key>" '[ $rc -eq 0 ] && [ "$(printf "%s\n" "$o" | tail -n1)" = "https://web--shop.dev.example.com/?opsx_key=$k1" ]'
ok "plain url unchanged" '[ "$($E url web --project shop 2>/dev/null | tail -n1)" = "https://web--shop.dev.example.com" ]'
$L set-buffer -- placeholder
OPSX_EXPOSE_NO_COPY='' $E url web --project shop --with-key >/dev/null 2>&1
ok "url --with-key copies the login link" '[ "$($L show-buffer)" = "https://web--shop.dev.example.com/?opsx_key=$k1" ]'
for bad in "list --with-key" "up 3000 --with-key" "url web --public" "list --public" "url web --for x" "down web --ttl 1d" "key" "key spin" "share" "share web --list --revoke x" "share web --list --for x"; do
  # shellcheck disable=SC2086
  $E $bad --project shop >/dev/null 2>&1; rc=$?
  ok "misused options exit 2: $bad" '[ $rc -eq 2 ]'
done

# ---- route fingerprint + reconcile (fake admin) ----
fp1=$(group_of web--shop)
ok "route has a fingerprint group (full sha256)" '[[ "$fp1" =~ ^expose-fp-[0-9a-f]{64}$ ]]'
# Hand-insert a pre-auth route (no group, flat reverse_proxy) in place of web's.
adm_post() { curl -sS --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' --data-binary "$2" "http://127.0.0.1$1" >/dev/null; }
curl -sS --unix-socket "$SOCK" -X DELETE "http://127.0.0.1/id/expose-web--shop" >/dev/null
adm_post /config/apps/http/servers/expose/routes '{"@id":"expose-web--shop","match":[{"host":["web--shop.dev.example.com"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:3000"}]}],"terminal":true}'
ok "pre-auth route has no group" '[ -z "$(group_of web--shop)" ]'
$E list >/dev/null 2>"$SP/upg.err"
ok "list rebuilds the pre-auth route (fingerprint back, subroute inside)" '[ "$(group_of web--shop)" = "$fp1" ] && adm /id/expose-web--shop | grep -q "\"subroute\"" && grep -q "out of date" "$SP/upg.err"'
ok "rebuilt once: one web route" '[ "$(routes | grep -o "\"expose-web--shop\"" | wc -l)" -eq 1 ]'
$E list >/dev/null 2>"$SP/upg2.err"
ok "up-to-date routes are left alone" '! grep -q "out of date" "$SP/upg2.err"'

# ---- loopback bind check (real listeners, fake admin) ----
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
serve() { (cd "$SP" && exec python3 -m http.server "$1" --bind "$2" >/dev/null 2>&1) & BG_PID=$!; for _ in $(seq 1 50); do ss -Hltn "sport = :$1" 2>/dev/null | grep -q . && break; sleep 0.1; done; }
if [ "$(uname -s)" = Linux ] && command -v ss >/dev/null 2>&1; then
  WP=$(free_port); serve "$WP" 0.0.0.0; WPID=$BG_PID
  e=$($E up "$WP" --name wild --project shop 2>&1 >/dev/null); rc=$?
  ok "0.0.0.0 bind refused: exit 2, names 0.0.0.0 and 127.0.0.1" '[ $rc -eq 2 ] && [[ "$e" == *"0.0.0.0"* ]] && [[ "$e" == *"127.0.0.1"* ]]'
  ok "0.0.0.0 bind refused: no route, no state" '[ -z "$(dial_of wild--shop)" ] && [ ! -e "$RD/wild--shop.env" ]'
  # refused re-publish keeps the old port
  $E up 3000 --name keep --project shop >/dev/null 2>&1
  $E up "$WP" --name keep --project shop >/dev/null 2>&1; rc=$?
  ok "refused re-publish: exit 2, still routes to 3000" '[ $rc -eq 2 ] && [ "$(dial_of keep--shop)" = "127.0.0.1:3000" ] && grep -qx "PORT=3000" "$RD/keep--shop.env"'
  $E down keep --project shop >/dev/null
  # late public bind shows up in list
  LP2=$(free_port)
  $E up "$LP2" --name late --project shop >/dev/null 2>&1
  serve "$LP2" 0.0.0.0; LPID=$BG_PID
  l=$($E list); j=$($E list --json)
  ok "late 0.0.0.0 bind: list BIND PUBLIC" 'printf "%s\n" "$l" | grep -Eq "^late +shop +$LP2 +[^ ]+ +yes +PUBLIC +login$"'
  ok "late 0.0.0.0 bind: list --json bind public" 'printf "%s" "$j" | python3 -c "import json,sys; d=[o for o in json.load(sys.stdin) if o[\"name\"]==\"late\"]; assert d and d[0][\"bind\"]==\"public\""'
  kill "$LPID" "$WPID" 2>/dev/null; wait "$LPID" "$WPID" 2>/dev/null
  $E down late --project shop >/dev/null
  # 127.0.0.1 accepted (the live server from above)
  o=$($E up "$HP" --name live --project shop 2>/dev/null); rc=$?
  ok "127.0.0.1 bind accepted: exit 0, URL last" '[ $rc -eq 0 ] && [ "$(printf "%s\n" "$o" | tail -n1)" = "https://live--shop.dev.example.com" ]'
  # no ss on PATH: up refuses (fail closed), list shows -
  NOSS=$SP/noss; mkdir -p "$NOSS"
  for f in /usr/local/bin/* /usr/bin/* /bin/*; do b=${f##*/}; [ "$b" = ss ] || [ -e "$NOSS/$b" ] || ln -s "$f" "$NOSS/$b"; done
  e=$(PATH=$NOSS $E up "$HP" --name noss --project shop 2>&1 >/dev/null); rc=$?
  ok "no ss on PATH: up exits 2 saying it cannot check, no state" '[ $rc -eq 2 ] && [[ "$e" == *"cannot check"* ]] && [ ! -e "$RD/noss--shop.env" ]'
  l=$(PATH=$NOSS $E list)
  ok "no ss on PATH: list BIND -" 'printf "%s\n" "$l" | grep -Eq "^live +shop +$HP +[^ ]+ +yes +- +login$"'
else
  echo "note: not Linux or no ss; bind checks untested here"
fi

# ---- --public (fake admin view) ----
o=$($E up 3000 --name hook --project shop --public 2>/dev/null); rc=$?
ok "up --public: exit 0, says public with no authentication" '[ $rc -eq 0 ] && printf "%s\n" "$o" | grep -qi "public with no authentication" && [ "$(printf "%s\n" "$o" | tail -n1)" = "https://hook--shop.dev.example.com" ]'
ok "up --public: flat route, PUBLIC=1 recorded" '! adm /id/expose-hook--shop | grep -q subroute && [ "$(dial_of hook--shop)" = "127.0.0.1:3000" ] && grep -qx "PUBLIC=1" "$RD/hook--shop.env"'
l=$($E list)
ok "list ACCESS public/login" 'printf "%s\n" "$l" | grep -Eq "^hook .* public$" && printf "%s\n" "$l" | grep -Eq "^web .* login$"'
o=$($E share hook --project shop 2>&1); rc=$?
ok "share of a public exposure refused, no token" '[ $rc -ne 0 ] && ! grep -q "^SHARE=" "$RD/hook--shop.env"'
$E up 3000 --name hook --project shop >/dev/null 2>&1
ok "up again without --public: login route, PUBLIC dropped" 'adm /id/expose-hook--shop | grep -q subroute && ! grep -q "^PUBLIC=" "$RD/hook--shop.env"'
$E down hook --project shop >/dev/null

# =====================================================================
# Real Caddy: the same expose.sh against a scratch Caddy (the installed
# ~/.local/share/tmux-opsx/bin/caddy, $OPSX_CADDY_BIN, or caddy on PATH) on a
# private admin socket and a high HTTP port on 127.0.0.1, with a "*.ex.test"
# server and no TLS. Requests set the Host header; cookies are passed by hand
# (they are Secure, so a cookie jar over http would drop them).
# =====================================================================
CADDY_BIN=${OPSX_CADDY_BIN:-}
if [ -z "$CADDY_BIN" ]; then
  for c in "$REAL_HOME/.local/share/tmux-opsx/bin/caddy" "$(command -v caddy 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { CADDY_BIN=$c; break; }
  done
fi
RC=$SP/rc; RSOCK=$RC/admin.sock; CADDY_PID=""; APP_PIDS=()
start_caddy() {
  mkdir -p "$RC/config/tmux-opsx" "$RC/state"; chmod 700 "$RC/config/tmux-opsx"
  printf 'EXPOSE_DOMAIN=ex.test\n' > "$RC/config/tmux-opsx/expose.env"
  RP=$(free_port)
  printf '{"admin":{"listen":"unix/%s","config":{"persist":false}},"apps":{"http":{"http_port":%s,"servers":{"expose":{"listen":["127.0.0.1:%s"],"automatic_https":{"disable":true},"routes":[]}}}}}\n' \
    "$RSOCK" "$RP" "$RP" > "$RC/caddy.json"
  XDG_DATA_HOME=$RC/data XDG_CONFIG_HOME=$RC/cfg "$CADDY_BIN" run --config "$RC/caddy.json" > "$RC/caddy.log" 2>&1 & CADDY_PID=$!
  for _ in $(seq 1 100); do [ -S "$RSOCK" ] && (exec 3<>"/dev/tcp/127.0.0.1/$RP") 2>/dev/null && return 0; sleep 0.1; done
  echo "real Caddy did not start:"; cat "$RC/caddy.log"; return 1
}
stop_caddy() { [ -n "$CADDY_PID" ] && kill "$CADDY_PID" 2>/dev/null && wait "$CADDY_PID" 2>/dev/null; CADDY_PID=""; }
RE() { XDG_CONFIG_HOME=$RC/config XDG_STATE_HOME=$RC/state OPSX_EXPOSE_ADMIN=$RSOCK "$E" "$@"; }
# echo app: answers "app <name> cookie=[<Cookie>]" and logs each request.
cat > "$SP/echo-app.py" <<'PYAPP'
import http.server, sys
name, port, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(log, "a") as f: f.write(self.path + "\n")
        b = ("app %s cookie=[%s]\n" % (name, self.headers.get("Cookie", ""))).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYAPP
start_app() { # start_app <name> -> sets APP_PORT
  APP_PORT=$(free_port)
  python3 "$SP/echo-app.py" "$1" "$APP_PORT" "$RC/app-$1.log" & APP_PIDS+=($!)
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$APP_PORT") 2>/dev/null && return 0; sleep 0.1; done
}
# rq <label> <path> [curl args...]: status code; body in $RC/body, headers in $RC/hdr
rq() { local h=$1 p=$2; shift 2; curl -s -o "$RC/body" -D "$RC/hdr" -w '%{http_code}' -H "Host: $h.ex.test" "$@" "http://127.0.0.1:$RP$p"; }
hdr() { grep -i "^$1:" "$RC/hdr" | head -n1 | cut -d' ' -f2- | tr -d '\r'; }
tok_of() { printf '%s' "${1##*opsx_share=}"; }

if [ -z "$CADDY_BIN" ]; then
  echo "SKIP real-Caddy tests: no caddy binary (install.sh --expose-domain, \$OPSX_CADDY_BIN or caddy on PATH)"
elif ! start_caddy; then
  ok "real Caddy starts" 'false'
else
  # ---- smoke: the helper's Caddy answers through the scratch server ----
  ok "real Caddy: smoke request answered (no route -> empty 200)" '[ "$(rq nothing /)" = 200 ]'
  start_app web; WEBP=$APP_PORT; start_app api; APIP=$APP_PORT; start_app web2; WEB2P=$APP_PORT
  RE up "$WEBP" --name web --project shop >/dev/null 2>&1
  RE up "$APIP" --name api --project shop >/dev/null 2>&1
  RK=$(cat "$RC/config/tmux-opsx/expose.key")

  # ---- login required ----
  : > "$RC/app-web.log"
  code=$(rq web--shop /)
  ok "no cookie: 401, app not reached" '[ "$code" = 401 ] && [ ! -s "$RC/app-web.log" ]'
  ok "401 is the HTML login page with an opsx_key field, no-store" 'grep -q "name=\"opsx_key\"" "$RC/body" && grep -qi "may have expired" "$RC/body" && [[ "$(hdr Content-Type)" == text/html* ]] && [ "$(hdr Cache-Control)" = no-store ]'
  ok "wrong owner cookie: 401" '[ "$(rq web--shop / -H "Cookie: opsx_auth=wrong")" = 401 ]'
  code=$(rq web--shop "/admin?opsx_key=wrong")
  ok "wrong key: 401, no cookie set" '[ "$code" = 401 ] && [ -z "$(hdr Set-Cookie)" ]'
  code=$(rq web--shop "/admin?opsx_key=$RK")
  sc=$(hdr Set-Cookie)
  ok "login link: 302 to /admin on the same host, without the key" '[ "$code" = 302 ] && [ "$(hdr Location)" = https://web--shop.ex.test/admin ]'
  code2=$(rq web--shop "//evil.example/x?opsx_key=$RK")
  ok "login link on a //host path: redirect stays on the exposure host" '[ "$code2" = 302 ] && [ "$(hdr Location)" = https://web--shop.ex.test//evil.example/x ]'
  rq web--shop "/admin?opsx_key=$RK" >/dev/null
  ok "login link: owner cookie with Domain, Path, Secure, HttpOnly, SameSite=Lax, 30-day Max-Age" '[[ "$sc" == "opsx_auth=$RK;"* ]] && [[ "$sc" == *"Domain=ex.test"* ]] && [[ "$sc" == *"Path=/"* ]] && [[ "$sc" == *"Secure"* ]] && [[ "$sc" == *"HttpOnly"* ]] && [[ "$sc" == *"SameSite=Lax"* ]] && [[ "$sc" == *"Max-Age=2592000"* ]]'
  rq api--shop / -H "Cookie: opsx_auth=$RK" >/dev/null
  ok "owner cookie reaches the api app (another exposure)" 'grep -q "^app api " "$RC/body"'
  rq web--shop / -H "Cookie: sid=1; opsx_auth=$RK; theme=dark" >/dev/null
  ok "app sees its cookies without opsx_auth" 'grep -qx "app web cookie=\[sid=1; theme=dark\]" "$RC/body"'
  rq web--shop / -H "Cookie: opsx_auth=$RK; sid=1" >/dev/null
  ok "leading opsx_auth stripped cleanly" 'grep -qx "app web cookie=\[sid=1\]" "$RC/body"'

  # ---- pre-auth route upgraded (real Caddy) ----
  curl -sS --unix-socket "$RSOCK" -X DELETE "http://127.0.0.1/id/expose-web--shop" >/dev/null
  curl -sS --unix-socket "$RSOCK" -X POST -H 'Content-Type: application/json' --data-binary \
    '{"@id":"expose-web--shop","match":[{"host":["web--shop.ex.test"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:'"$WEBP"'"}]}],"terminal":true}' \
    "http://127.0.0.1/config/apps/http/servers/expose/routes" >/dev/null
  ok "hand-inserted pre-auth route lets anyone in" '[ "$(rq web--shop /)" = 200 ]'
  RE list >/dev/null 2>&1
  ok "after list, the pre-auth route needs a login (401)" '[ "$(rq web--shop /)" = 401 ]'

  # ---- --public ----
  o=$(RE up "$WEB2P" --name hook --project shop --public 2>/dev/null)
  ok "--public: cookie-less request reaches the app, output says public" '[ "$(rq hook--shop /)" = 200 ] && grep -q "^app web2 " "$RC/body" && printf "%s\n" "$o" | grep -qi "public with no authentication"'
  ok "--public: list ACCESS public" 'RE list | grep -Eq "^hook .* public$"'
  rq hook--shop / -H "Cookie: sid=1; opsx_auth=$RK; opsx_share=zzzzzzzzzzzzzzzzzzzzzzzz; theme=dark" >/dev/null
  ok "--public: owner and share cookies stripped, others kept" 'grep -qx "app web2 cookie=\[sid=1; theme=dark\]" "$RC/body"'
  RE up "$WEB2P" --name hook --project shop >/dev/null 2>&1
  ok "up again without --public: 401, ACCESS login" '[ "$(rq hook--shop /)" = 401 ] && RE list | grep -Eq "^hook .* login$"'
  RE down hook --project shop >/dev/null

  # ---- share links ----
  o=$(RE share web --for Acme --project shop 2>/dev/null); rc=$?
  A1=$(printf '%s\n' "$o" | tail -n1); TA1=$(tok_of "$A1")
  ok "share --for Acme: exit 0, last line is <url>/?opsx_share=<token>" '[ $rc -eq 0 ] && [[ "$A1" =~ ^https://web--shop\.ex\.test/\?opsx_share=[A-Za-z0-9_-]{22,}$ ]]'
  ok "share token not the owner key, key not printed" '[ "$TA1" != "$RK" ] && [[ "$o" != *"$RK"* ]]'
  ok "recipient normalised to acme in state" 'grep -q "^SHARE=[0-9a-f]\{6\}:acme:[0-9]*:$TA1$" "$RC/state/tmux-opsx/expose/routes/web--shop.env"'
  o=$(RE share web --for acme --project shop 2>/dev/null); A2=$(printf '%s\n' "$o" | tail -n1); TA2=$(tok_of "$A2")
  ok "same recipient replaced: new token, old link 401, new link 302" '[ "$TA1" != "$TA2" ] && [ "$(rq web--shop "/?opsx_share=$TA1")" = 401 ] && [ "$(rq web--shop "/?opsx_share=$TA2")" = 302 ] && [ "$(grep -c ":acme:" "$RC/state/tmux-opsx/expose/routes/web--shop.env")" -eq 1 ]'
  code=$(rq web--shop "/x/y?opsx_share=$TA2"); sc=$(hdr Set-Cookie)
  exp=$(grep ":acme:" "$RC/state/tmux-opsx/expose/routes/web--shop.env" | cut -d: -f3)
  ok "share link: 302 to the path, host-only cookie (no Domain), Expires at the deadline" '[ "$code" = 302 ] && [ "$(hdr Location)" = https://web--shop.ex.test/x/y ] && [[ "$sc" == "opsx_share=$TA2;"* ]] && [[ "$sc" != *"Domain"* ]] && [[ "$sc" == *"Path=/"* ]] && [[ "$sc" == *"Secure"* ]] && [[ "$sc" == *"HttpOnly"* ]] && [[ "$sc" == *"SameSite=Lax"* ]] && [[ "$sc" == *"Expires=$(LC_ALL=C date -u -d "@$exp" "+%a, %d %b %Y %H:%M:%S GMT")"* ]]'
  rq web--shop / -H "Cookie: opsx_share=$TA2; theme=dark" >/dev/null
  ok "share cookie reaches the app, stripped" 'grep -qx "app web cookie=\[theme=dark\]" "$RC/body"'
  ok "web share token refused on api (query and cookie)" '[ "$(rq api--shop "/?opsx_share=$TA2")" = 401 ] && [ "$(rq api--shop / -H "Cookie: opsx_share=$TA2")" = 401 ]'
  now=$(date +%s)
  ok "default ttl: 7 days" '[ $((exp - now)) -ge $((7*86400 - 60)) ] && [ $((exp - now)) -le $((7*86400)) ]'
  o=$(RE share web --project shop 2>/dev/null); D1=$(tok_of "$(printf '%s\n' "$o" | tail -n1)")
  did=$(grep ":$D1$" "$RC/state/tmux-opsx/expose/routes/web--shop.env" | cut -d= -f2 | cut -d: -f1)
  ok "no --for: recipient link-<id>" 'grep -q "^SHARE=$did:link-$did:" "$RC/state/tmux-opsx/expose/routes/web--shop.env"'
  G=$(tok_of "$(RE share web --for globex --ttl never --project shop 2>/dev/null | tail -n1)")
  ok "--ttl never: no deadline, cookie without Expires" 'grep -q ":globex:never:$G$" "$RC/state/tmux-opsx/expose/routes/web--shop.env" && [ "$(rq web--shop "/?opsx_share=$G")" = 302 ] && [[ "$(hdr Set-Cookie)" != *Expires* ]]'
  l=$(RE share web --list --project shop 2>/dev/null)
  ok "share --list: header + rows for acme and globex with ID, expiry, link" 'printf "%s\n" "$l" | head -1 | grep -Eq "^FOR +ID +EXPIRES +LINK$" && printf "%s\n" "$l" | grep -Eq "^acme +[0-9a-f]{6} +[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z +https://web--shop.ex.test/\?opsx_share=$TA2$" && printf "%s\n" "$l" | grep -Eq "^globex +[0-9a-f]{6} +never +https://web--shop.ex.test/\?opsx_share=$G$"'
  ok "share --list: acme expires 7 days from now" 'printf "%s\n" "$l" | grep -q "^acme .* $(date -u -d "@$exp" +%Y-%m-%dT%H:%MZ) "'
  n_before=$(grep -c "^SHARE=" "$RC/state/tmux-opsx/expose/routes/web--shop.env")
  e=$(RE share web --ttl 3weeks --project shop 2>&1); rc=$?
  ok "invalid ttl: exit 2 naming it, no token" '[ $rc -eq 2 ] && [[ "$e" == *3weeks* ]] && [ "$(grep -c "^SHARE=" "$RC/state/tmux-opsx/expose/routes/web--shop.env")" -eq "$n_before" ]'
  for t in 0d 5w 1.5h -1d d; do
    RE share web --ttl "$t" --project shop >/dev/null 2>&1; rc=$?
    ok "invalid ttl $t: exit 2" '[ $rc -eq 2 ]'
  done
  RE share nosuch --project shop >/dev/null 2>&1; rc=$?
  ok "share of an unknown exposure: non-zero, no record" '[ $rc -ne 0 ] && [ ! -e "$RC/state/tmux-opsx/expose/routes/nosuch--shop.env" ]'

  # ---- expiry enforced by the proxy (stored deadline 2s ahead via OPSX_EXPOSE_NOW) ----
  S=$(tok_of "$(OPSX_EXPOSE_NOW=$(( $(date +%s) - 58 )) RE share web --for shorty --ttl 1m --project shop 2>/dev/null | tail -n1)")
  ok "short link works before its deadline" '[ "$(rq web--shop "/?opsx_share=$S")" = 302 ] && [ "$(rq web--shop / -H "Cookie: opsx_share=$S")" = 200 ]'
  sleep 3
  ok "after its deadline, no expose.sh call in between: query and cookie 401" '[ "$(rq web--shop "/?opsx_share=$S")" = 401 ] && [ "$(rq web--shop / -H "Cookie: opsx_share=$S")" = 401 ]'
  ok "expired token still listed as expired until the next call prunes it" 'grep -q ":shorty:" "$RC/state/tmux-opsx/expose/routes/web--shop.env"'
  l=$(RE share web --list --project shop 2>/dev/null)
  ok "expired token gone from --list and state after the next call" '! printf "%s\n" "$l" | grep -q "^shorty " && ! grep -q ":shorty:" "$RC/state/tmux-opsx/expose/routes/web--shop.env"'

  # ---- revoke ----
  o=$(RE share web --revoke acme --project shop 2>/dev/null); rc=$?
  ok "revoke acme: exit 0, its cookie 401, globex still works" '[ $rc -eq 0 ] && [ "$(rq web--shop / -H "Cookie: opsx_share=$TA2")" = 401 ] && [ "$(rq web--shop / -H "Cookie: opsx_share=$G")" = 200 ]'
  o=$(RE share web --revoke nosuch --project shop 2>/dev/null); rc=$?
  ok "revoke nosuch: exit 0, says nothing matched" '[ $rc -eq 0 ] && [[ "$o" == *"nothing to revoke"* ]]'
  RE share web --revoke "$did" --project shop >/dev/null 2>&1
  ok "revoke by id" '! grep -q "^SHARE=$did:" "$RC/state/tmux-opsx/expose/routes/web--shop.env" && [ "$(rq web--shop "/?opsx_share=$D1")" = 401 ]'

  # ---- re-publish keeps links; down drops them ----
  RE up "$WEB2P" --name web --project shop >/dev/null 2>&1
  rq web--shop / -H "Cookie: opsx_share=$G" >/dev/null
  ok "re-publish to a new port: globex link still works, reaches the new app" 'grep -q "^app web2 " "$RC/body" && [ "$(rq web--shop "/?opsx_share=$G")" = 302 ]'

  # ---- key rotate ----
  o=$(RE key rotate 2>&1); rc=$?
  RK2=$(cat "$RC/config/tmux-opsx/expose.key")
  ok "key rotate: exit 0, new key, not printed" '[ $rc -eq 0 ] && [ "$RK2" != "$RK" ] && [[ "$o" != *"$RK2"* ]] && [ "$(stat -c %a "$RC/config/tmux-opsx/expose.key")" = 600 ]'
  ok "key rotate: old owner cookie and old login link 401" '[ "$(rq web--shop / -H "Cookie: opsx_auth=$RK")" = 401 ] && [ "$(rq api--shop "/?opsx_key=$RK")" = 401 ]'
  NL=$(RE url web --project shop --with-key 2>/dev/null | tail -n1)
  ok "key rotate: url --with-key prints the new key, which logs in" '[ "$NL" = "https://web--shop.ex.test/?opsx_key=$RK2" ] && [ "$(rq web--shop "/?opsx_key=$RK2")" = 302 ]'
  ok "key rotate: share links still work" '[ "$(rq web--shop / -H "Cookie: opsx_share=$G")" = 200 ]'
  RE share web --revoke all --project shop >/dev/null 2>&1
  ok "revoke all: no SHARE lines, globex 401" '! grep -q "^SHARE=" "$RC/state/tmux-opsx/expose/routes/web--shop.env" && [ "$(rq web--shop / -H "Cookie: opsx_share=$G")" = 401 ]'

  # ---- down then up drops share links ----
  Z=$(tok_of "$(RE share web --for acme --project shop 2>/dev/null | tail -n1)")
  RE down web --project shop >/dev/null 2>&1
  RE up "$WEBP" --name web --project shop >/dev/null 2>&1
  ok "down then up: old link 401, --list empty" '[ "$(rq web--shop "/?opsx_share=$Z")" = 401 ] && RE share web --list --project shop 2>/dev/null | grep -q "no share links"'

  stop_caddy
  kill "${APP_PIDS[@]}" 2>/dev/null; wait "${APP_PIDS[@]}" 2>/dev/null
  ok "real Caddy torn down" '! (exec 3<>"/dev/tcp/127.0.0.1/$RP") 2>/dev/null'
fi

# =====================================================================
# install.sh --expose-domain, in fresh scratch HOMEs, fully offline:
# fake caddy ($OPSX_CADDY_BIN), fake Cloudflare ($OPSX_CLOUDFLARE_API on
# 127.0.0.1), PATH shims that log any sudo/systemctl call, a curl shim that
# logs its argv, and stub agent/node CLIs. The install never touches your
# real ~/.config, systemd, DNS or Cloudflare.
# =====================================================================
stop_fake
unset OPSX_EXPOSE_ADMIN CLAUDE_CONFIG_DIR CODEX_HOME GEMINI_HOME OPENCODE_CONFIG_DIR XDG_DATA_HOME CLOUDFLARE_API_TOKEN
SH=$SP/shims; mkdir -p "$SH"
REAL_CURL=$(command -v curl)
for c in sudo systemctl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/privileged.log"\nexit 0\n' "$c" "$SP" > "$SH/$c"
done
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/curl-args.log"\nexec "%s" "$@"\n' "$SP" "$REAL_CURL" > "$SH/curl"
for c in claude node npm; do
  command -v "$c" >/dev/null 2>&1 || printf '#!/bin/sh\necho 0.0.0\n' > "$SH/$c"
done
chmod +x "$SH"/*
mkdir -p "$SP/caddy-ok" "$SP/caddy-bad"
printf '#!/bin/sh\n[ "$1" = list-modules ] && { echo http.handlers.reverse_proxy; echo dns.providers.cloudflare; exit 0; }\nexit 0\n' > "$SP/caddy-ok/caddy"
printf '#!/bin/sh\n[ "$1" = list-modules ] && { echo http.handlers.reverse_proxy; exit 0; }\nexit 0\n' > "$SP/caddy-bad/caddy"
chmod +x "$SP/caddy-ok/caddy" "$SP/caddy-bad/caddy"

# Fake Cloudflare token verify: token "good-*" is active, anything else rejected.
CFP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 - "$CFP" <<'PYCF' & CF_PID=$!
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        good = auth.startswith("Bearer good-") and self.path.endswith("/user/tokens/verify")
        body = {"success": good, "result": {"status": "active"} if good else None,
                "errors": [] if good else [{"code": 1000, "message": "Invalid API Token"}]}
        b = json.dumps(body).encode()
        self.send_response(200 if good else 401); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYCF
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$CFP") 2>/dev/null && break; sleep 0.1; done

INSTALL_FLAGS=(--skip-openspec --skip-graphify --skip-commands --skip-mcp --skip-memory)
H_N=0
new_home() { H_N=$((H_N+1)); IH=$SP/ih$H_N; mkdir -p "$IH"; rm -f "$SP/privileged.log" "$SP/curl-args.log"; }
# run_install <env assignments...> -- <install args...>; stdin is never a terminal
run_install() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u TMUX HOME="$IH" PATH="$SH:$PATH" NO_COLOR=1 "${envs[@]}" \
    bash "$REPO/install.sh" "${INSTALL_FLAGS[@]}" "$@" </dev/null > "$IH.out" 2>&1
}
SKILL_DIRS=(.claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills)
n_expose_dirs() { local n=0 d; for d in "${SKILL_DIRS[@]}"; do [ -d "$IH/$d/expose" ] && n=$((n+1)); done; echo $n; }
installed_anything() { [ -e "$IH/.claude/agents" ] || [ -e "$IH/.claude/skills" ] || [ -e "$IH/.config/tmux-opsx" ]; }

ok "install --help shows --expose-domain" 'bash "$REPO/install.sh" --help | grep -q -- "--expose-domain"'

# not passed
new_home; run_install OPSX_CADDY_BIN="$SP/caddy-ok/caddy" -- ; rc=$?
ok "no flag: install ok" '[ $rc -eq 0 ]'
ok "no flag: no expose dirs/config/caddy, no Cloudflare call" '[ "$(n_expose_dirs)" -eq 0 ] && [ ! -e "$IH/.config/tmux-opsx" ] && [ ! -e "$IH/.local/share/tmux-opsx" ] && ! grep -q cloudflare "$SP/curl-args.log" 2>/dev/null'
ok "no flag: no expose output" '! sed "s|$SP||g" "$IH.out" | grep -qi "expose"'

# invalid domain
new_home; run_install CLOUDFLARE_API_TOKEN=t1 OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-ok/caddy" -- --expose-domain 'not a domain'; rc=$?
ok "invalid domain: non-zero, named, nothing installed" '[ $rc -ne 0 ] && grep -q "not a domain" "$IH.out" && ! installed_anything'
new_home; run_install CLOUDFLARE_API_TOKEN=t1 OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-ok/caddy" -- --expose-domain 'Dev.Example.com'; rc=$?
ok "uppercase domain lowercased" '[ $rc -eq 0 ] && grep -qx "EXPOSE_DOMAIN=dev.example.com" "$IH/.config/tmux-opsx/expose.env"'

# no token anywhere
new_home; run_install OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-ok/caddy" -- --expose-domain dev.example.com; rc=$?
ok "no token: non-zero naming CLOUDFLARE_API_TOKEN, nothing installed" '[ $rc -ne 0 ] && grep -q CLOUDFLARE_API_TOKEN "$IH.out" && ! installed_anything'

# rejected token (fake Cloudflare)
new_home; run_install CLOUDFLARE_API_TOKEN=bad-t OPSX_CLOUDFLARE_API="http://127.0.0.1:$CFP" OPSX_CADDY_BIN="$SP/caddy-ok/caddy" -- --expose-domain dev.example.com; rc=$?
ok "rejected token: non-zero, says invalid, no expose.env" '[ $rc -ne 0 ] && grep -qi "invalid" "$IH.out" && [ ! -e "$IH/.config/tmux-opsx/expose.env" ] && ! installed_anything'
ok "rejected token: token not on curl argv" '[ -s "$SP/curl-args.log" ] && ! grep -q "bad-t" "$SP/curl-args.log" && ! grep -q "bad-t" "$IH.out"'

# accepted token (fake Cloudflare), wildcard prefix, fresh install
new_home; run_install CLOUDFLARE_API_TOKEN=good-secret-t1 OPSX_CLOUDFLARE_API="http://127.0.0.1:$CFP" OPSX_CADDY_BIN="$SP/caddy-ok/caddy" -- --expose-domain '*.dev.example.com'; rc=$?
CFG=$IH/.config/tmux-opsx
ok "verified install exits 0" '[ $rc -eq 0 ]'
ok "wildcard prefix stripped" 'grep -qx "EXPOSE_DOMAIN=dev.example.com" "$CFG/expose.env"'
ok "token verified, never on argv or output" 'grep -q "token is valid" "$IH.out" && ! grep -q "good-secret-t1" "$SP/curl-args.log" "$IH.out"'

# fresh install with OPSX_EXPOSE_SKIP_VERIFY=1 + token from env
new_home; run_install CLOUDFLARE_API_TOKEN=secret-t1 OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-ok/caddy" -- --expose-domain dev.example.com; rc=$?
CFG=$IH/.config/tmux-opsx; STD=$IH/.local/state/tmux-opsx/expose
ok "fresh install exits 0" '[ $rc -eq 0 ]'
ok "six expose skill dirs with SKILL.md + executable expose.sh" 'for d in "${SKILL_DIRS[@]}"; do [ -f "$IH/$d/expose/SKILL.md" ] && [ -x "$IH/$d/expose/expose.sh" ] || exit 1; done'
ok "expose.env mode 600 in mode-700 dir, has domain + token" '[ "$(stat -c %a "$CFG/expose.env")" = 600 ] && [ "$(stat -c %a "$CFG")" = 700 ] && grep -qx "EXPOSE_DOMAIN=dev.example.com" "$CFG/expose.env" && grep -qx "CLOUDFLARE_API_TOKEN=secret-t1" "$CFG/expose.env"'
ok "token only in expose.env" '[ "$(grep -rl "secret-t1" "$CFG" | wc -l)" -eq 1 ]'
ok "token not printed" '! grep -q "secret-t1" "$IH.out"'
ok "no prompt without a terminal" '! grep -qi "token for dev.example.com (Zone" "$IH.out"'
ok "no caddy downloaded (OPSX_CADDY_BIN used)" '[ ! -e "$IH/.local/share/tmux-opsx/bin/caddy" ] && ! grep -q caddyserver.com "$SP/curl-args.log" 2>/dev/null'
if command -v jq >/dev/null 2>&1; then
  J="$CFG/caddy.json"
  ok "caddy.json: only :443" '[ "$(jq -c "[.apps.http.servers[].listen[]]" "$J")" = "[\":443\"]" ] && [ "$(jq -r ".apps.http.servers.expose.automatic_https.disable_redirects" "$J")" = true ]'
  ok "caddy.json: wildcard subject + cloudflare DNS" '[ "$(jq -r ".apps.tls.automation.policies[0].subjects[0]" "$J")" = "*.dev.example.com" ] && [ "$(jq -r ".apps.tls.automation.policies[0].issuers[0].challenges.dns.provider.name" "$J")" = cloudflare ]'
  ok "caddy.json: no autosave (admin.config.persist false)" '[ "$(jq -r ".admin.config.persist" "$J")" = false ]'
  ok "caddy.json: unix admin socket in mode-700 dir" 'a=$(jq -r ".admin.listen" "$J"); [[ "$a" == unix/* ]] && [ "$(dirname "${a#unix/}")" = "$STD" ] && [ "$(stat -c %a "$STD")" = 700 ]'
fi
ok "systemd unit written under user config" 'grep -q "^ExecStart=.* run --config" "$CFG/tmux-opsx-caddy.service" && ! grep -q -- "--resume" "$CFG/tmux-opsx-caddy.service" && grep -q "^ExecStartPost=-.*/expose/expose.sh\" list" "$CFG/tmux-opsx-caddy.service" && grep -q "^AmbientCapabilities=CAP_NET_BIND_SERVICE" "$CFG/tmux-opsx-caddy.service" && grep -q "^EnvironmentFile=$CFG/expose.env" "$CFG/tmux-opsx-caddy.service"'
ok "non-root: no sudo/systemctl invoked" '[ ! -e "$SP/privileged.log" ]'
ok "non-root: prints the systemctl command" 'grep -q "sudo systemctl enable --now tmux-opsx-caddy" "$IH.out" && grep -q "sudo install -m 644 .*tmux-opsx-caddy.service" "$IH.out"'
ok "DNS check warns, install still ok" 'grep -q "\*.dev.example.com" "$IH.out" && grep -qi "DNS-only" "$IH.out"'

# expose.sh as installed in this HOME talks to the fake admin on the configured socket
mkdir -p "$STD"; SOCK=$STD/caddy-admin.sock; start_fake
o=$(env -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$IH" "$IH/.claude/skills/expose/expose.sh" up 3000 --name web --project shop | tail -n1)
ok "installed expose.sh uses configured socket" '[ "$o" = "https://web--shop.dev.example.com" ]'
stop_fake

# rerun: identical files, token kept, no duplicates/backups
sum_before=$(cd "$IH" && find . -path ./.local/state -prune -o -type f -print | sort | xargs md5sum)
run_install OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-ok/caddy" -- --expose-domain dev.example.com; rc=$?
sum_after=$(cd "$IH" && find . -path ./.local/state -prune -o -type f -print | sort | xargs md5sum)
ok "rerun without token exits 0 and keeps t1" '[ $rc -eq 0 ] && grep -qx "CLOUDFLARE_API_TOKEN=secret-t1" "$CFG/expose.env"'
ok "rerun leaves identical files (no .bak, no duplicates)" '[ "$sum_before" = "$sum_after" ]'
run_install OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-ok/caddy" --
ok "later run without the flag leaves expose untouched" 'grep -qx "CLOUDFLARE_API_TOKEN=secret-t1" "$CFG/expose.env" && [ "$(n_expose_dirs)" -eq 6 ]'

# F1: rerun with another domain while the proxy runs (unit "installed" in a
# scratch systemd dir): the new caddy.json is loaded, routes move to the new domain.
SYSD=$SP/systemd; mkdir -p "$SYSD"; cp "$CFG/tmux-opsx-caddy.service" "$SYSD/"
start_fake
IE() { env -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$IH" "$IH/.claude/skills/expose/expose.sh" "$@"; }
IE up 3000 --name web --project shop >/dev/null
rm -f "$SP/privileged.log"
run_install OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-ok/caddy" OPSX_SYSTEMD_DIR="$SYSD" -- --expose-domain other.example.com; rc=$?
subj=$(adm /config/apps/tls/automation/policies/0/subjects/0)
ok "domain change: exit 0, new config loaded into running proxy" '[ $rc -eq 0 ] && grep -q "loaded the new" "$IH.out" && [ "$subj" = "\"*.other.example.com\"" ]'
ok "domain change: route re-added on the new domain" '[ "$(host_of web--shop)" = "web--shop.other.example.com" ] && [ "$(dial_of web--shop)" = "127.0.0.1:3000" ]'
ok "domain change: record URL rewritten" 'grep -qx "URL=https://web--shop.other.example.com" "$STD/routes/web--shop.env" && [ "$(IE url web --project shop | tail -n1)" = "https://web--shop.other.example.com" ]'
ok "domain change, same token + unit: no restart asked, no sudo" '! grep -q "systemctl restart" "$IH.out" && [ ! -e "$SP/privileged.log" ]'
# new token: Caddy reads it from its environment only at start -> restart command
run_install CLOUDFLARE_API_TOKEN=secret-t2 OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-ok/caddy" OPSX_SYSTEMD_DIR="$SYSD" -- --expose-domain other.example.com; rc=$?
ok "token change: prints the restart command, no sudo run" '[ $rc -eq 0 ] && grep -q "sudo systemctl restart tmux-opsx-caddy" "$IH.out" && [ ! -e "$SP/privileged.log" ] && ! grep -q "secret-t2" "$IH.out"'
# installed unit differs (e.g. an older one with --resume) -> restart command
sed -i "s| run --config| run --resume --config|" "$SYSD/tmux-opsx-caddy.service"
run_install OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-ok/caddy" OPSX_SYSTEMD_DIR="$SYSD" -- --expose-domain other.example.com; rc=$?
ok "stale installed unit: prints reinstall + restart" '[ $rc -eq 0 ] && grep -q "sudo install -m 644 .*tmux-opsx-caddy.service.* $SYSD/ && sudo systemctl daemon-reload && sudo systemctl restart tmux-opsx-caddy" "$IH.out"'
cp "$CFG/tmux-opsx-caddy.service" "$SYSD/"
# proxy stopped during a domain change: nothing to load, it reads caddy.json at start
stop_fake
run_install OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-ok/caddy" OPSX_SYSTEMD_DIR="$SYSD" -- --expose-domain third.example.com; rc=$?
ok "domain change, proxy stopped: exit 0, says it loads at start" '[ $rc -eq 0 ] && grep -q "reads the new" "$IH.out" && grep -q "\*.third.example.com" "$CFG/caddy.json" && grep -qx "URL=https://web--shop.third.example.com" "$STD/routes/web--shop.env"'
SOCK=$STD/caddy-admin.sock; start_fake
o=$(IE list)
ok "after the stopped proxy starts: route restored on the new domain" '[ "$(host_of web--shop)" = "web--shop.third.example.com" ]'
stop_fake

# caddy without the module
new_home; run_install CLOUDFLARE_API_TOKEN=t1 OPSX_EXPOSE_SKIP_VERIFY=1 OPSX_CADDY_BIN="$SP/caddy-bad/caddy" -- --expose-domain dev.example.com; rc=$?
ok "caddy lacking dns.providers.cloudflare fails" '[ $rc -ne 0 ] && grep -q "dns.providers.cloudflare" "$IH.out" && [ ! -e "$IH/.config/tmux-opsx/expose.env" ]'

# installed caddy with the module is reused (no download)
new_home; mkdir -p "$IH/.local/share/tmux-opsx/bin"; cp "$SP/caddy-ok/caddy" "$IH/.local/share/tmux-opsx/bin/caddy"
run_install CLOUDFLARE_API_TOKEN=t1 OPSX_EXPOSE_SKIP_VERIFY=1 -- --expose-domain dev.example.invalid; rc=$?
ok "installed caddy reused, nothing downloaded" '[ $rc -eq 0 ] && grep -q "already installed" "$IH.out" && ! grep -q caddyserver.com "$SP/curl-args.log" 2>/dev/null'
ok "unresolvable domain: warning, exit 0" '[ $rc -eq 0 ] && grep -q "\*.dev.example.invalid does not resolve" "$IH.out"'
kill "$CF_PID" 2>/dev/null

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
