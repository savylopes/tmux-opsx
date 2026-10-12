# Helpers for explain-page checks (sourced). Builds on _lib/fork.sh: private tmux
# server, scratch HOME/XDG, fake agent CLIs. Adds a scratch git project "shop", a
# FAKE expose.sh (never the real one), and a scratch port range.
. "$EVAL_ROOT/evals/_lib/fork.sh"
EXPLAIN="$EVAL_ROOT/skills/explain/explain.sh"
PROJ=shop
mkdir -p "$EVAL_TMP/$PROJ"
git -C "$EVAL_TMP/$PROJ" init -q 2>/dev/null || fail "git init"
cd "$EVAL_TMP/$PROJ"
export EXPOSE_LOG="$EVAL_TMP/expose.log"; : > "$EXPOSE_LOG"
export EXPOSE_MODE_FILE="$EVAL_TMP/expose.mode"
cat > "$EVAL_TMP/fake-expose.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$EXPOSE_LOG"
mode=$(cat "$EXPOSE_MODE_FILE" 2>/dev/null)
case "$1" in
  up)
    if [ "$mode" = notconfigured ]; then echo "expose is not configured; run install.sh --expose-domain <domain>" >&2; exit 3; fi
    echo "https://explain--shop.example.test/" ;;
  share) echo "shared"; echo "https://explain--shop.example.test/?k=LINK" ;;
  down) echo "removed" ;;
  *) echo "fake: $*" ;;
esac
SH
chmod +x "$EVAL_TMP/fake-expose.sh"
export OPSX_EXPOSE_SH="$EVAL_TMP/fake-expose.sh"
export EXPLAIN_FORK_SH="$FORK"
base=$((20000 + ($$ % 20000)))
export EXPLAIN_PORT_MIN=$base EXPLAIN_PORT_MAX=$((base + 90))
ROOT="$XDG_STATE_HOME/agent-forks/explain/$PROJ"
# run_explain <args...>: output in $OUT, status in $RC (stdin = a brief note)
run_explain() { OUT=$(printf 'Focus: test\n' | "$EXPLAIN" "$@" 2>&1); RC=$?; }
# explain-tagged windows on the private server
tagged_count() { T list-windows -a -F '#{@opsx_explain}' | grep -cx "$PROJ"; }
# template() prints the HTML skeleton from SKILL.md
template() {
  awk '/<!-- explain-page-template -->/{a=1;next} a&&!i&&/^```/{i=1;next} i&&/^```/{exit} i{print}' "$EVAL_ROOT/skills/explain/SKILL.md"
}
