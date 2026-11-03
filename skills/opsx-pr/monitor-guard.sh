#!/usr/bin/env bash
# PreToolUse hook of the ops-pr-monitor subagent (agents/opsx-pr-monitor.md).
#
# Reads the hook payload (JSON) on stdin and allows only one command:
#   <path>/pr.sh wait <n> --repo <arg> --slice <n> --poll <n> --gen <n>
# where <path> and <arg> are single shell words as `printf %q` writes them
# (backslash-escaped characters allowed, nothing else from the shell syntax:
# no ; | & $ ` ( ) < > quotes, globs, ~ or #, no newline). Everything else is
# denied with exit 2 and a reason on stderr, which Claude Code shows the
# subagent and blocks the tool call.
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

# One word: plain safe characters or a backslash-escaped printable character.
word='([A-Za-z0-9_./:+@,=%-]|\\[[:print:]])+'
num='[0-9]+'
re="^${word}/pr\\.sh wait ${num} --repo ${word} --slice ${num} --poll ${num} --gen ${num}\$"
[[ $cmd =~ $re ]] || deny "command not allowed: ${cmd:0:200}"
exit 0
