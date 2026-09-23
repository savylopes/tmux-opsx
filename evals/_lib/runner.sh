# Shared helpers for eval-suite checks: build a throwaway fixture suite under
# $EVAL_TMP and run the product runner (skills/opsx-run/opsx-eval.sh) on it.
# Sourced by checks; not a check itself.
RUNNER="$EVAL_ROOT/skills/opsx-run/opsx-eval.sh"
# Run the product runner on a fixture root without leaking this run's EVAL_* vars.
nested_eval() {
  env -u EVAL_ENV_FILE -u EVAL_ROOT -u EVAL_TMP -u EVAL_TRIAL -u EVAL_AGENT_CLI \
    "$RUNNER" "$@"
}
# mk_check <file> <scenario header> <level> <body...>
mk_check() {
  local f=$1 sc=$2 lvl=$3; shift 3
  mkdir -p "$(dirname "$f")"
  { printf '#!/usr/bin/env bash\n# scenario: %s\n# level: %s\n' "$sc" "$lvl"; printf '%s\n' "$@"; } > "$f"
  chmod +x "$f"
}
fail() { echo "FAIL: $*"; exit 1; }
