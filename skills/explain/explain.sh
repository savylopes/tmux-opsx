#!/usr/bin/env bash
# explain.sh — exposure and page library for the /explain skill.
#
# /explain turns a topic from the current agent session into a designed,
# diagrammed, addressable web page. A read-only fork (fork.sh open
# --page-dir) writes the page; this script keeps the project's pages in one
# directory and publishes that directory through /expose, which serves it
# with Caddy's file server behind the expose login.
#
# Usage:
#   explain.sh open "<topic>" [--lang en|pt|en,pt] [--window] [--vertical]
#                   [--cli <c>] [--model <m>] [--parent-model <m>] [--brief-only]
#                   [-- "<topic>"]  [< brief]
#   explain.sh native [--cli <c>] [--brief-only]    (= fork.sh native)
#   explain.sh serve                    publish the pages root, print its URL
#   explain.sh share [--for <r>] [--ttl <d>] [--list] [--revoke <r|id|all>]
#   explain.sh list                     pages, exposure state and URL
#   explain.sh stop                     remove the exposure, keep pages
#   explain.sh root                     print the pages root
#   explain.sh help
#
# `open` reads the parent's brief notes on stdin (optional; when stdin is not a
# TTY it waits up to $EXPLAIN_STDIN_WAIT s, default 3, for the first byte, so an
# idle inherited stdin does not hang it), adds the topic, the page URL, the
# languages (--lang, default en: one article and no switch; en,pt: both
# articles and the EN / PT switch) and the HTML template from SKILL.md cut
# down to those languages (unless the notes already carry a template), and
# opens the fork with `fork.sh open --page-dir <root>/<id>`. The page URL is
# the last line of its output.
#
# Project: the folder name of the main checkout of the current git
# repository (the same for every worktree), else the current directory's name
# — computed exactly like expose.sh.
#
# Pages root: ${XDG_STATE_HOME:-~/.local/state}/agent-forks/explain/<project>/
#   .ids/<n>          page id allocation (noclobber; ids are never reused)
#   .reindex          regenerates index.html and the .sha256 sidecars; run by
#                     `fork.sh page` after every page write
#   .lock             serialises id allocation
#   index.html        library index (id, title, created, fork)
#   index.html.sha256 the index's content hash, served as its ETag
#   <n>/index.html    page <n>; <n>/index.html.sha256 its ETag;
#                     <n>/manifest.tsv its labels; <n>/.meta (topic, created,
#                     fork, session, langs, url)
# The root is mode 700 and every file this skill writes is private (umask 077).
#
# Serving: `expose.sh up --dir <root> --name explain --hide manifest.tsv
# --hide '*.sha256' --csp <policy>` on every `open` and `serve` (idempotent;
# it also restores a route the proxy lost). Caddy then serves the root at
# https://explain--<project>.<domain>/ behind the expose login: only regular
# files, never dotfiles (.ids, .lock, .reindex, .meta), manifests or
# sidecars, no directory listing, /<n> redirected to /<n>/ with its query,
# ETag from the .sha256 sidecar (so the reload poll sees a same-second
# rewrite), Last-Modified, and on every response the strict
# Content-Security-Policy below (inline scripts and the pinned Mermaid file
# only; styles and fonts from the page and Google Fonts; connect/img 'self'
# or data:; no forms, frames or objects), Referrer-Policy: no-referrer and
# nosniff: the page is fork-written, so these controls live in the proxy,
# not in the page. expose.sh is $OPSX_EXPOSE_SH, else ../expose/expose.sh
# next to this skill, else expose.sh on PATH. Without a configured /expose
# nothing is served: `open` prints the page's file path with the
# `install.sh --expose-domain` hint and the fork still opens.
#
# Exit codes: 0 ok, 1 error, 2 usage (e.g. no topic), 3 expose not configured
# (share only).

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXPOSE_NAME=explain
STDIN_WAIT=${EXPLAIN_STDIN_WAIT:-3}
# Mermaid, pinned to one file with its SRI hash (npm mermaid@11.17.2,
# dist/mermaid.min.js). The CSP allows exactly this URL; the brief tells the
# fork to add this tag only to a page that uses Mermaid — change both
# together. Fonts come from Google Fonts (the template's <link>); the CSP
# allows exactly these two hosts for styles and fonts.
MERMAID_URL=https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js
MERMAID_SRI=sha384-EOXBFmc3gx5mb+vn0vPvvGqACToJD24hhacX5Yx+8NUUQrHIle/Qi5Bg9o3zKwW2
FONT_CSS_HOST=https://fonts.googleapis.com
FONT_HOST=https://fonts.gstatic.com
EXPLAIN_CSP="default-src 'none'; script-src 'unsafe-inline' $MERMAID_URL; style-src 'self' 'unsafe-inline' $FONT_CSS_HOST; img-src 'self' data:; font-src 'self' data: $FONT_HOST; connect-src 'self'; media-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; manifest-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

umask 077

die() { printf 'explain: %s\n' "$1" >&2; exit "${2:-1}"; }
note() { printf 'explain: %s\n' "$1" >&2; }

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# ---------------------------------------------------------------------------
# project and paths

# Same as expose.sh default_project: the main checkout's folder, else $PWD's.
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

PROJECT=$(default_project)
case "$PROJECT" in ''|.|..|*[[:cntrl:]]*) PROJECT=_$(printf '%s' "$PROJECT" | tr -d '[:cntrl:]') ;; esac
ROOT=${XDG_STATE_HOME:-$HOME/.local/state}/agent-forks/explain/$PROJECT

# ---------------------------------------------------------------------------
# tmux (pattern from fork.sh: some CLIs strip $TMUX / $TMUX_PANE)

recover_env_var() {
  local name=$1 pid=$$ i=0 val
  while [ "$pid" -gt 1 ] && [ "$i" -lt 30 ]; do
    if [ -r "/proc/$pid/environ" ]; then
      val=$({ tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null \
            | awk -v n="$name" 'index($0, n "=") == 1 { print substr($0, length(n) + 2); exit }')
      if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
    i=$((i + 1))
  done
  return 1
}

recover_tmux_env() {
  local v sock
  if [ -z "${TMUX:-}" ] && v=$(recover_env_var TMUX); then
    sock=${v%%,*}
    if [ -z "$sock" ] || [ -S "$sock" ]; then TMUX=$v; export TMUX; fi
  fi
  if [ -n "${TMUX:-}" ] && [ -z "${TMUX_PANE:-}" ] && v=$(recover_env_var TMUX_PANE); then
    TMUX_PANE=$v; export TMUX_PANE
  fi
}

tmux_ok() {
  command -v tmux >/dev/null 2>&1 || return 1
  recover_tmux_env
  [ -n "${TMUX:-}" ] && tmux display-message -p '#{pid}' >/dev/null 2>&1
}

require_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux is not installed."
  tmux_ok || die "tmux is required — run your agent inside a tmux session to use /explain."
}

current_session() {
  local s=""
  [ -n "${TMUX_PANE:-}" ] && s=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
  [ -n "$s" ] || s=$(tmux display-message -p '#S' 2>/dev/null)
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# helper scripts

find_fork() {
  local c
  for c in "${EXPLAIN_FORK_SH:-}" "$SELF_DIR/../fork/fork.sh" \
           "$HOME/.claude/skills/fork/fork.sh" "$HOME/.cursor/skills/fork/fork.sh" \
           "$HOME/.agents/skills/fork/fork.sh" "${CODEX_HOME:-$HOME/.codex}/skills/fork/fork.sh" \
           "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills/fork/fork.sh" \
           "$HOME/.gemini/skills/fork/fork.sh"; do
    [ -n "$c" ] && [ -x "$c" ] && { (cd -- "$(dirname -- "$c")" && printf '%s/fork.sh' "$(pwd)"); return 0; }
  done
  c=$(command -v fork.sh 2>/dev/null) && [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}

EXPOSE=""
find_expose() {
  EXPOSE=""
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

HINT='expose is not configured — nothing serves the pages; run install.sh --expose-domain <domain> to get a login-protected URL you can open on any device and share.'

strip_osc8() { sed -e 's/\x1b]8;;[^\x07\x1b]*\(\x07\|\x1b\\\)//g'; }

# ---------------------------------------------------------------------------
# meta files: key=value lines

meta_get() {
  [ -f "$2" ] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$2"
}

meta_set() {
  local key=$1 val=$2 file=$3 tmp
  val=$(printf '%s' "$val" | tr '\n\r' '  ')
  tmp=$(mktemp "$file.XXXXXX") || return 1
  [ -f "$file" ] && awk -v k="$key" 'index($0, k "=") != 1' "$file" > "$tmp"
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv -f "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# pages root, library index

# The library index generator. Kept self-contained: fork.sh runs it after
# every page write, from the fork child's sandbox. It also writes the
# .sha256 sidecar of the index and of every page (the ETag the proxy serves).
write_reindex() {
  local tmp
  tmp=$(mktemp "$ROOT/.reindex.XXXXXX") || die "cannot write $ROOT/.reindex"
  cat > "$tmp" <<'REINDEX'
#!/usr/bin/env bash
# .reindex — regenerates the /explain library index (index.html) of this
# directory and the <file>.sha256 sidecars (quoted sha256 of index.html, the
# ETag Caddy serves for it). Written by explain.sh; run by `fork.sh page`
# after a page write.
set -u
umask 077
root=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
meta() { [ -f "$2" ] || return 0; awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$2"; }
title_of() { [ -f "$1" ] || return 0; tr '\n\r' '  ' < "$1" | sed -n 's/.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\([^<]*\)<\/[Tt][Ii][Tt][Ll][Ee]>.*/\1/p' | cut -c1-200; }
ids() { local d; for d in "$root"/*/; do d=${d%/}; d=${d##*/}; case "$d" in ''|*[!0-9]*) ;; *) printf '%s\n' "$d" ;; esac; done | sort -rn; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64; else shasum -a 256 < "$1" | cut -c1-64; fi; }
# sidecar <file>: <file>.sha256 holds "<sha256>" (a strong ETag), replaced atomically.
sidecar() { local f=$1 h t; [ -f "$f" ] || return 0; h=$(sha "$f") || return 0; [ -n "$h" ] || return 0
  t=$(mktemp "$f.sha256.XXXXXX") || return 0; printf '"%s"' "$h" > "$t" && chmod 600 "$t" && mv -f "$t" "$f.sha256"; }
rows=""
for n in $(ids); do
  t=$(title_of "$root/$n/index.html")          # text between <title> tags: no '<'
  [ -n "${t//[[:space:]]/}" ] || t=$(meta topic "$root/$n/.meta" | esc)
  c=$(meta created "$root/$n/.meta" | esc)
  f=$(meta fork "$root/$n/.meta" | esc)
  rows="$rows<tr id=\"page-$n\"><td><a href=\"/$n/\">$n</a></td><td><a href=\"/$n/\">${t:-page $n}</a></td><td>${c:--}</td><td>${f:--}</td></tr>
"
  sidecar "$root/$n/index.html"
done
[ -n "$rows" ] || rows='<tr><td colspan="4">No pages yet.</td></tr>
'
proj=$(basename -- "$root" | esc)
tmp=$(mktemp "$root/.index.XXXXXX") || exit 1
cat > "$tmp" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Explain — $proj</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Red+Hat+Display:wght@600;700&family=Red+Hat+Text:wght@400;500&family=Red+Hat+Mono:wght@400;500&display=swap">
<style>
:root{color-scheme:light;--bg:#f5f7fa;--surface:#fff;--fg:#1a2230;--muted:#5a6577;--line:#d5dbe4;--accent:#0e7a89;--accent-soft:#e2f2f4;
--display:"Red Hat Display","Segoe UI",system-ui,sans-serif;--body:"Red Hat Text","Segoe UI",system-ui,sans-serif;--mono:"Red Hat Mono",ui-monospace,"SF Mono",Menlo,monospace}
@media (prefers-color-scheme:dark){:root{--bg:#10151c;--surface:#171e27;--fg:#e5e9f0;--muted:#98a3b4;--line:#2a3441;--accent:#3fb8c8;--accent-soft:#10303a;color-scheme:dark}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--body);font-size:16px;line-height:1.6}
.wrap{max-width:880px;margin:0 auto;padding:40px 20px 72px}
header{border-bottom:1px solid var(--line);padding-bottom:24px;margin-bottom:28px}
.eyebrow{font-family:var(--mono);font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 0 10px}
h1{font-family:var(--display);font-weight:700;font-size:clamp(28px,5vw,40px);line-height:1.1;margin:0;letter-spacing:-.01em}
.tscroll{overflow-x:auto;background:var(--surface);border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:15px}th,td{text-align:left;vertical-align:top;padding:10px 14px;border-bottom:1px solid var(--line)}
tr:last-child td{border-bottom:0}th{font-family:var(--mono);font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);font-weight:500}
td:first-child,td:nth-child(3),td:nth-child(4){font-family:var(--mono);font-size:13px;color:var(--muted);white-space:nowrap}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}td:nth-child(2) a{font-family:var(--display);font-weight:600;color:var(--fg)}
</style>
</head>
<body>
<div class="wrap">
<header><p class="eyebrow">explain · $proj</p><h1>Pages</h1></header>
<div class="tscroll">
<table>
<thead><tr><th>ID</th><th>Title</th><th>Created</th><th>Fork</th></tr></thead>
<tbody>
$rows</tbody>
</table>
</div>
</div>
<script>
(function(){var last=null;function poll(){fetch(location.pathname,{method:'HEAD',cache:'no-store'}).then(function(r){if(r.ok&&!r.redirected){var m=[r.headers.get('ETag'),r.headers.get('Last-Modified'),r.headers.get('Content-Length')].join('|');if(last!==null&&m!==last){location.reload();return}last=m}setTimeout(poll,2000)}).catch(function(){setTimeout(poll,2000)})}poll()})();
</script>
</body>
</html>
EOF
chmod 600 "$tmp" && mv -f "$tmp" "$root/index.html"
sidecar "$root/index.html"
REINDEX
  { chmod 755 "$tmp" && mv -f "$tmp" "$ROOT/.reindex"; } || die "cannot write $ROOT/.reindex"
}

ensure_root() {
  mkdir -p "$ROOT/.ids" || die "cannot create $ROOT"
  chmod 700 "$ROOT" 2>/dev/null
  write_reindex
  [ -f "$ROOT/index.html" ] || "$ROOT/.reindex" >/dev/null 2>&1
}

reindex() { [ -x "$ROOT/.reindex" ] && "$ROOT/.reindex" >/dev/null 2>&1; return 0; }

# Numeric page ids under the root, ascending.
page_ids() {
  local d
  [ -d "$ROOT" ] || return 0
  for d in "$ROOT"/*/; do
    d=${d%/}; d=${d##*/}
    case "$d" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$d"
  done | sort -n
}

# Allocate the next page id: .ids/<n> claimed with noclobber (O_EXCL), never
# reused even after the page directory is deleted.
alloc_id() {
  local n max f
  max=$( { page_ids
           for f in "$ROOT"/.ids/*; do f=${f##*/}; case "$f" in ''|*[!0-9]*) ;; *) printf '%s\n' "$f" ;; esac; done
         } | sort -n | tail -n 1)
  n=$(( ${max:-0} + 1 ))
  while ! ( set -C; : > "$ROOT/.ids/$n" ) 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -gt 100000 ] && die "could not allocate a page id under $ROOT"
  done
  mkdir -p "$ROOT/$n" || die "cannot create $ROOT/$n"
  printf '%s' "$n"
}

html_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# Placeholder shown until the fork writes the page; it reloads itself. $3 is
# the page's language set (en | pt | en,pt): the waiting line follows it.
write_placeholder() {
  local n=$1 topic tmp langs=${3:-en} html_lang=en lines=""
  topic=$(html_esc "$2")
  case "$langs" in
    pt) html_lang=pt ;;
  esac
  case "$langs" in
    *en*) lines='<p lang="en">The fork is writing this page. It appears here as soon as it is written.</p>' ;;
  esac
  case "$langs" in
    *pt*) lines="$lines${lines:+
}"'<p lang="pt">O fork está escrevendo esta página. Ela aparece aqui assim que for escrita.</p>' ;;
  esac
  tmp=$(mktemp "$ROOT/$n/.page.XXXXXX") || return 0
  cat > "$tmp" <<EOF
<!doctype html>
<html lang="$html_lang">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$topic</title>
<style>
:root{color-scheme:light;--bg:#f5f7fa;--fg:#1a2230;--muted:#5a6577;--line:#d5dbe4;--display:"Red Hat Display","Segoe UI",system-ui,sans-serif;--body:"Red Hat Text","Segoe UI",system-ui,sans-serif;--mono:"Red Hat Mono",ui-monospace,"SF Mono",Menlo,monospace}
@media (prefers-color-scheme:dark){:root{--bg:#10151c;--fg:#e5e9f0;--muted:#98a3b4;--line:#2a3441;color-scheme:dark}}
body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--body);font-size:16px;line-height:1.6}
.wrap{max-width:680px;margin:0 auto;padding:64px 20px}.eyebrow{font-family:var(--mono);font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 0 12px}
h1{font-family:var(--display);font-weight:700;font-size:clamp(28px,5vw,40px);line-height:1.1;margin:0 0 20px;padding-bottom:20px;border-bottom:1px solid var(--line)}p{color:var(--muted);margin:0 0 8px}
</style>
</head>
<body>
<div class="wrap">
<p class="eyebrow">explain · page $n</p>
<h1>$topic</h1>
$lines
</div>
<script>
(function(){var last=null;function poll(){fetch(location.pathname,{method:'HEAD',cache:'no-store'}).then(function(r){if(r.ok&&!r.redirected){var m=[r.headers.get('ETag'),r.headers.get('Last-Modified'),r.headers.get('Content-Length')].join('|');if(last!==null&&m!==last){location.reload();return}last=m}setTimeout(poll,2000)}).catch(function(){setTimeout(poll,2000)})}poll()})();
</script>
</body>
</html>
EOF
  chmod 600 "$tmp" && mv -f "$tmp" "$ROOT/$n/index.html"
}

# ---------------------------------------------------------------------------
# lock (serialises id allocation)

lock_root() {
  exec 9>"$ROOT/.lock" || die "cannot open $ROOT/.lock"
  if command -v flock >/dev/null 2>&1; then
    flock -w 60 9 || die "another /explain is still allocating a page (lock $ROOT/.lock)"
  fi
}
unlock_root() { exec 9>&-; }

# ---------------------------------------------------------------------------
# exposure

# Publish the pages root; sets BASE_URL (no trailing slash) and EXPOSED (1|0).
# `up` is idempotent for the same name and directory (no second exposure)
# and restores a route the proxy lost, so it runs on every open and serve.
BASE_URL=""; EXPOSED=0
ensure_exposure() {
  local out rc url
  EXPOSED=0; BASE_URL="file://$ROOT"
  find_expose
  if [ -z "$EXPOSE" ]; then
    note "$HINT"
    return 0
  fi
  out=$(OPSX_EXPOSE_NO_COPY=1 "$EXPOSE" up --dir "$ROOT" --name "$EXPOSE_NAME" \
        --hide manifest.tsv --hide '*.sha256' --csp "$EXPLAIN_CSP" 2>&1 </dev/null); rc=$?
  url=$(printf '%s\n' "$out" | strip_osc8 | awk 'NF { l = $0 } END { print l }')
  if [ "$rc" -eq 0 ] && [[ "$url" == http*://* ]]; then
    BASE_URL=${url%/}; EXPOSED=1
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    note "$HINT"
  else
    note "could not expose the pages (expose.sh up exit $rc)${url:+: $url} — the page is a file on this machine only."
  fi
  return 0
}

# URL of page $1 (the file path when nothing serves it).
page_url() {
  if [ "$EXPOSED" -eq 1 ]; then printf '%s/%s/' "$BASE_URL" "$1"; else printf '%s/%s/index.html' "$ROOT" "$1"; fi
}
library_url() {
  if [ "$EXPOSED" -eq 1 ]; then printf '%s/' "$BASE_URL"; else printf '%s/index.html' "$ROOT"; fi
}

# Leftovers of the previous explain version (its own loopback server in a
# tmux window): stop the recorded server if it is still ours, remove the
# window when it carries the old tag, and delete its files.
stop_legacy_server() {
  local rec=$ROOT/.server pid win
  if [ -f "$rec" ]; then
    pid=$(awk -F= '$1 == "pid" { print $2 }' "$rec")
    win=$(awk -F= '$1 == "window" { print $2 }' "$rec")
    if [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
       && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$ROOT/.serve.py"; then
      kill "$pid" 2>/dev/null
    fi
    if [ -n "${win:-}" ] && tmux_ok \
       && [ "$(tmux show-options -w -v -t "$win" @opsx_explain 2>/dev/null)" = "$PROJECT" ]; then
      tmux kill-window -t "$win" >/dev/null 2>&1
    fi
  fi
  rm -f "$ROOT/.server" "$ROOT/.hosts" "$ROOT/launch.sh" "$ROOT/.serve.py"
}

# ---------------------------------------------------------------------------
# brief

# The fenced HTML template from SKILL.md next to this script.
page_template() {
  [ -f "$SELF_DIR/SKILL.md" ] || return 0
  awk '
    /<!-- explain-page-template -->/ { armed = 1; next }
    armed && !inside && /^```/ { inside = 1; next }
    inside && /^```/ { exit }
    inside { print }
  ' "$SELF_DIR/SKILL.md"
}

# The template cut down to the page's languages ($1 = en | pt | en,pt): one
# language keeps only its <!-- article:xx --> block, drops the switch and the
# other title; both keep the skeleton as it is.
template_for() {
  local langs=$1
  page_template | awk -v langs="$langs" '
    BEGIN { both = (langs == "en,pt"); drop = "" }
    both { print; next }
    /^<!-- lang-switch -->$/ { skip = 1; next }
    /^<!-- \/lang-switch -->$/ { skip = 0; next }
    /^<!-- article:(en|pt) -->$/ { l = $0; sub(/^<!-- article:/, "", l); sub(/ -->$/, "", l); if (l != langs) drop = l; next }
    /^<!-- \/article:(en|pt) -->$/ { l = $0; sub(/^<!-- \/article:/, "", l); sub(/ -->$/, "", l); if (l == drop) drop = ""; next }
    skip || drop != "" { next }
    /^<html lang="en">$/ && langs == "pt" { print "<html lang=\"pt\">"; next }
    /^<title>TITLE_EN · TITLE_PT<\/title>$/ { print (langs == "pt" ? "<title>TITLE_PT</title>" : "<title>TITLE_EN</title>"); next }
    { print }
  '
}

build_brief() {
  local topic=$1 n=$2 url=$3 notes=$4 langs=${5:-en} tpl
  printf '## Question\nExplain: %s\n\n' "$topic"
  printf '## Page\n'
  printf -- '- Topic: %s\n' "$topic"
  printf -- '- Page %s of project %s\n' "$n" "$PROJECT"
  printf -- '- Page URL: %s\n' "$url"
  printf -- '- Library: %s\n' "$(library_url)"
  if [ "$EXPOSED" -eq 1 ]; then
    printf -- '- Served from this machine behind the expose login; nothing else is written or published.\n'
  else
    printf -- '- A file on this machine only (expose is not configured, nothing serves it); nothing else is written or published.\n'
  fi
  case "$langs" in
    en,pt) printf -- '- Languages: English and Portuguese on the same page (lang="en" and lang="pt", EN / PT switch, identical labels in both), written together in every page write.\n' ;;
    pt)    printf -- '- Languages: Portuguese only (português) — one <article lang="pt">, no language switch. Write everything, diagrams included, in Portuguese.\n' ;;
    *)     printf -- '- Languages: English only — one <article lang="en">, no language switch.\n' ;;
  esac
  printf -- '- Audience: the user, possibly a client they share the link with (a share link opens the whole page library of this project, not only this page). Write a clean, well-structured explanation with diagrams where they help; no internal chatter, and never secrets (keys, tokens, passwords, credentials, environment values).\n'
  if [ -n "${notes//[[:space:]]/}" ]; then
    printf '\n%s\n' "$notes"
  fi
  if ! printf '%s' "$notes" | grep -q 'data-label'; then
    tpl=$(template_for "$langs")
    if [ -n "$tpl" ]; then
      printf '\n## HTML template\n\n'
      printf 'Start every page from this skeleton. Keep the fonts <link>, the <style> and every <script> block as they are; replace the eyebrow, the titles and the content of the article(s).\n\n'
      printf -- '- Design: build the page from the template'"'"'s elements, each labelled. Open with the hero (header.hero: a mono .eyebrow with the provenance, the h1, a .lede that gives the whole answer in two sentences with the one thing to remember in bold). Then key cards (.key: three or four facts, .k key and .v value coloured accent / warn / bad / ok), framed figures (figure > .frame > svg, or two side by side in a .pair, each with a figcaption), tables (.tscroll > table, .pill states ok / bad / warn / no), callouts (.callout, .warn, .bad, .ok, with a bold lead-in), a terms list (dl.terms) near the end and a footer naming the sources. Prose lives in .prose (68 ch); figures and tables may use the whole rail.\n'
      printf -- '- Diagrams: inline SVG first (viewBox, role="img", aria-label, boxes as rect with rx, text as text, colours only from the tokens: var(--accent), var(--accent-soft), var(--warn), var(--bad), var(--ok), var(--surface), currentColor; arrows as line with marker-end; every marker id unique across the page, suffixed with the language). Mermaid (<pre class="mermaid"> inside the .frame) only when a diagram has too many nodes to draw by hand, and then add exactly this tag before the first <script> in <head> (the server allows only this file):\n\n      <script src="%s" integrity="%s" crossorigin="anonymous" referrerpolicy="no-referrer"></script>\n\n  A page without Mermaid must not carry that tag. An ASCII <pre> is the last resort.\n' "$MERMAID_URL" "$MERMAID_SRI"
      case "$langs" in
        en,pt) printf -- '- Languages: write the page in English (<article lang="en">) and in Portuguese (<article lang="pt">) in the same write, with identical labels in the same order in both articles; <title> holds both titles (English · Portuguese); keep the EN / PT switch.\n' ;;
        pt)    printf -- '- Languages: one <article lang="pt">, Portuguese only; <title> is the Portuguese title; there is no switch.\n' ;;
        *)     printf -- '- Languages: one <article lang="en">, English only; <title> is the English title; there is no switch.\n' ;;
      esac
      printf -- '- The server enforces a Content-Security-Policy: no external resource besides the fonts <link> and, when used, the Mermaid tag above; no other scripts, images, styles, frames, fetches or forms.\n'
      # shellcheck disable=SC2016  # literal Markdown backticks
      printf '\n```html\n%s\n```\n' "$tpl"
    fi
  fi
}

# ---------------------------------------------------------------------------
# subcommands

# The parent's notes on stdin (not a TTY). Waits at most $STDIN_WAIT seconds
# for the first byte, so an inherited stdin that nobody writes to (an agent
# tool runner's open pipe) does not hang `open`; then reads to EOF.
read_notes() {
  local c="" rc
  IFS= read -r -N 1 -t "$STDIN_WAIT" c; rc=$?
  if [ "$rc" -gt 128 ]; then
    note "no notes on stdin within ${STDIN_WAIT}s; opening without notes (pass them with a heredoc, or </dev/null for none)."
    return 0
  fi
  [ -n "$c" ] || return 0
  printf '%s' "$c"
  cat
}

# en | pt | en,pt (pt,en is accepted and normalised); anything else is a
# usage error naming the accepted values.
norm_langs() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
    en) printf 'en' ;;
    pt) printf 'pt' ;;
    en,pt|pt,en|both) printf 'en,pt' ;;
    *) return 1 ;;
  esac
}

cmd_open() {
  local topic="" have_topic=0 fargs=() notes="" fork n url out rc fid sess langs=en
  while [ $# -gt 0 ]; do
    case "$1" in
      --window|--vertical|--brief-only) fargs+=("$1"); shift ;;
      --lang)
        [ -n "${2:-}" ] || die "--lang needs a value: en, pt or en,pt" 2
        langs=$(norm_langs "$2") || die "unknown language set '$2' for --lang — accepted values: en, pt, en,pt (nothing was opened)." 2
        shift 2 ;;
      --lang=*)
        langs=$(norm_langs "${1#--lang=}") || die "unknown language set '${1#--lang=}' for --lang — accepted values: en, pt, en,pt (nothing was opened)." 2
        shift ;;
      --cli|--model|--parent-model)
        [ -n "${2:-}" ] || die "$1 needs a value" 2
        fargs+=("$1" "$2"); shift 2 ;;
      --cli=*|--model=*|--parent-model=*) fargs+=("$1"); shift ;;
      --) shift   # everything after -- is the topic, even when it starts with -
          [ $# -le 1 ] || die "one topic only (quote it): $*" 2
          if [ $# -eq 1 ]; then
            [ "$have_topic" -eq 0 ] || die "one topic only (quote it): $1" 2
            topic=$1; have_topic=1; shift
          fi
          break ;;
      -h|--help) usage; return 0 ;;
      -*) die "unknown option for open: $1" 2 ;;
      *) [ "$have_topic" -eq 0 ] || die "one topic only (quote it): $1" 2
         topic=$1; have_topic=1; shift ;;
    esac
  done
  topic=$(printf '%s' "$topic" | tr '\n\r\t' '   ' | sed -e 's/^ *//' -e 's/ *$//')
  [ -n "$topic" ] || die 'a topic is required — usage: /explain "<topic>" (nothing was opened).' 2

  fork=$(find_fork) || die "fork.sh not found — install the /fork skill (install.sh) or set \$EXPLAIN_FORK_SH."
  require_tmux
  [ -t 0 ] || notes=$(read_notes)

  mkdir -p "$ROOT" || die "cannot create $ROOT"
  lock_root
  ensure_root
  n=$(alloc_id) || exit 1
  unlock_root
  ensure_exposure

  sess=$(current_session)
  : > "$ROOT/$n/.meta"
  meta_set topic "$topic" "$ROOT/$n/.meta"
  meta_set created "$(now)" "$ROOT/$n/.meta"
  meta_set fork "" "$ROOT/$n/.meta"
  meta_set session "$sess" "$ROOT/$n/.meta"
  meta_set langs "$langs" "$ROOT/$n/.meta"
  write_placeholder "$n" "$topic" "$langs"
  reindex
  url=$(page_url "$n")
  meta_set url "$url" "$ROOT/$n/.meta"

  out=$(build_brief "$topic" "$n" "$url" "$notes" "$langs" | "$fork" open --page-dir "$ROOT/$n" "${fargs[@]}" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf -- "${ROOT:?}/$n"
    reindex
    printf '%s\n' "$out" >&2
    die "the fork did not open; page $n was discarded."
  fi
  fid=$(printf '%s\n' "$out" | awk '/^fork [0-9]+ /{ print $2; exit }')
  meta_set fork "$fid" "$ROOT/$n/.meta"
  reindex
  printf '%s\n' "$out"
  if [ "$EXPOSED" -eq 0 ]; then
    printf '# local only: nothing serves this file; run install.sh --expose-domain <domain> to open it on other devices and share it\n'
  fi
  printf '# library: %s\n' "$(library_url)"
  printf 'page %s %s\n' "$n" "$url"
}

cmd_serve() {
  mkdir -p "$ROOT" || die "cannot create $ROOT"
  lock_root
  ensure_root
  unlock_root
  reindex
  ensure_exposure
  if [ "$EXPOSED" -eq 1 ]; then
    printf 'explain pages for %s (%s) published at %s/\n' "$PROJECT" "$ROOT" "$BASE_URL"
  else
    printf 'explain pages for %s in %s (not served)\n' "$PROJECT" "$ROOT"
  fi
  printf '%s\n' "$(library_url)"
}

cmd_share() {
  find_expose
  [ -n "$EXPOSE" ] || die "$HINT" 3
  exec "$EXPOSE" share "$EXPOSE_NAME" "$@"
}

# Title of page $1 for the terminal (entities decoded).
page_title() {
  local f=$ROOT/$1/index.html t
  [ -f "$f" ] && t=$(tr '\n\r' '  ' < "$f" | sed -n 's/.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\([^<]*\)<\/[Tt][Ii][Tt][Ll][Ee]>.*/\1/p' \
    | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e 's/&amp;/\&/g' | cut -c1-70)
  [ -n "${t//[[:space:]]/}" ] || t=$(meta_get topic "$ROOT/$1/.meta" | cut -c1-70)
  printf '%s' "$t"
}

# exposure_state — "exposed: <url>/" when expose.sh knows the explain
# exposure of this project, else "exposed: no" (with the reason).
exposure_state() {
  local out rc url
  find_expose
  if [ -z "$EXPOSE" ]; then printf 'exposed: no (expose.sh not found)\n'; return 0; fi
  out=$(OPSX_EXPOSE_NO_COPY=1 "$EXPOSE" url "$EXPOSE_NAME" 2>/dev/null </dev/null); rc=$?
  url=$(printf '%s\n' "$out" | strip_osc8 | awk 'NF { l = $0 } END { print l }')
  case "$rc" in
    0) if [[ "$url" == http*://* ]]; then printf 'exposed: %s/\n' "${url%/}"; else printf 'exposed: no\n'; fi ;;
    3) printf 'exposed: no (expose is not configured)\n' ;;
    4) printf 'exposed: unknown (the expose proxy is not running)\n' ;;
    *) printf 'exposed: no\n' ;;
  esac
}

cmd_list() {
  local n any=0
  for n in $(page_ids); do
    if [ "$any" -eq 0 ]; then
      printf '%-4s %-24s %-5s %s\n' ID CREATED FORK TITLE
      any=1
    fi
    printf '%-4s %-24s %-5s %s\n' "$n" "$(meta_get created "$ROOT/$n/.meta")" \
      "$(meta_get fork "$ROOT/$n/.meta" | sed 's/^$/-/')" "$(page_title "$n")"
  done
  [ "$any" -eq 1 ] || printf 'no explain pages for project %s\n' "$PROJECT"
  printf 'pages:   %s\n' "$ROOT"
  exposure_state
}

cmd_stop() {
  local out rc removed=0
  find_expose
  if [ -n "$EXPOSE" ]; then
    out=$(OPSX_EXPOSE_NO_COPY=1 "$EXPOSE" down "$EXPOSE_NAME" </dev/null 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^removed '; then removed=1; fi
  fi
  stop_legacy_server
  if [ "$removed" -eq 1 ]; then
    printf 'explain exposure for %s removed; pages kept in %s\n' "$PROJECT" "$ROOT"
  else
    printf 'explain pages for %s are not exposed; pages kept in %s\n' "$PROJECT" "$ROOT"
  fi
  return 0
}

cmd_native() {
  local fork
  fork=$(find_fork) || die "fork.sh not found — install the /fork skill (install.sh) or set \$EXPLAIN_FORK_SH."
  exec "$fork" native "$@"
}

usage() {
  sed -n '2,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  open)   shift; cmd_open "$@" ;;
  native) shift; cmd_native "$@" ;;
  serve)  shift; cmd_serve "$@" ;;
  share)  shift; cmd_share "$@" ;;
  list)   shift; cmd_list "$@" ;;
  stop)   shift; cmd_stop "$@" ;;
  root)   printf '%s\n' "$ROOT" ;;
  help|-h|--help) usage ;;
  '') usage >&2; exit 2 ;;
  --)     cmd_open "$@" ;;        # explain.sh -- "<topic starting with ->"
  -*) die "unknown option: $1 (expected open|share|list|stop|serve|native|root|help)" 2 ;;
  *)  cmd_open "$@" ;;
esac
