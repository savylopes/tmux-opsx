#!/usr/bin/env bash
# Scripted tests for skills/opsx-run/opsx-dev.sh (`opsx dev`) and the
# container cleanup in opsx-window.sh close.
#
# Runs in a scratch HOME/XDG with scratch git repos (project `shop`, a
# worktree on opsx/add-auth). `docker` is tests/fake-docker.sh, which records
# every call (docker.log, argv.N) and keeps container state in files; `fail`
# lines ("<rc> <substring>") make a matching call exit with <rc>. tmux work
# goes to a private server. Never talks to a real Docker daemon or your tmux session.
# Usage: bash tests/test-dev.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016
set -u
for t in git tmux; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t is required"; exit 1; }
done
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
DEV=$REPO/skills/opsx-run/opsx-dev.sh
W=$REPO/skills/opsx-run/opsx-window.sh
OPSX=$REPO/bin/opsx
SP=$(cd -- "$(mktemp -d "${TMPDIR:-/tmp}/dev-test.XXXXXX")" && pwd -P)
SOCK_NAME=opsx-dev-test-$$
L="tmux -L $SOCK_NAME"

export HOME=$SP/home XDG_CONFIG_HOME=$SP/home/.config XDG_STATE_HOME=$SP/home/.local/state
mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export OPSX_SKILLS_DIR=$REPO/skills

cleanup() {
  $L kill-server 2>/dev/null
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK_NAME"
  rm -rf "$SP"
}
trap cleanup EXIT

# ---------------------------------------------------------------- fake docker
FD=$SP/docker
mkdir -p "$SP/bin" "$FD/c" "$FD/img"
cp "$REPO/tests/fake-docker.sh" "$SP/bin/docker"
chmod +x "$SP/bin/docker"
printf '#!/usr/bin/env bash\nexec sleep 3000\n' > "$SP/bin/fakecli"
chmod +x "$SP/bin/fakecli"
export FAKE_DOCKER_DIR=$FD
FULL_PATH=$SP/bin:$PATH
export PATH=$FULL_PATH

# A PATH with everything but docker (the fake and any real one).
mkdir -p "$SP/nodocker"
IFS=: read -ra _dirs <<<"$PATH"
for dd in "${_dirs[@]}"; do
  [ "$dd" = "$SP/bin" ] && continue
  for f in "$dd"/*; do
    b=${f##*/}
    [ "$b" = docker ] && continue
    [ -x "$f" ] && [ ! -e "$SP/nodocker/$b" ] && ln -s "$f" "$SP/nodocker/$b"
  done
done
ln -s "$SP/bin/fakecli" "$SP/nodocker/fakecli" 2>/dev/null
NODOCKER_PATH=$SP/nodocker

pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

reset_docker() { rm -rf "$FD"; mkdir -p "$FD/c" "$FD/img"; }
log()     { cat "$FD/docker.log" 2>/dev/null; }
ncalls()  { log | grep -c -- "$1"; }
# argv file of the last call whose log line starts with $1.
last_argv() {
  local i
  i=$(grep -n -- "^$1" "$FD/docker.log" | tail -n 1 | cut -d: -f1)
  [ -n "$i" ] && cat "$FD/argv.$i"
}
dv() { local dir=$1; shift; ( cd "$dir" && "$DEV" "$@" ); }

# ---------------------------------------------------------------- scratch repo
PROJ=shop
R=$SP/$PROJ
WT=$SP/wt-add-auth
mkdir -p "$R/pkg" "$R/.opsx"
git -C "$R" init -q -b main
echo x > "$R/pkg/x.go"
git -C "$R" add -A; git -C "$R" commit -qm init
git -C "$R" worktree add -q "$WT" -b opsx/add-auth >/dev/null 2>&1
GITDIR=$R/.git
UG="$(id -u):$(id -g)"
CN=opsx-dev-shop-add-auth

# ================================================================ 1.1 config
ok "bash -n"                                    'bash -n "$DEV"'
out=$(dv "$WT" go version 2>&1); rc=$?
ok "missing dev.yaml: non-zero, names opsx init" '[ $rc -ne 0 ] && [[ "$out" == *"opsx init"* ]] && [ "$(ncalls "^run")" -eq 0 ]'

mkdir -p "$WT/.opsx"
printf 'image: golang:1.22\ndockerfile: .opsx/Dockerfile\n' > "$WT/.opsx/dev.yaml"
out=$(dv "$WT" true 2>&1); rc=$?
ok "both image and dockerfile: non-zero, names both, no run" '[ $rc -ne 0 ] && [[ "$out" == *image* ]] && [[ "$out" == *dockerfile* ]] && ! log | grep -q "^run"'
printf '# nothing\nsetup: true\n' > "$WT/.opsx/dev.yaml"
out=$(dv "$WT" true 2>&1); rc=$?
ok "neither image nor dockerfile: non-zero"     '[ $rc -ne 0 ] && [[ "$out" == *neither* ]] && ! log | grep -q "^run"'

printf 'image: golang:1.22\ncolour: blue\n' > "$WT/.opsx/dev.yaml"
out=$(dv "$WT" true 2>&1); rc=$?
ok "unknown key: warns, still runs"             '[ $rc -eq 0 ] && [[ "$out" == *colour* ]] && [ "$(ncalls "^exec .* $CN true")" -eq 1 ]'

out=$( cd "$WT" && PATH=$NODOCKER_PATH "$DEV" go version 2>&1 ); rc=$?
ok "missing docker: non-zero, mentions docker"  '[ $rc -ne 0 ] && [[ "$out" == *docker* ]]'

# ================================================================ 1.2 create
reset_docker
printf 'image: golang:1.22\ncache: /go/pkg/mod\n' > "$WT/.opsx/dev.yaml"
dv "$WT" true >/dev/null 2>&1; rc1=$?
dv "$WT" true >/dev/null 2>&1; rc2=$?
ok "change worktree: container $CN created once" '[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ "$(ncalls "^run ")" -eq 1 ] && log | grep -q "^run .*--name $CN "'
ok "change worktree: exec twice"                '[ "$(ncalls "^exec .* $CN true$")" -eq 2 ]'
A=$(last_argv "run ")
ok "create: -d and --network host"              'grep -qx -- -d <<<"$A" && grep -A1 -x -- --network <<<"$A" | grep -qx host'
ok "create: checkout at the same path"          'grep -qx -- "$WT:$WT" <<<"$A"'
ok "create: main .git at the same path"         'grep -qx -- "$GITDIR:$GITDIR" <<<"$A"'
ok "create: named volume on the cache path"     'grep -qx -- "opsx-dev-shop-cache-go-pkg-mod:/go/pkg/mod" <<<"$A"'
ok "create: home volume"                        'grep -qx -- "opsx-dev-shop-home:/opsx-home" <<<"$A"'
ok "create: labels project, checkout, hash"     'grep -qx "opsx.dev.project=shop" <<<"$A" && grep -qx "opsx.dev.checkout=$WT" <<<"$A" && grep -q "^opsx.dev.hash=" <<<"$A"'
ok "create: sleep entrypoint, image, infinity"  'grep -A1 -x -- --entrypoint <<<"$A" | grep -qx sleep && [ "$(tail -n 2 <<<"$A" | tr "\n" " ")" = "golang:1.22 infinity " ]'
ok "create: volumes chowned as root once"       '[ "$(ncalls "^exec -u 0:0 $CN chown -R $UG /opsx-home /go/pkg/mod")" -eq 1 ]'

reset_docker
dv "$R" true >/dev/null 2>&1 || true
ok "main checkout: opsx-dev-shop-main (no dev.yaml there yet -> none)" '! log | grep -q "^run"'
mkdir -p "$R/.opsx"; printf 'image: golang:1.22\n' > "$R/.opsx/dev.yaml"
dv "$R" true >/dev/null 2>&1
ok "main checkout: container opsx-dev-shop-main" 'log | grep -q "^run .*--name opsx-dev-shop-main "'
A=$(last_argv "run ")
ok "main checkout: no separate .git mount"      '! grep -qx -- "$GITDIR:$GITDIR" <<<"$A"'
git -C "$R" worktree add -q "$SP/Other Tree" -b feature/x >/dev/null 2>&1
mkdir -p "$SP/Other Tree/.opsx"; printf 'image: golang:1.22\n' > "$SP/Other Tree/.opsx/dev.yaml"
dv "$SP/Other Tree" true >/dev/null 2>&1
ok "other worktree: folder name, sanitised"     'log | grep -q "^run .*--name opsx-dev-shop-other-tree "'

# ================================================================ 1.3 exec
reset_docker
printf 'image: golang:1.22\n' > "$WT/.opsx/dev.yaml"
dv "$WT" true >/dev/null 2>&1
printf '3 go test\n' > "$FD/fail"
dv "$WT/pkg" go test ./pkg >/dev/null 2>&1; rc=$?
rm -f "$FD/fail"
A=$(last_argv "exec ")
ok "exec: exit status returned (3)"             '[ $rc -eq 3 ]'
ok "exec: -u uid:gid"                           'grep -A1 -x -- -u <<<"$A" | grep -qx "$UG"'
ok "exec: -w current directory"                 'grep -A1 -x -- -w <<<"$A" | grep -qx "$WT/pkg"'
ok "exec: HOME=/opsx-home"                      'grep -A1 -x -- -e <<<"$A" | grep -qx "HOME=/opsx-home"'
ok "exec: argv as separate words"               '[ "$(tail -n 4 <<<"$A" | tr "\n" "|")" = "$CN|go|test|./pkg|" ]'
dv "$WT" printf '%s\n' 'a b' '$HOME' >/dev/null 2>&1
A=$(last_argv "exec ")
ok "exec: no shell re-interpretation"           'grep -qx "a b" <<<"$A" && grep -qx "\$HOME" <<<"$A"'
dv "$WT" true > "$SP/out.txt" 2>&1
A=$(last_argv "exec ")
ok "exec: no -t when stdout is a file"          '! grep -qx -- -t <<<"$A" && ! grep -qx -- -it <<<"$A"'
out=$(dv "$WT" -x 2>&1); rc=$?
ok "unknown option -> exit 2, hints --"         '[ $rc -eq 2 ] && [[ "$out" == *"opsx dev -- -x"* ]]'
dv "$WT" -- -x >/dev/null 2>&1
ok "-- passes a dash command"                   '[ "$(last_argv "exec " | tail -n 1)" = "-x" ]'

# ================================================================ setup
reset_docker
printf 'image: golang:1.22\nsetup: go mod download\nsetup: echo second\n' > "$WT/.opsx/dev.yaml"
dv "$WT" true >/dev/null 2>&1
dv "$WT" true >/dev/null 2>&1
ok "setup once, in order, as the user in the checkout root" '[ "$(ncalls "^exec -u $UG -w $WT -e HOME=/opsx-home $CN sh -c go mod download$")" -eq 1 ] && [ "$(ncalls "sh -c echo second$")" -eq 1 ] && [ "$(log | grep -n "sh -c go mod download" | cut -d: -f1)" -lt "$(log | grep -n "sh -c echo second" | cut -d: -f1)" ]'
reset_docker
printf '1 sh -c go mod download\n' > "$FD/fail"
out=$(dv "$WT" true 2>&1); rc=$?
rm -f "$FD/fail"
ok "setup failure: non-zero, names the line, rm -f" '[ $rc -ne 0 ] && [[ "$out" == *"go mod download"* ]] && log | grep -qx "rm -f $CN" && [ ! -f "$FD/c/$CN" ]'
ok "setup failure: the command did not run"     '[ "$(ncalls "^exec .* $CN true$")" -eq 0 ]'

# ================================================================ Dockerfile
reset_docker
printf 'FROM golang:1.22\n' > "$WT/.opsx/Dockerfile"
printf 'dockerfile: .opsx/Dockerfile\n' > "$WT/.opsx/dev.yaml"
dv "$WT" true >/dev/null 2>&1
dv "$WT" true >/dev/null 2>&1
TAG=opsx-dev/shop:$(sha256sum < "$WT/.opsx/Dockerfile" | cut -c1-12)
ok "dockerfile: one build, tagged opsx-dev/shop:<hash>" '[ "$(ncalls "^build ")" -eq 1 ] && log | grep -q "^build -t $TAG -f $WT/.opsx/Dockerfile $WT$"'
ok "dockerfile: container from the tag"         'log | grep -q "^run .* $TAG infinity$"'
printf '1 build \n' > "$FD/fail"
printf 'FROM golang:1.23\n' > "$WT/.opsx/Dockerfile"
reset_docker; printf '1 build \n' > "$FD/fail"
out=$(dv "$WT" true 2>&1); rc=$?
rm -f "$FD/fail"
ok "dockerfile: failed build -> non-zero, no container" '[ $rc -ne 0 ] && ! log | grep -q "^run "'

# ================================================================ recreate
reset_docker
printf 'image: golang:1.22\nsetup: go mod download\n' > "$WT/.opsx/dev.yaml"
dv "$WT" true >/dev/null 2>&1
printf 'image: golang:1.23\nsetup: go mod download\n' > "$WT/.opsx/dev.yaml"
out=$(dv "$WT" true 2>&1); rc=$?
ok "dev.yaml edited: rm -f old, run with golang:1.23" '[ $rc -eq 0 ] && log | grep -qx "rm -f $CN" && log | grep -q "^run .* golang:1.23 infinity$" && [ "$(log | grep -n "^rm -f $CN" | cut -d: -f1)" -lt "$(log | grep -n "golang:1.23 infinity" | cut -d: -f1)" ]'
ok "dev.yaml edited: setup ran again"           '[ "$(ncalls "sh -c go mod download$")" -eq 2 ]'

# ================================================================ status / rm
reset_docker
out=$(dv "$WT" --status 2>&1); rc=$?
ok "--status with none"                         '[ $rc -eq 0 ] && [[ "$out" == *"no dev container"* ]]'
dv "$WT" true >/dev/null 2>&1
out=$(cd "$WT" && bash "$OPSX" dev --status 2>&1); rc=$?
ok "opsx dev --status (as documented): name, image, state" '[ $rc -eq 0 ] && [[ "$out" == *"container: $CN"* ]] && [[ "$out" == *"image:     golang:1.23"* ]] && [[ "$out" == *"state:     running"* ]]'
out=$(dv "$WT" --rm 2>&1); rc=$?
ok "--rm removes dev and preview containers"    '[ $rc -eq 0 ] && log | grep -qx "rm -f $CN" && log | grep -qx "rm -f $CN-preview" && [[ "$out" == *"removed container $CN"* ]]'
reset_docker
out=$(dv "$WT" --rm 2>&1); rc=$?
ok "--rm with nothing -> exit 0"                '[ $rc -eq 0 ]'
dv "$WT" true >/dev/null 2>&1; dv "$R" true >/dev/null 2>&1
printf 'x\n\nother\n' > "$FD/c/opsx-dev-other-main"
out=$(dv "$WT" --rm --all 2>&1); rc=$?
ok "--rm --all removes the project's containers" '[ $rc -eq 0 ] && [ ! -f "$FD/c/$CN" ] && [ ! -f "$FD/c/opsx-dev-shop-main" ] && [ -f "$FD/c/opsx-dev-other-main" ]'
ok "--rm --all keeps volumes"                   '! log | grep -q "^volume rm"'
out=$(cd "$WT" && PATH=$NODOCKER_PATH "$DEV" --rm 2>&1); rc=$?
ok "--rm without docker -> exit 0"              '[ $rc -eq 0 ]'

# ================================================================ launcher
out=$(bash "$OPSX" help); rc=$?
ok "opsx help lists dev"                        '[ $rc -eq 0 ] && printf "%s\n" "$out" | grep -qE "^ +dev "'
reset_docker
out=$(cd "$WT/pkg" && bash "$OPSX" dev go version 2>&1); rc=$?
ok "opsx dev dispatches to opsx-dev.sh"         '[ $rc -eq 0 ] && log | grep -q "^exec .* $CN go version$"'

# ================================================================ 2.2 close
$L -f /dev/null new-session -d -s dt -x 160 -y 40 'exec sleep 3000'
TMUX="$($L display -p '#{socket_path}'),$($L display -p '#{pid}'),0"
TMUX_PANE=$($L display -p -t dt '#{pane_id}')
export TMUX TMUX_PANE
printf 'apply\n' > "$SP/prompt.txt"
reset_docker
printf 'img\nh\nshop\n' > "$FD/c/opsx-dev-shop-c1"
(cd "$R" && "$W" ensure c1 --prompt-file "$SP/prompt.txt" --agent-cli fakecli --model default) >/dev/null 2>&1
out=$(cd "$R" && "$W" close c1 2>&1); rc=$?
ok "close c1 removes its dev container"         '[ $rc -eq 0 ] && log | grep -qx "rm -f opsx-dev-shop-c1" && [[ "$out" == *"removed container opsx-dev-shop-c1"* ]]'
(cd "$R" && "$W" ensure c1 --prompt-file "$SP/prompt.txt" --agent-cli fakecli --model default) >/dev/null 2>&1
out=$(cd "$R" && PATH=$NODOCKER_PATH "$W" close c1 2>&1); rc=$?
ok "close c1 without docker: exit 0, no docker output" '[ $rc -eq 0 ] && [[ "$out" == *"closed "* ]] && [[ "$out" != *docker* ]] && [[ "$out" != *container* ]]'
reset_docker
printf 'img\nh\nshop\n' > "$FD/c/opsx-dev-shop-c2"
printf 'img\nh\nshop\n' > "$FD/c/opsx-dev-shop-main"
(cd "$R" && "$W" ensure c2 --prompt-file "$SP/prompt.txt" --agent-cli fakecli --model default) >/dev/null 2>&1
$L new-window -d -t dt: 'exec sleep 3000'
out=$(cd "$R" && "$W" close --all --force 2>&1); rc=$?
ok "close --all removes every project container" '[ $rc -eq 0 ] && [ -z "$(ls "$FD/c")" ]'
reset_docker
printf '1 rm -f\n' > "$FD/fail"
printf 'img\nh\nshop\n' > "$FD/c/opsx-dev-shop-c3"
(cd "$R" && "$W" ensure c3 --prompt-file "$SP/prompt.txt" --agent-cli fakecli --model default) >/dev/null 2>&1
out=$(cd "$R" && "$W" close c3 2>&1); rc=$?
rm -f "$FD/fail"
ok "close c3 with a failing docker rm: still exit 0" '[ $rc -eq 0 ] && [[ "$out" == *"closed "* ]]'

# ================================================================ 3 agents + docs
for a in applier eval reviewer security qa; do
  ok "agents/opsx-$a.md: Toolchain via opsx dev" 'grep -q "\.opsx/dev\.yaml" "$REPO/agents/opsx-$a.md" && grep -q "opsx dev" "$REPO/agents/opsx-$a.md"'
done
ok "README: opsx dev --shell, dockerfile:, cache:" 'grep -q "opsx dev --shell" "$REPO/README.md" && grep -q "dockerfile:" "$REPO/README.md" && grep -q "cache:" "$REPO/README.md"'
ok "README: Linux host networking assumption"   'grep -qi "host network" "$REPO/README.md" && grep -q "Linux" "$REPO/README.md"'
ok "SKILL.md: opsx dev documented"              'grep -q "opsx dev" "$REPO/skills/opsx-run/SKILL.md" && grep -q "\.opsx/dev\.yaml" "$REPO/skills/opsx-run/SKILL.md"'

ok "shellcheck (if installed)"                  '! command -v shellcheck >/dev/null || shellcheck "$DEV" "$0"'

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
