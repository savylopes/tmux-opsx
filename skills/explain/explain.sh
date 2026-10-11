#!/usr/bin/env bash
# explain.sh — server, exposure and page library for the /explain skill.
#
# /explain turns a topic from the current agent session into a clean,
# diagrammed, addressable web page. A read-only fork (fork.sh open
# --page-dir) writes the page; this script serves the project's pages from a
# loopback static server and publishes it once through /expose.
#
# Usage:
#   explain.sh open "<topic>" [--window] [--vertical] [--cli <c>] [--model <m>]
#                   [--parent-model <m>] [--brief-only]           [< brief]
#   explain.sh native [--cli <c>] [--brief-only]    (= fork.sh native)
#   explain.sh serve                    start / reuse the server, print its URL
#   explain.sh share [--for <r>] [--ttl <d>] [--list] [--revoke <r|id|all>]
#   explain.sh list                     pages, server state and URL
#   explain.sh stop                     remove exposure + server, keep pages
#   explain.sh root                     print the pages root
#   explain.sh help
#
# `open` reads the parent's brief notes on stdin (optional), adds the topic,
# the page URL and the HTML template from SKILL.md (unless the notes already
# carry one), and opens the fork with `fork.sh open --page-dir <root>/<id>`.
# The page URL is the last line of its output.
#
# Project: the folder name of the main checkout of the current git
# repository (the same for every worktree), else the current directory's name
# — computed exactly like expose.sh.
#
# Pages root: ${XDG_STATE_HOME:-~/.local/state}/agent-forks/explain/<project>/
#   .ids/<n>          page id allocation (noclobber; ids are never reused)
#   .server           record of the running server (port= window= pid= …)
#   .reindex          regenerates index.html; run by `fork.sh page`
#   .serve.py         the page server (written by this script)
#   .hosts            extra Host names the server accepts (the expose host)
#   .lock             serialises server start and id allocation
#   launch.sh         the server's launcher
#   index.html        library index (id, title, created, fork)
#   <n>/index.html    page <n>; <n>/manifest.tsv its labels; <n>/.meta
# The root is mode 700 and every file this skill writes is private (umask 077).
#
# Server: `python3 -I .serve.py --bind 127.0.0.1 --port <port>`, in a
# detached tmux window named "ox >explain" tagged @opsx_explain=<project>
# (not @opsx_preview: `close-all` must leave it alone). Reused while the
# recorded window still carries the tag and the port answers, else restarted.
# It serves only `/`, `/index.html`, `/<n>/` and `/<n>/index.html` (no
# directory listings, dotfiles, launch.sh, manifests or .meta), GET/HEAD
# only, and answers 421 to any Host other than 127.0.0.1 / localhost / the
# names in .hosts (DNS rebinding). Every response carries a strict
# Content-Security-Policy (inline scripts and the pinned Mermaid file only;
# connect/img/font/style 'self' or data:; no forms, frames or objects),
# Referrer-Policy: no-referrer, nosniff and frame-ancestors 'none': the page
# is fork-written, so these controls live in the server, not in the page.
# Exposure: `expose.sh up <port> --name explain` → explain--<project>.<domain>
# ($OPSX_EXPOSE_SH, else ../expose/expose.sh next to this skill, else
# expose.sh on PATH). Without a configured /expose the local URL is printed
# with the `install.sh --expose-domain` hint and the fork still opens.
#
# Exit codes: 0 ok, 1 error, 2 usage (e.g. no topic), 3 expose not configured
# (share only).

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PORT_MIN=${EXPLAIN_PORT_MIN:-4100}
PORT_MAX=${EXPLAIN_PORT_MAX:-4199}
WINDOW_NAME='ox >explain'
EXPOSE_NAME=explain
READY_WAIT=${EXPLAIN_READY_WAIT:-10}
# Mermaid, pinned to one file with its SRI hash (npm mermaid@11.17.2,
# dist/mermaid.min.js). The CSP allows exactly this URL; SKILL.md's template
# carries the same URL and hash — change all three together.
MERMAID_URL=https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js

umask 077

die() { printf 'explain: %s\n' "$1" >&2; exit "${2:-1}"; }
note() { printf 'explain: %s\n' "$1" >&2; }
say() { printf '%s\n' "$1"; }

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
SERVER_REC=$ROOT/.server

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

# True when window $1 exists and is tagged @opsx_explain=<project>.
window_is_ours() {
  [ -n "${1:-}" ] || return 1
  [ "$(tmux display-message -p -t "$1" '#{window_id}' 2>/dev/null)" = "$1" ] || return 1
  [ "$(tmux show-options -w -v -t "$1" @opsx_explain 2>/dev/null)" = "$PROJECT" ]
}

# Window ids tagged for this project, on this tmux server.
tagged_windows() {
  tmux list-windows -a -F '#{window_id}	#{@opsx_explain}' 2>/dev/null \
    | awk -F '\t' -v p="$PROJECT" '$2 == p { print $1 }'
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

HINT='expose is not configured — the page is served on this machine only; run install.sh --expose-domain <domain> to get a login-protected URL you can open on any device and share.'

strip_osc8() { sed -e 's/\x1b]8;;[^\x07\x1b]*\(\x07\|\x1b\\\)//g'; }

# ---------------------------------------------------------------------------
# record file (.server): key=value lines

rec_get() {
  [ -f "$SERVER_REC" ] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$SERVER_REC"
}

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
# ports and HTTP

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

valid_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# Free loopback port, preferring $1 (the last one used).
pick_port() {
  local last=${1:-} p
  if valid_port "$last" && ! port_in_use "$last"; then printf '%s' "$last"; return 0; fi
  for ((p = PORT_MIN; p <= PORT_MAX; p++)); do
    port_in_use "$p" && continue
    printf '%s' "$p"; return 0
  done
  return 1
}

# Does HEAD http://127.0.0.1:$1/ answer with 2xx/3xx?
head_ok() {
  local code line
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -I -w '%{http_code}' --max-time 2 "http://127.0.0.1:$1/" 2>/dev/null) || true
  else
    line=$( { exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
              printf 'HEAD / HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nConnection: close\r\n\r\n' "$1" >&3
              timeout 2 head -n1 <&3; } 2>/dev/null) || line=""
    code=$(printf '%s' "$line" | awk '{print $2}')
  fi
  [[ "${code:-000}" =~ ^[23][0-9][0-9]$ ]]
}

# ---------------------------------------------------------------------------
# pages root, library index

# The library index generator. Kept self-contained: fork.sh runs it after
# every page write, from the fork child's sandbox.
write_reindex() {
  local tmp
  tmp=$(mktemp "$ROOT/.reindex.XXXXXX") || die "cannot write $ROOT/.reindex"
  cat > "$tmp" <<'REINDEX'
#!/usr/bin/env bash
# .reindex — regenerates the /explain library index (index.html) of this
# directory. Written by explain.sh; run by `fork.sh page` after a page write.
set -u
root=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
meta() { [ -f "$2" ] || return 0; awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$2"; }
title_of() { [ -f "$1" ] || return 0; tr '\n\r' '  ' < "$1" | sed -n 's/.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\([^<]*\)<\/[Tt][Ii][Tt][Ll][Ee]>.*/\1/p' | cut -c1-200; }
ids() { local d; for d in "$root"/*/; do d=${d%/}; d=${d##*/}; case "$d" in ''|*[!0-9]*) ;; *) printf '%s\n' "$d" ;; esac; done | sort -rn; }
rows=""
for n in $(ids); do
  t=$(title_of "$root/$n/index.html")          # text between <title> tags: no '<'
  [ -n "${t//[[:space:]]/}" ] || t=$(meta topic "$root/$n/.meta" | esc)
  c=$(meta created "$root/$n/.meta" | esc)
  f=$(meta fork "$root/$n/.meta" | esc)
  rows="$rows<tr id=\"page-$n\"><td><a href=\"/$n/\">$n</a></td><td><a href=\"/$n/\">${t:-page $n}</a></td><td>${c:--}</td><td>${f:--}</td></tr>
"
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
<style>
body{font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;max-width:52rem;margin:2rem auto;padding:0 1rem;color:#1d1d1f;background:#fff}
h1{font-size:1.5rem}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #e5e5e5}
th{font-size:.8rem;text-transform:uppercase;color:#666}a{color:#0b57d0;text-decoration:none}a:hover{text-decoration:underline}
td:first-child,td:nth-child(3),td:nth-child(4){white-space:nowrap;color:#555;font-size:.9rem}
@media (prefers-color-scheme:dark){body{background:#111;color:#eee}th,td{border-color:#333}a{color:#8ab4f8}}
</style>
</head>
<body>
<h1>Explain — $proj</h1>
<table>
<thead><tr><th>ID</th><th>Title</th><th>Created</th><th>Fork</th></tr></thead>
<tbody>
$rows</tbody>
</table>
<script>
(function(){var last=null;function poll(){fetch(location.pathname,{method:'HEAD',cache:'no-store'}).then(function(r){var m=(r.headers.get('Last-Modified')||'')+'|'+(r.headers.get('Content-Length')||'');if(last!==null&&m!==last){location.reload();return}last=m;setTimeout(poll,2000)}).catch(function(){setTimeout(poll,2000)})}poll()})();
</script>
</body>
</html>
EOF
chmod 600 "$tmp" && mv -f "$tmp" "$root/index.html"
REINDEX
  { chmod 755 "$tmp" && mv -f "$tmp" "$ROOT/.reindex"; } || die "cannot write $ROOT/.reindex"
}

# The page server. Self-contained Python (stdlib only), run with -I.
write_server() {
  local tmp
  tmp=$(mktemp "$ROOT/.serve.XXXXXX") || die "cannot write $ROOT/.serve.py"
  {
    printf '# .serve.py — /explain page server (generated by explain.sh; do not edit)\n'
    printf 'MERMAID_URL = %s\n' "'$MERMAID_URL'"
    cat <<'SERVE'
import argparse, os, re, stat, sys
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

CSP = ("default-src 'none'; "
       "script-src 'unsafe-inline' " + MERMAID_URL + "; "
       "style-src 'self' 'unsafe-inline'; "
       "img-src 'self' data:; font-src 'self' data:; connect-src 'self'; "
       "media-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; "
       "manifest-src 'none'; base-uri 'none'; form-action 'none'; "
       "frame-ancestors 'none'")
SECURITY = [
    ("Content-Security-Policy", CSP),
    ("Referrer-Policy", "no-referrer"),
    ("X-Content-Type-Options", "nosniff"),
    ("X-Frame-Options", "DENY"),
    ("Cross-Origin-Opener-Policy", "same-origin"),
    ("Cross-Origin-Resource-Policy", "same-origin"),
]
PAGE = re.compile(r"/(?:([0-9]{1,9})/)?(?:index\.html)?")
BARE = re.compile(r"/([0-9]{1,9})")
ROOT = "."


def host_name(value):
    h = (value or "").strip().lower()
    if h.startswith("["):
        return h.split("]", 1)[0] + "]"
    return h.rsplit(":", 1)[0] if ":" in h else h


def allowed_hosts():
    names = {"127.0.0.1", "localhost"}
    try:
        with open(os.path.join(ROOT, ".hosts"), encoding="utf-8") as f:
            names.update(l.strip().lower() for l in f if l.strip())
    except OSError:
        pass
    return names


class Handler(BaseHTTPRequestHandler):
    server_version = "explain"
    sys_version = ""
    protocol_version = "HTTP/1.0"

    def end_headers(self):
        for k, v in SECURITY:
            self.send_header(k, v)
        BaseHTTPRequestHandler.end_headers(self)

    def plain(self, code, text, body, extra=()):
        data = (text + "\n").encode()
        self.send_response(code)
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(data)

    def serve(self, body):
        if host_name(self.headers.get("Host")) not in allowed_hosts():
            return self.plain(421, "misdirected request", body)
        path = urlsplit(self.path).path
        m = BARE.fullmatch(path)
        if m:
            return self.plain(301, "moved", body, [("Location", path + "/")])
        m = PAGE.fullmatch(path)
        if not m:
            return self.plain(404, "not found", body)
        fn = os.path.join(ROOT, m.group(1) or "", "index.html")
        try:
            fd = os.open(fn, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError:
            return self.plain(404, "not found", body)
        with os.fdopen(fd, "rb") as f:
            st = os.fstat(f.fileno())
            if not stat.S_ISREG(st.st_mode):
                return self.plain(404, "not found", body)
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Last-Modified", formatdate(st.st_mtime, usegmt=True))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        if body:
            self.wfile.write(data)

    def do_GET(self):
        self.serve(True)

    def do_HEAD(self):
        self.serve(False)

    def send_error(self, code, message=None, explain=None):
        try:
            self.plain(code, message or "error", self.command != "HEAD")
        except Exception:
            pass


def main():
    global ROOT
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--root", required=True)
    a = ap.parse_args()
    ROOT = os.path.abspath(a.root)
    ThreadingHTTPServer.daemon_threads = True
    httpd = ThreadingHTTPServer((a.bind, a.port), Handler)
    sys.stderr.write("explain: serving %s on http://%s:%d/\n" % (ROOT, a.bind, a.port))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
SERVE
  } > "$tmp" || die "cannot write $ROOT/.serve.py"
  mv -f "$tmp" "$ROOT/.serve.py" || die "cannot write $ROOT/.serve.py"
}

ensure_root() {
  mkdir -p "$ROOT/.ids" || die "cannot create $ROOT"
  chmod 700 "$ROOT" 2>/dev/null
  write_reindex
  write_server
  # The server serves no directory listings: the library index must exist
  # before it starts (its readiness probe is HEAD /).
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

# Placeholder shown until the fork writes the page; it reloads itself.
write_placeholder() {
  local n=$1 topic tmp
  topic=$(html_esc "$2")
  tmp=$(mktemp "$ROOT/$n/.page.XXXXXX") || return 0
  cat > "$tmp" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$topic</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem;color:#555}</style>
</head>
<body>
<h1>$topic</h1>
<p>The fork is writing this page. It appears here as soon as it is written.</p>
<script>
(function(){var last=null;function poll(){fetch(location.pathname,{method:'HEAD',cache:'no-store'}).then(function(r){var m=(r.headers.get('Last-Modified')||'')+'|'+(r.headers.get('Content-Length')||'');if(last!==null&&m!==last){location.reload();return}last=m;setTimeout(poll,2000)}).catch(function(){setTimeout(poll,2000)})}poll()})();
</script>
</body>
</html>
EOF
  chmod 600 "$tmp" && mv -f "$tmp" "$ROOT/$n/index.html"
}

# ---------------------------------------------------------------------------
# lock (serialises server start and id allocation)

lock_root() {
  exec 9>"$ROOT/.lock" || die "cannot open $ROOT/.lock"
  if command -v flock >/dev/null 2>&1; then
    flock -w 60 9 || die "another /explain is still starting the server (lock $ROOT/.lock)"
  fi
}
unlock_root() { exec 9>&-; }

# ---------------------------------------------------------------------------
# server

# 0 when the recorded server is up: window still ours and the port answers.
server_alive() {
  local port win
  [ -f "$SERVER_REC" ] || return 1
  port=$(rec_get port); win=$(rec_get window)
  valid_port "$port" || return 1
  window_is_ours "$win" || return 1
  head_ok "$port"
}

kill_tagged() {
  local w
  for w in $(tagged_windows); do
    tmux kill-window -t "$w" >/dev/null 2>&1
  done
}

start_server() {
  local sess last port out win pid i _try
  command -v python3 >/dev/null 2>&1 || die "python3 is required for the explain server."
  sess=$(current_session)
  [ -n "$sess" ] || die "could not determine the current tmux session."
  last=$(rec_get port)
  kill_tagged
  rm -f "$SERVER_REC"
  for _try in 1 2 3; do
    port=$(pick_port "$last") || die "no free loopback port in $PORT_MIN-$PORT_MAX"
    last=""
    {
      printf '#!/usr/bin/env bash\n'
      printf '# /explain server for project %s (generated by explain.sh)\n' "$PROJECT"
      printf 'exec python3 -I %q --bind 127.0.0.1 --port %q --root %q\n' "$ROOT/.serve.py" "$port" "$ROOT"
    } > "$ROOT/launch.sh" || die "cannot write $ROOT/launch.sh"
    out=$(tmux new-window -d -t "$sess:" -n "$WINDOW_NAME" -c "$ROOT" -P \
          -F '#{window_id} #{pane_pid}' "$(printf 'bash %q' "$ROOT/launch.sh")" 2>&1) \
      || die "failed to open the server window: $out"
    win=${out%% *}; pid=${out#* }
    tmux set-option -w -t "$win" @opsx_explain "$PROJECT" >/dev/null 2>&1
    tmux set-window-option -t "$win" automatic-rename off >/dev/null 2>&1
    tmux set-window-option -t "$win" allow-rename off >/dev/null 2>&1
    for ((i = 0; i < READY_WAIT * 10; i++)); do
      head_ok "$port" && break
      [ "$(tmux display-message -p -t "$win" '#{window_id}' 2>/dev/null)" = "$win" ] || break
      sleep 0.1
    done
    if head_ok "$port"; then
      {
        printf 'port=%s\n' "$port"
        printf 'window=%s\n' "$win"
        printf 'pid=%s\n' "$pid"
        printf 'session=%s\n' "$sess"
        printf 'started=%s\n' "$(now)"
      } > "$SERVER_REC"
      return 0
    fi
    tmux kill-window -t "$win" >/dev/null 2>&1
  done
  die "the explain server did not answer on 127.0.0.1:$port within ${READY_WAIT}s (see $ROOT/launch.sh)."
}

# Host name of URL $1 (lower case, no port, no userinfo).
url_host() {
  local h=${1#*://}
  h=${h%%/*}; h=${h##*@}
  case "$h" in \[*) h=${h%%]*}] ;; *) h=${h%%:*} ;; esac
  printf '%s\n' "$h" | tr '[:upper:]' '[:lower:]'
}

# Publish the server; sets BASE_URL (no trailing slash) and EXPOSED (1|0).
BASE_URL=""; EXPOSED=0
expose_server() {
  local port=$1 out rc url
  EXPOSED=0; BASE_URL="http://127.0.0.1:$port"
  : > "$ROOT/.hosts"
  find_expose
  if [ -z "$EXPOSE" ]; then
    note "$HINT"
    return 0
  fi
  # Also on reuse: `up` is idempotent for the same name and port (no second
  # exposure), and it restores a route the proxy lost.
  out=$(OPSX_EXPOSE_NO_COPY=1 "$EXPOSE" up "$port" --name "$EXPOSE_NAME" 2>&1 </dev/null); rc=$?
  url=$(printf '%s\n' "$out" | strip_osc8 | awk 'NF { l = $0 } END { print l }')
  if [ "$rc" -eq 0 ] && [[ "$url" == http*://* ]]; then
    BASE_URL=${url%/}; EXPOSED=1
    # The expose proxy forwards the public Host unchanged; allow exactly it.
    url_host "$BASE_URL" > "$ROOT/.hosts"
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    note "$HINT"
  else
    note "could not expose the explain server (expose.sh up exit $rc)${url:+: $url} — serving on this machine only."
  fi
  return 0
}

# Start or reuse the server and publish it. Caller holds the lock.
ensure_server() {
  server_alive || start_server
  expose_server "$(rec_get port)"
  meta_set url "$BASE_URL" "$SERVER_REC"
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

build_brief() {
  local topic=$1 n=$2 url=$3 notes=$4 tpl
  printf '## Question\nExplain: %s\n\n' "$topic"
  printf '## Page\n'
  printf -- '- Topic: %s\n' "$topic"
  printf -- '- Page %s of project %s\n' "$n" "$PROJECT"
  printf -- '- Page URL: %s\n' "$url"
  printf -- '- Library: %s\n' "${url%/"$n"/}/"
  if [ "$EXPOSED" -eq 1 ]; then
    printf -- '- Served from this machine behind the expose login; nothing else is written or published.\n'
  else
    printf -- '- Served on this machine only (expose is not configured); nothing else is written or published.\n'
  fi
  printf -- '- Audience: the user, possibly a client they share the link with (a share link opens the whole page library of this project, not only this page). Write a clean, well-structured explanation with diagrams where they help; no internal chatter, and never secrets (keys, tokens, passwords, credentials, environment values).\n'
  if [ -n "${notes//[[:space:]]/}" ]; then
    printf '\n%s\n' "$notes"
  fi
  if ! printf '%s' "$notes" | grep -q 'data-label'; then
    tpl=$(page_template)
    if [ -n "$tpl" ]; then
      # shellcheck disable=SC2016  # literal Markdown backticks
      printf '\n## HTML template\n\nStart every page from this skeleton. Keep the <style>, every <script> block and the Mermaid script tag (pinned URL, integrity hash) as they are; replace the title and the body content. The server enforces a Content-Security-Policy: no other external scripts, images, fonts, styles, frames, fetches or forms.\n\n```html\n%s\n```\n' "$tpl"
    fi
  fi
}

# ---------------------------------------------------------------------------
# subcommands

cmd_open() {
  local topic="" have_topic=0 fargs=() notes="" fork n url out rc fid sess
  while [ $# -gt 0 ]; do
    case "$1" in
      --window|--vertical|--brief-only) fargs+=("$1"); shift ;;
      --cli|--model|--parent-model)
        [ -n "${2:-}" ] || die "$1 needs a value" 2
        fargs+=("$1" "$2"); shift 2 ;;
      --cli=*|--model=*|--parent-model=*) fargs+=("$1"); shift ;;
      --) shift; [ $# -gt 0 ] && { topic=$1; have_topic=1; shift; } ;;
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
  [ -t 0 ] || notes=$(cat)

  mkdir -p "$ROOT" || die "cannot create $ROOT"
  lock_root
  ensure_root
  ensure_server
  n=$(alloc_id) || exit 1
  unlock_root

  sess=$(current_session)
  : > "$ROOT/$n/.meta"
  meta_set topic "$topic" "$ROOT/$n/.meta"
  meta_set created "$(now)" "$ROOT/$n/.meta"
  meta_set fork "" "$ROOT/$n/.meta"
  meta_set session "$sess" "$ROOT/$n/.meta"
  write_placeholder "$n" "$topic"
  reindex
  url="$BASE_URL/$n/"
  meta_set url "$url" "$ROOT/$n/.meta"

  out=$(build_brief "$topic" "$n" "$url" "$notes" | "$fork" open --page-dir "$ROOT/$n" "${fargs[@]}" 2>&1); rc=$?
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
    printf '# local only: run install.sh --expose-domain <domain> to open it on other devices and share it\n'
  fi
  printf '# library: %s/\n' "$BASE_URL"
  printf 'page %s %s\n' "$n" "$url"
}

cmd_serve() {
  require_tmux
  mkdir -p "$ROOT" || die "cannot create $ROOT"
  lock_root
  ensure_root
  ensure_server
  unlock_root
  reindex
  printf 'explain server for %s on 127.0.0.1:%s (window %s)\n' "$PROJECT" "$(rec_get port)" "$(rec_get window)"
  printf '%s/\n' "$BASE_URL"
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

cmd_list() {
  local n any=0 port win url state
  for n in $(page_ids); do
    if [ "$any" -eq 0 ]; then
      printf '%-4s %-24s %-5s %s\n' ID CREATED FORK TITLE
      any=1
    fi
    printf '%-4s %-24s %-5s %s\n' "$n" "$(meta_get created "$ROOT/$n/.meta")" \
      "$(meta_get fork "$ROOT/$n/.meta" | sed 's/^$/-/')" "$(page_title "$n")"
  done
  [ "$any" -eq 1 ] || printf 'no explain pages for project %s\n' "$PROJECT"
  port=$(rec_get port); win=$(rec_get window); url=$(rec_get url)
  state=stopped
  if [ -f "$SERVER_REC" ] && valid_port "$port" && head_ok "$port"; then
    if tmux_ok && ! window_is_ours "$win"; then state="stale (port answers, window $win gone)"
    else state="running on 127.0.0.1:$port (window $win)"; fi
  fi
  printf 'server: %s\n' "$state"
  printf 'pages:  %s\n' "$ROOT"
  if [ "$state" != stopped ] && [ -n "$url" ]; then printf 'url:    %s/\n' "$url"; fi
}

cmd_stop() {
  local win pid any=0 w
  win=$(rec_get window); pid=$(rec_get pid)
  [ -f "$SERVER_REC" ] && any=1
  find_expose
  if [ -n "$EXPOSE" ]; then
    OPSX_EXPOSE_NO_COPY=1 "$EXPOSE" down "$EXPOSE_NAME" </dev/null >/dev/null 2>&1 || true
  fi
  if tmux_ok; then
    if window_is_ours "$win"; then tmux kill-window -t "$win" >/dev/null 2>&1; any=1; fi
    for w in $(tagged_windows); do tmux kill-window -t "$w" >/dev/null 2>&1; any=1; done
  fi
  # The server outlived its window (tmux gone): stop it only if it is ours.
  if [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
     && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- ".serve.py" \
     && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$ROOT"; then
    kill "$pid" 2>/dev/null; any=1
  fi
  rm -f "$SERVER_REC"
  if [ "$any" -eq 1 ]; then
    printf 'explain server for %s stopped; pages kept in %s\n' "$PROJECT" "$ROOT"
  else
    printf 'explain server for %s is not running; pages in %s\n' "$PROJECT" "$ROOT"
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
  -*) die "unknown option: $1 (expected open|share|list|stop|serve|native|root|help)" 2 ;;
  *)  cmd_open "$@" ;;
esac
