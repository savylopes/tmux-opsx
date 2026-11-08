#!/usr/bin/env bash
# questions.sh — deterministic parts of /opsx-answer, /opsx-challenge and /opsx-settle.
#
#   questions.sh extract <change> --mode answer|challenge [--include-requirements] [--repo <dir>]
#   questions.sh cite <path> <line> <excerpt> [--repo <dir>]
#   questions.sh run new <answer|challenge|settle> --questions-file <tsv> [--max N] [--rounds N] [--repo <dir>]
#   questions.sh record <run> <qid> --round <k> --stage answer|challenge-a|challenge-b --verdict <v> [--sources <n>] [--repo <dir>]
#   questions.sh status <run> [--repo <dir>]
#
# extract  prints one TSV line per question of an OpenSpec change:
#          <id> <kind> <path>:<line> <text>, ids Q1, Q2, ... in file order.
#          answer:    list items under "## Open Questions" (design.md) and
#                     "## Open Points" (proposal.md), kind open; items starting
#                     with "Resolved:" are skipped.
#          challenge: "## Decisions" in design.md, kind decision: each ### heading,
#                     or each top-level list item when there is no ### heading.
#          --include-requirements adds each "### Requirement:" of the change's
#          specs/**/spec.md, kind req-spec. Exit 2 for an unknown or unsafe change.
# cite     checks that <excerpt> (whitespace runs collapsed) occurs within lines
#          <line>-2 .. <line>+2 of <path>. Exit 0 found, 1 not found, 2 no such
#          file, 3 path outside the repository and outside ~/.agents/memory.
#          Relative paths are relative to the repository top level.
# run new  creates .opsx/questions/<YYYYmmdd-HHMMSS>-<rand4>/ with questions.tsv,
#          meta (mode, rounds, max) and an empty verdicts.tsv, adds
#          .opsx/questions/ to .gitignore once, and prints the run id. Refuses
#          more than --max questions (default 6). --rounds defaults to 3 (settle;
#          1 for answer and challenge).
# record   validates and appends one verdict to the run's verdicts.tsv. Rejects
#          a verdict outside the stage's vocabulary, a round above the cap and an
#          unknown question. A verdict recorded after its round was decided (the
#          second challenger after a successful attack) is counted but does not
#          change the state.
#            answer:                  answered | partial | needs-human | unanswerable
#            challenge-a/challenge-b: stands | weakened | invalidated
#          --sources is the number of evidence items that survived validation (default 0).
# status   prints one line per question, derived from verdicts.tsv:
#          <qid> <state> round=<k> subagents=<n> history=<stage:verdict,...>
#          settle states: open, challenging, settled, contested, needs-human,
#          unanswerable. answer/challenge: the recorded verdict (pending before).
#
# Nothing is fetched: url: evidence is checked by the parent with its own web tool.
# Exit status: 0 ok, 1 cite mismatch, 2 usage or input error, 3 cite path outside.

# A && B || die is the intended guard idiom here.
# shellcheck disable=SC2015
set -euo pipefail

die() { printf 'questions: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
help() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; exit 0; }

CHANGE_RE='^[A-Za-z0-9-]+$'
RUN_RE='^[0-9]{8}-[0-9]{6}-[a-z0-9]{4}$'
QID_RE='^Q[1-9][0-9]*$'
KINDS="open decision req-spec req-client"
ANSWER_VERDICTS="answered partial needs-human unanswerable"
CHALLENGE_VERDICTS="stands weakened invalidated"
TMPQ=""

repo_root() {
  local d=${1:-} top
  if [ -z "$d" ]; then
    top=$(git rev-parse --show-toplevel 2>/dev/null) \
      || die "not in a git repository; pass --repo <dir>."
  else
    [ -d "$d" ] || die "$d is not a directory."
    top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || die "$d is not a git repository."
  fi
  (cd -- "$top" && pwd -P)
}

is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
in_list() { local w; for w in $2; do [ "$w" = "$1" ] && return 0; done; return 1; }

# Canonical absolute path without requiring it to exist (symlinks resolved).
canon() {
  local p=$1
  if realpath -m / >/dev/null 2>&1; then
    realpath -m -- "$p"
  else
    python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p"
  fi
}

under() { [ "$1" = "$2" ] || [[ $1 == "$2"/* ]]; }

# ---------------------------------------------------------------------------
# extract

# extract_items <file> <relpath> <section> <mode>
# mode: items (list items, skip Resolved:), decisions (### headings, else items),
#       reqs (### Requirement: anywhere). Prints <relpath>:<line>\t<text>.
extract_items() {
  [ -f "$1" ] || return 0
  awk -v rel="$2" -v sec="$3" -v mode="$4" '
    function flush() {
      if (cur != "") {
        t = cur; gsub(/[ \t]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
        if (!(t ~ /^(\*\*|~~)?Resolved:/)) {
          if (mode == "decisions") { itemn++; itemline[itemn] = curline; itemtext[itemn] = t }
          else print rel ":" curline "\t" t
        }
      }
      cur = ""
    }
    /^```/ { fence = !fence }
    fence { next }
    mode == "reqs" {
      if ($0 ~ /^### Requirement:/) {
        t = $0; sub(/^### Requirement:[ \t]*/, "", t); sub(/[ \t]+$/, "", t)
        print rel ":" NR "\t" t
      }
      next
    }
    /^## / {
      flush()
      h = $0; sub(/^## +/, "", h); sub(/[ \t]+$/, "", h)
      insec = (tolower(h) == tolower(sec))
      next
    }
    !insec { next }
    /^# / { flush(); insec = 0; next }
    mode == "decisions" && /^### / {
      flush()
      t = $0; sub(/^### +/, "", t); sub(/[ \t]+$/, "", t)
      headn++; headline[headn] = NR; headtext[headn] = t
      next
    }
    /^([-*+]|[0-9]+[.)])[ \t]+/ {
      flush()
      t = $0; sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", t)
      cur = t; curline = NR
      next
    }
    /^[ \t]+[^ \t]/ && cur != "" {
      t = $0; sub(/^[ \t]+/, "", t)
      if (t ~ /^([-*+]|[0-9]+[.)])[ \t]+/) next   # nested item: not a question of its own
      cur = cur " " t
      next
    }
    /^[ \t]*$/ { flush(); next }
    { flush() }
    END {
      flush()
      if (mode == "decisions") {
        if (headn > 0) for (i = 1; i <= headn; i++) print rel ":" headline[i] "\t" headtext[i]
        else for (i = 1; i <= itemn; i++) print rel ":" itemline[i] "\t" itemtext[i]
      }
    }
  ' "$1"
}

cmd_extract() {
  local change="" mode="" reqs=0 repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode=${2:-}; shift 2 || die "--mode needs answer or challenge." ;;
      --include-requirements) reqs=1; shift ;;
      --repo) repo=${2:-}; shift 2 || die "--repo needs a directory." ;;
      -h|--help) help ;;
      -*) die "extract: unknown option $1" ;;
      *) [ -z "$change" ] || die "extract: one change name only."; change=$1; shift ;;
    esac
  done
  [ -n "$change" ] || die "extract: missing change name."
  # The name is checked before any path is built from it.
  [[ $change =~ $CHANGE_RE ]] || die "unsafe change name '$change': use letters, digits and '-'."
  case "$mode" in answer|challenge) ;; *) die "extract: --mode must be answer or challenge." ;; esac
  local root dir rel f n=0 line
  root=$(repo_root "$repo")
  rel=openspec/changes/$change
  dir=$root/$rel
  [ -d "$dir" ] && [ ! -L "$dir" ] || die "no change '$change' in $root/openspec/changes/."
  {
    if [ "$mode" = answer ]; then
      extract_items "$dir/design.md" "$rel/design.md" "Open Questions" items | sed 's/^/open\t/'
      extract_items "$dir/proposal.md" "$rel/proposal.md" "Open Points" items | sed 's/^/open\t/'
    else
      extract_items "$dir/design.md" "$rel/design.md" "Decisions" decisions | sed 's/^/decision\t/'
    fi
    if [ "$reqs" -eq 1 ] && [ -d "$dir/specs" ]; then
      while IFS= read -r f; do
        extract_items "$f" "${f#"$root"/}" "" reqs | sed 's/^/req-spec\t/'
      done < <(find "$dir/specs" -type f -name spec.md ! -type l | LC_ALL=C sort)
    fi
  } | while IFS= read -r line; do
    n=$((n + 1))
    printf 'Q%d\t%s\n' "$n" "$line"
  done
}

# ---------------------------------------------------------------------------
# cite

cmd_cite() {
  local args=() repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=${2:-}; shift 2 || die "--repo needs a directory." ;;
      -h|--help) help ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ "${#args[@]}" -eq 3 ] || die "usage: questions.sh cite <path> <line> <excerpt>"
  local path=${args[0]} line=${args[1]} excerpt=${args[2]} root mem abs
  is_uint "$line" && [ "$line" -ge 1 ] || die "cite: <line> must be a positive number."
  root=$(repo_root "$repo")
  case "$path" in /*) abs=$path ;; ~/*) abs=$HOME/${path#\~/} ;; *) abs=$root/$path ;; esac
  abs=$(canon "$abs")
  mem=$(canon "$HOME/.agents/memory")
  # Confinement before existence: an outside path never reveals whether it exists.
  if ! under "$abs" "$root" && ! under "$abs" "$mem"; then
    printf 'questions: %s is outside the repository and ~/.agents/memory\n' "$path" >&2
    exit 3
  fi
  if [ ! -f "$abs" ]; then
    printf 'questions: no such file: %s\n' "$path" >&2
    exit 2
  fi
  local want
  want=$(printf '%s' "$excerpt" | tr '\n\r\t' '   ' | tr -s ' ' | sed -E 's/^ //; s/ $//')
  [ -n "$want" ] || exit 1
  if OPSX_Q_WANT="$want" awk -v lo="$((line - 2))" -v hi="$((line + 2))" '
      NR >= lo && NR <= hi { w = w " " $0 }
      NR > hi { exit }
      END {
        gsub(/[ \t\r]+/, " ", w); sub(/^ /, "", w)
        exit (index(w, ENVIRON["OPSX_Q_WANT"]) > 0 ? 0 : 1)
      }' "$abs"; then
    exit 0
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# runs

safe_dir() {
  if [ -L "$1" ]; then die "$1 is a symlink; refusing to use it."; fi
  if [ -e "$1" ] && [ ! -d "$1" ]; then die "$1 is not a directory."; fi
}

ensure_gitignore() {
  local gi=$1/.gitignore
  if [ -L "$gi" ]; then die "$gi is a symlink; refusing to edit it."; fi
  if [ -f "$gi" ] && grep -qxE '[[:space:]]*/?\.opsx(/questions)?/?[[:space:]]*' "$gi"; then
    return 0
  fi
  if [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ]; then printf '\n' >> "$gi"; fi
  printf '.opsx/questions/\n' >> "$gi"
}

rand4() {
  local r
  r=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c4 || true)
  [ "${#r}" -eq 4 ] || r=$(printf '%04x' "$((RANDOM % 65536))")
  printf '%s' "$r"
}

cmd_run() {
  [ "${1:-}" = new ] || die "usage: questions.sh run new <answer|challenge|settle> --questions-file <tsv> [--max N] [--rounds N]"
  shift
  local mode="" qf="" max=6 rounds="" repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --questions-file) qf=${2:-}; shift 2 || die "--questions-file needs a file." ;;
      --max) max=${2:-}; shift 2 || die "--max needs a number." ;;
      --rounds) rounds=${2:-}; shift 2 || die "--rounds needs a number." ;;
      --repo) repo=${2:-}; shift 2 || die "--repo needs a directory." ;;
      -h|--help) help ;;
      -*) die "run new: unknown option $1" ;;
      *) [ -z "$mode" ] || die "run new: one mode only."; mode=$1; shift ;;
    esac
  done
  case "$mode" in answer|challenge|settle) ;; *) die "run new: mode must be answer, challenge or settle." ;; esac
  [ -n "$qf" ] && [ -f "$qf" ] || die "run new: --questions-file must name an existing file."
  is_uint "$max" && [ "$max" -ge 1 ] || die "--max must be a positive number."
  if [ -z "$rounds" ]; then
    if [ "$mode" = settle ]; then rounds=3; else rounds=1; fi
  fi
  is_uint "$rounds" && [ "$rounds" -ge 1 ] && [ "$rounds" -le 20 ] || die "--rounds must be 1-20."
  [ "$mode" = settle ] || [ "$rounds" -eq 1 ] || die "--rounds only applies to settle."

  # Validate the questions before anything is created.
  local n=0 ln=0 id kind src text line seen=" " tmpq
  tmpq=$(mktemp 2>/dev/null || mktemp -t opsxq) || die "could not create a temp file."
  TMPQ=$tmpq
  trap 'rm -f "$TMPQ"' EXIT
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    line=${line%$'\r'}
    [ -n "${line//[[:space:]]/}" ] || continue
    IFS=$'\t' read -r id kind src text <<<"$line"
    [[ ${id:-} =~ $QID_RE ]] || die "questions file line $ln: id must be Q1, Q2, ..."
    in_list "${kind:-}" "$KINDS" || die "questions file line $ln: kind must be one of: $KINDS."
    [ -n "${src:-}" ] && [ -n "${text:-}" ] || die "questions file line $ln: need <id> <kind> <source> <text>."
    case "$seen" in *" $id "*) die "questions file line $ln: duplicate id $id." ;; esac
    seen="$seen$id "
    n=$((n + 1))
    printf '%s\t%s\t%s\t%s\n' "$id" "$kind" "$src" "$(printf '%s' "$text" | tr -d '\000-\010\013-\037')" >> "$tmpq"
  done < "$qf"
  [ "$n" -ge 1 ] || die "the questions file has no question."
  if [ "$n" -gt "$max" ]; then
    die "$n questions, more than --max $max: confirm a shorter list with the user (or raise --max)."
  fi

  local root base id_run dir
  root=$(repo_root "$repo")
  safe_dir "$root/.opsx"; safe_dir "$root/.opsx/questions"
  base=$root/.opsx/questions
  mkdir -p "$base" || die "cannot create $base"
  while :; do
    id_run=$(date +%Y%m%d-%H%M%S)-$(rand4)
    [[ $id_run =~ $RUN_RE ]] || continue
    [ -e "$base/$id_run" ] || break
  done
  dir=$base/$id_run
  mkdir "$dir" || die "cannot create $dir"
  cp "$tmpq" "$dir/questions.tsv"
  printf 'mode=%s\nrounds=%s\nmax=%s\ncreated=%s\n' "$mode" "$rounds" "$max" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/meta"
  : > "$dir/verdicts.tsv"
  ensure_gitignore "$root"
  printf '%s\n' "$id_run"
}

# run_dir <run> <repo>: the run directory, validated.
run_dir() {
  local run=$1 root
  [[ $run =~ $RUN_RE ]] || die "invalid run id '$run'."
  root=$(repo_root "$2")
  safe_dir "$root/.opsx"; safe_dir "$root/.opsx/questions"; safe_dir "$root/.opsx/questions/$run"
  [ -d "$root/.opsx/questions/$run" ] && [ -f "$root/.opsx/questions/$run/meta" ] \
    || die "no run '$run' in $root/.opsx/questions/."
  printf '%s' "$root/.opsx/questions/$run"
}

meta_get() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1/meta"; }

# replay <dir>: the state machine (design D3) over verdicts.tsv, one line per question.
replay() {
  local dir=$1 mode cap
  mode=$(meta_get "$dir" mode); cap=$(meta_get "$dir" rounds)
  awk -F'\t' -v mode="$mode" -v cap="$cap" '
    FNR == NR { if ($1 != "") { nq++; q[nq] = $1; st[$1] = (mode == "settle" ? "open" : "pending"); rd[$1] = 1 }; next }
    {
      id = $1; r = $2 + 0; stage = $3; v = $4; s = $5 + 0
      if (!(id in st)) next
      sub_n[id]++
      hist[id] = hist[id] (hist[id] == "" ? "" : ",") stage ":" v
      if (mode != "settle") { st[id] = v; rd[id] = r; next }
      if (final(st[id])) next
      if (stage == "answer") {
        if (r != rd[id] || st[id] != "open") next
        if (v == "needs-human" || v == "unanswerable") { st[id] = v; next }
        st[id] = "challenging"; delete ca[id]; delete cb[id]
        next
      }
      if (st[id] != "challenging" || r != rd[id]) next
      if (stage == "challenge-a") { ca[id] = v; sa[id] = s } else { cb[id] = v; sb[id] = s }
      if (v == "weakened" || v == "invalidated") {
        # A validated attack decides the round: a new answer is due.
        if (r >= cap) st[id] = "contested"; else { st[id] = "open"; rd[id] = r + 1 }
        delete ca[id]; delete cb[id]
        next
      }
      if ((id in ca) && (id in cb)) {
        if (sa[id] >= 1 && sb[id] >= 1) st[id] = "settled"
        else if (r >= cap) st[id] = "needs-human"
        else { st[id] = "challenging"; rd[id] = r + 1 }
        delete ca[id]; delete cb[id]
      }
    }
    function final(x) { return x == "settled" || x == "contested" || x == "needs-human" || x == "unanswerable" }
    END {
      for (i = 1; i <= nq; i++) {
        id = q[i]
        printf "%s %s round=%d subagents=%d history=%s\n", id, st[id], rd[id], sub_n[id] + 0, (hist[id] == "" ? "-" : hist[id])
      }
    }
  ' "$dir/questions.tsv" "$dir/verdicts.tsv"
}

cmd_record() {
  local run="" qid="" round="" stage="" verdict="" sources=0 repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --round) round=${2:-}; shift 2 || die "--round needs a number." ;;
      --stage) stage=${2:-}; shift 2 || die "--stage needs a value." ;;
      --verdict) verdict=${2:-}; shift 2 || die "--verdict needs a value." ;;
      --sources) sources=${2:-}; shift 2 || die "--sources needs a number." ;;
      --repo) repo=${2:-}; shift 2 || die "--repo needs a directory." ;;
      -h|--help) help ;;
      -*) die "record: unknown option $1" ;;
      *) if [ -z "$run" ]; then run=$1; elif [ -z "$qid" ]; then qid=$1; else die "record: too many arguments."; fi; shift ;;
    esac
  done
  [ -n "$run" ] && [ -n "$qid" ] || die "usage: questions.sh record <run> <qid> --round <k> --stage <s> --verdict <v> [--sources <n>]"
  local dir mode cap
  dir=$(run_dir "$run" "$repo")
  mode=$(meta_get "$dir" mode); cap=$(meta_get "$dir" rounds)
  [[ $qid =~ $QID_RE ]] && cut -f1 "$dir/questions.tsv" | grep -qxF "$qid" || die "unknown question '$qid' in run $run."
  is_uint "$round" && [ "$round" -ge 1 ] || die "--round must be a positive number."
  [ "$round" -le "$cap" ] || die "round $round is above the cap of $cap for run $run."
  is_uint "$sources" || die "--sources must be a number."
  case "$stage" in
    answer) in_list "$verdict" "$ANSWER_VERDICTS" || die "verdict '$verdict' is not an answer verdict ($ANSWER_VERDICTS)." ;;
    challenge-a|challenge-b) in_list "$verdict" "$CHALLENGE_VERDICTS" || die "verdict '$verdict' is not a challenge verdict ($CHALLENGE_VERDICTS)." ;;
    *) die "--stage must be answer, challenge-a or challenge-b." ;;
  esac
  case "$mode:$stage" in
    answer:challenge-*) die "an answer run records only --stage answer." ;;
    challenge:answer) die "a challenge run records only --stage challenge-a or challenge-b." ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$qid" "$round" "$stage" "$verdict" "$sources" >> "$dir/verdicts.tsv"
}

cmd_status() {
  local run="" repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=${2:-}; shift 2 || die "--repo needs a directory." ;;
      -h|--help) help ;;
      -*) die "status: unknown option $1" ;;
      *) [ -z "$run" ] || die "status: one run only."; run=$1; shift ;;
    esac
  done
  [ -n "$run" ] || die "usage: questions.sh status <run>"
  replay "$(run_dir "$run" "$repo")"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  extract) cmd_extract "$@" ;;
  cite)    cmd_cite "$@" ;;
  run)     cmd_run "$@" ;;
  record)  cmd_record "$@" ;;
  status)  cmd_status "$@" ;;
  -h|--help|help) help ;;
  "") usage 2 ;;
  *) printf 'questions: unknown command %s\n' "$cmd" >&2; usage 2 ;;
esac
