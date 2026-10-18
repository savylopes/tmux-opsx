#!/usr/bin/env bash
# Scripted tests for the learn skill (skills/learn/learn.sh + SKILL.md) and its
# install.sh wiring.
#
# Everything runs in scratch dirs: scratch git repos, a worktree, a non-git
# directory and scratch HOMEs. Your real HOME and repos are never touched.
# Usage: bash tests/test-learn.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016
set -u
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
SELF=$REPO/tests/test-learn.sh
L=$REPO/skills/learn/learn.sh
SP=$(mktemp -d "${TMPDIR:-/tmp}/learn-test.XXXXXX")
SP=$(cd "$SP" && pwd -P)
trap 'rm -rf "$SP"' EXIT
export TMPDIR=$SP/tmp; mkdir -p "$TMPDIR"
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
N=0
new_repo() {
  N=$((N+1)); R=$SP/shop$N; mkdir -p "$R"
  git -C "$R" init -q -b main && git -C "$R" commit -q --allow-empty -m init
}
learn() { (cd "$1" && shift && bash "$L" "$@"); }
skill() {  # skill <description-or-empty> [name]
  printf -- '---\nname: %s\n' "${2:-whatever}"
  [ -n "$1" ] && printf 'description: "%s"\n' "$1"
  printf -- '---\n\n# Body\n\n1. run `make x`\n'
}
links_of() {  # links_of <root> <name>: count of correct relative links
  local c=0 d
  for d in .claude .agents .cursor .gemini; do
    [ -L "$1/$d/skills/learned-$2" ] && [ "$(readlink "$1/$d/skills/learned-$2")" = "../../.opsx/skills/$2" ] \
      && [ -f "$1/$d/skills/learned-$2/SKILL.md" ] && c=$((c+1))
  done
  echo "$c"
}
tree_of() { (cd "$1" && find . -path ./.git -prune -o -print | sort); }

# ---------------------------------------------------------------- 1.1 root + names
new_repo; git -C "$R" worktree add -q "$SP/wt-x" -b x
ok "root: main checkout prints itself" '[ "$(learn "$R" root)" = "$R" ]'
mkdir -p "$R/sub/dir"
ok "root: subdirectory -> main checkout" '[ "$(learn "$R/sub/dir" root)" = "$R" ]'
ok "root: worktree -> main checkout" '[ "$(learn "$SP/wt-x" root)" = "$R" ]'
mkdir -p "$SP/plain/inner"
ok "root: outside git -> that directory" '[ "$(cd "$SP/plain/inner" && GIT_CEILING_DIRECTORIES=$SP bash "$L" root)" = "$SP/plain/inner" ]'
for bad in "Bad Name" "UPPER" "a_b" "a/b" ".." "" "$(printf 'a%.0s' $(seq 41))"; do
  out=$(skill "d" | learn "$R" save "$bad" 2>&1); rc=$?
  ok "name refused: '${bad:0:12}' -> exit 2" '[ $rc -eq 2 ]'
done
before=$(tree_of "$R")
ok "refused names create nothing" '[ "$(tree_of "$R")" = "$before" ] && [ ! -e "$R/.opsx" ]'
out=$(skill "d" | learn "$R" save "$(printf 'a%.0s' $(seq 40))" 2>&1); rc=$?
ok "40-character name accepted" '[ $rc -eq 0 ]'
learn "$R" remove "$(printf 'a%.0s' $(seq 40))" >/dev/null

# ---------------------------------------------------------------- 1.2 save + links
new_repo
out=$(skill "Re-run the zone proof. Use when asked to re-check it." whatever | learn "$R" save rerun-zone-proof 2>&1); rc=$?
F=$R/.opsx/skills/rerun-zone-proof/SKILL.md
ok "save: exit 0" '[ $rc -eq 0 ] || { echo "$out"; false; }'
ok "save: file exists with name learned-<name>" '[ -f "$F" ] && grep -qx "name: learned-rerun-zone-proof" "$F" && ! grep -q "^name: whatever" "$F"'
ok "save: description and body kept" 'grep -q "^description: \"Re-run the zone proof" "$F" && grep -q "run \`make x\`" "$F"'
ok "save: exactly one name line" '[ "$(grep -c "^name:" "$F")" -eq 1 ]'
ok "save: .claude link is a symlink to the folder" '[ -L "$R/.claude/skills/learned-rerun-zone-proof" ] && [ "$(cd "$R/.claude/skills/learned-rerun-zone-proof" && pwd -P)" = "$R/.opsx/skills/rerun-zone-proof" ]'
ok "save: four relative links" '[ "$(links_of "$R" rerun-zone-proof)" -eq 4 ]'
ok "save: no .opencode" '[ ! -e "$R/.opencode" ]'
ok "save: announces the path" '[[ "$out" == *"$F"* ]]'
ok "save: no .gitignore created" '[ ! -e "$R/.gitignore" ]'
ok "save: no temp leftovers" '[ "$(ls -A "$R/.opsx/skills/rerun-zone-proof")" = SKILL.md ] && [ -z "$(ls -A "$TMPDIR")" ]'
ok "save: clean stderr" '[[ "$out" != *"unbound"* ]] && [ "$(printf "%s\n" "$out" | wc -l)" -eq 1 ]'

printf -- '---\ndescription: no name line\n---\nbody\n' | learn "$R" save noname >/dev/null 2>&1
ok "save: missing name line gets one" 'grep -qx "name: learned-noname" "$R/.opsx/skills/noname/SKILL.md" && [ "$(sed -n 1p "$R/.opsx/skills/noname/SKILL.md")" = "---" ]'

skill "updated description" | learn "$R" save rerun-zone-proof >/dev/null 2>&1
ok "save: existing name is replaced" 'grep -q "updated description" "$F" && [ "$(grep -c "^description:" "$F")" -eq 1 ] && [ "$(links_of "$R" rerun-zone-proof)" -eq 4 ]'

new_repo; before=$(tree_of "$R")
out=$(printf '' | learn "$R" save ok 2>&1); rc1=$?
out=$(printf '  \n\n' | learn "$R" save ok 2>&1); rc2=$?
out=$(skill "" | learn "$R" save ok 2>&1); rc3=$?
out=$(printf '# no frontmatter\ndescription: x\n' | learn "$R" save ok 2>&1); rc4=$?
out=$(printf -- '---\ndescription: x\n' | learn "$R" save ok 2>&1); rc5=$?
out=$(printf -- '---\nname: a\n---\ndescription: in the body\n' | learn "$R" save ok 2>&1); rc6=$?
ok "save: empty stdin -> exit 2" '[ $rc1 -eq 2 ] && [ $rc2 -eq 2 ]'
ok "save: no description -> exit 2" '[ $rc3 -eq 2 ] && [ $rc6 -eq 2 ]'
ok "save: no / unclosed frontmatter -> exit 2" '[ $rc4 -eq 2 ] && [ $rc5 -eq 2 ]'
ok "save: refused input changes nothing" '[ "$(tree_of "$R")" = "$before" ] && [ -z "$(ls -A "$TMPDIR")" ]'

new_repo; git -C "$R" worktree add -q "$SP/wt-y$N" -b y
skill "d" | learn "$SP/wt-y$N" save x >/dev/null 2>&1
ok "save from a worktree lands in the main checkout" '[ -f "$R/.opsx/skills/x/SKILL.md" ] && [ "$(links_of "$R" x)" -eq 4 ] && [ ! -e "$SP/wt-y$N/.opsx" ] && [ ! -e "$SP/wt-y$N/.claude" ]'

new_repo
mkdir -p "$R/.claude/skills/openspec-propose"; printf 'mine\n' > "$R/.claude/skills/openspec-propose/SKILL.md"
ln -s /nonexistent "$R/.claude/skills/other-link"
snap=$(cd "$R/.claude/skills" && ls -la openspec-propose; cat openspec-propose/SKILL.md; readlink other-link)
skill "d" | learn "$R" save x >/dev/null 2>&1
ok "other skills untouched" '[ "$(cd "$R/.claude/skills" && ls -la openspec-propose; cat openspec-propose/SKILL.md; readlink other-link)" = "$snap" ]'
learn "$R" sync >/dev/null 2>&1
ok "sync leaves non-learned dangling links alone" '[ -L "$R/.claude/skills/other-link" ]'

new_repo
mkdir -p "$R/.claude/skills/learned-x"; printf 'hand\n' > "$R/.claude/skills/learned-x/SKILL.md"
out=$(skill "d" | learn "$R" save x 2>&1); rc=$?
ok "not a link: non-zero exit naming the path" '[ $rc -ne 0 ] && [[ "$out" == *"$R/.claude/skills/learned-x"* ]]'
ok "not a link: directory unchanged, nothing saved" '[ ! -L "$R/.claude/skills/learned-x" ] && [ "$(cat "$R/.claude/skills/learned-x/SKILL.md")" = hand ] && [ ! -e "$R/.opsx/skills/x" ]'

# ---------------------------------------------------------------- 1.3 sync, list, remove, ignore
new_repo
skill "does x" | learn "$R" save x >/dev/null 2>&1
skill "does y" | learn "$R" save y >/dev/null 2>&1
skill "does z" | learn "$R" save z >/dev/null 2>&1
rm "$R/.gemini/skills/learned-x"; rm -rf "$R/.opsx/skills/y"
out=$(learn "$R" sync 2>&1); rc=$?
ok "sync: exit 0" '[ $rc -eq 0 ]'
ok "sync: recreates the missing link" '[ "$(links_of "$R" x)" -eq 4 ]'
ok "sync: removes dangling learned-y links" '! ls -d "$R"/.*/skills/learned-y >/dev/null 2>&1 && ! [ -L "$R/.claude/skills/learned-y" ]'
ok "sync: z untouched" '[ "$(links_of "$R" z)" -eq 4 ]'
rm -rf "$R/.cursor"
learn "$R" sync >/dev/null 2>&1
ok "sync: recreates a missing CLI folder" '[ "$(links_of "$R" x)" -eq 4 ] && [ "$(links_of "$R" z)" -eq 4 ]'

rm "$R/.agents/skills/learned-z"
out=$(learn "$R" list 2>&1)
ok "list: one line per skill" '[ "$(printf "%s\n" "$out" | wc -l)" -eq 2 ]'
ok "list: name, description, links" 'printf "%s\n" "$out" | grep -q "^x	does x	links: .claude .agents .cursor .gemini$"'
ok "list: missing link not listed" 'printf "%s\n" "$out" | grep -q "^z	does z	links: .claude .cursor .gemini$"'
learn "$R" sync >/dev/null 2>&1
new_repo; out=$(learn "$R" list 2>&1)
ok "list: empty store says so" '[[ "$out" == *"no learned skills"* ]]'

new_repo
skill "d" | learn "$R" save x >/dev/null 2>&1
skill "d" | learn "$R" save keep >/dev/null 2>&1
out=$(learn "$R" remove x 2>&1); rc=$?
ok "remove: exit 0" '[ $rc -eq 0 ]'
ok "remove: folder and every learned-x link gone" '[ ! -e "$R/.opsx/skills/x" ] && for d in .claude .agents .cursor .gemini; do [ ! -L "$R/$d/skills/learned-x" ] || exit 1; done'
ok "remove: other skills unchanged" '[ -f "$R/.opsx/skills/keep/SKILL.md" ] && [ "$(links_of "$R" keep)" -eq 4 ]'
out=$(learn "$R" remove nope 2>&1); rc=$?
ok "remove: unknown name -> exit 0, nothing matched" '[ $rc -eq 0 ] && [[ "$out" == *"nothing matched"* ]]'
out=$(learn "$R" remove "Bad Name" 2>&1); rc=$?
ok "remove: bad name -> exit 2" '[ $rc -eq 2 ]'

new_repo
skill "d" | learn "$R" save x >/dev/null 2>&1
ok "before ignore: skill and link are not ignored" '! git -C "$R" check-ignore -q .opsx/skills/x/SKILL.md && ! git -C "$R" check-ignore -q .claude/skills/learned-x'
out1=$(learn "$R" ignore 2>&1); out2=$(learn "$R" ignore 2>&1)
ok "ignore: each line exactly once after two runs" '[ "$(grep -cxF ".opsx/skills/" "$R/.gitignore")" -eq 1 ] && [ "$(grep -cxF "**/skills/learned-*" "$R/.gitignore")" -eq 1 ]'
ok "ignore: prints what it added, then nothing new" '[[ "$out1" == *".opsx/skills/"* ]] && [[ "$out1" == *"**/skills/learned-*"* ]] && [[ "$out2" != *"added"* ]]'
ok "ignore: git check-ignore on skill file and links" 'for p in .opsx/skills/x/SKILL.md .claude/skills/learned-x .agents/skills/learned-x .cursor/skills/learned-x .gemini/skills/learned-x; do git -C "$R" check-ignore -q "$p" || exit 1; done'
ok "ignore: git status shows nothing to add" '[ -z "$(git -C "$R" status --porcelain --untracked-files=all | grep -v "^?? .gitignore$")" ]'
new_repo; printf 'node_modules' > "$R/.gitignore"
learn "$R" ignore >/dev/null 2>&1
ok "ignore: appends after a file without trailing newline" '[ "$(sed -n 1p "$R/.gitignore")" = node_modules ] && grep -qxF ".opsx/skills/" "$R/.gitignore"'
new_repo; git -C "$R" worktree add -q "$SP/wt-i$N" -b i
learn "$SP/wt-i$N" ignore >/dev/null 2>&1
ok "ignore from a worktree writes the main checkout's .gitignore" '[ -f "$R/.gitignore" ] && [ ! -e "$SP/wt-i$N/.gitignore" ]'

ok "only ignore writes .gitignore" '! sed "/^cmd_ignore()/,/^}/d" "$L" | grep -v "^#" | grep -q gitignore'
ok "shellcheck learn.sh (if installed)" '! command -v shellcheck >/dev/null || shellcheck -S warning "$L" "$SELF"'

# ---------------------------------------------------------------- 2.1 skill text
S=$REPO/skills/learn/SKILL.md
check_rule() {  # check_rule <file>: every item of the automatic capture rule
  local f=$1
  grep -q '\.opsx/skills/' "$f" && grep -qi 'multi-step' "$f" && grep -qi 'specific to this project' "$f" \
    && grep -qi 'verified' "$f" && grep -qi 'reusable' "$f" && grep -qi 'not already covered' "$f" \
    && grep -qi 'update' "$f" && grep -qi 'duplicat' "$f" && grep -qi 'memory' "$f" \
    && grep -qi 'secrets' "$f" && grep -qi 'one line' "$f"
}
ok "SKILL.md: frontmatter name learn + description" '[ "$(sed -n 2p "$S")" = "name: learn" ] && sed -n 3p "$S" | grep -q "^description: "'
ok "SKILL.md: capture rule items" 'check_rule "$S"'
ok "SKILL.md: learn.sh list before save, save, ignore only on request" 'grep -q "learn.sh\" list\|\"\$L\" list" "$S" && grep -q "save <name>" "$S" && grep -qi "only when the user asks" "$S"'

# ---------------------------------------------------------------- 2.2 + 3.1 install
mkdir -p "$SP/ibin"
for b in claude node npm; do printf '#!/bin/sh\necho 1.0.0\n' > "$SP/ibin/$b"; chmod +x "$SP/ibin/$b"; done
run_install(){  # run_install <home> [flags...]
  local h=$1; shift
  (cd "$REPO" && env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_HOME -u OPENCODE_CONFIG_DIR -u TMUX -u TMUX_PANE \
     -u SUDO_USER -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u OPSX_MODELS_CONF NO_COLOR=1 \
     HOME="$h" PATH="$h/.local/bin:$SP/ibin:/usr/bin:/bin" bash ./install.sh --skip-openspec --skip-graphify \
     --skip-commands --skip-mcp --skip-fork --skip-explain --skip-review --skip-init --no-backup "$@" </dev/null 2>&1)
}
SIX=".claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills"
FOUR=".claude/CLAUDE.md .codex/AGENTS.md .config/opencode/AGENTS.md .gemini/GEMINI.md"
IH=$SP/ih1; mkdir -p "$IH"
out=$(run_install "$IH"); rc=$?
ok "install exits 0" '[ $rc -eq 0 ] || { printf "%s\n" "$out" | tail -20; false; }'
ok "install: learn.sh executable in all six skill dirs" 'for d in $SIX; do [ -f "$IH/$d/learn/SKILL.md" ] && [ -x "$IH/$d/learn/learn.sh" ] || exit 1; done'
ok "install: learn block in the four instruction files" 'for f in $FOUR; do [ "$(grep -cxF "<!-- tmux-opsx:learn:start -->" "$IH/$f")" -eq 1 ] && grep -qxF "<!-- tmux-opsx:learn:end -->" "$IH/$f" || exit 1; done'
ok "install: Cursor note prints the learn block" '[[ "$out" == *"Cursor: add the learn block manually"* ]]'
ok "install: verify step checks learn" '[[ "$out" == *"learn.sh parses"* ]]'
blk=$SP/learnblock; sed -n '/<!-- tmux-opsx:learn:start -->/,/<!-- tmux-opsx:learn:end -->/p' "$IH/.claude/CLAUDE.md" > "$blk"
ok "learn block: capture rule items" 'check_rule "$blk"'
mem_before=$(sed -n '/<!-- tmux-opsx:memory:start -->/,/<!-- tmux-opsx:memory:end -->/p' "$IH/.claude/CLAUDE.md")
ok "memory block also present" '[ -n "$mem_before" ]'
out=$(run_install "$IH"); rc=$?
ok "second install: exit 0, learn block still once" '[ $rc -eq 0 ] && for f in $FOUR; do [ "$(grep -cxF "<!-- tmux-opsx:learn:start -->" "$IH/$f")" -eq 1 ] || exit 1; done'
ok "second install: memory block unchanged" '[ "$(sed -n "/<!-- tmux-opsx:memory:start -->/,/<!-- tmux-opsx:memory:end -->/p" "$IH/.claude/CLAUDE.md")" = "$mem_before" ]'
ok "installed learn.sh works" '[ "$(cd "$SP/plain" && GIT_CEILING_DIRECTORIES=$SP "$IH/.claude/skills/learn/learn.sh" root)" = "$SP/plain" ]'

new_repo; skill "d" | learn "$R" save x >/dev/null 2>&1
out=$(run_install "$IH" --uninstall); rc=$?
ok "uninstall: exit 0, no learn skill dirs" '[ $rc -eq 0 ] && for d in $SIX; do [ ! -e "$IH/$d/learn" ] || exit 1; done'
ok "uninstall: no learn block left" 'for f in $FOUR; do [ ! -f "$IH/$f" ] || ! grep -qF "tmux-opsx:learn:" "$IH/$f" || exit 1; done'
ok "uninstall: project .opsx/skills/ left alone" '[ -f "$R/.opsx/skills/x/SKILL.md" ] && [ "$(links_of "$R" x)" -eq 4 ]'

IH=$SP/ih2; mkdir -p "$IH"
out=$(run_install "$IH" --skip-learn); rc=$?
ok "--skip-learn: exit 0, no learn skill, no learn block" '[ $rc -eq 0 ] && for d in $SIX; do [ ! -e "$IH/$d/learn" ] || exit 1; done && ! grep -qF "tmux-opsx:learn:" "$IH/.claude/CLAUDE.md"'
ok "--skip-learn: memory block unaffected" 'grep -qxF "<!-- tmux-opsx:memory:start -->" "$IH/.claude/CLAUDE.md" && [ "$(sed -n "/<!-- tmux-opsx:memory:start -->/,/<!-- tmux-opsx:memory:end -->/p" "$IH/.claude/CLAUDE.md")" = "$mem_before" ]'
ok "install --help lists --skip-learn" 'bash "$REPO/install.sh" --help | grep -q -- "--skip-learn"'

# ---------------------------------------------------------------- 3.2 README
RD=$REPO/README.md
ok "README: learn.sh, .opsx/skills/, learned-, --skip-learn, learn.sh ignore" 'grep -q "learn.sh" "$RD" && grep -q "\.opsx/skills/" "$RD" && grep -q "learned-" "$RD" && grep -q -- "--skip-learn" "$RD" && grep -q "learn.sh ignore" "$RD"'
ok "README: tests list has test-learn.sh" 'grep -q "tests/test-learn.sh" "$RD"'

echo ""
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
