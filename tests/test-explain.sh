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
L2="tmux -L explain-test2-$$"
trap '$L kill-server 2>/dev/null; $L2 kill-server 2>/dev/null; rm -rf "$SP"' EXIT

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
[ "\$mode" = slow ] && [ "\$1" = up ] && { : > "$SP/expose.inside"; sleep 2; rm -f "$SP/expose.inside"; }
if [ "\$mode" = fail ] && [ "\$1" = up ]; then echo "expose: caddy admin API timed out" >&2; exit 1; fi
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
# page 1 is the bilingual template itself, with both titles filled in
tpl() { awk '/<!-- explain-page-template -->/ { a = 1; next } a && !i && /^```/ { i = 1; next } i && /^```/ { exit } i { print }' "$REPO/skills/explain/SKILL.md"; }
tpl | sed -e 's/<title>TITLE_EN · TITLE_PT</<title>Landing explained · Como o landing funciona</' | FORK_PAGE_DIR=$ROOT/1 $F page >/dev/null
printf 'P1\tx\n' | FORK_PAGE_DIR=$ROOT/1 $F page --manifest >/dev/null
printf '<!doctype html><html><head><title>Second &amp; last</title></head><body></body></html>\n' | FORK_PAGE_DIR=$ROOT/2 $F page >/dev/null
ok "library: index lists both titles (regenerated by fork.sh page)" 'grep -q "Landing explained" $ROOT/index.html && grep -q "Second &amp; last" $ROOT/index.html && grep -q "href=\"/1/\"" $ROOT/index.html && grep -q "href=\"/2/\"" $ROOT/index.html'
ok "library: served at /" 'curl -s "http://127.0.0.1:$PORT/" | grep -q "Landing explained"'

# --- 7 bilingual pages (EN + PT) --------------------------------------------
tpl > $SP/tpl.html
art() { awk -v l="$1" '$0 ~ "<article lang=\"" l "\"" { a = 1 } a { print } a && /<\/article>/ { exit }' $SP/tpl.html; }
labels() { art "$1" | grep -o 'data-label="[^"]*"'; }
ok "template: one English and one Portuguese article" '[ "$(grep -c "<article lang=\"en\">" $SP/tpl.html)" -eq 1 ] && [ "$(grep -c "<article lang=\"pt\">" $SP/tpl.html)" -eq 1 ]'
ok "template: identical labels in the same order in both" '[ -n "$(labels en)" ] && [ "$(labels en)" = "$(labels pt)" ] && [ "$(labels en | wc -l)" -ge 8 ]'
ok "template: ids equal labels in both articles" 'for l in en pt; do art $l | grep -o "<[a-z]* [^>]*data-label=[^>]*>" | while read -r t; do id=$(echo "$t" | sed -n "s/.* id=\"\([^\"]*\)\".*/\1/p"); dl=$(echo "$t" | sed -n "s/.*data-label=\"\([^\"]*\)\".*/\1/p"); [ "$id" = "$dl" ] || exit 1; done || exit 1; done'
ok "template: a Mermaid diagram in both languages" '[ "$(art en | grep -c "class=\"mermaid\"")" -ge 1 ] && [ "$(art pt | grep -c "class=\"mermaid\"")" -ge 1 ]'
ok "template: EN / PT switch and its script" 'grep -q "data-set-lang=\"en\"" $SP/tpl.html && grep -q "data-set-lang=\"pt\"" $SP/tpl.html && grep -q "localStorage" $SP/tpl.html && grep -q "navigator.language" $SP/tpl.html && grep -q "URLSearchParams(location.search).get(.lang.)" $SP/tpl.html'
ok "template: Mermaid per shown language, not on load" 'grep -q "startOnLoad: false" $SP/tpl.html && grep -q "mermaid.run(" $SP/tpl.html'
ok "template: <title> holds both titles" 'grep -q "<title>TITLE_EN · TITLE_PT</title>" $SP/tpl.html'
ok "template: no external resource besides the pinned Mermaid" '[ "$(grep -oE "(src|href)=\"https?://[^\"]*" $SP/tpl.html | sort -u)" = "src=\"https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js" ]'
ok "brief: both languages in the template note and the protocol" 'grep -q "Languages: English and Portuguese" $SD/$FID/brief.md && grep -q "<article lang=\"pt\">" $SD/$FID/brief.md && sed -n "/^## Page protocol/,\$p" $SD/$FID/brief.md | grep -q "Two languages, one write"'
ok "library: bilingual title listed" 'grep -q "Landing explained · Como o landing funciona" $ROOT/index.html && curl -s "http://127.0.0.1:$PORT/" | grep -q "Como o landing funciona"'
ok "page: bilingual page served with the CSP" 'curl -s "http://127.0.0.1:$PORT/1/" | grep -q "<article lang=\"pt\">" && curl -sI "http://127.0.0.1:$PORT/1/" | grep -qi "^Content-Security-Policy: default-src"'
# the switch and the reload poll as behaviour, node only (no browser needed)
if command -v node >/dev/null 2>&1; then
  so=$(node "$REPO/tests/explain-lang-sim.mjs" lang $SP/tpl.html 2>&1); src=$?; echo "$so"
  ok "sim: language switch, deep links, hand-over by label ($(echo "$so" | grep -c ^PASS) checks)" '[ $src -eq 0 ] && ! echo "$so" | grep -q "^FAIL"'
  so=$(node "$REPO/tests/explain-lang-sim.mjs" poll $SP/tpl.html 2>&1); src=$?; echo "$so"
  ok "sim: page poll ignores errors/redirects, sees a same-second rewrite" '[ $src -eq 0 ] && ! echo "$so" | grep -q "^FAIL"'
  so=$(node "$REPO/tests/explain-lang-sim.mjs" poll $ROOT/index.html 2>&1); src=$?
  ok "sim: library index poll likewise" '[ $src -eq 0 ] && ! echo "$so" | grep -q "^FAIL"'
else
  echo "SKIP sim: no node"
fi
# the switch itself, in a real headless Chromium against the real server (CSP in force)
chrome=${EXPLAIN_TEST_CHROME:-}
if [ -z "$chrome" ]; then
  for c in chromium chromium-browser google-chrome google-chrome-stable "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux/chrome; do
    c=$(command -v "$c" 2>/dev/null || true); [ -n "$c" ] && "$c" --version >/dev/null 2>&1 && { chrome=$c; break; }
  done
fi
if [ -n "$chrome" ] && command -v node >/dev/null 2>&1 && node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null; then
  cp $ROOT/1/index.html $SP/page1.orig
  bo=$(timeout 180 node "$REPO/tests/explain-lang-check.mjs" "$chrome" "http://127.0.0.1:$PORT/1/" "$ROOT/1/index.html" 2>&1); brc=$?
  echo "$bo"
  ok "browser: language switch (headless Chromium, $(echo "$bo" | grep -c ^PASS) checks)" '[ $brc -eq 0 ] && ! echo "$bo" | grep -q "^FAIL"'
  cp $SP/page1.orig $ROOT/1/index.html
else
  echo "SKIP browser: language switch (no runnable Chromium or node >= 22; set EXPLAIN_TEST_CHROME)"
fi
ok "page: served at /1/ with Last-Modified and an ETag" 'curl -sI "http://127.0.0.1:$PORT/1/" | grep -qi "^Last-Modified:" && curl -sI "http://127.0.0.1:$PORT/1/" | grep -qi "^ETag: \"[0-9a-f]\{32\}\""'
# F5: a rewrite in the same second with the same length still changes what the poll compares
hv() { curl -sI "http://127.0.0.1:$PORT/1/" | tr -d '\r' | grep -i "^$1:"; }
cp $ROOT/1/index.html $SP/page1.keep
printf '<html><head><title>x</title></head><body>AAAA</body></html>\n' > $ROOT/1/index.html; touch -d '2026-01-01 00:00:00' $ROOT/1/index.html
e1=$(hv ETag); m1=$(hv Last-Modified); c1=$(hv Content-Length)
printf '<html><head><title>x</title></head><body>BBBB</body></html>\n' > $ROOT/1/index.html; touch -d '2026-01-01 00:00:00' $ROOT/1/index.html
e2=$(hv ETag); m2=$(hv Last-Modified); c2=$(hv Content-Length)
ok "etag: same-second, same-length rewrite changes the ETag" '[ "$m1" = "$m2" ] && [ "$c1" = "$c2" ] && [ -n "$e1" ] && [ "$e1" != "$e2" ]'
cp $SP/page1.keep $ROOT/1/index.html
# F2: /<n> keeps the query
ok "redirect: /1?lang=pt -> /1/?lang=pt" '[ "$(curl -sI "http://127.0.0.1:$PORT/1?lang=pt" | tr -d "\r" | sed -n "s/^Location: //Ip")" = "/1/?lang=pt" ] && [ "$(curl -sI "http://127.0.0.1:$PORT/1" | tr -d "\r" | sed -n "s/^Location: //Ip")" = "/1/" ]'
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
ok "list: both pages with ids, forks and titles" 'echo "$l" | grep -Eq "^1 +[^ ]+ +$FID +Landing explained · Como" && echo "$l" | grep -Eq "^2 +[^ ]+ +$F2 +Second & last"'
ok "list: server running + URL" 'echo "$l" | grep -q "^server: running on 127.0.0.1:$PORT" && echo "$l" | grep -q "^url: *https://explain--shop.example.test/"'
rm -rf $ROOT/2
o3=$($X open "third topic" --window </dev/null 2>&1)
ok "ids: deleted page id is not reused" '[ "$(echo "$o3" | tail -n1 | cut -d" " -f2)" = 3 ] && [ ! -d $ROOT/2 ]'
ok "placeholder: says it in English and Portuguese" 'grep -q "<p lang=\"en\">" $ROOT/3/index.html && grep -q "<p lang=\"pt\">" $ROOT/3/index.html'
if command -v node >/dev/null 2>&1; then
  so=$(node "$REPO/tests/explain-lang-sim.mjs" poll $ROOT/3/index.html 2>&1); src=$?
  ok "sim: placeholder poll ignores errors/redirects" '[ $src -eq 0 ] && ! echo "$so" | grep -q "^FAIL"'
fi

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
PORT=$(rec port)
# --- F1: re-exposure keeps the public host working ---------------------------
pub() { curl -s -o /dev/null -w '%{http_code}' --max-time 2 -H "Host: explain--shop.example.test" "http://127.0.0.1:$PORT/1/"; }
echo slow > $SP/expose.mode; rm -f $SP/expose.inside
$X serve >/dev/null 2>&1 & bg=$!
for _ in $(seq 50); do [ -f $SP/expose.inside ] && break; sleep 0.1; done
during=$(pub); inside=$([ -f $SP/expose.inside ] && echo yes)
wait $bg
ok "re-exposure: the public host answers 200 while expose.sh up runs" '[ "$inside" = yes ] && [ "$during" = 200 ] && [ "$(pub)" = 200 ]'
echo fail > $SP/expose.mode
o=$($X serve 2>&1); rc=$?
ok "re-exposure: a failed up keeps the public host (route may still be live)" '[ $rc -eq 0 ] && [[ "$o" == *"exit 1"* ]] && grep -qx "explain--shop.example.test" $ROOT/.hosts && [ "$(pub)" = 200 ]'
echo ok > $SP/expose.mode; $X serve >/dev/null 2>&1

# --- F5: `--` and stdin ----------------------------------------------------
o=$($X open --window -- "-v is a topic" </dev/null 2>&1); rc=$?; n=$(echo "$o" | tail -n1 | cut -d" " -f2)
ok "open --: a topic starting with - after --" '[ $rc -eq 0 ] && grep -qx "topic=-v is a topic" $ROOT/$n/.meta'
o=$($X -- "--also a topic" --window </dev/null 2>&1); rc=$?
ok "explain.sh -- <topic> --window: everything after -- is the topic" '[ $rc -eq 2 ] && [[ "$o" == *"one topic only"* ]]'
o=$($X -- "--also a topic" </dev/null 2>&1); rc=$?; n=$(echo "$o" | tail -n1 | cut -d" " -f2); FD=$(echo "$o" | awk '/^fork /{print $2; exit}')
ok "explain.sh -- <topic>: opens it" '[ $rc -eq 0 ] && grep -qx "topic=--also a topic" $ROOT/$n/.meta'
$F close $FD >/dev/null 2>&1
o=$($X open --window "a" -- "b" </dev/null 2>&1); rc=$?
ok "open: a second topic after -- refused" '[ $rc -eq 2 ] && [[ "$o" == *"one topic only"* ]]'
t0=$(date +%s)
o=$(EXPLAIN_STDIN_WAIT=1 timeout 30 $X open "idle stdin" --window < <(sleep 40) 2>&1); rc=$?
t1=$(date +%s); n=$(echo "$o" | tail -n1 | cut -d" " -f2); FI=$(echo "$o" | awk '/^fork /{print $2; exit}')
ok "open: an idle non-TTY stdin does not hang it" '[ $rc -eq 0 ] && [ $((t1 - t0)) -lt 15 ] && [[ "$o" == *"no notes on stdin"* ]] && [ -f $ROOT/$n/.meta ]'
o=$(printf '## Focus\n- piped notes arrive\n' | $X open "piped" --window 2>&1); FP=$(echo "$o" | awk '/^fork /{print $2; exit}')
sleep 0.5
ok "open: piped notes still reach the brief" 'grep -q "piped notes arrive" $SD/$FP/brief.md'
$F close $FI >/dev/null 2>&1; $F close $FP >/dev/null 2>&1

# --- F5: a second tmux server reuses the server, never orphans it ------------
env -u TMUX $L2 -f /dev/null new-session -d -s es2 -x 200 -y 50 -c "$SP/shop" 'exec sleep 3000'
sock2=$($L2 display -p '#{socket_path}'); pid2=$($L2 display -p '#{pid}'); P2=$($L2 display -p -t es2 '#{pane_id}')
W=$(rec window); PORT=$(rec port)
o=$(TMUX="$sock2,$pid2,0" TMUX_PANE=$P2 $X serve 2>&1); rc=$?
ok "second tmux server: reuses the running server and says where it is" '[ $rc -eq 0 ] && [ "$(rec window)" = "$W" ] && [ "$(rec port)" = "$PORT" ] && [ -z "$($L2 list-windows -a -F "#{@opsx_explain}" | grep shop)" ] && [[ "$o" == *"another tmux server"* ]]'
l=$(TMUX="$sock2,$pid2,0" TMUX_PANE=$P2 $X list)
ok "second tmux server: list names the server's tmux socket" 'echo "$l" | grep -q "^server: running on 127.0.0.1:$PORT (window $W, tmux server "'
o=$(TMUX="$sock2,$pid2,0" TMUX_PANE=$P2 $X stop 2>&1)
ok "second tmux server: stop reaches the window on the first server" '[ -z "$(tagged)" ] && ! answers $PORT && [ ! -f $ROOT/.server ]'
$X serve >/dev/null 2>&1
o=$(TMUX="$sock2,$pid2,0" TMUX_PANE=$P2 $X serve 2>&1)
$L kill-window -t "$(rec window)" 2>/dev/null; sleep 0.3
o=$(TMUX="$sock2,$pid2,0" TMUX_PANE=$P2 $X serve 2>&1); rc=$?
ok "second tmux server: window gone on the first -> started here, one server" '[ $rc -eq 0 ] && [ -z "$(tagged)" ] && [ "$($L2 list-windows -a -F "#{@opsx_explain}" | grep -c shop)" -eq 1 ] && answers $(rec port)'
TMUX="$sock2,$pid2,0" TMUX_PANE=$P2 $X stop >/dev/null 2>&1
$X serve >/dev/null 2>&1; PORT=$(rec port)

$X stop >/dev/null
ok "help mentions open/share/list/stop" 'h=$($X help); for w in open share list stop; do [[ "$h" == *"explain.sh $w"* ]] || exit 1; done'

$F close --all >/dev/null 2>&1
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
