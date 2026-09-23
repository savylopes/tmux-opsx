#!/usr/bin/env bash
# opsx-eval.sh — run a repo's saved eval suite (evals/) without any LLM.
#
# Usage:
#   opsx-eval.sh [--change <c>] [--capability <cap>]... [--all]
#                [--agentic] [--trials N] [--json] [--root <dir>]
#   opsx-eval.sh --compare <baseline.json> <current.json> [--json]
#
# Scope:
#   --change <c>        Checks for capabilities touched by that change's delta
#                       specs (openspec/changes/<c>/specs/<cap>/), plus a
#                       coverage report: scenarios with no check are MISSING.
#   --capability <cap>  Checks in evals/<cap>/ (repeatable).
#   --all               Every check in evals/ (default when no scope is given).
#                       With --change: run every check, coverage for that change.
#
# Options:
#   --agentic           Also run L3 (agent-in-the-loop) checks, N trials each.
#   --trials N          Trials per L3 check (default: eval.yaml agentic.trials, else 3).
#   --json              Machine-readable output with full evidence.
#   --root <dir>        Repo root (default: git toplevel of $PWD, else $PWD).
#   --compare B C       Compare two --json results; report every check that was
#                       PASS in B and FAIL in C as REGRESSION.
#   -h, --help          Show this help.
#
# Check contract (evals/<capability>/<scenario-slug>.check, any language):
#   # scenario: <capability> / <Scenario title>
#   # level: L1 | L2 | L3
#   exit 0 = PASS, 77 = UNVERIFIABLE, anything else or a timeout = FAIL.
#   stdout/stderr = evidence. Env: EVAL_ROOT, EVAL_TMP (fresh per check),
#   eval.yaml `env`, and whatever `setup` wrote to $EVAL_ENV_FILE (KEY=VALUE lines).
#   L3 checks also get EVAL_TRIAL and EVAL_AGENT_CLI.
#
# evals/eval.yaml (all keys optional):
#   setup: <command>        run once before checks (cwd = root)
#   teardown: <command>     always run afterwards, even on failure or interrupt
#   env: { KEY: value }     or a nested block of KEY: value lines
#   timeout: 60             seconds per check
#   agentic: { trials: 3, threshold: <trials>, cli: claude }
#
# Exit: 0 no FAIL, 1 at least one FAIL (or REGRESSION with --compare),
#       2 configuration or runner error.

set -uo pipefail
export LC_ALL=C

SCOPE_CHANGE=""
SCOPE_CAPS=()
SCOPE_ALL=0
AGENTIC=0
TRIALS_OPT=""
JSON=0
ROOT=""
COMPARE=0
COMPARE_BASE=""
COMPARE_CUR=""

err()  { printf 'opsx-eval: %s\n' "$*" >&2; }
fatal() { err "$*"; exit 2; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; exit 0; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --change)     [ $# -ge 2 ] || fatal "--change needs a change name"; SCOPE_CHANGE=$2; shift 2 ;;
    --capability) [ $# -ge 2 ] || fatal "--capability needs a name"; SCOPE_CAPS+=("$2"); shift 2 ;;
    --all)        SCOPE_ALL=1; shift ;;
    --agentic)    AGENTIC=1; shift ;;
    --trials)     [ $# -ge 2 ] || fatal "--trials needs a number"; TRIALS_OPT=$2; shift 2 ;;
    --json)       JSON=1; shift ;;
    --root)       [ $# -ge 2 ] || fatal "--root needs a directory"; ROOT=$2; shift 2 ;;
    --compare)    [ $# -ge 3 ] || fatal "--compare needs <baseline.json> <current.json>"
                  COMPARE=1; COMPARE_BASE=$2; COMPARE_CUR=$3; shift 3 ;;
    -h|--help)    usage ;;
    *)            fatal "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -n "$TRIALS_OPT" ]; then
  is_uint "$TRIALS_OPT" && [ "$TRIALS_OPT" -ge 1 ] || fatal "--trials must be a positive integer"
fi
if [ -n "$SCOPE_CHANGE" ] && [ "${#SCOPE_CAPS[@]}" -gt 0 ]; then
  fatal "--change and --capability are mutually exclusive"
fi
if [ "$SCOPE_ALL" -eq 1 ] && [ "${#SCOPE_CAPS[@]}" -gt 0 ]; then
  fatal "--all cannot be combined with --capability"
fi

# ------------------------------------------------------------------ helpers

json_str() {
  # Escape stdin as a JSON string (with quotes). Control chars other than
  # \n \t \r are dropped; invalid UTF-8 is passed through.
  local s
  s=$(cat; printf x); s=${s%x}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$s"
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//'
}

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

# ------------------------------------------------------------------ compare

# Extract "id<TAB>status" pairs from an opsx-eval.sh --json result file.
# Relies on the runner's own format: one result object per line.
result_pairs() {
  awk '/^ *\{"id":"/ {
    if (!match($0, /"id":"[^"]*"/)) next
    id = substr($0, RSTART + 6, RLENGTH - 7)
    if (!match($0, /,"level":"[^"]*","status":"[A-Z_]+"/)) next
    s = substr($0, RSTART, RLENGTH); sub(/.*"status":"/, "", s); sub(/"$/, "", s)
    print id "\t" s
  }' "$1"
}

if [ "$COMPARE" -eq 1 ]; then
  for f in "$COMPARE_BASE" "$COMPARE_CUR"; do
    [ -r "$f" ] || fatal "cannot read $f"
    grep -q '"results"' "$f" || fatal "$f is not an opsx-eval.sh --json result"
  done
  regressions=()
  while IFS=$'\t' read -r id status; do
    [ "$status" = "FAIL" ] || continue
    base=$(result_pairs "$COMPARE_BASE" | awk -F'\t' -v k="$id" '$1==k { print $2; exit }')
    [ "$base" = "PASS" ] && regressions+=("$id")
  done < <(result_pairs "$COMPARE_CUR")
  if [ "$JSON" -eq 1 ]; then
    printf '{"regressions":['
    sep=""
    for id in "${regressions[@]+"${regressions[@]}"}"; do
      printf '%s%s' "$sep" "$(printf '%s' "$id" | json_str)"; sep=","
    done
    printf ']}\n'
  else
    if [ "${#regressions[@]}" -eq 0 ]; then
      echo "no regressions"
    else
      for id in "${regressions[@]}"; do echo "REGRESSION $id (PASS on baseline, FAIL now)"; done
    fi
  fi
  [ "${#regressions[@]}" -eq 0 ] && exit 0 || exit 1
fi

# ------------------------------------------------------------------ root

if [ -z "$ROOT" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
[ -d "$ROOT" ] || fatal "root is not a directory: $ROOT"
ROOT=$(cd -- "$ROOT" && pwd) || fatal "cannot enter $ROOT"
EVALS="$ROOT/evals"
CONFIG="$EVALS/eval.yaml"

# ------------------------------------------------------------------ config

CFG_SETUP=""
CFG_TEARDOWN=""
CFG_TIMEOUT=60
CFG_TRIALS=3
CFG_THRESHOLD=""
CFG_CLI="claude"
CFG_ENV=()

# Minimal YAML reader for the eval.yaml schema: top-level scalars, `env` and
# `agentic` as a nested block or a flow map `{ k: v, ... }`. Prints key=value.
parse_yaml() {
  awk '
    function unq(v) {
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      return v
    }
    function strip_comment(line,   i, c, q) {
      q = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (q == "" && (c == "\"" || c == "\047")) q = c
        else if (q != "" && c == q) q = ""
        else if (q == "" && c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t]/)) return substr(line, 1, i - 1)
      }
      return line
    }
    function flow(prefix, body,   n, parts, i, k, v, p) {
      sub(/^[ \t]*\{/, "", body); sub(/\}[ \t]*$/, "", body)
      n = split(body, parts, ",")
      for (i = 1; i <= n; i++) {
        p = index(parts[i], ":"); if (p == 0) continue
        k = unq(substr(parts[i], 1, p - 1)); v = unq(substr(parts[i], p + 1))
        if (k != "") print prefix "." k "=" v
      }
    }
    {
      line = strip_comment($0)
      if (line ~ /^[ \t]*$/) next
      p = index(line, ":")
      if (p == 0) { print "error=line " NR ": expected key: value"; next }
      key = substr(line, 1, p - 1); val = substr(line, p + 1)
      indent = match(line, /[^ ]/) - 1
      key = unq(key)
      if (indent == 0) {
        section = ""
        v = unq(val)
        if (v == "") { section = key; next }
        if (v ~ /^\{.*\}$/) { flow(key, v); next }
        print key "=" v
      } else {
        if (section == "") { print "error=line " NR ": unexpected indentation"; next }
        print section "." key "=" unq(val)
      }
    }
  ' "$1"
}

if [ -f "$CONFIG" ]; then
  while IFS= read -r kv; do
    k=${kv%%=*}; v=${kv#*=}
    case "$k" in
      error)            fatal "eval.yaml: $v" ;;
      setup)            CFG_SETUP=$v ;;
      teardown)         CFG_TEARDOWN=$v ;;
      timeout)          is_uint "$v" && [ "$v" -ge 1 ] || fatal "eval.yaml: timeout must be a positive integer (got '$v')"
                        CFG_TIMEOUT=$v ;;
      env.*)            name=${k#env.}
                        case "$name" in [A-Za-z_]*) ;; *) fatal "eval.yaml: bad env name '$name'" ;; esac
                        case "$name" in *[!A-Za-z0-9_]*) fatal "eval.yaml: bad env name '$name'" ;; esac
                        CFG_ENV+=("$name=$v") ;;
      agentic.trials)   is_uint "$v" && [ "$v" -ge 1 ] || fatal "eval.yaml: agentic.trials must be a positive integer"
                        CFG_TRIALS=$v ;;
      agentic.threshold) is_uint "$v" && [ "$v" -ge 1 ] || fatal "eval.yaml: agentic.threshold must be a positive integer"
                        CFG_THRESHOLD=$v ;;
      agentic.cli)      CFG_CLI=$v ;;
      *)                err "eval.yaml: ignoring unknown key '$k'" ;;
    esac
  done < <(parse_yaml "$CONFIG")
fi

TRIALS=${TRIALS_OPT:-$CFG_TRIALS}
THRESHOLD=${CFG_THRESHOLD:-$TRIALS}
[ "$THRESHOLD" -le "$TRIALS" ] || THRESHOLD=$TRIALS

# ------------------------------------------------------------------ scope

CAPS=()          # capabilities in scope (empty + SCOPE_KIND=all = every dir)
SCOPE_KIND=all
SCOPE_LABEL=all
if [ -n "$SCOPE_CHANGE" ]; then
  case "$SCOPE_CHANGE" in */*|.*) fatal "invalid change name: $SCOPE_CHANGE" ;; esac
  cdir="$ROOT/openspec/changes/$SCOPE_CHANGE"
  [ -d "$cdir" ] || fatal "no change at openspec/changes/$SCOPE_CHANGE"
  SCOPE_KIND=change; SCOPE_LABEL="change:$SCOPE_CHANGE"
  [ "$SCOPE_ALL" -eq 1 ] && SCOPE_LABEL="all+change:$SCOPE_CHANGE"
  if [ -d "$cdir/specs" ]; then
    while IFS= read -r d; do CAPS+=("$(basename "$d")"); done \
      < <(find "$cdir/specs" -mindepth 1 -maxdepth 1 -type d | sort)
  fi
elif [ "${#SCOPE_CAPS[@]}" -gt 0 ]; then
  for c in "${SCOPE_CAPS[@]}"; do
    case "$c" in */*|.*|'') fatal "invalid capability name: $c" ;; esac
  done
  CAPS=("${SCOPE_CAPS[@]}")
  SCOPE_KIND=capability; SCOPE_LABEL="capability:$(IFS=,; printf '%s' "${CAPS[*]}")"
fi

# Check files in scope, sorted for deterministic order.
CHECKS=()
if [ -d "$EVALS" ]; then
  if [ "$SCOPE_KIND" = all ] || [ "$SCOPE_ALL" -eq 1 ]; then
    while IFS= read -r f; do CHECKS+=("$f"); done \
      < <(find "$EVALS" -mindepth 2 -maxdepth 2 -type f -name '*.check' | sort)
  else
    for c in "${CAPS[@]+"${CAPS[@]}"}"; do
      [ -d "$EVALS/$c" ] || continue
      while IFS= read -r f; do CHECKS+=("$f"); done \
        < <(find "$EVALS/$c" -mindepth 1 -maxdepth 1 -type f -name '*.check' | sort)
    done
  fi
fi

header() {  # header <file> <name> -> value of "# name: value" in the first 30 lines
  awk -v n="$2" 'NR > 30 { exit }
    { l = $0; sub(/^[ \t]*(#|\/\/|--|;)+[ \t]*/, "", l)
      if (tolower(substr(l, 1, length(n) + 1)) == n ":") { v = substr(l, length(n) + 2); sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v); print v; exit } }' "$1"
}

# ------------------------------------------------------------------ run state

RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/opsx-eval.XXXXXX") || fatal "cannot create a temp dir"
EVAL_ENV_FILE="$RUN_DIR/env"
: > "$EVAL_ENV_FILE"
SETUP_ENV=()
TEARDOWN_DONE=0

load_setup_env() {
  local line
  SETUP_ENV=()
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#export }
    case "$line" in
      ''|'#'*) continue ;;
      [A-Za-z_]*=*) k=${line%%=*}
                    case "$k" in *[!A-Za-z0-9_]*) err "setup env: ignoring '$line'"; continue ;; esac
                    SETUP_ENV+=("$line") ;;
      *) err "setup env: ignoring '$line'" ;;
    esac
  done < "$EVAL_ENV_FILE"
}

run_hook() {  # run_hook <label> <command>
  ( cd "$ROOT" && env "${CFG_ENV[@]+"${CFG_ENV[@]}"}" "${SETUP_ENV[@]+"${SETUP_ENV[@]}"}" \
      EVAL_ROOT="$ROOT" EVAL_ENV_FILE="$EVAL_ENV_FILE" bash -c "$2" ) >"$RUN_DIR/$1.log" 2>&1
}

teardown() {
  [ "$TEARDOWN_DONE" -eq 0 ] || return 0
  TEARDOWN_DONE=1
  if [ -n "$CFG_TEARDOWN" ]; then
    if ! run_hook teardown "$CFG_TEARDOWN"; then
      err "teardown failed:"; sed 's/^/  /' "$RUN_DIR/teardown.log" >&2
    fi
  fi
  rm -rf "$RUN_DIR"
}
trap 'teardown' EXIT
trap 'teardown; exit 130' INT
trap 'teardown; exit 143' TERM

if [ -n "$CFG_SETUP" ] && [ "${#CHECKS[@]}" -gt 0 ]; then
  if ! run_hook setup "$CFG_SETUP"; then
    err "setup failed:"; sed 's/^/  /' "$RUN_DIR/setup.log" >&2
    exit 2
  fi
  load_setup_env
fi

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout
fi

# run_once <check> <outfile> [extra env...] -> sets RC and TIMED_OUT
run_once() {
  local check=$1 out=$2; shift 2
  local tmp start
  tmp=$(mktemp -d "$RUN_DIR/tmp.XXXXXX") || { RC=2; TIMED_OUT=0; echo "cannot create EVAL_TMP" >"$out"; return; }
  TIMED_OUT=0
  start=$(date +%s)
  local cmd=(env "${CFG_ENV[@]+"${CFG_ENV[@]}"}" "${SETUP_ENV[@]+"${SETUP_ENV[@]}"}" "$@"
             EVAL_ROOT="$ROOT" EVAL_TMP="$tmp" "$check")
  if [ -n "$TIMEOUT_BIN" ]; then
    ( cd "$ROOT" && exec "$TIMEOUT_BIN" -k 5 "$CFG_TIMEOUT" "${cmd[@]}" ) </dev/null >"$out" 2>&1
    RC=$?
    if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then
      [ $(( $(date +%s) - start )) -ge "$CFG_TIMEOUT" ] && TIMED_OUT=1
    fi
  else
    # Portable watchdog: own process group, killed as a whole on timeout.
    set -m
    ( cd "$ROOT" && exec "${cmd[@]}" ) </dev/null >"$out" 2>&1 &
    local pid=$!
    set +m
    ( sleep "$CFG_TIMEOUT"
      if kill -0 "$pid" 2>/dev/null; then
        : > "$tmp.timeout"; kill -TERM -- "-$pid" 2>/dev/null
        sleep 5; kill -KILL -- "-$pid" 2>/dev/null
      fi ) >/dev/null 2>&1 &
    local wd=$!
    wait "$pid"; RC=$?
    kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
    [ -e "$tmp.timeout" ] && TIMED_OUT=1
    rm -f "$tmp.timeout"
  fi
  rm -rf "$tmp"
}

# ------------------------------------------------------------------ run checks

R_ID=(); R_CAP=(); R_SCEN=(); R_LEVEL=(); R_STATUS=(); R_EXIT=(); R_NOTE=(); R_EVID=(); R_SECS=()
add_result() {  # id cap scenario level status exit note evidence-file secs
  R_ID+=("$1"); R_CAP+=("$2"); R_SCEN+=("$3"); R_LEVEL+=("$4"); R_STATUS+=("$5")
  R_EXIT+=("$6"); R_NOTE+=("$7"); R_SECS+=("$9")
  if [ -n "$8" ] && [ -f "$8" ]; then R_EVID+=("$(cat "$8")"); else R_EVID+=(""); fi
}

for check in "${CHECKS[@]+"${CHECKS[@]}"}"; do
  cap=$(basename "$(dirname "$check")")
  slug=$(basename "$check" .check)
  id="$cap/$slug"
  scenario=$(header "$check" scenario)
  [ -n "$scenario" ] || scenario="$cap / $slug"
  level=$(header "$check" level | tr '[:lower:]' '[:upper:]')
  note=""
  case "$level" in
    L1|L2|L3) ;;
    '') level=L1; note="no level header, assumed L1" ;;
    *)  add_result "$id" "$cap" "$scenario" "$level" FAIL "" "invalid level header '$level'" "" 0; continue ;;
  esac
  if [ ! -x "$check" ]; then
    add_result "$id" "$cap" "$scenario" "$level" FAIL "" "check is not executable (chmod +x)" "" 0
    continue
  fi
  out="$RUN_DIR/out"
  if [ "$level" = L3 ]; then
    if [ "$AGENTIC" -eq 0 ]; then
      add_result "$id" "$cap" "$scenario" "$level" NOT_RUN "" "L3: run with --agentic" "" 0
      continue
    fi
    passes=0; unver=0; t0=$(date +%s); : > "$RUN_DIR/l3"
    for ((t = 1; t <= TRIALS; t++)); do
      run_once "$check" "$out" EVAL_TRIAL="$t" EVAL_AGENT_CLI="$CFG_CLI"
      tnote=""
      if [ "$TIMED_OUT" -eq 1 ]; then tnote=" (timeout after ${CFG_TIMEOUT}s)"
      elif [ "$RC" -eq 0 ]; then passes=$((passes + 1))
      elif [ "$RC" -eq 77 ]; then unver=$((unver + 1))
      fi
      { printf -- '--- trial %d: exit %d%s\n' "$t" "$RC" "$tnote"; cat "$out"; } >> "$RUN_DIR/l3"
    done
    secs=$(( $(date +%s) - t0 ))
    rate="pass rate $passes/$TRIALS (threshold $THRESHOLD)"
    if [ "$unver" -eq "$TRIALS" ]; then status=UNVERIFIABLE
    elif [ "$passes" -ge "$THRESHOLD" ]; then status=PASS
    else status=FAIL
    fi
    add_result "$id" "$cap" "$scenario" "$level" "$status" "" "$rate${note:+; $note}" "$RUN_DIR/l3" "$secs"
    continue
  fi
  t0=$(date +%s)
  run_once "$check" "$out"
  secs=$(( $(date +%s) - t0 ))
  if [ "$TIMED_OUT" -eq 1 ]; then
    status=FAIL; note="timeout after ${CFG_TIMEOUT}s${note:+; $note}"
  elif [ "$RC" -eq 0 ]; then status=PASS
  elif [ "$RC" -eq 77 ]; then status=UNVERIFIABLE
  else status=FAIL
  fi
  add_result "$id" "$cap" "$scenario" "$level" "$status" "$RC" "$note" "$out" "$secs"
done

# ------------------------------------------------------------------ coverage

M_CAP=(); M_SCEN=(); M_SLUG=()
if [ "$SCOPE_KIND" = change ]; then
  for cap in "${CAPS[@]+"${CAPS[@]}"}"; do
    spec="$ROOT/openspec/changes/$SCOPE_CHANGE/specs/$cap/spec.md"
    [ -f "$spec" ] || continue
    # Scenarios under ADDED / MODIFIED requirements; REMOVED / RENAMED carry none to check.
    while IFS= read -r title; do
      title=$(trim "$title")
      [ -n "$title" ] || continue
      slug=$(slugify "$title")
      found=0
      for i in "${!R_ID[@]}"; do
        if [ "${R_CAP[$i]}" = "$cap" ] && { [ "${R_SCEN[$i]}" = "$cap / $title" ] || [ "${R_ID[$i]}" = "$cap/$slug" ]; }; then
          found=1; break
        fi
      done
      if [ "$found" -eq 0 ]; then M_CAP+=("$cap"); M_SCEN+=("$title"); M_SLUG+=("$slug"); fi
    done < <(awk '
      /^## / { sec = toupper($0); keep = (sec ~ /ADDED/ || sec ~ /MODIFIED/) }
      keep && /^####[ \t]+Scenario:/ { sub(/^####[ \t]+Scenario:[ \t]*/, ""); print }
    ' "$spec")
  done
fi

# ------------------------------------------------------------------ output

n_pass=0; n_fail=0; n_unv=0; n_nr=0; n_miss=${#M_CAP[@]}
for s in "${R_STATUS[@]+"${R_STATUS[@]}"}"; do
  case "$s" in
    PASS) n_pass=$((n_pass + 1)) ;;
    FAIL) n_fail=$((n_fail + 1)) ;;
    UNVERIFIABLE) n_unv=$((n_unv + 1)) ;;
    NOT_RUN) n_nr=$((n_nr + 1)) ;;
  esac
done
n_total=${#R_ID[@]}

if [ "$JSON" -eq 1 ]; then
  printf '{\n'
  printf '  "root": %s,\n' "$(printf '%s' "$ROOT" | json_str)"
  printf '  "scope": %s,\n' "$(printf '%s' "$SCOPE_LABEL" | json_str)"
  printf '  "agentic": %s,\n' "$([ "$AGENTIC" -eq 1 ] && echo true || echo false)"
  printf '  "evals_dir": %s,\n' "$([ -d "$EVALS" ] && echo true || echo false)"
  printf '  "totals": {"total":%d,"pass":%d,"fail":%d,"unverifiable":%d,"not_run":%d,"missing":%d},\n' \
    "$n_total" "$n_pass" "$n_fail" "$n_unv" "$n_nr" "$n_miss"
  printf '  "results": [\n'
  for i in "${!R_ID[@]}"; do
    exitv=${R_EXIT[$i]:-null}
    printf '    {"id":%s,"capability":%s,"scenario":%s,"level":%s,"status":"%s","exit":%s,"seconds":%d,"note":%s,"evidence":%s}%s\n' \
      "$(printf '%s' "${R_ID[$i]}" | json_str)" \
      "$(printf '%s' "${R_CAP[$i]}" | json_str)" \
      "$(printf '%s' "${R_SCEN[$i]}" | json_str)" \
      "$(printf '%s' "${R_LEVEL[$i]}" | json_str)" \
      "${R_STATUS[$i]}" "$exitv" "${R_SECS[$i]}" \
      "$(printf '%s' "${R_NOTE[$i]}" | json_str)" \
      "$(printf '%s' "${R_EVID[$i]}" | json_str)" \
      "$([ "$i" -lt $((n_total - 1)) ] && echo ,)"
  done
  printf '  ],\n'
  printf '  "missing": [\n'
  for i in "${!M_CAP[@]}"; do
    printf '    {"capability":%s,"scenario":%s,"slug":%s}%s\n' \
      "$(printf '%s' "${M_CAP[$i]}" | json_str)" \
      "$(printf '%s' "${M_SCEN[$i]}" | json_str)" \
      "$(printf '%s' "${M_SLUG[$i]}" | json_str)" \
      "$([ "$i" -lt $((n_miss - 1)) ] && echo ,)"
  done
  printf '  ]\n}\n'
else
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
  else
    B=""; G=""; Y=""; R=""; D=""; N=""
  fi
  printf '%sopsx-eval%s  root=%s  scope=%s%s\n' "$B" "$N" "$ROOT" "$SCOPE_LABEL" \
    "$([ "$AGENTIC" -eq 1 ] && printf '  agentic (trials=%s threshold=%s cli=%s)' "$TRIALS" "$THRESHOLD" "$CFG_CLI")"
  [ -d "$EVALS" ] || printf '%s(no evals/ directory)%s\n' "$D" "$N"
  printf '\n'
  for i in "${!R_ID[@]}"; do
    case "${R_STATUS[$i]}" in
      PASS) c=$G; label="PASS        " ;;
      FAIL) c=$R; label="FAIL        " ;;
      UNVERIFIABLE) c=$Y; label="UNVERIFIABLE" ;;
      NOT_RUN) c=$D; label="NOT RUN     " ;;
    esac
    printf '%s%s%s  %-3s %s  %s— %s%s\n' "$c" "$label" "$N" "${R_LEVEL[$i]}" "${R_ID[$i]}" "$D" "${R_SCEN[$i]}" "$N"
    [ -n "${R_NOTE[$i]}" ] && printf '                   %s\n' "${R_NOTE[$i]}"
    if [ "${R_STATUS[$i]}" = FAIL ] || [ "${R_STATUS[$i]}" = UNVERIFIABLE ]; then
      ev=${R_EVID[$i]}
      if [ -n "$ev" ]; then
        printf '%s\n' "$ev" | tail -n 8 | cut -c1-200 | sed "s/^/                   ${D}|${N} /"
      fi
    fi
  done
  for i in "${!M_CAP[@]}"; do
    printf '%sMISSING     %s      %s/%s  %s— %s / %s%s\n' "$Y" "$N" "${M_CAP[$i]}" "${M_SLUG[$i]}" "$D" "${M_CAP[$i]}" "${M_SCEN[$i]}" "$N"
  done
  [ "$n_total" -eq 0 ] && [ "$n_miss" -eq 0 ] && printf '%sno checks in scope%s\n' "$D" "$N"
  printf '\n%sTotal %d%s · %s%d pass%s · %s%d fail%s · %d unverifiable · %d not run · %d missing\n' \
    "$B" "$n_total" "$N" "$G" "$n_pass" "$N" "$R" "$n_fail" "$N" "$n_unv" "$n_nr" "$n_miss"
fi

[ "$n_fail" -eq 0 ] && exit 0 || exit 1
