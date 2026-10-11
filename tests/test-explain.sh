#!/usr/bin/env bash
# Scripted tests for skills/explain/explain.sh.
#
# Runs on a private tmux server (tmux -L explain-test-$$) with fake agent CLIs,
# a fake expose.sh and a scratch XDG_STATE_HOME, so it never touches your tmux
# session, your /expose setup or your pages. The explain server itself is the
# real server (.serve.py written by explain.sh) on a scratch loopback port.
# Usage: bash tests/test-explain.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016,SC2086
set -u
command -v tmux >/dev/null 2>&1 || { echo "tmux is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
X=$REPO/skills/explain/explain.sh
F=$REPO/skills/fork/fork.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/explain-test.XXXXXX")
L="tmux -L explain-test-$$"
trap '$L kill-server 2>/dev/null; rm -rf "$SP"' EXIT

# fake agent CLIs (log args + FORK_* env, then idle)
mkdir -p "$SP/fakebin"
for c in claude agent codex opencode gemini; do
  cat > "$SP/fakebin/$c" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$0")
{ printf 'CLI=%s\n' "$name"; for a in "$@"; do printf 'ARG=%s\n' "${a:0:60}"; done; env | grep '^FORK_'; } > "$FORK_DIR/fake-$name.log"
echo "fake $name started for fork $FORK_ID"
exec sleep 600
EOF
  chmod +x "$SP/fakebin/$c"
done

# fake expose.sh: logs its arguments; behaviour from $SP/expose.mode
cat > "$SP/fake-expose.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SP/expose.log"
mode=\$(cat "$SP/expose.mode" 2>/dev/null || echo ok)
if [ "\$mode" = unconfigured ]; then
  echo "expose: not configured — run install.sh --expose-domain <domain> first" >&2
  exit 3
fi
case "\$1" in
  up)    echo "exposed 127.0.0.1:\$2"; echo "https://explain--shop.example.test" ;;
  share) shift 2; echo "share link (\$*):"; echo "https://explain--shop.example.test/?opsx_share=tok123" ;;
  down)  echo "removed \$2" ;;
  url)   echo "https://explain--shop.example.test" ;;
esac
exit 0
EOF
chmod +x "$SP/fake-expose.sh"
echo ok > "$SP/expose.mode"

export XDG_STATE_HOME=$SP/state
export PATH=$SP/fakebin:$PATH
export OPSX_EXPOSE_SH=$SP/fake-expose.sh
export FORK_HOST_CLI=none
EXPLAIN_PORT_MIN=$((47000 + RANDOM % 500)); export EXPLAIN_PORT_MIN EXPLAIN_PORT_MAX=$((EXPLAIN_PORT_MIN + 60))
unset CLAUDE_CODE_SESSION_ID FORK_CLI FORK_MODEL FORK_NATIVE EXPLAIN_FORK_SH

# scratch project "shop" with a change worktree
git init -q "$SP/shop" && git -C "$SP/shop" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$SP/shop" worktree add -q "$SP/wt-change" -b opsx/change 2>/dev/null
ROOT=$XDG_STATE_HOME/agent-forks/explain/shop

$L kill-server 2>/dev/null
env -u TMUX $L -f /dev/null new-session -d -s es -x 220 -y 60 -c "$SP/shop" 'exec sleep 3000'
sock=$($L display -p '#{socket_path}'); pid=$($L display -p '#{pid}')
P=$($L display -p -t es '#{pane_id}')
export TMUX="$sock,$pid,0" TMUX_PANE=$P
SD=$XDG_STATE_HOME/agent-forks/es

pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
tagged() { $L list-windows -a -F '#{window_id} #{@opsx_explain}' | awk '$2 == "shop" { print $1 }'; }
rec() { awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2) }' "$ROOT/.server"; }
answers() { curl -s -o /dev/null -I -w '%{http_code}' --max-time 2 "http://127.0.0.1:$1/" | grep -q '^200$'; }
cd "$SP/shop" || exit 1

# --- 2.1 project and pages root -------------------------------------------
r1=$($X root); r2=$(cd "$SP/wt-change" && $X root)
ok "root: main checkout -> explain/shop" '[ "$r1" = "$ROOT" ]'
ok "root: worktree resolves to the same root" '[ "$r2" = "$ROOT" ]'

# --- 2.2 server: first call, reuse, stale record ----------------------------
nw=$($L list-windows -a | wc -l)
o=$($X serve 2>&1); echo "$o"
W1=$(rec window); PORT=$(rec port)
ok "serve: one tagged window named 'ox >explain'" '[ "$(tagged | wc -l)" -eq 1 ] && [ "$(tagged)" = "$W1" ] && [ "$($L display -p -t "$W1" "#{window_name}")" = "ox >explain" ]'
ok "serve: .server record (port, window, pid)" '[ -n "$PORT" ] && [ -n "$W1" ] && [ -n "$(rec pid)" ]'
ok "serve: port answers on loopback" 'answers $PORT'
ok "serve: bound to 127.0.0.1 only" 'grep -q -- "--bind 127.0.0.1" $ROOT/launch.sh'
ok "serve: library index written" '[ -f $ROOT/index.html ] && [ -x $ROOT/.reindex ]'
ok "serve: tag is not @opsx_preview" '[ -z "$($L show-options -w -v -t "$W1" @opsx_preview 2>/dev/null)" ]'
o=$($X serve 2>&1)
ok "serve again: no new window, same port" '[ "$(tagged | wc -l)" -eq 1 ] && [ "$(rec window)" = "$W1" ] && [ "$(rec port)" = "$PORT" ] && [ "$($L list-windows -a | wc -l)" -eq $((nw + 1)) ]'
$L kill-window -t "$W1"; sleep 0.3
o=$($X serve 2>&1)
W2=$(rec window)
ok "stale record (window gone) -> restarted" '[ -n "$W2" ] && [ "$W2" != "$W1" ] && [ "$(tagged | wc -l)" -eq 1 ] && answers $(rec port)'
sed -i 's/^window=.*/window=@9999/' $ROOT/.server
o=$($X serve 2>&1)
ok "stale record (unknown window) -> replaced, old window closed" '[ "$(rec window)" != "@9999" ] && [ "$(tagged | wc -l)" -eq 1 ] && answers $(rec port)'
PORT=$(rec port); W=$(rec window)

# --- 2.3 exposure ------------------------------------------------------------
ok "expose: up <port> --name explain" 'grep -qx "up $PORT --name explain" $SP/expose.log'
ok "serve prints the exposed URL" '[ "$(echo "$o" | tail -n1)" = "https://explain--shop.example.test/" ]'

# --- 2.5 open ----------------------------------------------------------------
: > $SP/expose.log
o=$(printf '## Focus\n- the land gate\n' | $X open "how landing works" --window 2>&1); rc=$?; echo "$o"
FID=$(echo "$o" | awk '/^fork /{print $2; exit}')
ok "open: exit 0, fork line relayed" '[ $rc -eq 0 ] && [[ "$o" == *"fork $FID pane %"* ]]'
ok "open: page URL is the last line and names /1/" '[ "$(echo "$o" | tail -n1)" = "page 1 https://explain--shop.example.test/1/" ]'
ok "open: reuse, no second window or exposure" '[ "$(tagged | wc -l)" -eq 1 ] && [ "$(rec window)" = "$W" ] && [ "$(sort -u $SP/expose.log | grep -c "^up ")" -le 1 ] && ! grep -q "^up" <(grep -v "^up $PORT --name explain$" $SP/expose.log)'
sleep 1.2
ok "open: fork meta page_dir = <root>/1" 'grep -qx "page_dir=$ROOT/1" $SD/$FID/meta'
ok "open: child env FORK_PAGE_DIR" 'grep -qx "FORK_PAGE_DIR=$ROOT/1" $SD/$FID/fake-claude.log'
ok "open: brief has topic, URL, notes" 'grep -q "how landing works" $SD/$FID/brief.md && grep -q "https://explain--shop.example.test/1/" $SD/$FID/brief.md && grep -q "the land gate" $SD/$FID/brief.md'
ok "open: brief has page protocol" 'grep -q "$F page" $SD/$FID/brief.md && grep -q manifest.tsv $SD/$FID/brief.md && grep -q "S P D T C N" $SD/$FID/brief.md && grep -qi mermaid $SD/$FID/brief.md'
ok "open: brief has the HTML template" 'grep -q "data-label" $SD/$FID/brief.md && grep -q "class=\"mermaid\"" $SD/$FID/brief.md && grep -q "Last-Modified" $SD/$FID/brief.md'
ok "open: page protocol is the last section" '[ "$(grep "^## " $SD/$FID/brief.md | tail -n1)" = "## Page protocol (fork $FID)" ]'
ok "open: claude page allow rule" 'grep -q "page:" $SD/$FID/launch.sh && grep -qx "ARG=plan" $SD/$FID/fake-claude.log'
ok "open: page .meta (topic, created, fork, session)" 'grep -qx "topic=how landing works" $ROOT/1/.meta && grep -q "^created=." $ROOT/1/.meta && grep -qx "fork=$FID" $ROOT/1/.meta && grep -qx "session=es" $ROOT/1/.meta'
ok "open: placeholder served at /1/" 'curl -s "http://127.0.0.1:$PORT/1/" | grep -q "how landing works"'

nwin=$($L list-windows -a | wc -l); npages=$(find $ROOT -mindepth 1 -maxdepth 1 | wc -l)
e=$($X open "" 2>&1); rc=$?
ok "open: empty topic refused, nothing opened" '[ $rc -eq 2 ] && [[ "$e" == *"topic is required"* ]] && [ "$($L list-windows -a | wc -l)" -eq $nwin ] && [ "$(find $ROOT -mindepth 1 -maxdepth 1 | wc -l)" -eq $npages ]'
e=$($X open "   " </dev/null 2>&1); rc=$?
ok "open: blank topic refused" '[ $rc -eq 2 ]'
e=$($X open --window 2>&1 </dev/null); rc=$?
ok "open: flags without topic refused" '[ $rc -eq 2 ] && [ "$($L list-windows -a | wc -l)" -eq $nwin ]'

# --- 2.4 ids, library index ------------------------------------------------
o2=$($X open "second topic" --window </dev/null 2>&1); F2=$(echo "$o2" | awk '/^fork /{print $2; exit}')
ok "ids: second page is 2" '[ "$(echo "$o2" | tail -n1)" = "page 2 https://explain--shop.example.test/2/" ] && [ -d $ROOT/2 ]'
printf '<!doctype html><html><head><title>Landing explained</title></head><body><p id="P1" data-label="P1">x</p></body></html>\n' | FORK_PAGE_DIR=$ROOT/1 $F page >/dev/null
printf 'P1\tx\n' | FORK_PAGE_DIR=$ROOT/1 $F page --manifest >/dev/null
printf '<!doctype html><html><head><title>Second &amp; last</title></head><body></body></html>\n' | FORK_PAGE_DIR=$ROOT/2 $F page >/dev/null
ok "library: index lists both titles (regenerated by fork.sh page)" 'grep -q "Landing explained" $ROOT/index.html && grep -q "Second &amp; last" $ROOT/index.html && grep -q "href=\"/1/\"" $ROOT/index.html && grep -q "href=\"/2/\"" $ROOT/index.html'
ok "library: served at /" 'curl -s "http://127.0.0.1:$PORT/" | grep -q "Landing explained"'
ok "page: served at /1/ with Last-Modified" 'curl -sI "http://127.0.0.1:$PORT/1/" | grep -qi "^Last-Modified:"'
# security (F1-F4): CSP and headers from the server, Host allowlist, no internal files
hdr=$(curl -sI "http://127.0.0.1:$PORT/1/")
csp=$(printf '%s\n' "$hdr" | tr -d '\r' | awk 'tolower($0) ~ /^content-security-policy:/ { sub(/^[^:]*: */, ""); print }')
ok "csp: sent by the server on pages" '[[ "$csp" == *"default-src '"'none'"'"* ]] && [[ "$csp" == *"connect-src '"'self'"'"* ]] && [[ "$csp" == *"img-src '"'self'"' data:"* ]] && [[ "$csp" == *"form-action '"'none'"'"* ]] && [[ "$csp" == *"frame-ancestors '"'none'"'"* ]]'
ok "csp: scripts only inline + the pinned Mermaid file" '[[ "$csp" == *"script-src '"'unsafe-inline'"' https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js;"* ]] && [[ "$csp" != *"script-src *"* ]] && [[ "$csp" != *"unsafe-eval"* ]]'
ok "csp: also on the library and on errors" 'curl -sI "http://127.0.0.1:$PORT/" | grep -qi "^Content-Security-Policy: default-src" && curl -sI "http://127.0.0.1:$PORT/nope" | grep -qi "^Content-Security-Policy: default-src"'
ok "headers: no-referrer, nosniff" 'printf "%s\n" "$hdr" | grep -qi "^Referrer-Policy: no-referrer" && printf "%s\n" "$hdr" | grep -qi "^X-Content-Type-Options: nosniff"'
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$@"; }
ok "host: foreign Host rejected (DNS rebinding)" '[ "$(code -H "Host: evil.example" "http://127.0.0.1:$PORT/1/")" = 421 ] && [ "$(code -H "Host: explain--shop.example.test.evil.example" "http://127.0.0.1:$PORT/")" = 421 ]'
ok "host: expose host and localhost accepted" '[ "$(code -H "Host: explain--shop.example.test" "http://127.0.0.1:$PORT/1/")" = 200 ] && [ "$(code -H "Host: localhost:$PORT" "http://127.0.0.1:$PORT/1/")" = 200 ] && grep -qx "explain--shop.example.test" $ROOT/.hosts'
ok "internal files not served" 'for u in /launch.sh /.server /.serve.py /.hosts /.reindex /.lock /.ids/ /.ids/1 /1/.meta /1/manifest.tsv /1/../launch.sh /%2e%2e/; do [ "$(code "http://127.0.0.1:$PORT$u")" = 404 ] || exit 1; done'
ok "no directory listing, /<n> redirects to /<n>/" '[ "$(code "http://127.0.0.1:$PORT/2/x/")" = 404 ] && [ "$(code "http://127.0.0.1:$PORT/1")" = 301 ] && [ "$(code "http://127.0.0.1:$PORT/1/index.html")" = 200 ]'
ok "only GET/HEAD" '[ "$(code -X POST "http://127.0.0.1:$PORT/1/")" != 200 ] && [ "$(code -X PUT "http://127.0.0.1:$PORT/1/")" != 200 ]'
ok "private files: root 700, pages 600" '[ "$(stat -c %a $ROOT)" = 700 ] && [ "$(stat -c %a $ROOT/1/index.html)" = 600 ] && [ "$(stat -c %a $ROOT/index.html)" = 600 ] && [ "$(stat -c %a $ROOT/1/.meta)" = 600 ]'
ok "template: pinned Mermaid with SRI, no referrer" 'grep -q "mermaid@11.17.2/dist/mermaid.min.js\" integrity=\"sha384-" $SD/$FID/brief.md && grep -q "referrerpolicy=\"no-referrer\"" $SD/$FID/brief.md && ! grep -q "mermaid@11/" $SD/$FID/brief.md'
ok "brief: share opens the whole library, no secrets" 'grep -q "whole page library" $SD/$FID/brief.md && grep -qi "never secrets" $SD/$FID/brief.md'
l=$($X list); echo "$l"
ok "list: both pages with ids, forks and titles" 'echo "$l" | grep -Eq "^1 +[^ ]+ +$FID +Landing explained" && echo "$l" | grep -Eq "^2 +[^ ]+ +$F2 +Second & last"'
ok "list: server running + URL" 'echo "$l" | grep -q "^server: running on 127.0.0.1:$PORT" && echo "$l" | grep -q "^url: *https://explain--shop.example.test/"'
rm -rf $ROOT/2
o3=$($X open "third topic" --window </dev/null 2>&1)
ok "ids: deleted page id is not reused" '[ "$(echo "$o3" | tail -n1 | cut -d" " -f2)" = 3 ] && [ ! -d $ROOT/2 ]'

# --- worktree: same root and exposure name ---------------------------------
ow=$(cd "$SP/wt-change" && $X open "from the worktree" --window </dev/null 2>&1); FW=$(echo "$ow" | awk '/^fork /{print $2; exit}')
ok "worktree: page under the shop root, same host" '[ "$(echo "$ow" | tail -n1)" = "page 4 https://explain--shop.example.test/4/" ] && [ -f $ROOT/4/.meta ] && [ "$(tagged | wc -l)" -eq 1 ]'
ok "worktree: fork cwd is the worktree" 'grep -qx "cwd=$SP/wt-change" $SD/$FW/meta'

# --- 2.6 share, stop ---------------------------------------------------------
: > $SP/expose.log
s=$($X share --for acme --ttl 3d 2>&1); rc=$?
ok "share: args reach expose.sh" '[ $rc -eq 0 ] && grep -qx "share explain --for acme --ttl 3d" $SP/expose.log'
ok "share: link is the last line" '[ "$(echo "$s" | tail -n1)" = "https://explain--shop.example.test/?opsx_share=tok123" ]'
$X share --revoke acme >/dev/null; $X share --list >/dev/null
ok "share: --revoke / --list pass through" 'grep -qx "share explain --revoke acme" $SP/expose.log && grep -qx "share explain --list" $SP/expose.log'

$F close $FID >/dev/null
cp -r $ROOT/1 $SP/page1.before
st=$($X stop); rc=$?; echo "$st"
ok "stop: exit 0, exposure removed" '[ $rc -eq 0 ] && grep -qx "down explain" $SP/expose.log'
ok "stop: no tagged window left, port closed" '[ -z "$(tagged)" ] && ! answers $PORT'
ok "stop: record removed, pages kept unchanged" '[ ! -f $ROOT/.server ] && [ -f $ROOT/1/index.html ] && diff -r $SP/page1.before $ROOT/1 >/dev/null && [ -f $ROOT/3/index.html ]'
st=$($X stop); rc=$?
ok "stop again: exit 0, not running" '[ $rc -eq 0 ] && [[ "$st" == *"not running"* ]]'
l=$($X list)
ok "list after stop: stopped, pages still listed" 'echo "$l" | grep -q "^server: stopped" && echo "$l" | grep -Eq "^1 +"'

# --- 2.3 expose not configured --------------------------------------------
echo unconfigured > $SP/expose.mode; : > $SP/expose.log
o=$($X open "offline topic" --window </dev/null 2>&1); rc=$?; echo "$o"
NPORT=$(rec port)
ok "unconfigured: expose up was tried" 'grep -q "^up $NPORT --name explain$" $SP/expose.log'
ok "unconfigured: local URL + install hint, fork still opens" '[ $rc -eq 0 ] && [ "$(echo "$o" | tail -n1)" = "page 5 http://127.0.0.1:$NPORT/5/" ] && [[ "$o" == *"install.sh --expose-domain"* ]] && [[ "$o" == *"fork "*" pane %"* ]]'
ok "unconfigured: expose host no longer accepted" '[ ! -s $ROOT/.hosts ] && [ "$(curl -s -o /dev/null -w "%{http_code}" -H "Host: explain--shop.example.test" "http://127.0.0.1:$NPORT/")" = 421 ]'
ok "unconfigured: brief has the local URL" 'FU=$(echo "$o" | awk "/^fork /{print \$2; exit}"); grep -q "http://127.0.0.1:$NPORT/5/" $SD/$FU/brief.md'
s=$($X share --for x 2>&1); rc=$?
ok "unconfigured: share fails with expose's exit 3" '[ $rc -eq 3 ]'
OPSX_EXPOSE_SH=$SP/missing-expose.sh $X stop >/dev/null
ok "stop without expose.sh: still stops" '[ -z "$(tagged)" ] && [ ! -f $ROOT/.server ]'

# --- fork failure discards the page ------------------------------------------
echo ok > $SP/expose.mode
e=$($X open "bad cli" --cli nosuchcli </dev/null 2>&1); rc=$?
ok "fork failure: non-zero, page discarded, id kept" '[ $rc -ne 0 ] && [ ! -d $ROOT/6 ] && [ -f $ROOT/.ids/6 ]'
$X stop >/dev/null
ok "help mentions open/share/list/stop" 'h=$($X help); for w in open share list stop; do [[ "$h" == *"explain.sh $w"* ]] || exit 1; done'

$F close --all >/dev/null 2>&1
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
