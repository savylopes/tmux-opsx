# Helpers for project-init checks: scratch repos, fake openspec/graphify/docker,
# and a PATH without a real docker. Sourced by checks; not a check itself.
set -u
fail() { echo "FAIL: $*"; exit 1; }
OPSX="$EVAL_ROOT/bin/opsx"
export OPSX_SKILLS_DIR="$EVAL_ROOT/skills"
export HOME="$EVAL_TMP/home"; mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_HOME="$HOME/.codex" XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"; mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
# A PATH made of symlinks to the system tools, minus docker/graphify/openspec.
SYSBIN="$EVAL_TMP/sysbin"; FAKEBIN="$EVAL_TMP/fakebin"; mkdir -p "$SYSBIN" "$FAKEBIN"
for d in /usr/bin /bin; do
  for f in "$d"/*; do
    b=${f##*/}
    case "$b" in docker|graphify|openspec) continue;; esac
    [ -e "$SYSBIN/$b" ] || ln -s "$f" "$SYSBIN/$b" 2>/dev/null
  done
done
ORIG_PATH=$PATH
export PATH="$FAKEBIN:$SYSBIN"
fake() {  # fake <name> [extra shell]: logs args to $EVAL_TMP/<name>.log
  printf '#!/bin/sh\necho "$*" >> "%s/%s.log"\n%s\n' "$EVAL_TMP" "$1" "${2:-}" > "$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}
fake_openspec() { fake openspec 'mkdir -p openspec/specs openspec/changes'; }
mkrepo() {  # mkrepo [dir]: empty git repo, cd into it
  R="${1:-$EVAL_TMP/repo}"; mkdir -p "$R"; cd "$R" || exit 1
  git init -q . || exit 1
}
commit_all() { git add -A && git commit -qm base; }
run_init() {  # run_init args... -> sets out, rc
  out=$("$OPSX" init "$@" 2>&1 </dev/null); rc=$?
  echo "--- opsx init $* (exit $rc)"; echo "$out"
}
snap() { find . -path ./.git -prune -o -type f -exec sha1sum {} + 2>/dev/null | sort; }
