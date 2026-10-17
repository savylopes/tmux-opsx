#!/usr/bin/env bash
# opsx-review.sh — deterministic parts of /opsx-review.
#
#   opsx-review.sh resolve <PR number | PR URL | TICKET-KEY> [--repo <dir>]
#   opsx-review.sh session <name>
#   opsx-review.sh worktree <change> <sha> [--repo <dir>]
#
# resolve   prints key=value lines (pr, url, title, author, head, head_sha, base,
#           state, ticket, change) for one pull request. Exit 2: no PR found,
#           exit 3: several PRs match a ticket (candidates printed as pr=… lines).
# session   renames the tmux session that owns this pane ($TMUX_PANE).
# worktree  adds (or reuses) the detached review worktree ../wt-<change> at <sha>.
#
# --repo defaults to the git top level of $PWD. Nothing here pushes, comments or
# switches a branch.
set -euo pipefail

die() { printf 'opsx-review: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

KEY_RE='[A-Za-z][A-Za-z0-9]+-[0-9]+'

repo_dir() {
  local d=${1:-}
  if [ -z "$d" ]; then
    d=$(git rev-parse --show-toplevel 2>/dev/null) \
      || die "not in a git repository; pass --repo <dir> (the code repository, not the OpenSpec root)."
  fi
  [ -d "$d/.git" ] || [ -f "$d/.git" ] || die "$d is not a git repository."
  printf '%s' "$d"
}

# First ticket key (ABC-123) in a string, upper-cased; empty when none.
ticket_in() {
  printf '%s' "$1" | grep -oE "(^|[^A-Za-z0-9])$KEY_RE" | head -n1 \
    | sed -E 's/^[^A-Za-z0-9]//' | tr '[:lower:]' '[:upper:]' || true
}

# kebab-case, a-z0-9 only, at most 40 characters.
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-40 | sed -E 's/-+$//'
}

# review-<ticket>-<slug>: slug from the branch after the key, else from the title.
change_name() {
  local ticket=$1 head=$2 title=$3 pr=$4 rest key slug
  rest=$(printf '%s' "$head" | tr '[:upper:]' '[:lower:]')
  key=$(printf '%s' "$ticket" | tr '[:upper:]' '[:lower:]')
  if [ -n "$key" ] && [[ $rest == *"$key"* ]]; then
    rest=${rest#*"$key"}
    rest=${rest#[-_/]}
  fi
  rest=${rest##*/}
  slug=$(slugify "$rest")
  [ -n "$slug" ] || slug=$(slugify "$title")
  if [ -n "$ticket" ]; then
    printf 'review-%s%s' "$(printf '%s' "$ticket" | tr '[:upper:]' '[:lower:]')" "${slug:+-$slug}"
  else
    printf 'review-pr-%s%s' "$pr" "${slug:+-$slug}"
  fi
}

PR_FIELDS=number,url,title,author,headRefName,headRefOid,baseRefName,state,body

print_pr() {
  local json=$1 n url title author head sha base state body ticket
  n=$(jq -r '.number' <<<"$json"); url=$(jq -r '.url' <<<"$json")
  title=$(jq -r '.title' <<<"$json"); author=$(jq -r '.author.login' <<<"$json")
  head=$(jq -r '.headRefName' <<<"$json"); sha=$(jq -r '.headRefOid' <<<"$json")
  base=$(jq -r '.baseRefName' <<<"$json"); state=$(jq -r '.state' <<<"$json")
  body=$(jq -r '.body // ""' <<<"$json")
  ticket=${FORCED_TICKET:-}
  [ -n "$ticket" ] || ticket=$(ticket_in "$head")
  [ -n "$ticket" ] || ticket=$(ticket_in "$title")
  [ -n "$ticket" ] || ticket=$(ticket_in "$body")
  printf 'pr=%s\nurl=%s\ntitle=%s\nauthor=%s\nhead=%s\nhead_sha=%s\nbase=%s\nstate=%s\nticket=%s\nchange=%s\n' \
    "$n" "$url" "$title" "$author" "$head" "$sha" "$base" "$state" "$ticket" \
    "$(change_name "$ticket" "$head" "$title" "$n")"
}

cmd_resolve() {
  local arg="" repo="" json matches count
  while [ $# -gt 0 ]; do
    case $1 in
      --repo) [ $# -ge 2 ] || die "--repo needs a value"; repo=$2; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$arg" ] || die "one PR or ticket only"; arg=$1; shift ;;
    esac
  done
  [ -n "$arg" ] || die "resolve needs a PR number, PR URL or ticket key"
  command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required."
  command -v jq >/dev/null 2>&1 || die "jq is required."
  repo=$(repo_dir "$repo")
  cd "$repo"
  if [[ $arg =~ ^#?([0-9]+)$ ]] || [[ $arg =~ /pull/([0-9]+) ]]; then
    json=$(gh pr view "${BASH_REMATCH[1]}" --json "$PR_FIELDS" 2>/dev/null) \
      || { printf 'opsx-review: PR %s not found\n' "${BASH_REMATCH[1]}" >&2; exit 2; }
    print_pr "$json"
    return
  fi
  [[ $arg =~ ^$KEY_RE$ ]] || die "'$arg' is neither a PR number, a PR URL nor a ticket key."
  FORCED_TICKET=$(printf '%s' "$arg" | tr '[:lower:]' '[:upper:]')
  # Match the key in the branch, title or body; open PRs first, then any state.
  for state in open all; do
    matches=$(gh pr list --state "$state" --limit 200 --json "$PR_FIELDS" \
      | jq -c --arg k "$FORCED_TICKET" '
          [.[] | select(([.headRefName, .title, (.body // "")] | join("\n") | ascii_upcase)
                        | test("(^|[^A-Z0-9])" + $k + "([^A-Z0-9]|$)"))]')
    count=$(jq 'length' <<<"$matches")
    [ "$count" -eq 0 ] || break
  done
  case $count in
    0) printf 'opsx-review: no pull request mentions %s\n' "$FORCED_TICKET" >&2; exit 2 ;;
    1) print_pr "$(jq -c '.[0]' <<<"$matches")" ;;
    *) jq -r '.[] | "pr=\(.number) head=\(.headRefName) state=\(.state) title=\(.title)"' <<<"$matches"
       exit 3 ;;
  esac
}

session_exists() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | awk -v n="$1" '$0==n { found=1; exit } END { exit !found }'
}

cmd_session() {
  local name=${1:-} new old=""
  [ -n "$name" ] || die "session needs a name"
  # tmux reads '.' and ':' as target separators.
  new=$(printf '%s' "$name" | tr ':. \t' '----' | sed 's/--*/-/g; s/^-//; s/-$//')
  [ -n "$new" ] || die "name '$name' is empty after cleaning"
  if [ -z "${TMUX:-}" ]; then
    printf 'session skipped: not inside tmux\n'
    return
  fi
  [ -n "${TMUX_PANE:-}" ] && old=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)
  [ -n "$old" ] || old=$(tmux display-message -p '#S' 2>/dev/null || true)
  [ -n "$old" ] || die "could not determine the current tmux session."
  if [ "$old" = "$new" ]; then
    printf 'session unchanged %s\n' "$new"
  else
    session_exists "$new" && die "a session named '$new' already exists."
    tmux rename-session -t "=$old" "$new"
    printf 'session renamed %s -> %s\n' "$old" "$new"
  fi
  # The agent CLI keeps its own session title; only the user can set it.
  if [ -n "${CLAUDECODE:-}${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf 'claude: type /rename %s\n' "$new"
  fi
}

cmd_worktree() {
  local change="" sha="" repo="" wt cur
  while [ $# -gt 0 ]; do
    case $1 in
      --repo) [ $# -ge 2 ] || die "--repo needs a value"; repo=$2; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) if [ -z "$change" ]; then change=$1; elif [ -z "$sha" ]; then sha=$1; else die "too many arguments"; fi; shift ;;
    esac
  done
  if [ -z "$change" ] || [ -z "$sha" ]; then die "worktree needs <change> <sha>"; fi
  repo=$(repo_dir "$repo")
  wt=$(cd "$repo/.." && pwd)/wt-$change
  git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null \
    || git -C "$repo" fetch -q origin "$sha" 2>/dev/null \
    || die "commit $sha is not available; run 'git -C $repo fetch origin <head branch>' first."
  if [ -e "$wt" ]; then
    cur=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || die "$wt exists and is not a worktree."
    [ "$cur" = "$(git -C "$repo" rev-parse "$sha^{commit}")" ] \
      || die "$wt is at $cur, not $sha; remove it first: git -C $repo worktree remove $wt"
    printf 'worktree reused %s\n' "$wt"
  else
    git -C "$repo" worktree add -q --detach "$wt" "$sha"
    printf 'worktree created %s\n' "$wt"
  fi
}

[ $# -ge 1 ] || usage 1
sub=$1; shift
case $sub in
  resolve)  cmd_resolve "$@" ;;
  session)  cmd_session "$@" ;;
  worktree) cmd_worktree "$@" ;;
  -h|--help|help) usage 0 ;;
  *) die "unknown command: $sub (resolve | session | worktree)" ;;
esac
