#!/usr/bin/env bash
# learn.sh — project skills learned by coding agents (the `learn` skill).
#
# Usage:
#   learn.sh root            print the project root (main checkout, never a worktree)
#   learn.sh save <name>     read a SKILL.md on stdin, store it, link it for every CLI
#   learn.sh sync            recreate missing links, drop dangling learned-* links
#   learn.sh list            one line per skill: name, description, linked CLI folders
#   learn.sh remove <name>   delete the skill and its links
#   learn.sh ignore          add .opsx/skills/ and **/skills/learned-* to .gitignore
#   learn.sh help
#
# Storage: <root>/.opsx/skills/<name>/SKILL.md, where <root> is the main checkout
# of the current git repository (the directory holding its common git dir, the
# same for every worktree), else the current directory.
#
# Links: a relative symlink learned-<name> -> ../../.opsx/skills/<name> directly
# inside <root>/.claude/skills, .agents/skills, .cursor/skills and .gemini/skills.
# OpenCode reads .claude/skills and .agents/skills, so .opencode gets no link.
# Entries whose name does not start with learned- are never touched, and a
# learned-<name> entry that is not a symlink is never replaced.
#
# <name>: [a-z0-9-], 1 to 40 characters. The stored frontmatter `name` is
# always learned-<name>; the frontmatter must carry a `description`.
#
# Exit codes: 0 ok, 1 conflict or I/O error, 2 bad usage or refused input.
# Only `ignore` ever writes .gitignore.

set -uo pipefail

LINK_DIRS=(.claude .agents .cursor .gemini)

die()  { printf 'learn: %s\n' "$*" >&2; exit 1; }
bad()  { printf 'learn: %s\n' "$*" >&2; exit 2; }

usage() {
  sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0"
}

# Main checkout of the current repository, else $PWD.
root_dir() {
  local common top
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  if [ -z "$common" ]; then
    common=$(git rev-parse --git-common-dir 2>/dev/null) && common=$(cd -- "$common" 2>/dev/null && pwd -P) || common=""
  fi
  if [ -n "$common" ]; then
    if [ "$(basename -- "$common")" = .git ]; then
      dirname -- "$common"
      return 0
    fi
    # Not a plain .git dir (submodule, bare repo): use the work tree top.
    top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
    if [ -n "$top" ]; then
      printf '%s\n' "$top"
      return 0
    fi
  fi
  pwd
}

valid_name() {
  case $1 in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  [ "${#1}" -le 40 ]
}

check_name() {
  valid_name "${1:-}" || bad "invalid name '${1:-}': use [a-z0-9-], at most 40 characters"
}

# Fails (naming the path) when learned-<name> exists in a link dir and is not a symlink.
check_links_free() {
  local root=$1 name=$2 d p
  for d in "${LINK_DIRS[@]}"; do
    p=$root/$d/skills/learned-$name
    if [ -e "$p" ] && [ ! -L "$p" ]; then
      printf 'learn: %s exists and is not a symlink; left it alone\n' "$p" >&2
      return 1
    fi
  done
  return 0
}

# Create or refresh the four learned-<name> links. Returns 1 if one was refused.
link_skill() {
  local root=$1 name=$2 d dir p rc=0
  for d in "${LINK_DIRS[@]}"; do
    dir=$root/$d/skills
    p=$dir/learned-$name
    if [ -e "$p" ] && [ ! -L "$p" ]; then
      printf 'learn: %s exists and is not a symlink; left it alone\n' "$p" >&2
      rc=1; continue
    fi
    mkdir -p -- "$dir" || { printf 'learn: cannot create %s\n' "$dir" >&2; rc=1; continue; }
    if [ -L "$p" ] && [ "$(readlink -- "$p")" = "../../.opsx/skills/$name" ]; then
      continue
    fi
    rm -f -- "$p"
    ln -s -- "../../.opsx/skills/$name" "$p" || { printf 'learn: cannot link %s\n' "$p" >&2; rc=1; }
  done
  return "$rc"
}

# Rewrite the frontmatter of $1 (stdin copy) so name: is learned-<name>.
# Prints the result; exits 2 from awk when there is no frontmatter/description.
rewrite_frontmatter() {
  local file=$1 name=$2
  awk -v want="name: learned-$name" '
    NR == 1 { sub(/\r$/, "") }
    NR == 1 && $0 != "---" { exit 3 }
    NR == 1 { print; print want; infm = 1; next }
    infm == 1 {
      line = $0; sub(/\r$/, "", line)
      if (line == "---") { infm = 0; closed = 1; print; next }
      if (line ~ /^name:/) next
      if (line ~ /^description:[ \t]*[^ \t]/) desc = 1
      print; next
    }
    { print }
    END {
      if (NR == 0) exit 3
      if (!closed || !desc) exit 3
    }
  ' "$file"
}

skill_description() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    /^---[ \t\r]*$/ { exit }
    /^description:/ {
      sub(/^description:[ \t]*/, ""); sub(/\r$/, "")
      if ($0 ~ /^".*"$/ || $0 ~ /^\x27.*\x27$/) $0 = substr($0, 2, length($0) - 2)
      print; exit
    }
  ' "$1"
}

TMPIN="" TMPOUT=""
cleanup() { rm -f -- ${TMPIN:+"$TMPIN"} ${TMPOUT:+"$TMPOUT"}; }
trap cleanup EXIT

cmd_save() {
  local name=${1:-} root store dir
  [ $# -eq 1 ] || bad "usage: learn.sh save <name> < SKILL.md"
  check_name "$name"
  TMPIN=$(mktemp "${TMPDIR:-/tmp}/learn.XXXXXX") || die "cannot create a temp file"
  cat > "$TMPIN"
  if ! grep -q '[^[:space:]]' "$TMPIN"; then
    bad "empty input: pipe a SKILL.md on stdin"
  fi
  root=$(root_dir)
  store=$root/.opsx/skills
  dir=$store/$name
  TMPOUT=$(mktemp "${TMPDIR:-/tmp}/learn.XXXXXX") || die "cannot create a temp file"
  if ! rewrite_frontmatter "$TMPIN" "$name" > "$TMPOUT"; then
    bad "input has no frontmatter with a description: start with ---, a 'description:' line, then ---"
  fi
  check_links_free "$root" "$name" || exit 1
  mkdir -p -- "$dir" || die "cannot create $dir"
  local part=$dir/.SKILL.md.$$
  if ! { cp -- "$TMPOUT" "$part" && chmod 644 "$part" && mv -f -- "$part" "$dir/SKILL.md"; }; then
    rm -f -- "$part"; die "cannot write $dir/SKILL.md"
  fi
  link_skill "$root" "$name" || exit 1
  printf 'saved learned-%s -> %s/SKILL.md\n' "$name" "$dir"
}

# Names of stored skills (folders with a SKILL.md and a valid name).
stored_names() {
  local store=$1 d n
  [ -d "$store" ] || return 0
  for d in "$store"/*/; do
    [ -d "$d" ] || continue
    n=$(basename -- "$d")
    valid_name "$n" && [ -f "$d/SKILL.md" ] && printf '%s\n' "$n"
  done
}

cmd_sync() {
  [ $# -eq 0 ] || bad "usage: learn.sh sync"
  local root store n d p rc=0 linked=0 dropped=0
  root=$(root_dir); store=$root/.opsx/skills
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    link_skill "$root" "$n" || rc=1
    linked=$((linked + 1))
  done < <(stored_names "$store")
  for d in "${LINK_DIRS[@]}"; do
    for p in "$root/$d/skills"/learned-*; do
      [ -L "$p" ] || continue
      if [ ! -e "$p" ]; then
        rm -f -- "$p" && dropped=$((dropped + 1))
      fi
    done
  done
  printf 'synced %d skill(s), removed %d dangling link(s) in %s\n' "$linked" "$dropped" "$root"
  return "$rc"
}

cmd_list() {
  [ $# -eq 0 ] || bad "usage: learn.sh list"
  local root store n d links desc any=0
  root=$(root_dir); store=$root/.opsx/skills
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    any=1
    links=""
    for d in "${LINK_DIRS[@]}"; do
      [ -L "$root/$d/skills/learned-$n" ] && [ -e "$root/$d/skills/learned-$n" ] && links="$links $d"
    done
    desc=$(skill_description "$store/$n/SKILL.md")
    printf '%s\t%s\tlinks:%s\n' "$n" "$desc" "${links:- none}"
  done < <(stored_names "$store")
  [ "$any" -eq 1 ] || printf 'no learned skills in %s/.opsx/skills/\n' "$root"
}

cmd_remove() {
  [ $# -eq 1 ] || bad "usage: learn.sh remove <name>"
  local name=$1 root d p found=0
  check_name "$name"
  root=$(root_dir)
  if [ -d "$root/.opsx/skills/$name" ]; then
    rm -rf -- "$root/.opsx/skills/$name" || die "cannot remove $root/.opsx/skills/$name"
    found=1
  fi
  for d in "${LINK_DIRS[@]}"; do
    p=$root/$d/skills/learned-$name
    if [ -L "$p" ]; then
      rm -f -- "$p" && found=1
    elif [ -e "$p" ]; then
      printf 'learn: %s is not a symlink; left it alone\n' "$p" >&2
    fi
  done
  if [ "$found" -eq 1 ]; then
    printf 'removed learned-%s from %s\n' "$name" "$root"
  else
    printf 'nothing matched %s in %s\n' "$name" "$root"
  fi
}

cmd_ignore() {
  [ $# -eq 0 ] || bad "usage: learn.sh ignore"
  local root gi line added=0
  root=$(root_dir); gi=$root/.gitignore
  for line in '.opsx/skills/' '**/skills/learned-*'; do
    if [ -f "$gi" ] && grep -qxF -- "$line" "$gi"; then
      continue
    fi
    if [ -s "$gi" ] && [ -n "$(tail -c1 -- "$gi")" ]; then
      printf '\n' >> "$gi" || die "cannot write $gi"
    fi
    printf '%s\n' "$line" >> "$gi" || die "cannot write $gi"
    printf 'added to %s: %s\n' "$gi" "$line"
    added=1
  done
  [ "$added" -eq 1 ] || printf '%s already ignores learned skills\n' "$gi"
}

cmd=${1:-help}
[ $# -gt 0 ] && shift
case $cmd in
  root)   [ $# -eq 0 ] || bad "usage: learn.sh root"; root_dir ;;
  save)   cmd_save "$@" ;;
  sync)   cmd_sync "$@" ;;
  list)   cmd_list "$@" ;;
  remove) cmd_remove "$@" ;;
  ignore) cmd_ignore "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
