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
# --- session-restore helpers ---
SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"; TMUXCONF="$HOME/.tmux.conf"
MARK='tmux-opsx session restore'
count_hooks() { python3 - "$SETTINGS" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(0); sys.exit()
n=0
for e in d.get("hooks",{}).get("SessionStart",[]):
    for h in e.get("hooks",[]):
        if "opsx-sessions.sh" in h.get("command","") and " hook" in h.get("command",""): n+=1
print(n)
PY
}
mk_conf() { # [extra line before run]
  { echo "set -g @plugin 'tmux-plugins/tpm'"; echo "set -g @plugin 'tmux-plugins/tmux-resurrect'"
    [ $# -gt 0 ] && printf '%s\n' "$@"
    echo "run '~/.tmux/plugins/tpm/tpm'"; } > "$TMUXCONF"; }
mk_loginctl() { # Linger value
  mkdir -p "$EVAL_TMP/stub"
  printf '#!/usr/bin/env bash\necho "Linger=%s"\n' "$1" > "$EVAL_TMP/stub/loginctl"
  printf '#!/usr/bin/env bash\necho sudo-called >> "%s/sudo.log"; exit 1\n' "$EVAL_TMP" > "$EVAL_TMP/stub/sudo"
  chmod +x "$EVAL_TMP/stub/"*; export PATH="$EVAL_TMP/stub:$PATH"; }
