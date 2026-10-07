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
E=$REPO/skills/expose/expose.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/expose-test.XXXXXX")
L="tmux -L expose-test-$$"
FAKE_PID=""; HTTP_PID=""
cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
  $L kill-server 2>/dev/null
  rm -rf "$SP"
}
trap cleanup EXIT

export HOME=$SP/home XDG_CONFIG_HOME=$SP/home/.config XDG_STATE_HOME=$SP/home/.local/state
mkdir -p "$HOME"
SOCK=$SP/admin.sock
export OPSX_EXPOSE_ADMIN=$SOCK

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
dial_of() { adm "/id/expose-$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["handle"][0]["upstreams"][0]["dial"])' 2>/dev/null; }
host_of() { adm "/id/expose-$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["match"][0]["host"][0])' 2>/dev/null; }
RD=$XDG_STATE_HOME/tmux-opsx/expose/routes

# ---- 1.1 help / usage ----
h=$($E help); rc=$?
ok "help exits 0" '[ $rc -eq 0 ]'
ok "help lists subcommands and options" 'for w in up down list url help --name --project --json; do [[ "$h" == *"$w"* ]] || exit 1; done'
$E bogus >/dev/null 2>&1; rc=$?
ok "unknown subcommand exits 2" '[ $rc -eq 2 ]'

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

o=$($E up 3000 --name web --project shop); rc=$?
ok "publish: exit 0, last line is URL" '[ $rc -eq 0 ] && [ "$(printf "%s\n" "$o" | tail -n1)" = "https://web--shop.dev.example.com" ]'
ok "publish: route host + dial" '[ "$(host_of web--shop)" = "web--shop.dev.example.com" ] && [ "$(dial_of web--shop)" = "127.0.0.1:3000" ]'
ok "publish: public warning line" 'printf "%s\n" "$o" | grep -qi "public with no authentication"'
ok "publish: state record" 'grep -qx "PORT=3000" "$RD/web--shop.env" && grep -qx "URL=https://web--shop.dev.example.com" "$RD/web--shop.env"'
ok "copied through tmux" '[ "$($L show-buffer)" = "https://web--shop.dev.example.com" ]'
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

# ---- url ----
o=$($E url web --project shop); rc=$?
ok "url reprints" '[ $rc -eq 0 ] && [ "$(printf "%s\n" "$o" | tail -n1)" = "https://web--shop.dev.example.com" ]'
$L set-buffer -- placeholder
$E url web --project shop >/dev/null
ok "url copies again" '[ "$($L show-buffer)" = "https://web--shop.dev.example.com" ]'
$E url nosuch --project shop >/dev/null 2>&1; rc=$?
ok "url unknown exits non-zero" '[ $rc -ne 0 ]'

# ---- 1.4 list / UP probe ----
$E up 3999 --name idle --project shop >/dev/null
l=$($E list); j=$($E list --json)
ok "list header" 'printf "%s\n" "$l" | head -1 | grep -Eq "^NAME +PROJECT +PORT +URL +UP$"'
ok "idle row UP no" 'printf "%s\n" "$l" | grep -Eq "^idle +shop +3999 +https://idle--shop.dev.example.com +no$"'
ok "json idle up false" 'printf "%s" "$j" | python3 -c "import json,sys; d=[o for o in json.load(sys.stdin) if o[\"name\"]==\"idle\"]; assert d and d[0][\"up\"] is False and d[0][\"port\"]==3999 and set(d[0])=={\"name\",\"project\",\"port\",\"url\",\"up\"}"'
HP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
(cd "$SP" && exec python3 -m http.server "$HP" --bind 127.0.0.1 >/dev/null 2>&1) & HTTP_PID=$!
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$HP") 2>/dev/null && break; sleep 0.1; done
$E up "$HP" --name live --project shop >/dev/null
l=$($E list); j=$($E list --json)
ok "live row UP yes" 'printf "%s\n" "$l" | grep -Eq "^live +shop +$HP +.* yes$"'
ok "json live up true" 'printf "%s" "$j" | python3 -c "import json,sys; d=[o for o in json.load(sys.stdin) if o[\"name\"]==\"live\"]; assert d and d[0][\"up\"] is True"'

# ---- 2.3 reconciliation after a proxy restart ----
stop_fake; start_fake
ok "restarted proxy has no routes" '[ "$(nroutes)" -eq 0 ]'
l=$($E list 2>/dev/null)
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
new_home; run_install CLOUDFLARE_API_TOKEN=t1 OPSX_EXPOSE_SKIP_VERIFY=1 -- --expose-domain 'Dev.Example.com'; rc=$?
ok "uppercase domain refused" '[ $rc -ne 0 ] && ! installed_anything'

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
