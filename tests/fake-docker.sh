#!/usr/bin/env bash
# Fake docker for tests/test-dev.sh and tests/test-preview.sh.
#
# Every call is logged: one line per call in $FAKE_DOCKER_DIR/docker.log, the
# argv of call N one word per line in $FAKE_DOCKER_DIR/argv.N. Containers are
# files $FAKE_DOCKER_DIR/c/<name> (image, hash label, project label), images
# built or present are files in $FAKE_DOCKER_DIR/img. Lines "<rc> <substring>"
# in $FAKE_DOCKER_DIR/fail make a call whose arguments contain <substring>
# exit with <rc>. A foreground `run` (no -d) runs its command on the host, in
# its -w directory with its -e variables, like a container on host network.
d=$FAKE_DOCKER_DIR
n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/n"
printf '%s\n' "$*" >> "$d/docker.log"
printf '%s\n' "$@" > "$d/argv.$n"
if [ -f "$d/fail" ]; then
  while read -r rc pat; do
    [ -n "$pat" ] && [[ "$*" == *"$pat"* ]] && { echo "fake docker: forced failure" >&2; exit "$rc"; }
  done < "$d/fail"
fi
cmd=$1; shift
cfile() { printf '%s/c/%s' "$d" "$1"; }
case "$cmd" in
  container)
    [ "$1" = inspect ] || exit 1; shift
    fmt=""; [ "$1" = -f ] && { fmt=$2; shift 2; }
    f=$(cfile "$1")
    [ -f "$f" ] || { echo "Error: No such container: $1" >&2; exit 1; }
    [ -n "$fmt" ] || { echo '[]'; exit 0; }
    img=$(sed -n 1p "$f"); hash=$(sed -n 2p "$f")
    fmt=${fmt//'{{.State.Running}}'/true}
    fmt=${fmt//'{{.State.Status}}'/running}
    fmt=${fmt//'{{.Config.Image}}'/$img}
    fmt=${fmt//'{{index .Config.Labels "opsx.dev.hash"}}'/$hash}
    printf '%s\n' "$fmt" ;;
  image)
    [ "$1" = inspect ] || exit 0
    [ -f "$d/img/$(printf '%s' "$2" | tr '/:' '__')" ]; exit $? ;;
  build)
    while [ $# -gt 0 ]; do [ "$1" = -t ] && tag=$2; shift; done
    : > "$d/img/$(printf '%s' "$tag" | tr '/:' '__')" ;;
  run)
    name=""; hash=""; project=""; detach=0; rm=0; ep=""; wd=""; envs=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -d) detach=1; shift ;;
        --rm) rm=1; shift ;;
        -i|-t|--init) shift ;;
        --name) name=$2; shift 2 ;;
        --entrypoint) ep=$2; shift 2 ;;
        -w) wd=$2; shift 2 ;;
        -e) envs+=("$2"); shift 2 ;;
        --label)
          case "$2" in
            opsx.dev.hash=*) hash=${2#*=} ;;
            opsx.dev.project=*) project=${2#*=} ;;
          esac; shift 2 ;;
        --network|-v|-u) shift 2 ;;
        *) break ;;
      esac
    done
    img=$1; shift
    printf '%s\n%s\n%s\n' "$img" "$hash" "$project" > "$(cfile "$name")"
    if [ "$detach" -eq 1 ]; then echo "id-$name"; exit 0; fi
    # Foreground (preview): run the command on the host, like host networking.
    [ -z "$wd" ] || cd "$wd" || exit 1
    trap '[ "$rm" -eq 1 ] && rm -f "$(cfile "$name")"' EXIT
    env "${envs[@]}" "${ep:-sh}" "$@"
    exit $? ;;
  exec)
    while [ $# -gt 0 ]; do
      case "$1" in
        -i|-t|-it) shift ;;
        -u|-w|-e) shift 2 ;;
        *) break ;;
      esac
    done
    [ -f "$(cfile "$1")" ] || { echo "Error: No such container: $1" >&2; exit 1; }
    exit 0 ;;
  rm)
    [ "$1" = -f ] && shift
    for c in "$@"; do rm -f "$(cfile "$c")"; done ;;
  start) exit 0 ;;
  ps)
    project=""
    while [ $# -gt 0 ]; do
      [ "$1" = --filter ] && case "$2" in label=opsx.dev.project=*) project=${2#label=opsx.dev.project=} ;; esac
      shift
    done
    for f in "$d"/c/*; do
      [ -f "$f" ] || continue
      [ "$(sed -n 3p "$f")" = "$project" ] && basename "$f"
    done ;;
  *) exit 0 ;;
esac
exit 0
