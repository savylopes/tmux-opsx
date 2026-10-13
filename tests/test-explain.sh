#!/usr/bin/env bash
# Scripted tests for skills/explain/explain.sh.
#
# Runs on a private tmux server (tmux -L explain-test-$$) with fake agent CLIs,
# a fake expose.sh and a scratch XDG_STATE_HOME, so it never touches your tmux
# session, your /expose setup or your pages. Serving is expose's job (a
# directory exposure, tested against a real Caddy in tests/test-expose.sh);
# here the fake expose.sh records what explain.sh asks it to publish.
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
HTTP_PID=""
trap '$L kill-server 2>/dev/null; $L2 kill-server 2>/dev/null; [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null; rm -rf "$SP"' EXIT

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

# fake expose.sh: logs its arguments (one line per call, --csp's value in
# full); behaviour from $SP/expose.mode; $SP/expose.up records a live
# directory exposure (up creates it, down removes it, url needs it).
cat > "$SP/fake-expose.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SP/expose.log"
mode=\$(cat "$SP/expose.mode" 2>/dev/null || echo ok)
if [ "\$mode" = unconfigured ]; then
  echo "expose: not configured — run install.sh --expose-domain <domain> first" >&2
  exit 3
fi
if [ "\$mode" = fail ] && [ "\$1" = up ]; then echo "expose: caddy admin API timed out" >&2; exit 1; fi
case "\$1" in
  up)    shift; dir=""; while [ \$# -gt 0 ]; do case "\$1" in --dir) dir=\$2; shift 2 ;; *) shift ;; esac; done
         printf '%s\n' "\$dir" > "$SP/expose.up"; echo "exposed \$dir at https://explain--shop.example.test"; echo "https://explain--shop.example.test" ;;
  share) shift 2; echo "share link (\$*):"; echo "https://explain--shop.example.test/?opsx_share=tok123" ;;
  down)  if [ -f "$SP/expose.up" ]; then rm -f "$SP/expose.up"; echo "removed https://explain--shop.example.test (\$(cat "$SP/expose.up" 2>/dev/null))"; else echo "nothing matched \$2 in project shop — nothing to remove"; fi ;;
  url)   [ -f "$SP/expose.up" ] || { echo "expose: no exposure named '\$2' in project shop" >&2; exit 1; }; echo "https://explain--shop.example.test" ;;
esac
exit 0
EOF
chmod +x "$SP/fake-expose.sh"
echo ok > "$SP/expose.mode"

export XDG_STATE_HOME=$SP/state
export PATH=$SP/fakebin:$PATH
export OPSX_EXPOSE_SH=$SP/fake-expose.sh
export FORK_HOST_CLI=none
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
# the last `up` line the fake expose.sh logged
last_up() { grep '^up ' "$SP/expose.log" | tail -n1; }
sha() { sha256sum < "$1" | cut -c1-64; }
cd "$SP/shop" || exit 1

# --- 2.1 project and pages root -------------------------------------------
r1=$($X root); r2=$(cd "$SP/wt-change" && $X root)
ok "root: main checkout -> explain/shop" '[ "$r1" = "$ROOT" ]'
ok "root: worktree resolves to the same root" '[ "$r2" = "$ROOT" ]'

# --- 2.2 serve: the directory exposure, no server of its own ---------------
nw=$($L list-windows -a | wc -l)
o=$($X serve 2>&1); rc=$?; echo "$o"
UP=$(last_up)
ok "serve: exit 0, URL is the last line" '[ $rc -eq 0 ] && [ "$(echo "$o" | tail -n1)" = "https://explain--shop.example.test/" ]'
ok "serve: expose.sh up --dir <root> --name explain with the hides and a policy" '[[ "$UP" == "up --dir $ROOT --name explain --hide manifest.tsv --hide *.sha256 --csp "* ]]'
ok "serve: no window, no port, no server files" '[ "$($L list-windows -a | wc -l)" -eq $nw ] && [ -z "$(tagged)" ] && [ ! -e $ROOT/.server ] && [ ! -e $ROOT/launch.sh ] && [ ! -e $ROOT/.serve.py ] && [ ! -e $ROOT/.hosts ]'
ok "serve: library index, its sidecar and .reindex written" '[ -f $ROOT/index.html ] && [ -x $ROOT/.reindex ] && [ "$(cat $ROOT/index.html.sha256)" = "\"$(sha $ROOT/index.html)\"" ]'
: > $SP/expose.log
o=$($X serve 2>&1)
ok "serve again: up --dir called again (idempotent), nothing else created" '[ "$(grep -c "^up " $SP/expose.log)" -eq 1 ] && [ "$($L list-windows -a | wc -l)" -eq $nw ]'

# --- the policy explain asks for ------------------------------------------
csp=${UP#*--csp }
ok "csp: default-src none, connect/img self, no forms or frames" '[[ "$csp" == *"default-src '"'none'"'"* ]] && [[ "$csp" == *"connect-src '"'self'"'"* ]] && [[ "$csp" == *"img-src '"'self'"' data:"* ]] && [[ "$csp" == *"form-action '"'none'"'"* ]] && [[ "$csp" == *"frame-ancestors '"'none'"'"* ]]'
ok "csp: scripts only inline + the pinned Mermaid file" '[[ "$csp" == *"script-src '"'unsafe-inline'"' https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js;"* ]] && [[ "$csp" != *"script-src *"* ]] && [[ "$csp" != *"unsafe-eval"* ]]'
ok "csp: styles and fonts from self and Google Fonts only" '[[ "$csp" == *"style-src '"'self'"' '"'unsafe-inline'"' https://fonts.googleapis.com;"* ]] && [[ "$csp" == *"font-src '"'self'"' data: https://fonts.gstatic.com;"* ]] && [ "$(grep -oE "https?://[^ ;]+" <<<"$csp" | sort -u | wc -l)" -eq 3 ]'

# --- 2.5 open ----------------------------------------------------------------
: > $SP/expose.log
o=$(printf '## Focus\n- the land gate\n' | $X open "how landing works" --window --lang en,pt 2>&1); rc=$?; echo "$o"
FID=$(echo "$o" | awk '/^fork /{print $2; exit}')
ok "open: exit 0, fork line relayed" '[ $rc -eq 0 ] && [[ "$o" == *"fork $FID pane %"* ]]'
ok "open: page URL is the last line and names /1/" '[ "$(echo "$o" | tail -n1)" = "page 1 https://explain--shop.example.test/1/" ]'
ok "open: library line, exposure republished, no window" '[[ "$o" == *"# library: https://explain--shop.example.test/"* ]] && [ "$(grep -c "^up --dir $ROOT --name explain " $SP/expose.log)" -eq 1 ] && [ -z "$(tagged)" ]'
sleep 1.2
ok "open: fork meta page_dir = <root>/1" 'grep -qx "page_dir=$ROOT/1" $SD/$FID/meta'
ok "open: child env FORK_PAGE_DIR" 'grep -qx "FORK_PAGE_DIR=$ROOT/1" $SD/$FID/fake-claude.log'
ok "open: brief has topic, URL, notes" 'grep -q "how landing works" $SD/$FID/brief.md && grep -q "https://explain--shop.example.test/1/" $SD/$FID/brief.md && grep -q "the land gate" $SD/$FID/brief.md'
ok "open: brief has page protocol" 'grep -q "$F page" $SD/$FID/brief.md && grep -q manifest.tsv $SD/$FID/brief.md && grep -q "S P D T C N" $SD/$FID/brief.md && grep -qi mermaid $SD/$FID/brief.md'
ok "open: brief has the HTML template" 'grep -q "data-label" $SD/$FID/brief.md && grep -q "header.hero" $SD/$FID/brief.md && grep -q "Last-Modified" $SD/$FID/brief.md'
ok "open: brief names the design vocabulary and SVG-first diagrams" 'for w in "hero" "key cards" "framed figures" "pills" "callouts" "terms list" "inline SVG first" "Keep the fonts <link>"; do grep -qF -- "$w" $SD/$FID/brief.md || exit 1; done'
ok "open: page .meta records langs=en,pt" 'grep -qx "langs=en,pt" $ROOT/1/.meta'
ok "open: page protocol is the last section" '[ "$(grep "^## " $SD/$FID/brief.md | tail -n1)" = "## Page protocol (fork $FID)" ]'
ok "open: claude page allow rule" 'grep -q "page:" $SD/$FID/launch.sh && grep -qx "ARG=plan" $SD/$FID/fake-claude.log'
ok "open: page .meta (topic, created, fork, session, url)" 'grep -qx "topic=how landing works" $ROOT/1/.meta && grep -q "^created=." $ROOT/1/.meta && grep -qx "fork=$FID" $ROOT/1/.meta && grep -qx "session=es" $ROOT/1/.meta && grep -qx "url=https://explain--shop.example.test/1/" $ROOT/1/.meta'
ok "open: placeholder written with its sidecar" 'grep -q "how landing works" $ROOT/1/index.html && [ "$(cat $ROOT/1/index.html.sha256)" = "\"$(sha $ROOT/1/index.html)\"" ]'

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
sleep 0.5
# --- --lang: English only by default, one article, no switch --------------
brieftpl() { awk '/^```html$/ { a = 1; next } a && /^```$/ { exit } a { print }' "$SD/$1/brief.md"; }
brieftpl $F2 > $SP/tpl-en.html
ok "default --lang: brief says English only, langs=en in .meta" 'grep -q "^- Languages: English only" $SD/$F2/brief.md && grep -qx "langs=en" $ROOT/2/.meta'
ok "default --lang: one <article lang=\"en\">, no switch, English title, no markers" '[ "$(grep -c "<article lang=" $SP/tpl-en.html)" -eq 1 ] && grep -q "<article lang=\"en\">" $SP/tpl-en.html && ! grep -q "data-set-lang=\"" $SP/tpl-en.html && grep -q "<title>TITLE_EN</title>" $SP/tpl-en.html && ! grep -q "article:\|lang-switch" $SP/tpl-en.html'
ok "default --lang: the template keeps the style, the scripts and the fonts link" 'grep -q "header.hero" $SP/tpl-en.html && [ "$(grep -c "<script>" $SP/tpl-en.html)" -eq 2 ] && grep -q "fonts.googleapis.com" $SP/tpl-en.html && [ "$(grep -c "<script src=" $SP/tpl-en.html)" -eq 0 ]'
ok "placeholder: English only for a default page" 'grep -q "<p lang=\"en\">" $ROOT/2/index.html && ! grep -q "<p lang=\"pt\">" $ROOT/2/index.html && grep -q "<html lang=\"en\">" $ROOT/2/index.html && grep -q -- "--display" $ROOT/2/index.html'
if command -v node >/dev/null 2>&1; then
  so=$(node "$REPO/tests/explain-lang-sim.mjs" single $SP/tpl-en.html 2>&1); src=$?; echo "$so"
  ok "sim: single-language page shown whatever is remembered, ids kept ($(echo "$so" | grep -c ^PASS) checks)" '[ $src -eq 0 ] && ! echo "$so" | grep -q "^FAIL"'
fi
nids=$(ls $ROOT/.ids | wc -l)
e=$($X open --lang de "bad lang" --window </dev/null 2>&1); rc=$?
ok "--lang de: exit 2 naming the accepted values, no id allocated" '[ $rc -eq 2 ] && [[ "$e" == *"en, pt, en,pt"* ]] && [ "$(ls $ROOT/.ids | wc -l)" -eq $nids ]'
e=$($X open --lang "bad lang" --window </dev/null 2>&1); rc=$?
ok "--lang without a value set: exit 2" '[ $rc -eq 2 ]'
# page 1 is the bilingual template itself, with both titles filled in
tpl() { awk '/<!-- explain-page-template -->/ { a = 1; next } a && !i && /^```/ { i = 1; next } i && /^```/ { exit } i { print }' "$REPO/skills/explain/SKILL.md"; }
tpl | sed -e 's/<title>TITLE_EN · TITLE_PT</<title>Landing explained · Como o landing funciona</' | FORK_PAGE_DIR=$ROOT/1 $F page >/dev/null
printf 'P1\tx\n' | FORK_PAGE_DIR=$ROOT/1 $F page --manifest >/dev/null
printf '<!doctype html><html><head><title>Second &amp; last</title></head><body></body></html>\n' | FORK_PAGE_DIR=$ROOT/2 $F page >/dev/null
ok "library: index lists both titles (regenerated by fork.sh page)" 'grep -q "Landing explained" $ROOT/index.html && grep -q "Second &amp; last" $ROOT/index.html && grep -q "href=\"/1/\"" $ROOT/index.html && grep -q "href=\"/2/\"" $ROOT/index.html'
ok "library: same design tokens and fonts as the pages" 'grep -q -- "--display" $ROOT/index.html && grep -q "fonts.googleapis.com" $ROOT/index.html && grep -q "class=\"eyebrow\"" $ROOT/index.html'
ok "sidecars: every page and the index have the hash of their content, mode 600" 'for f in $ROOT/index.html $ROOT/1/index.html $ROOT/2/index.html; do [ "$(cat $f.sha256)" = "\"$(sha $f)\"" ] && [ "$(stat -c %a $f.sha256)" = 600 ] || exit 1; done'
# a rewrite in the same second with the same length still changes the sidecar
printf '<html><head><title>x</title></head><body>AAAA</body></html>\n' | FORK_PAGE_DIR=$ROOT/2 $F page >/dev/null; s1=$(cat $ROOT/2/index.html.sha256)
printf '<html><head><title>x</title></head><body>BBBB</body></html>\n' | FORK_PAGE_DIR=$ROOT/2 $F page >/dev/null; s2=$(cat $ROOT/2/index.html.sha256)
ok "sidecars: same-length rewrite -> different ETag value" '[ -n "$s1" ] && [ "$s1" != "$s2" ] && [ "$s2" = "\"$(sha $ROOT/2/index.html)\"" ]'
printf '<!doctype html><html><head><title>Second &amp; last</title></head><body></body></html>\n' | FORK_PAGE_DIR=$ROOT/2 $F page >/dev/null

# --- 7 bilingual pages (EN + PT) --------------------------------------------
tpl > $SP/tpl.html
art() { awk -v l="$1" '$0 ~ "<article lang=\"" l "\"" { a = 1 } a { print } a && /<\/article>/ { exit }' $SP/tpl.html; }
labels() { art "$1" | grep -o 'data-label="[^"]*"'; }
ok "template: one English and one Portuguese article" '[ "$(grep -c "<article lang=\"en\">" $SP/tpl.html)" -eq 1 ] && [ "$(grep -c "<article lang=\"pt\">" $SP/tpl.html)" -eq 1 ]'
ok "template: identical labels in the same order in both" '[ -n "$(labels en)" ] && [ "$(labels en)" = "$(labels pt)" ] && [ "$(labels en | wc -l)" -ge 8 ]'
ok "template: ids equal labels in both articles" 'for l in en pt; do art $l | grep -o "<[a-z]* [^>]*data-label=[^>]*>" | while read -r t; do id=$(echo "$t" | sed -n "s/.* id=\"\([^\"]*\)\".*/\1/p"); dl=$(echo "$t" | sed -n "s/.*data-label=\"\([^\"]*\)\".*/\1/p"); [ "$id" = "$dl" ] || exit 1; done || exit 1; done'
ok "template: a framed SVG figure in both languages, marker ids per language" '[ "$(art en | grep -c "<svg viewBox=")" -ge 3 ] && [ "$(art pt | grep -c "<svg viewBox=")" -ge 3 ] && art en | grep -q "role=\"img\" aria-label=" && art en | grep -q "id=\"arrow-en-1\"" && art pt | grep -q "id=\"arrow-pt-1\""'
ok "template: the design elements" 'for w in "header.hero" ".eyebrow" ".lede" ".key" "figure .frame" ".pair" ".pill" ".callout" ".callout.warn" ".callout.bad" "dl.terms" "footer" "--display" "--body" "--mono" "prefers-color-scheme:dark" "[data-label]::before"; do grep -qF -- "$w" $SP/tpl.html || { echo "missing $w"; exit 1; }; done'
ok "template: no Mermaid script by default, pinned tag given in the brief" '[ "$(grep -c "<script src=" $SP/tpl.html)" -eq 0 ] && grep -q "A page without Mermaid must not carry that tag" $SD/$FID/brief.md'
ok "template: EN / PT switch and its script" 'grep -q "data-set-lang=\"en\"" $SP/tpl.html && grep -q "data-set-lang=\"pt\"" $SP/tpl.html && grep -q "localStorage" $SP/tpl.html && grep -q "navigator.language" $SP/tpl.html && grep -q "URLSearchParams(location.search).get(.lang.)" $SP/tpl.html'
ok "template: Mermaid per shown language, not on load" 'grep -q "startOnLoad: false" $SP/tpl.html && grep -q "mermaid.run(" $SP/tpl.html'
ok "template: <title> holds both titles" 'grep -q "<title>TITLE_EN · TITLE_PT</title>" $SP/tpl.html'
ok "template: no external resource besides the Google Fonts stylesheet" '[ "$(grep -oE "(src|href)=\"https?://[^\"/]*" $SP/tpl.html | sort -u)" = "href=\"https://fonts.googleapis.com" ]'
ok "brief: both languages in the template note, the protocol defers to the Languages: line" 'grep -q "Languages: English and Portuguese" $SD/$FID/brief.md && grep -q "<article lang=\"pt\">" $SD/$FID/brief.md && sed -n "/^## Page protocol/,\$p" $SD/$FID/brief.md | grep -q "Languages:" && sed -n "/^## Page protocol/,\$p" $SD/$FID/brief.md | grep -q "inline SVG"'
ok "library: bilingual title listed" 'grep -q "Landing explained · Como o landing funciona" $ROOT/index.html'
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
# the switch itself, in a real headless Chromium against the pages root served by a
# test-local static server (the CSP is the proxy's business: tests/test-expose.sh)
chrome=${EXPLAIN_TEST_CHROME:-}
if [ -z "$chrome" ]; then
  for c in chromium chromium-browser google-chrome google-chrome-stable "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux/chrome; do
    c=$(command -v "$c" 2>/dev/null || true); [ -n "$c" ] && "$c" --version >/dev/null 2>&1 && { chrome=$c; break; }
  done
fi
if [ -n "$chrome" ] && command -v node >/dev/null 2>&1 && node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null; then
  HPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  (cd "$ROOT" && exec python3 -m http.server "$HPORT" --bind 127.0.0.1 >/dev/null 2>&1) & HTTP_PID=$!
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$HPORT") 2>/dev/null && break; sleep 0.1; done
  cp $ROOT/1/index.html $SP/page1.orig
  bo=$(timeout 180 node "$REPO/tests/explain-lang-check.mjs" "$chrome" "http://127.0.0.1:$HPORT/1/" "$ROOT/1/index.html" 2>&1); brc=$?
  echo "$bo"
  ok "browser: language switch (headless Chromium, $(echo "$bo" | grep -c ^PASS) checks)" '[ $brc -eq 0 ] && ! echo "$bo" | grep -q "^FAIL"'
  cp $SP/page1.orig $ROOT/1/index.html
  kill "$HTTP_PID" 2>/dev/null; HTTP_PID=""
else
  echo "SKIP browser: language switch (no runnable Chromium or node >= 22; set EXPLAIN_TEST_CHROME)"
fi
ok "private files: root 700, pages and meta 600" '[ "$(stat -c %a $ROOT)" = 700 ] && [ "$(stat -c %a $ROOT/1/index.html)" = 600 ] && [ "$(stat -c %a $ROOT/index.html)" = 600 ] && [ "$(stat -c %a $ROOT/1/.meta)" = 600 ]'
ok "template: pinned Mermaid with SRI, no referrer" 'grep -q "mermaid@11.17.2/dist/mermaid.min.js\" integrity=\"sha384-" $SD/$FID/brief.md && grep -q "referrerpolicy=\"no-referrer\"" $SD/$FID/brief.md && ! grep -q "mermaid@11/" $SD/$FID/brief.md'
ok "brief: share opens the whole library, no secrets" 'grep -q "whole page library" $SD/$FID/brief.md && grep -qi "never secrets" $SD/$FID/brief.md'
l=$($X list); echo "$l"
ok "list: both pages with ids, forks and titles" 'echo "$l" | grep -Eq "^1 +[^ ]+ +$FID +Landing explained · Como" && echo "$l" | grep -Eq "^2 +[^ ]+ +$F2 +Second & last"'
ok "list: pages root + exposed URL" 'echo "$l" | grep -q "^pages: *$ROOT$" && echo "$l" | grep -q "^exposed: https://explain--shop.example.test/$"'
rm -rf $ROOT/2
o3=$($X open "third topic" --window --lang pt </dev/null 2>&1); F3=$(echo "$o3" | awk '/^fork /{print $2; exit}')
ok "ids: deleted page id is not reused" '[ "$(echo "$o3" | tail -n1 | cut -d" " -f2)" = 3 ] && [ ! -d $ROOT/2 ]'
ok "placeholder: Portuguese only for --lang pt" 'grep -q "<p lang=\"pt\">" $ROOT/3/index.html && ! grep -q "<p lang=\"en\">" $ROOT/3/index.html && grep -q "<html lang=\"pt\">" $ROOT/3/index.html && grep -qx "langs=pt" $ROOT/3/.meta'
sleep 0.5
brieftpl $F3 > $SP/tpl-pt.html
ok "--lang pt: brief says Portuguese only, one <article lang=\"pt\">, Portuguese title, html lang" 'grep -q "^- Languages: Portuguese only" $SD/$F3/brief.md && [ "$(grep -c "<article lang=" $SP/tpl-pt.html)" -eq 1 ] && grep -q "<article lang=\"pt\">" $SP/tpl-pt.html && grep -q "<title>TITLE_PT</title>" $SP/tpl-pt.html && grep -q "<html lang=\"pt\">" $SP/tpl-pt.html && ! grep -q "data-set-lang=\"" $SP/tpl-pt.html'
if command -v node >/dev/null 2>&1; then
  so=$(node "$REPO/tests/explain-lang-sim.mjs" single $SP/tpl-pt.html 2>&1); src=$?
  ok "sim: Portuguese-only page likewise" '[ $src -eq 0 ] && ! echo "$so" | grep -q "^FAIL"'
  so=$(node "$REPO/tests/explain-lang-sim.mjs" poll $ROOT/3/index.html 2>&1); src=$?
  ok "sim: placeholder poll ignores errors/redirects" '[ $src -eq 0 ] && ! echo "$so" | grep -q "^FAIL"'
fi

# --- worktree: same root and exposure name ---------------------------------
ow=$(cd "$SP/wt-change" && $X open "from the worktree" --window </dev/null 2>&1); FW=$(echo "$ow" | awk '/^fork /{print $2; exit}')
ok "worktree: page under the shop root, same host" '[ "$(echo "$ow" | tail -n1)" = "page 4 https://explain--shop.example.test/4/" ] && [ -f $ROOT/4/.meta ] && [ "$(last_up)" = "$UP" ]'
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
# leftovers of the old server-based explain are cleaned up by stop
printf 'port=4100\nwindow=@9999\npid=\n' > $ROOT/.server; : > $ROOT/.hosts; : > $ROOT/launch.sh; : > $ROOT/.serve.py
st=$($X stop); rc=$?; echo "$st"
ok "stop: exit 0, exposure removed (down explain)" '[ $rc -eq 0 ] && grep -qx "down explain" $SP/expose.log && [[ "$st" == *"exposure for shop removed"* ]]'
ok "stop: old server files removed, pages kept unchanged" '[ ! -e $ROOT/.server ] && [ ! -e $ROOT/.hosts ] && [ ! -e $ROOT/launch.sh ] && [ ! -e $ROOT/.serve.py ] && [ -f $ROOT/1/index.html ] && diff -r $SP/page1.before $ROOT/1 >/dev/null && [ -f $ROOT/3/index.html ]'
st=$($X stop); rc=$?
ok "stop again: exit 0, says not exposed" '[ $rc -eq 0 ] && [[ "$st" == *"not exposed"* ]]'
l=$($X list)
ok "list after stop: exposed: no, pages still listed" 'echo "$l" | grep -q "^exposed: no" && echo "$l" | grep -Eq "^1 +"'

# --- 2.3 expose not configured --------------------------------------------
echo unconfigured > $SP/expose.mode; : > $SP/expose.log
o=$($X open "offline topic" --window </dev/null 2>&1); rc=$?; echo "$o"
ok "unconfigured: expose up --dir was tried" 'grep -q "^up --dir $ROOT --name explain " $SP/expose.log'
ok "unconfigured: file path + install hint, fork still opens" '[ $rc -eq 0 ] && [ "$(echo "$o" | tail -n1)" = "page 5 $ROOT/5/index.html" ] && [[ "$o" == *"install.sh --expose-domain"* ]] && [[ "$o" == *"# local only"* ]] && [[ "$o" == *"fork "*" pane %"* ]]'
ok "unconfigured: brief has the file path and says nothing serves it" 'FU=$(echo "$o" | awk "/^fork /{print \$2; exit}"); grep -q "Page URL: $ROOT/5/index.html" $SD/$FU/brief.md && grep -q "nothing serves it" $SD/$FU/brief.md'
s=$($X share --for x 2>&1); rc=$?
ok "unconfigured: share fails with expose's exit 3" '[ $rc -eq 3 ]'
l=$($X list)
ok "unconfigured: list says expose is not configured" 'echo "$l" | grep -q "^exposed: no (expose is not configured)"'
st=$(OPSX_EXPOSE_SH=$SP/missing-expose.sh $X stop); rc=$?
ok "stop without expose.sh: exit 0" '[ $rc -eq 0 ]'
o=$(OPSX_EXPOSE_SH=$SP/missing-expose.sh $X serve 2>&1); rc=$?
ok "serve without expose.sh: exit 0, file path, hint" '[ $rc -eq 0 ] && [ "$(echo "$o" | tail -n1)" = "$ROOT/index.html" ] && [[ "$o" == *"not configured"* ]]'

# --- a failing up: the page is still written, as a file --------------------
echo fail > $SP/expose.mode; : > $SP/expose.log
o=$($X open "failing expose" --window </dev/null 2>&1); rc=$?
ok "up fails: open still succeeds with the file path and says why" '[ $rc -eq 0 ] && [ "$(echo "$o" | tail -n1)" = "page 6 $ROOT/6/index.html" ] && [[ "$o" == *"exit 1"* ]]'
echo ok > $SP/expose.mode

# --- fork failure discards the page ------------------------------------------
e=$($X open "bad cli" --cli nosuchcli </dev/null 2>&1); rc=$?
ok "fork failure: non-zero, page discarded, id kept" '[ $rc -ne 0 ] && [ ! -d $ROOT/7 ] && [ -f $ROOT/.ids/7 ]'

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

# --- a second tmux server: nothing to reuse, serve works the same ------------
env -u TMUX $L2 -f /dev/null new-session -d -s es2 -x 200 -y 50 -c "$SP/shop" 'exec sleep 3000'
sock2=$($L2 display -p '#{socket_path}'); pid2=$($L2 display -p '#{pid}'); P2=$($L2 display -p -t es2 '#{pane_id}')
: > $SP/expose.log
o=$(TMUX="$sock2,$pid2,0" TMUX_PANE=$P2 $X serve 2>&1); rc=$?
ok "second tmux server: serve publishes the same root, no tmux state involved" '[ $rc -eq 0 ] && [ "$(echo "$o" | tail -n1)" = "https://explain--shop.example.test/" ] && grep -q "^up --dir $ROOT --name explain " $SP/expose.log && [ -z "$($L2 list-windows -a -F "#{@opsx_explain}" | grep shop)" ]'

$X stop >/dev/null
ok "help mentions open/share/list/stop and --lang" 'h=$($X help); for w in "explain.sh open" "explain.sh share" "explain.sh list" "explain.sh stop" "--lang"; do [[ "$h" == *"$w"* ]] || exit 1; done'

$F close --all >/dev/null 2>&1
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
