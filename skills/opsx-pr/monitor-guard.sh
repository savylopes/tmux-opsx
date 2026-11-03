#!/usr/bin/env bash
# PreToolUse hook of the ops-pr-monitor subagent (agents/opsx-pr-monitor.md).
#
# Reads the hook payload (JSON) on stdin and allows only two command shapes:
#   <pr.sh> wait <n> --repo <arg> --slice <n> --poll <n> --gen <n>
# where <pr.sh> and <arg> are single shell words as `printf %q` writes them
# (backslash-escaped characters allowed, nothing else from the shell syntax:
# no ; | & $ ` ( ) < > quotes, globs, ~ or #, no newline), and <pr.sh> is an
# absolute path that resolves to the pr.sh next to this guard (install.sh puts
# both in the same directory): no relative path, no VAR=... prefix, no other
# pr.sh. And, for the monitor's fallback when Claude Code moved a call to the
# background (after 180 s), a read of that call's task output file:
#   cat <file>   |   tail -n <n> <file>
# with <file> = /tmp/claude-<uid>/<dir>/<dir>/tasks/<id>.output (no `..`).
# Everything else is denied with exit 2 and a reason on stderr, which Claude
# Code shows the subagent and blocks the tool call.
set -u

deny() { printf 'monitor-guard: %s; ops-pr-monitor may only run its pr.sh wait command\n' "$1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || deny "jq is missing, cannot read the hook payload"
payload=$(cat) || deny "no hook payload"
cmd=$(printf '%s' "$payload" | jq -r 'if (.tool_input.command | type) == "string" then .tool_input.command else empty end' 2>/dev/null) \
  || deny "unreadable hook payload"
[ -n "$cmd" ] || deny "no Bash command in the hook payload"

# A newline or carriage return could join a second command.
case $cmd in
  *$'\n'*|*$'\r'*) deny "multi-line command" ;;
esac

# The task output file of a backgrounded call (plain characters only).
seg='[A-Za-z0-9_.-]+'
out_re="^(cat|tail -n [0-9]+) /tmp/claude-[0-9]+/${seg}/${seg}/tasks/[A-Za-z0-9_-]+\\.output\$"
if [[ $cmd =~ $out_re ]]; then
  case "/$cmd/" in
    */../*|*/./*) deny "path with . or .. segments: ${cmd:0:200}" ;;
  esac
  exit 0
fi

# One word: plain safe characters or a backslash-escaped printable character.
word='([A-Za-z0-9_./:+@,=%-]|\\[[:print:]])+'
num='[0-9]+'
re="^(${word}) wait ${num} --repo ${word} --slice ${num} --poll ${num} --gen ${num}\$"
[[ $cmd =~ $re ]] || deny "command not allowed: ${cmd:0:200}"

# The program must be the installed pr.sh next to this guard, by absolute path.
prog=${BASH_REMATCH[1]}
# Undo printf %q's backslash escapes (the word holds no other quoting).
prog=$(printf '%s' "$prog" | sed 's/\\\(.\)/\1/g')
case $prog in
  /*) ;;
  *) deny "pr.sh path is not absolute: ${prog:0:200}" ;;
esac
# Resolve both sides the same way (directory symlinks too); no realpath -e,
# which BSD lacks.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || deny "cannot resolve the guard's directory"
[ -f "$here/pr.sh" ] || deny "no pr.sh next to the guard ($here/pr.sh)"
[ -f "$prog" ] || deny "pr.sh path does not exist: ${prog:0:200}"
pdir=$(cd -- "$(dirname -- "$prog")" 2>/dev/null && pwd -P) || deny "cannot resolve ${prog:0:200}"
[ "$pdir/$(basename -- "$prog")" = "$here/pr.sh" ] || deny "not the installed pr.sh ($here/pr.sh): ${prog:0:200}"
exit 0
