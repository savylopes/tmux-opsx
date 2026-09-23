# Shared helpers for install checks: run ./install.sh against a scratch HOME
# inside $EVAL_TMP, skipping every step that would touch the network or
# anything outside HOME. Sourced by checks; not a check itself.
export HOME="$EVAL_TMP/home"
export CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_HOME="$HOME/.codex"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME/.config" "$HOME/.local/state"
run_install() {
  ( cd "$EVAL_ROOT" && ./install.sh --skip-openspec --skip-graphify --skip-commands \
      --skip-mcp --skip-memory --skip-fork --no-backup "$@" ) </dev/null 2>&1
}
# Global agents dir of each supported CLI (from ./install.sh --help).
AGENT_DIRS="$HOME/.claude/agents $HOME/.cursor/agents $HOME/.codex/agents $HOME/.config/opencode/agents $HOME/.gemini/agents"
eval_agent_files() {  # every ops-eval agent file anywhere under the scratch HOME
  find "$HOME" -path '*/agents/*' \( -name 'opsx-eval.*' -o -name 'ops-eval.*' \) 2>/dev/null
}
fail() { echo "FAIL: $*"; exit 1; }
