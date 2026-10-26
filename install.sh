#!/usr/bin/env bash
# tmux-opsx installer — macOS and Linux.
#
# Installs:
#   1. the OpenSpec CLI            (npm -g @fission-ai/openspec)
#   2. OpenSpec skills + /opsx:*   -> global dirs for Claude / Cursor / Codex / OpenCode / Gemini
#      (openspec-propose, openspec-apply-change, … plus slash commands;
#       Codex reads them from ~/.agents/skills and $CODEX_HOME/skills)
#   3. Graphify CLI + /graphify    -> global dirs for Claude / Cursor / Codex / OpenCode / Gemini
#                                   -> ~/.agents/skills/graphify/
#      graphify's always-on wiring goes global too, never into the checkout:
#                                   -> ~/.claude/CLAUDE.md (graphify writes this itself)
#                                   -> marked block in ~/.gemini/GEMINI.md
#                                   -> BeforeTool hook in ~/.gemini/settings.json
#                                   -> ~/.config/opencode/plugins/graphify.js (auto-loaded)
#   4. ops-applier + ops-qa + ops-reviewer + ops-security + ops-eval
#                                   -> ~/.claude/agents/opsx-{applier,qa,reviewer,security,eval}.md
#                                   -> ~/.cursor/agents/opsx-{applier,qa,reviewer,security,eval}.md
#                                   -> ~/.codex/agents/ops-{applier,qa,reviewer,security,eval}.toml
#                                   -> ~/.config/opencode/agents/ops-{applier,qa,reviewer,security,eval}.md
#                                   -> ~/.gemini/agents/opsx-{applier,qa,reviewer,security,eval}.md
#      Claude Code, Cursor and OpenCode files get their frontmatter `model:` from
#      agents/models.conf merged with ~/.config/tmux-opsx/models.conf (never
#      written here); a model the CLI does not accept warns and becomes inherit.
#   5. the /opsx-run skill         -> ~/.claude/skills/opsx-run/
#                                   -> ~/.cursor/skills/opsx-run/
#                                   -> ~/.agents/skills/opsx-run/   (Codex / Agent Skills)
#                                   -> ~/.codex/skills/opsx-run/    (Codex home)
#                                   -> ~/.config/opencode/skills/opsx-run/  (OpenCode)
#                                   -> ~/.gemini/skills/opsx-run/  (Gemini CLI)
#      (opsx-window.sh + opsx-merge.sh + opsx-land.sh + opsx-eval.sh + opsx-preview.sh
#       + opsx-dev.sh + opsx-sessions.sh + models.conf)
#   6. browser-use MCP             -> ~/.gemini/settings.json
#                                   -> ~/.codex/config.toml
#                                   -> ~/.config/opencode/opencode.json{,c}
#   7. the memory skill + store    -> ~/.claude/skills/memory/
#                                   -> ~/.cursor/skills/memory/
#                                   -> ~/.agents/skills/memory/
#                                   -> ~/.codex/skills/memory/
#                                   -> ~/.config/opencode/skills/memory/
#                                   -> ~/.gemini/skills/memory/
#                                   -> ~/.agents/memory/ (shared store, created once)
#                                   -> marked block in CLAUDE.md / ~/.codex/AGENTS.md /
#                                      ~/.config/opencode/AGENTS.md / ~/.gemini/GEMINI.md
#                                   -> one-time import of existing Claude Code memories
#   7b. the learn skill            -> ~/.claude/skills/learn/  (and the other five
#                                      skill dirs, like memory; learn.sh)
#                                   -> marked learn block in the same files as memory
#      Learned skills live in each project's .opsx/skills/, never touched here.
#   8. the /fork skill             -> ~/.claude/skills/fork/
#                                   -> ~/.cursor/skills/fork/
#                                   -> ~/.agents/skills/fork/
#                                   -> ~/.codex/skills/fork/
#                                   -> ~/.config/opencode/skills/fork/
#                                   -> ~/.gemini/skills/fork/
#      (fork.sh; fork state lives in ~/.local/state/agent-forks/, never touched here)
#      the /explain skill          -> ~/.claude/skills/explain/  (and the other five
#                                      skill dirs, like /fork; explain.sh; pages live in
#                                      ~/.local/state/agent-forks/explain/, never touched here)
#      the /opsx-review skill      -> ~/.claude/skills/opsx-review/  (and the other five
#                                      skill dirs, like /fork; opsx-review.sh)
#      the /opsx-pr skill          -> ~/.claude/skills/opsx-pr/  (and the other five
#                                      skill dirs, like /fork; pr.sh; PR state lives in
#                                      ~/.local/state/tmux-opsx/pr/, never touched here)
#      the /opsx-task skill        -> ~/.claude/skills/opsx-task/  (and the other five
#                                      skill dirs, like /fork; opsx-task.sh; briefs live
#                                      in each repo's git-ignored .opsx/tasks/, never touched here)
#   9. the /expose skill + proxy   ONLY with --expose-domain <domain>:
#                                   -> ~/.claude/skills/expose/  (and the other five
#                                      skill dirs, like /fork; expose.sh)
#                                   -> ~/.config/tmux-opsx/expose.env (domain + Cloudflare
#                                      token, mode 600, never backed up)
#                                   -> ~/.config/tmux-opsx/caddy.json (*.<domain> on :443,
#                                      wildcard cert via DNS-01, admin API on a unix socket)
#                                   -> ~/.config/tmux-opsx/tmux-opsx-caddy.service (Linux)
#                                   -> ~/.local/share/tmux-opsx/bin/caddy (with caddy-dns/cloudflare)
#      The token comes from $CLOUDFLARE_API_TOKEN or a hidden prompt, never from a
#      flag. No sudo: a non-root run prints the one systemd command to run; a root
#      run enables the unit itself. DNS is never changed — add a DNS-only
#      *.<domain> record pointing at this host yourself.
#   9b. push notifications (ntfy) unless --skip-notify:
#                                   -> opsx-notify.sh in every opsx-run skill dir (item 5)
#                                   -> Stop, Notification (permission_prompt) and PreToolUse
#                                      (AskUserQuestion) hooks merged into ~/.claude/settings.json
#                                      (.bak first; replaced on a rerun, never duplicated)
#      and, with --expose-domain, a self-hosted ntfy server:
#                                   -> ~/.local/share/tmux-opsx/bin/ntfy (pinned release,
#                                      sha256 checked against a hash pinned here; or $OPSX_NTFY_BIN)
#                                   -> ~/.config/tmux-opsx/ntfy-server.yml (127.0.0.1:2586,
#                                      base https://ntfy.<domain>, deny-all)
#                                   -> ~/.config/tmux-opsx/tmux-opsx-ntfy.service (Linux)
#                                   -> static route opsx-ntfy (ntfy.<domain>) in caddy.json
#                                   -> ntfy user opsx, a random topic and a token in
#                                      ~/.config/tmux-opsx/notify.env (mode 600)
#      State (auth and cache DB) lives in ~/.local/state/tmux-opsx/ntfy/, never deleted.
#  10. the opsx command + /opsx-init skill
#                                   -> ~/.local/bin/opsx  (or ~/bin when only that is on PATH)
#                                   -> ~/.claude/skills/opsx-init/  (and the other five
#                                      skill dirs, like /fork; opsx-init.sh)
#      `opsx init` sets up a repo (OpenSpec, config context skeleton, graphify
#      ignore, .opsx/dev.yaml); it only ever writes inside the repo it runs in.
#  11. session restore (Claude Code) unless --skip-restore:
#                                   -> SessionStart hook in ~/.claude/settings.json
#                                      (opsx-sessions.sh hook, matcher startup|resume|clear)
#                                   -> marked block in ~/.tmux.conf above the tpm `run`
#                                      line: @resurrect-hook-post-save-all /
#                                      @resurrect-hook-post-restore-all running
#                                      `<opsx> sessions save|restore` (absolute path; with
#                                      --skip-init `bash <skill>/opsx-sessions.sh save|restore`)
#      The block is only written when the file loads tmux-resurrect and sets
#      neither hook option itself; otherwise the lines are printed. With
#      --restore-at-boot the block also sets @continuum-boot 'on' (kept on later
#      installs) and lingering is checked: the `sudo loginctl enable-linger`
#      command is printed, never run. State: ~/.local/state/tmux-opsx/sessions/,
#      never touched here.
#
# Window CLIs: Claude Code (claude), Cursor CLI (agent), Codex CLI (codex),
# OpenCode (opencode), and Gemini CLI (gemini). At least one must be on PATH.
#
# Usage: ./install.sh [options]
#   --prefix <dir>     Claude config dir (default: ~/.claude, or $CLAUDE_CONFIG_DIR)
#   --skip-openspec    Don't install/upgrade the OpenSpec CLI
#   --skip-graphify    Don't verify/install Graphify or copy its global skill
#   --skip-commands    Don't install global OpenSpec skills / /opsx:* commands
#   --skip-mcp         Don't install the browser-use MCP server
#   --skip-memory      Don't install the memory skill, instruction blocks, store, or import
#   --skip-learn       Don't install the learn skill or its instruction block
#   --skip-fork        Don't install the /fork skill
#   --skip-explain     Don't install the /explain skill
#   --skip-review      Don't install the /opsx-review skill
#   --skip-pr          Don't install the /opsx-pr skill
#   --skip-task        Don't install the /opsx-task skill
#   --skip-init        Don't install the opsx command or the /opsx-init skill
#   --skip-restore     Don't install the session restore hook or the ~/.tmux.conf block
#   --restore-at-boot  Also start tmux (and the restore) at system start through
#                      tmux-continuum's @continuum-boot (see item 11)
#   --skip-notify      Don't install push notifications (opsx-notify.sh, the Claude Code
#                      hooks, the ntfy server and its route); removes them on a rerun
#   --expose-domain <d>  Set up /expose: publish local ports at https://<name>--<project>.<d>
#                      (opt-in; needs $CLOUDFLARE_API_TOKEN or a prompt, see item 9).
#                      Use a domain that serves nothing else: the login cookie
#                      is sent to every host under it
#   --no-backup        Overwrite existing files without keeping a .bak copy
#   --uninstall        Remove everything this script installs (except the CLI)
#   -h, --help         Show this help
#
# Run as your normal user — sudo is not needed. If openspec is already installed
# under /usr/local but that prefix is not writable, the upgrade is skipped and
# the skill files are still installed. Running as root is fine when root is the
# login user (e.g. a VPS); files then go under /root. `sudo ./install.sh` from a
# normal user installs into that user's home, not /root.

set -uo pipefail

EXPLICIT_PREFIX=0
SKIP_OPENSPEC=0
SKIP_GRAPHIFY=0
SKIP_COMMANDS=0
SKIP_MCP=0
SKIP_MEMORY=0
SKIP_LEARN=0
SKIP_FORK=0
SKIP_EXPLAIN=0
SKIP_REVIEW=0
SKIP_PR=0
SKIP_TASK=0
SKIP_INIT=0
SKIP_RESTORE=0
RESTORE_AT_BOOT=0
SKIP_NOTIFY=0
EXPOSE_DOMAIN=""
BACKUP=1
UNINSTALL=0
NPM_PKG="@fission-ai/openspec"

# ---------- output helpers ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; D=""; N=""
fi
info() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s%s%s\n' "$B" "$N" "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
note() { printf '    %s%s%s\n' "$D" "$*" "$N"; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)        PREFIX=${2:?--prefix needs a directory}; EXPLICIT_PREFIX=1; shift 2 ;;
    --skip-openspec) SKIP_OPENSPEC=1; shift ;;
    --skip-graphify) SKIP_GRAPHIFY=1; shift ;;
    --skip-commands) SKIP_COMMANDS=1; shift ;;
    --skip-mcp)      SKIP_MCP=1; shift ;;
    --skip-memory)   SKIP_MEMORY=1; shift ;;
    --skip-learn)    SKIP_LEARN=1; shift ;;
    --skip-fork)     SKIP_FORK=1; shift ;;
    --skip-explain)  SKIP_EXPLAIN=1; shift ;;
    --skip-review)   SKIP_REVIEW=1; shift ;;
    --skip-pr)       SKIP_PR=1; shift ;;
    --skip-task)     SKIP_TASK=1; shift ;;
    --skip-init)     SKIP_INIT=1; shift ;;
    --skip-restore)  SKIP_RESTORE=1; shift ;;
    --restore-at-boot) RESTORE_AT_BOOT=1; shift ;;
    --skip-notify)   SKIP_NOTIFY=1; shift ;;
    --expose-domain) [ $# -ge 2 ] || die "--expose-domain needs a domain"
                     EXPOSE_DOMAIN=$2; [ -n "$EXPOSE_DOMAIN" ] || die "--expose-domain needs a domain"; shift 2 ;;
    --expose-domain=*) EXPOSE_DOMAIN=${1#--expose-domain=}; [ -n "$EXPOSE_DOMAIN" ] || die "--expose-domain needs a domain"; shift ;;
    --no-backup)     BACKUP=0; shift ;;
    --uninstall)     UNINSTALL=1; shift ;;
    -h|--help)       usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# --expose-domain: strip a leading '*.', lowercase, then require a DNS name of
# at least two labels. Checked here, before anything is installed.
if [ -n "$EXPOSE_DOMAIN" ]; then
  EXPOSE_DOMAIN_ARG=$EXPOSE_DOMAIN
  EXPOSE_DOMAIN=${EXPOSE_DOMAIN#\*.}
  EXPOSE_DOMAIN=${EXPOSE_DOMAIN%.}
  EXPOSE_DOMAIN=$(printf '%s' "$EXPOSE_DOMAIN" | LC_ALL=C tr 'A-Z' 'a-z')
  if ! [[ "$EXPOSE_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
     || [ "${#EXPOSE_DOMAIN}" -gt 200 ]; then
    die "invalid --expose-domain '$EXPOSE_DOMAIN_ARG': use a DNS name like dev.example.com (labels of a-z, 0-9 and '-', not starting or ending with '-')"
  fi
fi

# Skill files belong in the invoking user's home. sudo drops ~/.local/bin from
# PATH and sets HOME=/root, which makes both the prefix and CLI checks wrong.
# When a normal user ran `sudo ./install.sh`, install into that user's home.
# When root is the real login (common on a VPS), /root is the right home.
if [ "$(id -u)" -eq 0 ]; then
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    REAL_HOME=${REAL_HOME:-/home/$SUDO_USER}
    export HOME="$REAL_HOME"
    for d in "$HOME/.local/bin" "$HOME/bin"; do
      [ -d "$d" ] && PATH="$d:$PATH"
    done
    export PATH
    note "running under sudo — installing into $SUDO_USER's home ($HOME)"
  else
    HOME=${HOME:-/root}
    export HOME
    for d in "$HOME/.local/bin" "$HOME/bin"; do
      [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
    done
    export PATH
    note "running as root — installing into $HOME"
  fi
fi

if [ "$EXPLICIT_PREFIX" -eq 1 ]; then
  :
elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  PREFIX=$CLAUDE_CONFIG_DIR
else
  PREFIX=$HOME/.claude
fi

run_as_owner() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    sudo -u "$SUDO_USER" -H "$@"
  else
    "$@"
  fi
}

# Resolve this script's directory without readlink -f (absent on stock macOS).
SRC=$(cd -- "$(dirname -- "$0")" && pwd)

OS=$(uname -s)
case "$OS" in
  Darwin) PLATFORM="macOS" ;;
  Linux)  PLATFORM="Linux" ;;
  *) die "unsupported platform: $OS (this installer supports macOS and Linux)" ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

npm_global_prefix() {
  run_as_owner npm config get prefix 2>/dev/null | tr -d '\r\n'
}

npm_prefix_writable() {
  local p
  p=$(npm_global_prefix)
  [ -n "$p" ] && [ -w "$p" ]
}

# Install or upgrade openspec. Never requires sudo for the skill files themselves;
# only the npm global prefix may need elevated permissions to upgrade.
install_openspec() {
  local user_local=$HOME/.local

  if run_as_owner npm install -g "$NPM_PKG" >/dev/null 2>&1; then
    ok "openspec $(openspec --version 2>/dev/null) ($(command -v openspec))"
    return 0
  fi

  # Global prefix not writable — very common when npm uses /usr/local.
  if have openspec; then
    ok "openspec $(openspec --version 2>/dev/null) ($(command -v openspec))"
    warn "skipped upgrade — npm prefix $(npm_global_prefix) is not writable by $(id -un)"
    note "to upgrade later: sudo npm install -g $NPM_PKG"
    note "or move npm to your home: npm config set prefix ~/.local && npm install -g $NPM_PKG"
    return 0
  fi

  # Not on PATH yet — install under ~/.local without touching /usr/local.
  mkdir -p "$user_local/bin" "$user_local/lib/node_modules"
  if run_as_owner npm install --prefix "$user_local" -g "$NPM_PKG" >/dev/null 2>&1; then
    export PATH="$user_local/bin:$PATH"
    ok "openspec $(openspec --version 2>/dev/null) ($user_local/bin/openspec)"
    note "installed under ~/.local — add to your shell profile if needed:"
    note "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    return 0
  fi

  warn "could not install $NPM_PKG"
  note "try: sudo npm install -g $NPM_PKG"
  note "or:  npm config set prefix ~/.local && npm install -g $NPM_PKG"
  return 1
}

graphify_version() {
  graphify --version 2>/dev/null | awk '{print $NF; exit}'
}

# Verify graphify is on PATH, or install it (uv tool / pipx / pip --user).
install_graphify_cli() {
  local user_local=$HOME/.local
  export PATH="$user_local/bin:$PATH"

  if have graphify; then
    ok "graphify $(graphify_version) ($(command -v graphify))"
    return 0
  fi

  if have uv; then
    note "installing graphifyy with uv tool"
    if run_as_owner uv tool install graphifyy >/dev/null 2>&1; then
      hash -r 2>/dev/null || true
      if have graphify; then
        ok "graphify $(graphify_version) ($(command -v graphify))"
        return 0
      fi
    fi
  fi

  if have pipx; then
    note "installing graphifyy with pipx"
    if run_as_owner pipx install graphifyy >/dev/null 2>&1; then
      hash -r 2>/dev/null || true
      if have graphify; then
        ok "graphify $(graphify_version) ($(command -v graphify))"
        return 0
      fi
    fi
  fi

  if have python3; then
    note "installing graphifyy with pip --user"
    if run_as_owner python3 -m pip install --user graphifyy >/dev/null 2>&1 \
       || run_as_owner python3 -m pip install --user graphifyy --break-system-packages >/dev/null 2>&1; then
      hash -r 2>/dev/null || true
      if have graphify; then
        ok "graphify $(graphify_version) ($(command -v graphify))"
        return 0
      fi
    fi
  fi

  warn "could not install graphify"
  note "try: uv tool install graphifyy"
  note "or:  pipx install graphifyy"
  return 1
}

# Copy a graphify skill tree (SKILL.md + references/) into a global skills dir.
copy_graphify_skill_tree() {
  local src=$1 dest=$2 label=$3
  local f
  [ -d "$src" ] || return 1
  [ -f "$src/SKILL.md" ] || return 1
  mkdir -p "$dest" || die "cannot create $dest"
  install_file "$src/SKILL.md" "$dest/SKILL.md"
  [ -f "$src/.graphify_version" ] && install_file "$src/.graphify_version" "$dest/.graphify_version"
  if [ -d "$src/references" ]; then
    mkdir -p "$dest/references"
    for f in "$src/references"/*; do
      [ -f "$f" ] || continue
      install_file "$f" "$dest/references/$(basename "$f")"
    done
  fi
  ok "/graphify -> $dest ($label)"
}

# Merge the Gemini BeforeTool hook graphify generated (in $src_settings) into
# the global ~/.gemini/settings.json, replacing any earlier graphify hook.
upsert_gemini_graphify_hook() {
  local src_settings=$1 dest=$2
  have python3 || return 1
  [ -f "$src_settings" ] || return 1
  mkdir -p "$(dirname "$dest")" || return 1
  HOOK_SRC=$src_settings HOOK_DEST=$dest python3 <<'PYHOOK' || return 1
import json, os, re

src = os.environ["HOOK_SRC"]
dest = os.environ["HOOK_DEST"]

def load(path):
    if not os.path.isfile(path):
        return {}
    raw = open(path, encoding="utf-8-sig").read()
    raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    raw = re.sub(r"(?m)^\s*//.*?$", "", raw)
    obj = json.loads(raw) if raw.strip() else {}
    return obj if isinstance(obj, dict) else {}

src_hooks = load(src).get("hooks", {})
new_hooks = [h for h in src_hooks.get("BeforeTool", []) if "graphify" in json.dumps(h)]
if not new_hooks:
    raise SystemExit("no graphify BeforeTool hook in " + src)

obj = load(dest)
hooks = obj.setdefault("hooks", {})
if not isinstance(hooks, dict):
    hooks = {}
    obj["hooks"] = hooks
before = hooks.get("BeforeTool", [])
if not isinstance(before, list):
    before = []
hooks["BeforeTool"] = [h for h in before if "graphify" not in json.dumps(h)] + new_hooks

with open(dest + ".tmp", "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
    f.write("\n")
PYHOOK
  replace_if_changed "$dest"
}

# Move $dest.tmp over $dest, keeping a timestamped backup, unless identical.
# Sets REPLACED=1 when $dest was changed or created, 0 when it was identical.
replace_if_changed() {
  local dest=$1
  REPLACED=0
  if [ -f "$dest" ] && cmp -s "$dest" "$dest.tmp"; then
    rm -f "$dest.tmp"
    return 0
  fi
  REPLACED=1
  if [ -e "$dest" ] && [ "$BACKUP" -eq 1 ]; then
    cp "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  fi
  mv "$dest.tmp" "$dest" || die "cannot write $dest"
}

# Drop graphify's BeforeTool hook from the global Gemini settings.
remove_gemini_graphify_hook() {
  local dest=$1
  [ -f "$dest" ] || return 0
  grep -q 'graphify' "$dest" 2>/dev/null || return 0
  have python3 || return 1
  HOOK_DEST=$dest python3 <<'PYHOOK' || return 1
import json, os, re

dest = os.environ["HOOK_DEST"]
raw = open(dest, encoding="utf-8-sig").read()
raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
raw = re.sub(r"(?m)^\s*//.*?$", "", raw)
obj = json.loads(raw) if raw.strip() else {}
hooks = obj.get("hooks")
if isinstance(hooks, dict) and isinstance(hooks.get("BeforeTool"), list):
    hooks["BeforeTool"] = [h for h in hooks["BeforeTool"] if "graphify" not in json.dumps(h)]
    if not hooks["BeforeTool"]:
        del hooks["BeforeTool"]
    if not hooks:
        del obj["hooks"]
with open(dest + ".tmp", "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
    f.write("\n")
PYHOOK
  replace_if_changed "$dest"
  ok "removed graphify hook from $(printf '%s' "$dest" | sed "s|$HOME|~|")"
}

# graphify's Gemini install writes its always-on section to ./GEMINI.md and its
# hook to ./.gemini/settings.json — project files. Lift both out of the scratch
# dir into the global Gemini config so every project gets them.
install_graphify_gemini_globals() {
  local scratch=$1 blockfile
  if [ -f "$scratch/GEMINI.md" ]; then
    blockfile=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
    {
      printf '%s\n' "$GRAPHIFY_BLOCK_START"
      cat "$scratch/GEMINI.md"
      [ -n "$(tail -c1 "$scratch/GEMINI.md")" ] && printf '\n'
      printf '%s\n' "$GRAPHIFY_BLOCK_END"
    } > "$blockfile"
    upsert_block_file "$GEMINI_MD" "$GRAPHIFY_BLOCK_START" "$GRAPHIFY_BLOCK_END" "$blockfile"
    rm -f "$blockfile"
    ok "graphify section -> $(printf '%s' "$GEMINI_MD" | sed "s|$HOME|~|") (Gemini CLI)"
  else
    warn "graphify did not generate a GEMINI.md section"
  fi
  if upsert_gemini_graphify_hook "$scratch/.gemini/settings.json" "$GEMINI_SETTINGS"; then
    ok "graphify BeforeTool hook -> $(printf '%s' "$GEMINI_SETTINGS" | sed "s|$HOME|~|") (Gemini CLI)"
  else
    warn "could not add graphify's BeforeTool hook to $GEMINI_SETTINGS"
  fi
}

# graphify's OpenCode install writes ./.opencode/plugins/graphify.js and
# registers it in ./.opencode/opencode.json — project files. OpenCode auto-loads
# ~/.config/opencode/plugins/*.js, so the global copy needs no config entry.
install_graphify_opencode_globals() {
  local scratch=$1
  if [ -f "$scratch/.opencode/plugins/graphify.js" ]; then
    install_file "$scratch/.opencode/plugins/graphify.js" "$OPENCODE_GRAPHIFY_PLUGIN"
    ok "graphify plugin -> $(printf '%s' "$OPENCODE_GRAPHIFY_PLUGIN" | sed "s|$HOME|~|") (OpenCode, auto-loaded)"
  else
    warn "graphify did not generate an OpenCode plugin"
  fi
}

# Install Graphify's packaged skill globally for Claude, Codex, OpenCode, Agent
# Skills and Gemini. The skill files already go to each CLI's global skills dir,
# but graphify drops its Gemini/OpenCode always-on wiring into the *current
# directory*, so run it from a scratch dir (nothing lands in the checkout) and
# move that wiring into the global config dirs afterwards. Cursor has no global
# `graphify install --platform cursor` (that writes a project rule), so copy the
# Claude skill tree into ~/.cursor/skills/graphify.
install_graphify_skills() {
  local p scratch
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] || [ "$PREFIX" = "$HOME/.claude" ] || export CLAUDE_CONFIG_DIR=$PREFIX

  scratch=$(mktemp -d 2>/dev/null || mktemp -d -t tmuxopsx)
  [ -n "$scratch" ] && [ -d "$scratch" ] || die "could not create a temp directory"
  for p in claude codex opencode agents gemini; do
    if (cd "$scratch" && graphify install --platform "$p" >/dev/null 2>&1); then
      ok "graphify install --platform $p"
    else
      warn "graphify install --platform $p failed"
      rm -rf "$scratch"
      return 1
    fi
  done
  install_graphify_gemini_globals "$scratch"
  install_graphify_opencode_globals "$scratch"
  rm -rf "$scratch"

  copy_graphify_skill_tree "$PREFIX/skills/graphify" "$HOME/.cursor/skills/graphify" "Cursor CLI" \
    || copy_graphify_skill_tree "$HOME/.claude/skills/graphify" "$HOME/.cursor/skills/graphify" "Cursor CLI" \
    || warn "could not copy graphify skill into ~/.cursor/skills/graphify"
}

remove_graphify_skill() {
  local dest=$1 label=$2
  if [ -d "$dest" ]; then
    rm -rf "$dest"
    ok "removed $dest ($label)"
  fi
}

# Copy a file, keeping a timestamped backup of anything it replaces.
install_file() {
  local src=$1 dest=$2
  mkdir -p "$(dirname "$dest")" || die "cannot create $(dirname "$dest")"
  if [ -e "$dest" ] && [ "$BACKUP" -eq 1 ]; then
    if ! cmp -s "$src" "$dest"; then
      local bak
      bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
      cp "$dest" "$bak" || die "cannot back up $dest"
      note "backed up existing $(basename "$dest") -> $(basename "$bak")"
    fi
  fi
  cp "$src" "$dest" || die "cannot write $dest"
}

CURSOR_AGENTS_DIR=$HOME/.cursor/agents
CURSOR_SKILLS_DIR=$HOME/.cursor/skills/opsx-run
CURSOR_COMMANDS_DIR=$HOME/.cursor/commands
CODEX_HOME_DIR=${CODEX_HOME:-$HOME/.codex}
CODEX_AGENTS_DIR=$CODEX_HOME_DIR/agents
CODEX_SKILLS_DIR=$CODEX_HOME_DIR/skills/opsx-run
CODEX_OPENSPEC_SKILLS_DIR=$CODEX_HOME_DIR/skills
AGENTS_SKILLS_DIR=$HOME/.agents/skills/opsx-run
AGENTS_OPENSPEC_SKILLS_DIR=$HOME/.agents/skills
OPENCODE_CONFIG_DIR=${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}
OPENCODE_AGENTS_DIR=$OPENCODE_CONFIG_DIR/agents
OPENCODE_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills/opsx-run
OPENCODE_OPENSPEC_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills
OPENCODE_COMMANDS_DIR=$OPENCODE_CONFIG_DIR/commands
GEMINI_HOME_DIR=${GEMINI_HOME:-$HOME/.gemini}
GEMINI_AGENTS_DIR=$GEMINI_HOME_DIR/agents
GEMINI_SKILLS_DIR=$GEMINI_HOME_DIR/skills/opsx-run
GEMINI_OPENSPEC_SKILLS_DIR=$GEMINI_HOME_DIR/skills
GEMINI_COMMANDS_DIR=$GEMINI_HOME_DIR/commands
GEMINI_SETTINGS=$GEMINI_HOME_DIR/settings.json
CODEX_CONFIG=$CODEX_HOME_DIR/config.toml
CURSOR_MEMORY_SKILLS_DIR=$HOME/.cursor/skills/memory
CODEX_MEMORY_SKILLS_DIR=$CODEX_HOME_DIR/skills/memory
AGENTS_MEMORY_SKILLS_DIR=$HOME/.agents/skills/memory
OPENCODE_MEMORY_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills/memory
GEMINI_MEMORY_SKILLS_DIR=$GEMINI_HOME_DIR/skills/memory
MEMORY_STORE_DIR=$HOME/.agents/memory
CURSOR_LEARN_SKILLS_DIR=$HOME/.cursor/skills/learn
CODEX_LEARN_SKILLS_DIR=$CODEX_HOME_DIR/skills/learn
AGENTS_LEARN_SKILLS_DIR=$HOME/.agents/skills/learn
OPENCODE_LEARN_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills/learn
GEMINI_LEARN_SKILLS_DIR=$GEMINI_HOME_DIR/skills/learn
CURSOR_FORK_SKILLS_DIR=$HOME/.cursor/skills/fork
CODEX_FORK_SKILLS_DIR=$CODEX_HOME_DIR/skills/fork
AGENTS_FORK_SKILLS_DIR=$HOME/.agents/skills/fork
OPENCODE_FORK_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills/fork
GEMINI_FORK_SKILLS_DIR=$GEMINI_HOME_DIR/skills/fork
CURSOR_EXPLAIN_SKILLS_DIR=$HOME/.cursor/skills/explain
CODEX_EXPLAIN_SKILLS_DIR=$CODEX_HOME_DIR/skills/explain
AGENTS_EXPLAIN_SKILLS_DIR=$HOME/.agents/skills/explain
OPENCODE_EXPLAIN_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills/explain
GEMINI_EXPLAIN_SKILLS_DIR=$GEMINI_HOME_DIR/skills/explain
CURSOR_REVIEW_SKILLS_DIR=$HOME/.cursor/skills/opsx-review
CODEX_REVIEW_SKILLS_DIR=$CODEX_HOME_DIR/skills/opsx-review
AGENTS_REVIEW_SKILLS_DIR=$HOME/.agents/skills/opsx-review
OPENCODE_REVIEW_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills/opsx-review
GEMINI_REVIEW_SKILLS_DIR=$GEMINI_HOME_DIR/skills/opsx-review
CURSOR_PR_SKILLS_DIR=$HOME/.cursor/skills/opsx-pr
CODEX_PR_SKILLS_DIR=$CODEX_HOME_DIR/skills/opsx-pr
AGENTS_PR_SKILLS_DIR=$HOME/.agents/skills/opsx-pr
OPENCODE_PR_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills/opsx-pr
GEMINI_PR_SKILLS_DIR=$GEMINI_HOME_DIR/skills/opsx-pr
CURSOR_TASK_SKILLS_DIR=$HOME/.cursor/skills/opsx-task
CODEX_TASK_SKILLS_DIR=$CODEX_HOME_DIR/skills/opsx-task
AGENTS_TASK_SKILLS_DIR=$HOME/.agents/skills/opsx-task
OPENCODE_TASK_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills/opsx-task
GEMINI_TASK_SKILLS_DIR=$GEMINI_HOME_DIR/skills/opsx-task
CURSOR_EXPOSE_SKILLS_DIR=$HOME/.cursor/skills/expose
CODEX_EXPOSE_SKILLS_DIR=$CODEX_HOME_DIR/skills/expose
AGENTS_EXPOSE_SKILLS_DIR=$HOME/.agents/skills/expose
OPENCODE_EXPOSE_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills/expose
GEMINI_EXPOSE_SKILLS_DIR=$GEMINI_HOME_DIR/skills/expose
CURSOR_INIT_SKILLS_DIR=$HOME/.cursor/skills/opsx-init
CODEX_INIT_SKILLS_DIR=$CODEX_HOME_DIR/skills/opsx-init
AGENTS_INIT_SKILLS_DIR=$HOME/.agents/skills/opsx-init
OPENCODE_INIT_SKILLS_DIR=$OPENCODE_CONFIG_DIR/skills/opsx-init
GEMINI_INIT_SKILLS_DIR=$GEMINI_HOME_DIR/skills/opsx-init
# The launcher marks itself with this line; uninstall removes only marked files.
OPSX_LAUNCHER_MARK='# tmux-opsx launcher'
CODEX_AGENTS_MD=$CODEX_HOME_DIR/AGENTS.md
OPENCODE_AGENTS_MD=$OPENCODE_CONFIG_DIR/AGENTS.md
GEMINI_MD=$GEMINI_HOME_DIR/GEMINI.md
OPENCODE_PLUGINS_DIR=$OPENCODE_CONFIG_DIR/plugins
OPENCODE_GRAPHIFY_PLUGIN=$OPENCODE_PLUGINS_DIR/graphify.js
GRAPHIFY_BLOCK_START='<!-- tmux-opsx:graphify:start -->'
GRAPHIFY_BLOCK_END='<!-- tmux-opsx:graphify:end -->'
if [ -f "$OPENCODE_CONFIG_DIR/opencode.jsonc" ]; then
  OPENCODE_CONFIG=$OPENCODE_CONFIG_DIR/opencode.jsonc
else
  OPENCODE_CONFIG=$OPENCODE_CONFIG_DIR/opencode.json
fi

# Copy every openspec-* skill folder from a generated tree into a global skills dir.
install_openspec_skills() {
  local src_skills=$1 dest_skills=$2 label=$3
  local d name count=0
  if [ ! -d "$src_skills" ]; then
    warn "no OpenSpec skills generated for $label ($src_skills missing) — skipping"
    return 0
  fi
  mkdir -p "$dest_skills" || die "cannot create $dest_skills"
  for d in "$src_skills"/openspec-*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    mkdir -p "$dest_skills/$name" || die "cannot create $dest_skills/$name"
    if [ -f "$d/SKILL.md" ]; then
      install_file "$d/SKILL.md" "$dest_skills/$name/SKILL.md"
      count=$((count + 1))
    fi
  done
  if [ "$count" -gt 0 ]; then
    ok "$count OpenSpec skills -> $dest_skills ($label)"
  fi
}

# Copy opsx command files (flat opsx-*.md or nested opsx/*.md) into a global dir.
install_openspec_commands() {
  local src_commands=$1 dest_commands=$2 label=$3
  local f name count=0
  [ -d "$src_commands" ] || return 0
  mkdir -p "$dest_commands" || die "cannot create $dest_commands"
  # Cursor / OpenCode style: opsx-propose.md at the commands root.
  for f in "$src_commands"/opsx-*.md "$src_commands"/opsx-*.toml; do
    [ -e "$f" ] || continue
    install_file "$f" "$dest_commands/$(basename "$f")"
    count=$((count + 1))
  done
  # Claude style: commands/opsx/{propose,apply,…}.md
  if [ -d "$src_commands/opsx" ]; then
    mkdir -p "$dest_commands/opsx" || die "cannot create $dest_commands/opsx"
    for f in "$src_commands"/opsx/*; do
      [ -f "$f" ] || continue
      install_file "$f" "$dest_commands/opsx/$(basename "$f")"
      count=$((count + 1))
    done
  fi
  if [ "$count" -gt 0 ]; then
    ok "$count OpenSpec commands -> $dest_commands ($label)"
  fi
}

# Remove globally installed OpenSpec skill folders (openspec-*).
remove_openspec_skills() {
  local dest_skills=$1 label=$2
  local d removed=0
  [ -d "$dest_skills" ] || return 0
  for d in "$dest_skills"/openspec-*; do
    [ -d "$d" ] || continue
    rm -rf "$d"
    removed=$((removed + 1))
  done
  if [ "$removed" -gt 0 ]; then
    ok "removed $removed OpenSpec skills from $dest_skills ($label)"
  fi
}

# Remove globally installed OpenSpec command files.
remove_openspec_commands() {
  local dest_commands=$1 label=$2
  local f removed=0
  [ -d "$dest_commands" ] || return 0
  for f in "$dest_commands"/opsx-*.md "$dest_commands"/opsx-*.toml; do
    [ -e "$f" ] || continue
    rm -f "$f"
    removed=$((removed + 1))
  done
  if [ -d "$dest_commands/opsx" ]; then
    rm -rf "$dest_commands/opsx"
    ok "removed commands/opsx ($label)"
  fi
  if [ "$removed" -gt 0 ]; then
    ok "removed $removed OpenSpec command files from $dest_commands ($label)"
  fi
}

# Install the skill files (SKILL.md + helper scripts) into one destination dir.
install_opsx_run_skill() {
  local dest=$1 label=$2
  install_file "$SRC/skills/opsx-run/SKILL.md"       "$dest/SKILL.md"
  install_file "$SRC/skills/opsx-run/opsx-window.sh" "$dest/opsx-window.sh"
  install_file "$SRC/skills/opsx-run/opsx-merge.sh"  "$dest/opsx-merge.sh"
  install_file "$SRC/skills/opsx-run/opsx-land.sh"   "$dest/opsx-land.sh"
  install_file "$SRC/skills/opsx-run/opsx-eval.sh"   "$dest/opsx-eval.sh"
  install_file "$SRC/skills/opsx-run/opsx-preview.sh" "$dest/opsx-preview.sh"
  install_file "$SRC/skills/opsx-run/opsx-dev.sh"    "$dest/opsx-dev.sh"
  install_file "$SRC/skills/opsx-run/opsx-sessions.sh" "$dest/opsx-sessions.sh"
  install_file "$SRC/agents/models.conf"             "$dest/models.conf"
  if [ "$SKIP_NOTIFY" -eq 0 ]; then
    install_file "$SRC/skills/opsx-run/opsx-notify.sh" "$dest/opsx-notify.sh"
    chmod +x "$dest/opsx-notify.sh" || die "cannot chmod +x $dest/opsx-notify.sh"
  else
    rm -f "$dest/opsx-notify.sh"
  fi
  chmod +x "$dest/opsx-window.sh" || die "cannot chmod +x $dest/opsx-window.sh"
  chmod +x "$dest/opsx-merge.sh"  || die "cannot chmod +x $dest/opsx-merge.sh"
  chmod +x "$dest/opsx-land.sh"   || die "cannot chmod +x $dest/opsx-land.sh"
  chmod +x "$dest/opsx-eval.sh"   || die "cannot chmod +x $dest/opsx-eval.sh"
  chmod +x "$dest/opsx-preview.sh" || die "cannot chmod +x $dest/opsx-preview.sh"
  chmod +x "$dest/opsx-dev.sh"    || die "cannot chmod +x $dest/opsx-dev.sh"
  chmod +x "$dest/opsx-sessions.sh" || die "cannot chmod +x $dest/opsx-sessions.sh"
  ok "/opsx-run -> $dest ($label)"
}

# Install the memory skill (SKILL.md + templates + import script) into one dest dir.
install_memory_skill() {
  local dest=$1 label=$2
  install_file "$SRC/skills/memory/SKILL.md" "$dest/SKILL.md"
  mkdir -p "$dest/templates" || die "cannot create $dest/templates"
  install_file "$SRC/skills/memory/templates/memory.md"  "$dest/templates/memory.md"
  install_file "$SRC/skills/memory/templates/MEMORY.md"  "$dest/templates/MEMORY.md"
  install_file "$SRC/skills/memory/import-claude-memory.sh" "$dest/import-claude-memory.sh"
  chmod +x "$dest/import-claude-memory.sh" || die "cannot chmod +x $dest/import-claude-memory.sh"
  ok "memory -> $dest ($label)"
}

# Install the learn skill (SKILL.md + learn.sh) into one dest dir.
install_learn_skill() {
  local dest=$1 label=$2
  install_file "$SRC/skills/learn/SKILL.md" "$dest/SKILL.md"
  install_file "$SRC/skills/learn/learn.sh" "$dest/learn.sh"
  chmod +x "$dest/learn.sh" || die "cannot chmod +x $dest/learn.sh"
  ok "learn -> $dest ($label)"
}

# Install the /fork skill (SKILL.md + fork.sh) into one dest dir.
install_fork_skill() {
  local dest=$1 label=$2
  install_file "$SRC/skills/fork/SKILL.md" "$dest/SKILL.md"
  install_file "$SRC/skills/fork/fork.sh"  "$dest/fork.sh"
  chmod +x "$dest/fork.sh" || die "cannot chmod +x $dest/fork.sh"
  ok "/fork -> $dest ($label)"
}

# Install the /explain skill (SKILL.md + explain.sh) into one dest dir.
install_explain_skill() {
  local dest=$1 label=$2
  install_file "$SRC/skills/explain/SKILL.md"   "$dest/SKILL.md"
  install_file "$SRC/skills/explain/explain.sh" "$dest/explain.sh"
  chmod +x "$dest/explain.sh" || die "cannot chmod +x $dest/explain.sh"
  ok "/explain -> $dest ($label)"
}

# Install the /opsx-review skill (SKILL.md + opsx-review.sh) into one dest dir.
install_review_skill() {
  local dest=$1 label=$2
  install_file "$SRC/skills/opsx-review/SKILL.md"       "$dest/SKILL.md"
  install_file "$SRC/skills/opsx-review/opsx-review.sh" "$dest/opsx-review.sh"
  chmod +x "$dest/opsx-review.sh" || die "cannot chmod +x $dest/opsx-review.sh"
  ok "/opsx-review -> $dest ($label)"
}

# Install the /opsx-pr skill (SKILL.md + pr.sh) into one dest dir. pr.sh finds
# opsx-window.sh in the sibling opsx-run skill folder.
install_pr_skill() {
  local dest=$1 label=$2
  install_file "$SRC/skills/opsx-pr/SKILL.md" "$dest/SKILL.md"
  install_file "$SRC/skills/opsx-pr/pr.sh"    "$dest/pr.sh"
  chmod +x "$dest/pr.sh" || die "cannot chmod +x $dest/pr.sh"
  ok "/opsx-pr -> $dest ($label)"
}

# Install the /opsx-task skill (SKILL.md + opsx-task.sh) into one dest dir.
install_task_skill() {
  local dest=$1 label=$2
  install_file "$SRC/skills/opsx-task/SKILL.md"     "$dest/SKILL.md"
  install_file "$SRC/skills/opsx-task/opsx-task.sh" "$dest/opsx-task.sh"
  chmod +x "$dest/opsx-task.sh" || die "cannot chmod +x $dest/opsx-task.sh"
  ok "/opsx-task -> $dest ($label)"
}

# Install the /opsx-init skill (SKILL.md + opsx-init.sh) into one dest dir.
install_opsx_init_skill() {
  local dest=$1 label=$2
  install_file "$SRC/skills/opsx-init/SKILL.md"     "$dest/SKILL.md"
  install_file "$SRC/skills/opsx-init/opsx-init.sh" "$dest/opsx-init.sh"
  chmod +x "$dest/opsx-init.sh" || die "cannot chmod +x $dest/opsx-init.sh"
  ok "/opsx-init -> $dest ($label)"
}

# The user's bin dir for the opsx launcher: ~/.local/bin, or ~/bin when that
# is on PATH and ~/.local/bin is not.
user_bin_dir() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) printf '%s' "$HOME/.local/bin" ;;
    *":$HOME/bin:"*)        printf '%s' "$HOME/bin" ;;
    *)                      printf '%s' "$HOME/.local/bin" ;;
  esac
}

# Install the /expose skill (SKILL.md + expose.sh) into one dest dir.
install_expose_skill() {
  local dest=$1 label=$2
  install_file "$SRC/skills/expose/SKILL.md"  "$dest/SKILL.md"
  install_file "$SRC/skills/expose/expose.sh" "$dest/expose.sh"
  chmod +x "$dest/expose.sh" || die "cannot chmod +x $dest/expose.sh"
  ok "/expose -> $dest ($label)"
}

# ---------- /expose: token, Caddy, base config, service, DNS check ----------
EXPOSE_CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/tmux-opsx
EXPOSE_ENV=$EXPOSE_CONFIG_DIR/expose.env
EXPOSE_CADDY_JSON=$EXPOSE_CONFIG_DIR/caddy.json
EXPOSE_UNIT_NAME=tmux-opsx-caddy
EXPOSE_UNIT=$EXPOSE_CONFIG_DIR/$EXPOSE_UNIT_NAME.service
EXPOSE_STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-opsx/expose
EXPOSE_SOCK=$EXPOSE_STATE_DIR/caddy-admin.sock
EXPOSE_BIN_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/tmux-opsx/bin
EXPOSE_SYSTEMD_DIR=${OPSX_SYSTEMD_DIR:-/etc/systemd/system}
EXPOSE_TOKEN=""
EXPOSE_TOKEN_SOURCE=""
CADDY_BIN=""
# Set by a rerun that changes an existing setup (see expose_apply_changes).
EXPOSE_OLD_DOMAIN=""
EXPOSE_CONFIG_CHANGED=0
EXPOSE_TOKEN_CHANGED=0

tilde() { printf '%s' "$1" | sed "s|^$HOME|~|"; }

# ---------- session restore (Claude SessionStart hook + ~/.tmux.conf block) ----------
RESTORE_BLOCK_START='# >>> tmux-opsx session restore >>>'
RESTORE_BLOCK_END='# <<< tmux-opsx session restore <<<'

# The tmux config install.sh edits: ~/.tmux.conf, or the XDG one when only
# that exists.
tmux_conf_path() {
  local xdg=${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf
  if [ ! -f "$HOME/.tmux.conf" ] && [ -f "$xdg" ]; then
    printf '%s' "$xdg"
  else
    printf '%s' "$HOME/.tmux.conf"
  fi
}

# Lines of $1 outside our marked block, comments dropped.
tmux_conf_active_lines() {
  awk -v start="$RESTORE_BLOCK_START" -v end="$RESTORE_BLOCK_END" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    skip { next }
    /^[[:space:]]*#/ { next }
    { print }' "$1" 2>/dev/null
}

tmux_conf_loads() { tmux_conf_active_lines "$1" | grep -q -- "$2"; }

# settings.json is edited by two installers (the notify hooks and the session
# restore hook): keep one .bak per run, of the file as it was before this run.
SETTINGS_BACKED_UP=""
backup_settings_once() {
  local f=$1
  [ "$BACKUP" -eq 1 ] && [ -e "$f" ] || return 0
  [ "$SETTINGS_BACKED_UP" = "$f" ] && return 0
  cp "$f" "$f.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  SETTINGS_BACKED_UP=$f
}

# Like replace_if_changed, with the once-per-run settings.json backup.
replace_settings_if_changed() {
  local dest=$1
  if [ -f "$dest" ] && cmp -s "$dest" "$dest.tmp"; then
    rm -f "$dest.tmp"
    return 0
  fi
  backup_settings_once "$dest"
  mv "$dest.tmp" "$dest" || die "cannot write $dest"
}

# True when $1 is missing or holds valid JSON.
settings_json_ok() {
  [ -f "$1" ] || return 0
  if have jq; then
    jq empty "$1" >/dev/null 2>&1
  else
    python3 -I -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8-sig"))' "$1" >/dev/null 2>&1
  fi
}

# Merge the opsx-sessions.sh SessionStart hook into Claude Code's settings.json
# (matcher startup|resume|clear), replacing an earlier copy of ours. Returns 2
# (file left alone) when settings.json is not valid JSON.
upsert_claude_session_hook() {
  local dest=$1 script=$2
  have python3 || return 1
  settings_json_ok "$dest" || return 2
  mkdir -p "$(dirname "$dest")" || return 1
  HOOK_DEST=$dest HOOK_SCRIPT=$script python3 <<'PYHOOK' || return 1
import json, os, shlex

dest = os.environ["HOOK_DEST"]
cmd = "bash " + shlex.quote(os.environ["HOOK_SCRIPT"]) + " hook"
obj = {}
if os.path.isfile(dest):
    raw = open(dest, encoding="utf-8-sig").read()
    obj = json.loads(raw) if raw.strip() else {}
if not isinstance(obj, dict):
    raise SystemExit(dest + " is not a JSON object")
hooks = obj.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
    obj["hooks"] = hooks
lst = hooks.get("SessionStart")
if not isinstance(lst, list):
    lst = []
lst = [h for h in lst if "opsx-sessions.sh" not in json.dumps(h)]
lst.append({"matcher": "startup|resume|clear",
            "hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
hooks["SessionStart"] = lst
with open(dest + ".tmp", "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
    f.write("\n")
PYHOOK
  replace_settings_if_changed "$dest"
}

remove_claude_session_hook() {
  local dest=$1
  [ -f "$dest" ] || return 0
  grep -q 'opsx-sessions.sh' "$dest" 2>/dev/null || return 0
  have python3 || { warn "python3 not found — remove the opsx-sessions.sh SessionStart hook from $dest by hand"; return 1; }
  HOOK_DEST=$dest python3 <<'PYHOOK' || { warn "could not edit $dest — remove the opsx-sessions.sh hook by hand"; return 1; }
import json, os

dest = os.environ["HOOK_DEST"]
raw = open(dest, encoding="utf-8-sig").read()
obj = json.loads(raw) if raw.strip() else {}
hooks = obj.get("hooks") if isinstance(obj, dict) else None
if isinstance(hooks, dict) and isinstance(hooks.get("SessionStart"), list):
    hooks["SessionStart"] = [h for h in hooks["SessionStart"] if "opsx-sessions.sh" not in json.dumps(h)]
    if not hooks["SessionStart"]:
        del hooks["SessionStart"]
    if not hooks:
        del obj["hooks"]
with open(dest + ".tmp", "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
    f.write("\n")
PYHOOK
  replace_settings_if_changed "$dest"
  ok "removed the session restore hook from $(tilde "$dest")"
}

# Print the marked block: both resurrect hooks (and @continuum-boot when $3 is 1).
restore_block_text() {
  local save_cmd=$1 restore_cmd=$2 boot=$3
  printf '%s\n' "$RESTORE_BLOCK_START"
  printf "set -g @resurrect-hook-post-save-all '%s'\n" "$save_cmd"
  printf "set -g @resurrect-hook-post-restore-all '%s'\n" "$restore_cmd"
  [ "$boot" -eq 1 ] && printf "set -g @continuum-boot 'on'\n"
  printf '%s\n' "$RESTORE_BLOCK_END"
}

print_restore_lines() {
  note "add these lines to your tmux config above the tpm 'run' line:"
  restore_block_text "$1" "$2" "$3" | sed -n '2,$p' | sed '$d' | while IFS= read -r l; do note "  $l"; done
}

# Add or refresh the marked block above the tpm run line, only when
# tmux-resurrect is loaded and neither resurrect hook option is set elsewhere.
# Sets RESTORE_BLOCK=installed|unchanged|printed.
install_restore_tmux_block() {
  local conf=$1 save_cmd=$2 restore_cmd=$3 boot=$4 blockfile tmp
  RESTORE_BLOCK=printed
  case "$save_cmd$restore_cmd" in
    *"'"*) warn "the opsx path contains a quote — not editing $(tilde "$conf")"
           print_restore_lines "$save_cmd" "$restore_cmd" "$boot"; return 0 ;;
  esac
  if [ ! -f "$conf" ]; then
    warn "no $(tilde "$conf") — session restore needs tmux-resurrect (and tmux-continuum for automatic restores)"
    print_restore_lines "$save_cmd" "$restore_cmd" "$boot"; return 0
  fi
  if ! tmux_conf_loads "$conf" 'tmux-resurrect'; then
    warn "$(tilde "$conf") does not load tmux-resurrect — left unchanged"
    note "install tmux-resurrect (set -g @plugin 'tmux-plugins/tmux-resurrect'), then re-run install.sh, or"
    print_restore_lines "$save_cmd" "$restore_cmd" "$boot"; return 0
  fi
  if tmux_conf_active_lines "$conf" | grep -Eq '@resurrect-hook-post-(save|restore)-all'; then
    warn "$(tilde "$conf") already sets a tmux-resurrect post-save/post-restore hook — left unchanged"
    note "merge the session restore commands into your hook by hand:"
    print_restore_lines "$save_cmd" "$restore_cmd" "$boot"; return 0
  fi
  # Keep the boot line of an earlier --restore-at-boot install.
  if [ "$boot" -eq 0 ] && awk -v s="$RESTORE_BLOCK_START" -v e="$RESTORE_BLOCK_END" \
       '$0 == s { b = 1; next } $0 == e { b = 0 } b && /@continuum-boot/ { f = 1 } END { exit !f }' "$conf"; then
    boot=1
    note "kept @continuum-boot from an earlier --restore-at-boot (delete that line from the block to stop starting at boot)"
  fi
  # Keep a --no-nudge the user added to the block's restore hook.
  if awk -v s="$RESTORE_BLOCK_START" -v e="$RESTORE_BLOCK_END" \
       '$0 == s { b = 1; next } $0 == e { b = 0 } b && /@resurrect-hook-post-restore-all/ && /--no-nudge/ { f = 1 } END { exit !f }' "$conf"; then
    restore_cmd="$restore_cmd --no-nudge"
    note "kept --no-nudge on the restore hook"
  fi
  if [ "$boot" -eq 1 ] && tmux_conf_active_lines "$conf" | grep -q '@continuum-boot'; then
    note "@continuum-boot is already set outside the block — not adding it again"
    boot=0
  fi
  if [ "$boot" -eq 1 ] && ! tmux_conf_loads "$conf" 'tmux-continuum'; then
    warn "@continuum-boot needs tmux-continuum, which $(tilde "$conf") does not load"
  fi
  blockfile=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  restore_block_text "$save_cmd" "$restore_cmd" "$boot" > "$blockfile"
  awk -v start="$RESTORE_BLOCK_START" -v end="$RESTORE_BLOCK_END" -v bf="$blockfile" '
    function block() { while ((getline l < bf) > 0) print l; close(bf); done = 1 }
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    skip { next }
    !done && /^[[:space:]]*run(-shell)?[[:space:]].*tpm/ { block() }
    { print }
    END { if (!done) block() }' "$conf" > "$tmp"
  rm -f "$blockfile"
  if cmp -s "$conf" "$tmp"; then
    rm -f "$tmp"; RESTORE_BLOCK=unchanged; return 0
  fi
  if [ "$BACKUP" -eq 1 ]; then
    cp "$conf" "$conf.bak.$(date +%Y%m%d%H%M%S)" || die "cannot back up $conf"
  fi
  cat "$tmp" > "$conf" || die "cannot write $conf"
  rm -f "$tmp"
  RESTORE_BLOCK=installed
}

# Start at boot needs a user systemd instance without a login: lingering.
# Prints the sudo command; never runs it.
restore_linger_check() {
  local user out
  user=${SUDO_USER:-${USER:-$(id -un 2>/dev/null)}}
  if [ "$PLATFORM" != Linux ]; then
    note "start at boot: tmux-continuum uses a launchd agent on macOS (no lingering needed)"
    return 0
  fi
  if have loginctl && out=$(loginctl show-user "$user" -p Linger 2>/dev/null); then
    case "$out" in
      *Linger=yes*) ok "lingering is on for $user (tmux starts at boot without a login)"; return 0 ;;
    esac
    warn "lingering is off for $user — without it the tmux server only starts at your first login"
  else
    warn "could not check lingering (loginctl show-user $user -p Linger)"
  fi
  note "run once:  sudo loginctl enable-linger $user"
}

# Value of KEY in a KEY=VALUE file, without sourcing it.
env_file_get() {
  local file=$1 key=$2 k v
  [ -f "$file" ] || return 1
  while IFS='=' read -r k v || [ -n "$k" ]; do
    if [ "$k" = "$key" ]; then printf '%s' "$v"; return 0; fi
  done < "$file"
  return 1
}

# Pick the Cloudflare token: $CLOUDFLARE_API_TOKEN, else a hidden prompt on a
# terminal, else the stored one. Never a command-line argument, never printed.
expose_token_intake() {
  local stored="" tok=""
  stored=$(env_file_get "$EXPOSE_ENV" CLOUDFLARE_API_TOKEN 2>/dev/null) || stored=""
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
    tok=$CLOUDFLARE_API_TOKEN
    EXPOSE_TOKEN_SOURCE="from \$CLOUDFLARE_API_TOKEN"
  elif [ -t 0 ]; then
    if [ -n "$stored" ]; then
      printf '  Cloudflare API token for %s (Zone:DNS:Edit; empty keeps the stored one): ' "$EXPOSE_DOMAIN" >&2
    else
      printf '  Cloudflare API token for %s (Zone:DNS:Edit on that zone): ' "$EXPOSE_DOMAIN" >&2
    fi
    IFS= read -rs tok || tok=""
    printf '\n' >&2
    if [ -n "$tok" ]; then
      EXPOSE_TOKEN_SOURCE="entered at the prompt"
    elif [ -n "$stored" ]; then
      tok=$stored
      EXPOSE_TOKEN_SOURCE="kept the stored token"
    fi
  elif [ -n "$stored" ]; then
    tok=$stored
    EXPOSE_TOKEN_SOURCE="kept the stored token"
  fi
  unset CLOUDFLARE_API_TOKEN
  [ -n "$tok" ] || die "--expose-domain needs a Cloudflare API token: set CLOUDFLARE_API_TOKEN (scoped to Zone:DNS:Edit for the zone of $EXPOSE_DOMAIN), or run install.sh from a terminal to be prompted. Nothing was installed."
  [[ "$tok" =~ ^[A-Za-z0-9._-]+$ ]] || die "the Cloudflare API token contains unexpected characters (allowed: A-Z a-z 0-9 . _ -). Nothing was installed."
  EXPOSE_TOKEN=$tok
}

# Ask Cloudflare whether the token is valid. The Authorization header goes to
# curl on stdin (-H @-), so the token never appears on a command line.
# /user/tokens/verify only knows user tokens (My Profile > API Tokens);
# account-owned tokens need OPSX_EXPOSE_SKIP_VERIFY=1.
expose_verify_token() {
  local api=${OPSX_CLOUDFLARE_API:-https://api.cloudflare.com/client/v4} resp
  if [ "${OPSX_EXPOSE_SKIP_VERIFY:-0}" = 1 ]; then
    note "skipped the Cloudflare token check (OPSX_EXPOSE_SKIP_VERIFY=1)"
    return 0
  fi
  if ! resp=$(printf 'Authorization: Bearer %s\n' "$EXPOSE_TOKEN" \
              | curl -sS --max-time 20 -H @- "$api/user/tokens/verify" 2>/dev/null); then
    die "could not reach the Cloudflare API to verify the token ($api). Check the network, or set OPSX_EXPOSE_SKIP_VERIFY=1 to skip the check. Nothing was installed."
  fi
  if printf '%s' "$resp" | grep -Eq '"success"[[:space:]]*:[[:space:]]*true' \
     && printf '%s' "$resp" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"active"'; then
    ok "Cloudflare API token is valid ($EXPOSE_TOKEN_SOURCE)"
  else
    die "the Cloudflare API token is invalid (Cloudflare rejected it, or it is not active). Create a user API token under My Profile > API Tokens, scoped to Zone:DNS:Edit for the zone of $EXPOSE_DOMAIN. Account-owned tokens (Manage Account > API Tokens) cannot be checked through /user/tokens/verify; to use one anyway, set OPSX_EXPOSE_SKIP_VERIFY=1. Nothing was installed."
  fi
}

# Write expose.env (mode 600, mode-700 dir) through a temp file + mv; no .bak.
expose_write_env() {
  local tmp old_token=""
  if [ -f "$EXPOSE_ENV" ]; then
    EXPOSE_OLD_DOMAIN=$(env_file_get "$EXPOSE_ENV" EXPOSE_DOMAIN 2>/dev/null) || EXPOSE_OLD_DOMAIN=""
    old_token=$(env_file_get "$EXPOSE_ENV" CLOUDFLARE_API_TOKEN 2>/dev/null) || old_token=""
    [ "$old_token" = "$EXPOSE_TOKEN" ] || EXPOSE_TOKEN_CHANGED=1
  fi
  mkdir -p "$EXPOSE_CONFIG_DIR" || die "cannot create $EXPOSE_CONFIG_DIR"
  chmod 700 "$EXPOSE_CONFIG_DIR" || die "cannot chmod 700 $EXPOSE_CONFIG_DIR"
  tmp=$( umask 077; mktemp "$EXPOSE_CONFIG_DIR/.expose.env.XXXXXX" ) || die "cannot create a temp file in $EXPOSE_CONFIG_DIR"
  if ! ( umask 077
         printf '# tmux-opsx /expose — written by install.sh --expose-domain. Mode 600; keep it private.\n'
         printf 'EXPOSE_DOMAIN=%s\n' "$EXPOSE_DOMAIN"
         printf 'EXPOSE_ADMIN_SOCKET=%s\n' "$EXPOSE_SOCK"
         printf 'CLOUDFLARE_API_TOKEN=%s\n' "$EXPOSE_TOKEN" ) > "$tmp" \
     || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$EXPOSE_ENV"; then
    rm -f "$tmp"
    die "cannot write $EXPOSE_ENV"
  fi
  ok "$(tilde "$EXPOSE_ENV") (domain $EXPOSE_DOMAIN, token $EXPOSE_TOKEN_SOURCE, mode 600)"
}

caddy_has_cloudflare() {
  "$1" list-modules 2>/dev/null | grep -Eq '^[[:space:]]*dns\.providers\.cloudflare([[:space:]]|$)'
}

# Use $OPSX_CADDY_BIN, or a previously installed Caddy with the Cloudflare DNS
# module, or download one from Caddy's build endpoint.
expose_get_caddy() {
  local os arch extra="" url tmp
  if [ -n "${OPSX_CADDY_BIN:-}" ]; then
    [ -x "$OPSX_CADDY_BIN" ] || die "OPSX_CADDY_BIN=$OPSX_CADDY_BIN is not an executable file"
    caddy_has_cloudflare "$OPSX_CADDY_BIN" \
      || die "$OPSX_CADDY_BIN does not list the dns.providers.cloudflare module (caddy list-modules)"
    CADDY_BIN=$OPSX_CADDY_BIN
    ok "caddy $(tilde "$CADDY_BIN") (from \$OPSX_CADDY_BIN, has dns.providers.cloudflare)"
    return 0
  fi
  CADDY_BIN=$EXPOSE_BIN_DIR/caddy
  if [ -x "$CADDY_BIN" ] && caddy_has_cloudflare "$CADDY_BIN"; then
    ok "caddy $(tilde "$CADDY_BIN") (already installed, has dns.providers.cloudflare)"
    return 0
  fi
  case "$PLATFORM" in macOS) os=darwin ;; *) os=linux ;; esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7*)        arch=arm; extra="&arm=7" ;;
    armv6*)        arch=arm; extra="&arm=6" ;;
    *) die "no Caddy build for CPU $(uname -m); set OPSX_CADDY_BIN to a caddy with caddy-dns/cloudflare" ;;
  esac
  url="https://caddyserver.com/api/download?os=$os&arch=$arch$extra&p=github.com/caddy-dns/cloudflare"
  mkdir -p "$EXPOSE_BIN_DIR" || die "cannot create $EXPOSE_BIN_DIR"
  tmp=$(mktemp "$EXPOSE_BIN_DIR/.caddy.XXXXXX") || die "cannot create a temp file in $EXPOSE_BIN_DIR"
  note "downloading Caddy with caddy-dns/cloudflare ($os/$arch) — this can take a minute"
  if ! curl -fsSL --max-time 600 -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "could not download Caddy from $url"
  fi
  chmod 755 "$tmp"
  if ! caddy_has_cloudflare "$tmp"; then
    rm -f "$tmp"
    die "the downloaded Caddy does not list dns.providers.cloudflare — removed it; re-run later or set OPSX_CADDY_BIN"
  fi
  mv -f "$tmp" "$CADDY_BIN" || { rm -f "$tmp"; die "cannot write $CADDY_BIN"; }
  ok "caddy $(tilde "$CADDY_BIN") (downloaded, has dns.providers.cloudflare)"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Base config: one HTTPS server on :443 only (no :80, no redirects), one
# wildcard certificate via ACME DNS-01 through Cloudflare, admin API on a unix
# socket inside a mode-700 state dir. Routes are added live by expose.sh.
expose_write_caddy_config() {
  local sock routes='[]'
  if [ "$NOTIFY_SERVER" -eq 1 ]; then
    routes="[
            $(notify_route_json)
          ]"
  fi
  mkdir -p "$EXPOSE_STATE_DIR" || die "cannot create $EXPOSE_STATE_DIR"
  chmod 700 "$EXPOSE_STATE_DIR" || die "cannot chmod 700 $EXPOSE_STATE_DIR"
  if [ "${#EXPOSE_SOCK}" -gt 100 ]; then
    warn "admin socket path is ${#EXPOSE_SOCK} characters; unix sockets are limited to ~104-108, so Caddy may fail to start"
    note "set a shorter XDG_STATE_HOME and re-run: $EXPOSE_SOCK"
  fi
  sock=$(json_escape "$EXPOSE_SOCK")
  cat > "$EXPOSE_CADDY_JSON.tmp" <<JSON || die "cannot write $EXPOSE_CADDY_JSON"
{
  "admin": {
    "listen": "unix/$sock",
    "config": {
      "persist": false
    }
  },
  "apps": {
    "http": {
      "servers": {
        "expose": {
          "listen": [":443"],
          "routes": $routes,
          "tls_connection_policies": [{}],
          "automatic_https": {
            "disable_redirects": true,
            "disable_certificates": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "automate": ["*.$EXPOSE_DOMAIN"]
      },
      "automation": {
        "policies": [
          {
            "subjects": ["*.$EXPOSE_DOMAIN"],
            "issuers": [
              {
                "module": "acme",
                "challenges": {
                  "dns": {
                    "provider": {
                      "name": "cloudflare",
                      "api_token": "{env.CLOUDFLARE_API_TOKEN}"
                    }
                  }
                }
              }
            ]
          }
        ]
      }
    }
  }
}
JSON
  local existed=0
  [ -f "$EXPOSE_CADDY_JSON" ] && existed=1
  replace_if_changed "$EXPOSE_CADDY_JSON"
  [ "$existed" -eq 1 ] && [ "$REPLACED" -eq 1 ] && EXPOSE_CONFIG_CHANGED=1
  ok "$(tilde "$EXPOSE_CADDY_JSON") (*.$EXPOSE_DOMAIN on :443, admin socket $(tilde "$EXPOSE_SOCK")$([ "$NOTIFY_SERVER" -eq 1 ] && printf ', route %s for ntfy.%s' "$NTFY_ROUTE_ID" "$EXPOSE_DOMAIN"))"
  expose_remove_autosave
}

# An earlier build ran Caddy with autosave on, so autosave.json may still hold
# routes with the owner key and share tokens. Delete it when it is ours (it
# names an expose route or the opsx cookies); leave any other Caddy's alone.
expose_remove_autosave() {
  local f=${XDG_CONFIG_HOME:-$HOME/.config}/caddy/autosave.json
  [ -f "$f" ] || return 0
  grep -qE '"expose-fp-|opsx_(auth|key|share)' "$f" 2>/dev/null || return 0
  if rm -f "$f"; then
    ok "removed $(tilde "$f") (an old Caddy autosave that held expose routes and keys)"
  else
    warn "cannot remove $(tilde "$f"); it may hold the owner key — delete it by hand"
  fi
}

expose_unit_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    printf '%s' "$SUDO_USER"
  else
    id -un
  fi
}

expose_write_unit() {
  cat > "$EXPOSE_UNIT.tmp" <<UNIT || die "cannot write $EXPOSE_UNIT"
# Written by tmux-opsx install.sh --expose-domain (the domain is in caddy.json)
[Unit]
Description=tmux-opsx expose proxy (Caddy on :443)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=$(expose_unit_user)
Environment="HOME=$HOME"
Environment="XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}"
Environment="XDG_STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}"
EnvironmentFile=$EXPOSE_ENV
# Caddy starts from caddy.json alone (autosave is off: "persist": false keeps
# the owner key and share tokens out of autosave.json), so a rerun of install.sh
# takes effect on the next start; expose.sh then puts the recorded routes back.
ExecStart="$CADDY_BIN" run --config "$EXPOSE_CADDY_JSON"
ExecStartPost=-"$PREFIX/skills/expose/expose.sh" list --json
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  replace_if_changed "$EXPOSE_UNIT"
  ok "$(tilde "$EXPOSE_UNIT") (systemd unit, runs as $(expose_unit_user), may bind :443)"
}

# Enable the service as root; otherwise print the one privileged command.
# A rerun that changed the setup also applies the change to a running proxy.
expose_service_step() {
  local cmd installed=$EXPOSE_SYSTEMD_DIR/$EXPOSE_UNIT_NAME.service
  if [ "$PLATFORM" = macOS ]; then
    expose_apply_changes
    note "macOS: no service is installed (documented gap). Start Caddy with:"
    info "    (set -a; . \"$EXPOSE_ENV\"; set +a; \"$CADDY_BIN\" run --config \"$EXPOSE_CADDY_JSON\")"
    [ "$EXPOSE_TOKEN_CHANGED" -eq 0 ] || warn "the token changed: stop a running Caddy and start it again with the command above"
    return 0
  fi
  expose_write_unit
  if [ "$(id -u)" -eq 0 ]; then
    if [ -f "$installed" ] && { [ "$EXPOSE_CONFIG_CHANGED" -eq 1 ] || [ "$EXPOSE_TOKEN_CHANGED" -eq 1 ] \
         || ! cmp -s "$EXPOSE_UNIT" "$installed"; }; then
      # Already set up and something changed: restart so Caddy reads the new
      # caddy.json and expose.env (routes come back via ExecStartPost).
      if install -m 644 "$EXPOSE_UNIT" "$installed" && systemctl daemon-reload \
         && systemctl enable "$EXPOSE_UNIT_NAME" && systemctl restart "$EXPOSE_UNIT_NAME"; then
        ok "restarted $EXPOSE_UNIT_NAME with the new configuration (systemd)"
      else
        warn "could not restart $EXPOSE_UNIT_NAME — check: systemctl status $EXPOSE_UNIT_NAME"
      fi
    elif install -m 644 "$EXPOSE_UNIT" "$installed" \
       && systemctl daemon-reload && systemctl enable --now "$EXPOSE_UNIT_NAME"; then
      ok "enabled and started $EXPOSE_UNIT_NAME (systemd)"
    else
      warn "could not enable $EXPOSE_UNIT_NAME — check: systemctl status $EXPOSE_UNIT_NAME"
    fi
    return 0
  fi
  # Push a changed caddy.json into a running proxy now.
  expose_apply_changes
  if [ -f "$installed" ]; then
    if ! cmp -s "$EXPOSE_UNIT" "$installed" || [ "$EXPOSE_TOKEN_CHANGED" -eq 1 ] \
       || { [ "$EXPOSE_CONFIG_CHANGED" -eq 1 ] && [ "$EXPOSE_APPLIED" -eq 0 ]; }; then
      cmd="sudo install -m 644 \"$EXPOSE_UNIT\" $EXPOSE_SYSTEMD_DIR/ && sudo systemctl daemon-reload && sudo systemctl restart $EXPOSE_UNIT_NAME"
      warn "the running proxy needs a restart to pick up the new configuration (install.sh never uses sudo):"
      info "    $cmd"
    fi
    return 0
  fi
  cmd="sudo install -m 644 \"$EXPOSE_UNIT\" $EXPOSE_SYSTEMD_DIR/ && sudo systemctl daemon-reload && sudo systemctl enable --now $EXPOSE_UNIT_NAME"
  warn "one privileged step left — run this once to start the proxy (install.sh never uses sudo):"
  info "    $cmd"
}

# Rerun with a new domain: point every recorded exposure's URL at it. The
# label (and so the route id) does not depend on the domain.
expose_rewrite_records() {
  local dir=$EXPOSE_STATE_DIR/routes f label tmp n=0
  [ -n "$EXPOSE_OLD_DOMAIN" ] && [ "$EXPOSE_OLD_DOMAIN" != "$EXPOSE_DOMAIN" ] || return 0
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.env; do
    [ -f "$f" ] || continue
    label=$(env_file_get "$f" LABEL 2>/dev/null) || continue
    [[ "$label" =~ ^[a-z0-9-]+$ ]] || continue
    tmp=$(mktemp "$dir/.rewrite.XXXXXX") || continue
    if awk -v url="https://$label.$EXPOSE_DOMAIN" 'BEGIN{FS=OFS="="} $1=="URL"{print "URL=" url; next} {print}' "$f" > "$tmp" \
       && mv -f "$tmp" "$f"; then
      n=$((n + 1))
    else
      rm -f "$tmp"
    fi
  done
  [ "$n" -eq 0 ] || ok "moved $n exposure URL(s) from *.$EXPOSE_OLD_DOMAIN to *.$EXPOSE_DOMAIN"
}

# If caddy.json changed and the proxy is running, load it through the admin
# socket (POST /load), then let expose.sh put the recorded routes back on the
# new domain. Sets EXPOSE_APPLIED=1 on success.
EXPOSE_APPLIED=0
expose_apply_changes() {
  local code
  [ "$EXPOSE_CONFIG_CHANGED" -eq 1 ] || return 0
  if [ ! -S "$EXPOSE_SOCK" ]; then
    note "the proxy is not running; it reads the new $(tilde "$EXPOSE_CADDY_JSON") when it starts"
    return 0
  fi
  code=$(curl -sS --max-time 30 --unix-socket "$EXPOSE_SOCK" -X POST -H 'Content-Type: application/json' \
           --data-binary @"$EXPOSE_CADDY_JSON" -o /dev/null -w '%{http_code}' http://127.0.0.1/load 2>/dev/null) || code=000
  case "$code" in
    2??)
      EXPOSE_APPLIED=1
      ok "loaded the new $(tilde "$EXPOSE_CADDY_JSON") into the running proxy"
      if OPSX_EXPOSE_ADMIN=$EXPOSE_SOCK bash "$SRC/skills/expose/expose.sh" list --json >/dev/null 2>&1; then
        ok "restored the recorded exposures on *.$EXPOSE_DOMAIN"
      else
        warn "could not restore the recorded exposures; the next expose.sh call retries"
      fi ;;
    000) note "the proxy is not reachable on $(tilde "$EXPOSE_SOCK"); it reads the new config when it starts" ;;
    *)   warn "the running proxy refused the new config (HTTP $code); it still serves the old one" ;;
  esac
}

# This host's addresses (best effort).
expose_host_addrs() {
  if [ "$PLATFORM" = Linux ] && hostname -I >/dev/null 2>&1; then
    hostname -I | tr ' ' '\n'
  elif have ifconfig; then
    ifconfig 2>/dev/null | awk '$1=="inet"||$1=="inet6"{print $2}' | sed 's/%.*//'
  fi
}

expose_resolve() {
  if have getent; then
    if have timeout; then timeout 10 getent ahosts "$1" 2>/dev/null; else getent ahosts "$1" 2>/dev/null; fi \
      | awk '{print $1}' | sort -u
  elif have python3; then
    python3 -c 'import socket,sys
try:
    print("\n".join(sorted({a[4][0] for a in socket.getaddrinfo(sys.argv[1], None)})))
except OSError:
    pass' "$1"
  fi
}

# Resolve a random name under the domain and compare with this host. Only warns.
expose_dns_check() {
  local probe addrs mine a
  probe="probe-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n').$EXPOSE_DOMAIN"
  addrs=$(expose_resolve "$probe" | grep -v '^$')
  if [ -z "$addrs" ]; then
    warn "*.$EXPOSE_DOMAIN does not resolve ($probe has no address)"
    note "add a wildcard record *.$EXPOSE_DOMAIN -> this host's public IP, DNS-only (grey cloud) in Cloudflare; install.sh never changes DNS"
    return 0
  fi
  mine=$(expose_host_addrs)
  for a in $addrs; do
    if printf '%s\n' "$mine" | grep -qxF "$a"; then
      ok "*.$EXPOSE_DOMAIN resolves to this host ($a)"
      return 0
    fi
  done
  warn "*.$EXPOSE_DOMAIN resolves to $(printf '%s' "$addrs" | tr '\n' ' ')which is not an address of this host"
  note "the wildcard record must be DNS-only (grey cloud) and point at this host; behind NAT this warning can be ignored"
}

# Under `sudo ./install.sh`, hand the expose files back to the real user.
expose_chown() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    chown -R "$SUDO_USER" "$EXPOSE_CONFIG_DIR" "$EXPOSE_STATE_DIR" 2>/dev/null || true
    [ -d "$NTFY_STATE_DIR" ] && chown -R "$SUDO_USER" "$NTFY_STATE_DIR" 2>/dev/null
    [ -d "$EXPOSE_BIN_DIR" ] && chown -R "$SUDO_USER" "$EXPOSE_BIN_DIR" 2>/dev/null
  fi
  return 0
}

# ---------- push notifications: ntfy server, notify.env, Claude Code hooks ----------
# The ntfy server is set up only with --expose-domain (static Caddy route
# opsx-ntfy for https://ntfy.<domain>); opsx-notify.sh and the Claude Code
# hooks are installed on every run without --skip-notify, so a notify.env
# written by hand for any ntfy server works too.
NOTIFY_ENV=$EXPOSE_CONFIG_DIR/notify.env
NTFY_VERSION=2.34.0
NTFY_BIN=""
NTFY_SERVER_YML=$EXPOSE_CONFIG_DIR/ntfy-server.yml
NTFY_STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-opsx/ntfy
NTFY_UNIT_NAME=tmux-opsx-ntfy
NTFY_UNIT=$EXPOSE_CONFIG_DIR/$NTFY_UNIT_NAME.service
NTFY_LISTEN=127.0.0.1:2586
NTFY_ROUTE_ID=opsx-ntfy
NTFY_USER=opsx
# 1 once this run has an ntfy binary for the server (route, unit, credentials).
NOTIFY_SERVER=0
NTFY_CONFIG_CHANGED=0
NOTIFY_READY=0
CLAUDE_SETTINGS=$PREFIX/settings.json

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1
  fi
}

# $OPSX_NTFY_BIN, or the pinned release already installed, or a download of
# the pinned release tarball verified against the sha256 pinned below for its
# arch (never against a checksum file from the download origin). A failed
# download skips the server for this run (warning); a hash mismatch aborts the
# install and leaves no binary. $OPSX_NTFY_RELEASE_BASE only changes where the
# tarball comes from; it must still match the pinned hash. Tests only:
# $OPSX_NTFY_SHA256 replaces the pinned hash, honoured only when
# $OPSX_NTFY_RELEASE_BASE is a local file:// fixture (never for a download
# over the network, which always has to match the pinned hash).
notify_get_ntfy() {
  local arch name base tmpd want got src
  if [ -n "${OPSX_NTFY_BIN:-}" ]; then
    [ -x "$OPSX_NTFY_BIN" ] || die "OPSX_NTFY_BIN=$OPSX_NTFY_BIN is not an executable file"
    NTFY_BIN=$OPSX_NTFY_BIN; NOTIFY_SERVER=1
    ok "ntfy $(tilde "$NTFY_BIN") (from \$OPSX_NTFY_BIN)"
    return 0
  fi
  if [ "$PLATFORM" = macOS ]; then
    warn "macOS: no ntfy server is installed (documented gap); point notify.env at any ntfy server by hand"
    return 0
  fi
  NTFY_BIN=$EXPOSE_BIN_DIR/ntfy
  if [ -x "$NTFY_BIN" ] && "$NTFY_BIN" --version 2>/dev/null | grep -qF "version $NTFY_VERSION"; then
    NOTIFY_SERVER=1
    ok "ntfy $NTFY_VERSION $(tilde "$NTFY_BIN") (already installed)"
    return 0
  fi
  # sha256 of ntfy_<NTFY_VERSION>_linux_<arch>.tar.gz, copied from
  # https://github.com/binwiederhier/ntfy/releases/download/v2.34.0/checksums.txt
  # Bump NTFY_VERSION and these hashes together.
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64; want=f78e2645c6457363f37d5d1c4f7cddb7e9658abd197824a7387a1a38d92bb895 ;;
    aarch64|arm64) arch=arm64; want=d585fe48d1b2e80b1b1719977bb651cc7d9259bacb817aa8a8d5b4c8f0c9e946 ;;
    armv7*)        arch=armv7; want=c8c3a58301db93a9f5de32c0b028ce09485e9dcb0fa1433b9171e073c23e8342 ;;
    armv6*)        arch=armv6; want=4eaad91bf08f6c959449203de009cfb065b564bd37ba32a2e1f95d75bcb9adb9 ;;
    *) warn "no pinned ntfy $NTFY_VERSION build for CPU $(uname -m); notifications server skipped (set OPSX_NTFY_BIN to an ntfy binary)"; NTFY_BIN=""; return 0 ;;
  esac
  case "${OPSX_NTFY_RELEASE_BASE:-}" in
    file://*) [ -n "${OPSX_NTFY_SHA256:-}" ] && want=$OPSX_NTFY_SHA256 ;;
  esac
  name=ntfy_${NTFY_VERSION}_linux_$arch.tar.gz
  base=${OPSX_NTFY_RELEASE_BASE:-https://github.com/binwiederhier/ntfy/releases/download/v$NTFY_VERSION}
  mkdir -p "$EXPOSE_BIN_DIR" || die "cannot create $EXPOSE_BIN_DIR"
  tmpd=$(mktemp -d "$EXPOSE_BIN_DIR/.ntfy.XXXXXX") || die "cannot create a temp dir in $EXPOSE_BIN_DIR"
  note "downloading ntfy $NTFY_VERSION (linux/$arch)"
  if ! curl -fsSL --max-time 600 -o "$tmpd/$name" "$base/$name"; then
    rm -rf "$tmpd"; NTFY_BIN=""
    warn "could not download ntfy from $base — the notification server is skipped this run"
    note "re-run online, set OPSX_NTFY_BIN to an ntfy binary, or pass --skip-notify"
    return 0
  fi
  got=$(sha256_of "$tmpd/$name") || { rm -rf "$tmpd"; die "no sha256sum or shasum to verify the ntfy download"; }
  if [ "$want" != "$got" ]; then
    rm -rf "$tmpd"
    die "the ntfy download $name does not match its pinned sha256 (expected $want, got $got) — removed it, no ntfy binary was installed"
  fi
  if ! tar -xzf "$tmpd/$name" -C "$tmpd" 2>/dev/null; then
    rm -rf "$tmpd"; die "cannot unpack $name"
  fi
  src=$tmpd/ntfy_${NTFY_VERSION}_linux_$arch/ntfy
  [ -f "$src" ] || { rm -rf "$tmpd"; die "$name has no ntfy binary"; }
  if ! chmod 755 "$src" || ! mv -f "$src" "$NTFY_BIN"; then
    rm -rf "$tmpd"; die "cannot write $NTFY_BIN"
  fi
  rm -rf "$tmpd"
  NOTIFY_SERVER=1
  ok "ntfy $NTFY_VERSION $(tilde "$NTFY_BIN") (downloaded, sha256 verified against the pinned hash)"
}

# The static Caddy route for https://ntfy.<domain> (streaming, no buffering).
notify_route_json() {
  printf '{"@id": "%s", "match": [{"host": ["ntfy.%s"]}], "handle": [{"handler": "reverse_proxy", "flush_interval": -1, "upstreams": [{"dial": "%s"}]}], "terminal": true}' \
    "$NTFY_ROUTE_ID" "$EXPOSE_DOMAIN" "$NTFY_LISTEN"
}

ntfy_cmd() { run_as_owner "$NTFY_BIN" "$@"; }
# ntfy_pw_cmd <password> <ntfy args...>: `ntfy user add|change-pass` with the
# password on stdin (ntfy reads it and its confirmation as two lines when
# stdin is not a TTY). Never in argv or the environment: under sudo, env_reset
# would drop NTFY_PASSWORD, and `env NTFY_PASSWORD=...` would show it in ps.
ntfy_pw_cmd() {
  local pw=$1; shift
  printf '%s\n%s\n' "$pw" "$pw" | ( unset NTFY_PASSWORD NTFY_PASSWORD_HASH; ntfy_cmd "$@" )
}

notify_write_server_config() {
  mkdir -p "$NTFY_STATE_DIR" || die "cannot create $NTFY_STATE_DIR"
  chmod 700 "$NTFY_STATE_DIR" || die "cannot chmod 700 $NTFY_STATE_DIR"
  cat > "$NTFY_SERVER_YML.tmp" <<YML || die "cannot write $NTFY_SERVER_YML"
# tmux-opsx push server — written by install.sh --expose-domain.
# Listens on loopback only; Caddy serves it at https://ntfy.$EXPOSE_DOMAIN.
base-url: https://ntfy.$EXPOSE_DOMAIN
listen-http: $NTFY_LISTEN
behind-proxy: true
auth-file: "$(json_escape "$NTFY_STATE_DIR/auth.db")"
auth-default-access: deny-all
cache-file: "$(json_escape "$NTFY_STATE_DIR/cache.db")"
YML
  local existed=0
  [ -f "$NTFY_SERVER_YML" ] && existed=1
  replace_if_changed "$NTFY_SERVER_YML"
  [ "$existed" -eq 1 ] && [ "$REPLACED" -eq 1 ] && NTFY_CONFIG_CHANGED=1
  ok "$(tilde "$NTFY_SERVER_YML") (ntfy on $NTFY_LISTEN, base https://ntfy.$EXPOSE_DOMAIN, deny-all)"
  # The ntfy user/token commands need the auth database to exist.
  if [ ! -e "$NTFY_STATE_DIR/auth.db" ]; then
    ( umask 077; : > "$NTFY_STATE_DIR/auth.db" ) || die "cannot create $NTFY_STATE_DIR/auth.db"
  fi
  # Under sudo the ntfy user/token commands run as $SUDO_USER: hand the config
  # dir (server.yml), the state dir (auth.db, later cache.db) and the bin dir
  # over first, or ntfy cannot read its config or open its database.
  expose_chown
}

random_alnum() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$1"; }
random_hex() { od -An -N"$1" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; }

# User opsx (random password), read-write on a random opsx-<12 hex> topic, one
# token; notify.env (mode 600). A rerun keeps all of it while the user and the
# token still exist in ntfy's auth database.
notify_credentials() {
  local topic token pw users tokens out tmp changed=""
  topic=$(env_file_get "$NOTIFY_ENV" NTFY_TOPIC 2>/dev/null) || topic=""
  token=$(env_file_get "$NOTIFY_ENV" NTFY_TOKEN 2>/dev/null) || token=""
  pw=$(env_file_get "$NOTIFY_ENV" NTFY_PASSWORD 2>/dev/null) || pw=""
  [[ "$topic" =~ ^opsx-[0-9a-f]{12}$ ]] || { topic="opsx-$(random_hex 6)"; changed="topic"; }
  users=$(ntfy_cmd user --config "$NTFY_SERVER_YML" list 2>&1) || users=""
  if ! printf '%s\n' "$users" | grep -q "^user $NTFY_USER "; then
    pw=$(random_alnum 24)
    [ "${#pw}" -eq 24 ] || { warn "could not generate a password (tr, head, /dev/urandom)"; return 0; }
    if ! out=$(ntfy_pw_cmd "$pw" user --config "$NTFY_SERVER_YML" add "$NTFY_USER" 2>&1); then
      warn "could not create the ntfy user $NTFY_USER: $out"; return 0
    fi
    token=""; changed="${changed:+$changed, }user"
    ok "ntfy user $NTFY_USER created (generated password)"
  elif [ -z "$pw" ]; then
    # The user exists but notify.env lost its password: set a new one.
    pw=$(random_alnum 24)
    if ! out=$(ntfy_pw_cmd "$pw" user --config "$NTFY_SERVER_YML" change-pass "$NTFY_USER" 2>&1); then
      warn "could not reset the password of ntfy user $NTFY_USER: $out"; return 0
    fi
    changed="${changed:+$changed, }password"
  fi
  if ! printf '%s\n' "$users" | grep -qF "read-write access to topic $topic"; then
    if ! out=$(ntfy_cmd access --config "$NTFY_SERVER_YML" "$NTFY_USER" "$topic" rw 2>&1); then
      warn "could not grant $NTFY_USER read-write on $topic: $out"; return 0
    fi
  fi
  if [ -n "$token" ]; then
    tokens=$(ntfy_cmd token --config "$NTFY_SERVER_YML" list "$NTFY_USER" 2>/dev/null) || tokens=""
    printf '%s\n' "$tokens" | grep -qF -- "$token" || token=""
  fi
  if [ -z "$token" ]; then
    out=$(ntfy_cmd token --config "$NTFY_SERVER_YML" add "$NTFY_USER" 2>/dev/null) || out=""
    token=$(printf '%s\n' "$out" | grep -oE 'tk_[A-Za-z0-9]+' | head -n1)
    [ -n "$token" ] || { warn "could not create an ntfy token for $NTFY_USER"; return 0; }
    changed="${changed:+$changed, }token"
  fi
  mkdir -p "$EXPOSE_CONFIG_DIR" || die "cannot create $EXPOSE_CONFIG_DIR"
  chmod 700 "$EXPOSE_CONFIG_DIR" || die "cannot chmod 700 $EXPOSE_CONFIG_DIR"
  tmp=$( umask 077; mktemp "$EXPOSE_CONFIG_DIR/.notify.env.XXXXXX" ) || die "cannot create a temp file in $EXPOSE_CONFIG_DIR"
  if ! ( umask 077
         printf '# tmux-opsx push notifications — written by install.sh --expose-domain. Mode 600; keep it private.\n'
         printf 'NTFY_URL=https://ntfy.%s\n' "$EXPOSE_DOMAIN"
         printf 'NTFY_TOPIC=%s\n' "$topic"
         printf 'NTFY_TOKEN=%s\n' "$token"
         printf 'NTFY_USER=%s\n' "$NTFY_USER"
         printf 'NTFY_PASSWORD=%s\n' "$pw" ) > "$tmp" || ! chmod 600 "$tmp"; then
    rm -f "$tmp"; die "cannot write $NOTIFY_ENV"
  fi
  if [ -f "$NOTIFY_ENV" ] && cmp -s "$tmp" "$NOTIFY_ENV"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$NOTIFY_ENV" || { rm -f "$tmp"; die "cannot write $NOTIFY_ENV"; }
  fi
  chmod 600 "$NOTIFY_ENV" 2>/dev/null
  NOTIFY_READY=1
  ok "$(tilde "$NOTIFY_ENV") (topic $topic, ${changed:+new }${changed:-kept the existing user and token}, mode 600)"
}

notify_write_unit() {
  cat > "$NTFY_UNIT.tmp" <<UNIT || die "cannot write $NTFY_UNIT"
# Written by tmux-opsx install.sh --expose-domain (push notifications)
[Unit]
Description=tmux-opsx push server (ntfy on $NTFY_LISTEN)
After=network.target

[Service]
Type=simple
User=$(expose_unit_user)
Environment="HOME=$HOME"
ExecStart="$NTFY_BIN" serve --config "$NTFY_SERVER_YML"
NoNewPrivileges=true
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  replace_if_changed "$NTFY_UNIT"
  ok "$(tilde "$NTFY_UNIT") (systemd unit, runs as $(expose_unit_user), listens on $NTFY_LISTEN)"
}

# Same sudo-or-print path as the proxy: root enables the unit, anyone else
# gets the one privileged command.
notify_service_step() {
  local cmd installed=$EXPOSE_SYSTEMD_DIR/$NTFY_UNIT_NAME.service
  if [ "$PLATFORM" = macOS ]; then
    note "macOS: start ntfy with: \"$NTFY_BIN\" serve --config \"$NTFY_SERVER_YML\""
    return 0
  fi
  notify_write_unit
  if [ "$(id -u)" -eq 0 ]; then
    if [ -f "$installed" ] && { [ "$NTFY_CONFIG_CHANGED" -eq 1 ] || ! cmp -s "$NTFY_UNIT" "$installed"; }; then
      if install -m 644 "$NTFY_UNIT" "$installed" && systemctl daemon-reload \
         && systemctl enable "$NTFY_UNIT_NAME" && systemctl restart "$NTFY_UNIT_NAME"; then
        ok "restarted $NTFY_UNIT_NAME with the new configuration (systemd)"
      else
        warn "could not restart $NTFY_UNIT_NAME — check: systemctl status $NTFY_UNIT_NAME"
      fi
    elif install -m 644 "$NTFY_UNIT" "$installed" \
       && systemctl daemon-reload && systemctl enable --now "$NTFY_UNIT_NAME"; then
      ok "enabled and started $NTFY_UNIT_NAME (systemd)"
    else
      warn "could not enable $NTFY_UNIT_NAME — check: systemctl status $NTFY_UNIT_NAME"
    fi
    return 0
  fi
  if [ -f "$installed" ]; then
    if ! cmp -s "$NTFY_UNIT" "$installed" || [ "$NTFY_CONFIG_CHANGED" -eq 1 ]; then
      cmd="sudo install -m 644 \"$NTFY_UNIT\" $EXPOSE_SYSTEMD_DIR/ && sudo systemctl daemon-reload && sudo systemctl restart $NTFY_UNIT_NAME"
      warn "the running push server needs a restart to pick up the new configuration (install.sh never uses sudo):"
      info "    $cmd"
    fi
    return 0
  fi
  cmd="sudo install -m 644 \"$NTFY_UNIT\" $EXPOSE_SYSTEMD_DIR/ && sudo systemctl daemon-reload && sudo systemctl enable --now $NTFY_UNIT_NAME"
  warn "one privileged step left — run this once to start the push server (install.sh never uses sudo):"
  info "    $cmd"
}

# --skip-notify / --uninstall: drop the ntfy unit (the state dir stays).
notify_remove_unit() {
  local installed=$EXPOSE_SYSTEMD_DIR/$NTFY_UNIT_NAME.service
  if [ -f "$NTFY_UNIT" ]; then
    rm -f "$NTFY_UNIT" && ok "removed $(tilde "$NTFY_UNIT") (push server unit)"
  fi
  [ -f "$installed" ] || return 0
  if [ "$(id -u)" -eq 0 ]; then
    systemctl disable --now "$NTFY_UNIT_NAME" >/dev/null 2>&1 || true
    if rm -f "$installed" && systemctl daemon-reload; then
      ok "disabled and removed $NTFY_UNIT_NAME (systemd)"
    else
      warn "could not remove $installed — check: systemctl status $NTFY_UNIT_NAME"
    fi
  else
    warn "remove the push server unit with (install.sh never uses sudo):"
    info "    sudo systemctl disable --now $NTFY_UNIT_NAME && sudo rm -f $installed && sudo systemctl daemon-reload"
  fi
}

# --skip-notify / --uninstall: drop the opsx-ntfy route from caddy.json and from a running proxy.
notify_remove_route() {
  local tmp
  [ -f "$EXPOSE_CADDY_JSON" ] && grep -q "\"$NTFY_ROUTE_ID\"" "$EXPOSE_CADDY_JSON" 2>/dev/null || return 0
  tmp=$EXPOSE_CADDY_JSON.tmp
  if have jq; then
    jq --arg id "$NTFY_ROUTE_ID" '(.apps.http.servers[]?.routes) |= (if type == "array" then map(select(."@id" != $id)) else . end)' \
      "$EXPOSE_CADDY_JSON" > "$tmp" 2>/dev/null || { rm -f "$tmp"; warn "could not edit $EXPOSE_CADDY_JSON"; return 0; }
  elif have python3; then
    python3 -I - "$EXPOSE_CADDY_JSON" "$NTFY_ROUTE_ID" > "$tmp" <<'PY' || { rm -f "$tmp"; warn "could not edit $EXPOSE_CADDY_JSON"; return 0; }
import json, sys
cfg = json.load(open(sys.argv[1]))
for srv in ((cfg.get("apps") or {}).get("http") or {}).get("servers", {}).values():
    if isinstance(srv.get("routes"), list):
        srv["routes"] = [r for r in srv["routes"] if not (isinstance(r, dict) and r.get("@id") == sys.argv[2])]
print(json.dumps(cfg, indent=2))
PY
  else
    warn "jq or python3 is needed to remove the $NTFY_ROUTE_ID route from $EXPOSE_CADDY_JSON"; return 0
  fi
  replace_if_changed "$EXPOSE_CADDY_JSON"
  ok "removed the $NTFY_ROUTE_ID route from $(tilde "$EXPOSE_CADDY_JSON")"
  if [ -S "$EXPOSE_SOCK" ]; then
    curl -sS --max-time 10 --unix-socket "$EXPOSE_SOCK" -X DELETE -o /dev/null \
      "http://127.0.0.1/id/$NTFY_ROUTE_ID" >/dev/null 2>&1 || true
  fi
}

# Hook command for one event: the installed helper, quoted only when needed.
notify_hook_cmd() {
  local p=$PREFIX/skills/opsx-run/opsx-notify.sh
  if [[ "$p" =~ ^[A-Za-z0-9_./~+-]+$ ]]; then
    printf '%s hook %s' "$p" "$1"
  else
    printf '"%s" hook %s' "$(json_escape "$p")" "$1"
  fi
}

# notify_settings_hooks add|remove: merge (or drop) the tmux-opsx hooks in
# Claude Code's settings.json with jq, else python3. Our entries are found by
# their `opsx-notify.sh hook` command; everything else is kept as it is. The
# file is rewritten only when it changes (with a .bak unless --no-backup).
notify_settings_hooks() {
  local mode=$1 f=$CLAUDE_SETTINGS tmp add=0 pre ntf stp
  [ "$mode" = add ] && add=1
  if [ ! -f "$f" ]; then
    [ "$add" -eq 1 ] || return 0
    mkdir -p "$(dirname "$f")" || die "cannot create $(dirname "$f")"
    printf '{}\n' > "$f.new" || die "cannot write $f"
  fi
  pre=$(notify_hook_cmd claude-pretool); ntf=$(notify_hook_cmd claude-notification); stp=$(notify_hook_cmd claude-stop)
  tmp=$f.tmp
  local src=$f; [ -f "$f.new" ] && src=$f.new
  if have jq; then
    if ! jq --arg add "$add" --arg pre "$pre" --arg ntf "$ntf" --arg stp "$stp" '
      def ours: (type == "object") and ((.command // "") | type == "string")
                and ((.command // "") | test("opsx-notify\\.sh[\"'"'"']? hook"));
      def group_has: (type == "object") and ([(.hooks // [])[]? | ours] | any);
      def strip: [ .[] | if group_has then (.hooks |= [ .[] | select(ours | not) ]) | select((.hooks | length) > 0) else . end ];
      has("hooks") as $had
      | if (.hooks | type) == "object" then
          .hooks |= with_entries(if (.value | type) == "array" and ([.value[] | group_has] | any)
                                 then (.value |= strip) | select((.value | length) > 0) else . end)
        else . end
      | if $add == "1" then
          .hooks = (.hooks // {})
          | .hooks.PreToolUse   = ((.hooks.PreToolUse // [])   + [{matcher: "AskUserQuestion", hooks: [{type: "command", command: $pre}]}])
          | .hooks.Notification = ((.hooks.Notification // []) + [{matcher: "permission_prompt", hooks: [{type: "command", command: $ntf}]}])
          | .hooks.Stop         = ((.hooks.Stop // [])         + [{hooks: [{type: "command", command: $stp}]}])
        else . end
      | if ($had | not) and ((.hooks // {}) | length) == 0 then del(.hooks) else . end
      ' "$src" > "$tmp" 2>/dev/null; then
      rm -f "$tmp" "$f.new"; warn "$(tilde "$f") is not valid JSON — left it alone (no notify hooks)"; return 0
    fi
  elif have python3; then
    if ! python3 -I - "$src" "$add" "$pre" "$ntf" "$stp" > "$tmp" 2>/dev/null <<'PY'; then
import json, re, sys
src, add, pre, ntf, stp = sys.argv[1:6]
d = json.load(open(src))
if not isinstance(d, dict):
    sys.exit(1)
pat = re.compile(r"""opsx-notify\.sh["']? hook""")
def ours(h):
    return isinstance(h, dict) and isinstance(h.get("command", ""), str) and bool(pat.search(h.get("command", "")))
def group_has(g):
    return isinstance(g, dict) and any(ours(h) for h in (g.get("hooks") or []))
had = "hooks" in d
hooks = d.get("hooks")
if isinstance(hooks, dict):
    for ev in list(hooks):
        v = hooks[ev]
        if isinstance(v, list) and any(group_has(g) for g in v):
            nv = []
            for g in v:
                if group_has(g):
                    g = dict(g); g["hooks"] = [h for h in g["hooks"] if not ours(h)]
                    if not g["hooks"]:
                        continue
                nv.append(g)
            if nv:
                hooks[ev] = nv
            else:
                del hooks[ev]
if add == "1":
    hooks = d.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        sys.exit(1)
    hooks.setdefault("PreToolUse", []).append({"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": pre}]})
    hooks.setdefault("Notification", []).append({"matcher": "permission_prompt", "hooks": [{"type": "command", "command": ntf}]})
    hooks.setdefault("Stop", []).append({"hooks": [{"type": "command", "command": stp}]})
if not had and not d.get("hooks"):
    d.pop("hooks", None)
print(json.dumps(d, indent=2, ensure_ascii=False))
PY
      rm -f "$tmp" "$f.new"; warn "$(tilde "$f") is not valid JSON — left it alone (no notify hooks)"; return 0
    fi
  else
    rm -f "$f.new"; warn "jq or python3 is needed to edit $(tilde "$f") — notify hooks not changed"; return 0
  fi
  if [ -f "$f.new" ]; then
    mv -f "$tmp" "$f" || die "cannot write $f"; rm -f "$f.new"
    ok "Claude Code hooks (Stop, Notification permission_prompt, PreToolUse AskUserQuestion) -> $(tilde "$f")"
    return 0
  fi
  if notify_json_same "$f" "$tmp"; then
    rm -f "$tmp"
    [ "$add" -eq 1 ] && ok "Claude Code notify hooks already in $(tilde "$f")"
    return 0
  fi
  backup_settings_once "$f"
  # Write through the file (keeps a symlinked settings.json and its mode).
  cat "$tmp" > "$f" || die "cannot write $f"
  rm -f "$tmp"
  if [ "$add" -eq 1 ]; then
    ok "Claude Code hooks (Stop, Notification permission_prompt, PreToolUse AskUserQuestion) -> $(tilde "$f")"
  else
    ok "removed the tmux-opsx notify hooks from $(tilde "$f")"
  fi
}

# Same JSON value (key order ignored)?
notify_json_same() {
  if have jq; then
    [ "$(jq -S . "$1" 2>/dev/null)" = "$(jq -S . "$2" 2>/dev/null)" ]
  else
    python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$1" "$2" 2>/dev/null
  fi
}

# Android setup lines (no password: `opsx notify info --show-password`).
notify_setup_lines() {
  local topic
  topic=$(env_file_get "$NOTIFY_ENV" NTFY_TOPIC 2>/dev/null) || return 0
  info "  Phone pushes (ntfy): server ${B}https://ntfy.$EXPOSE_DOMAIN${N}, user ${B}$NTFY_USER${N}, topic ${B}$topic${N}"
  info "     Android: install ntfy, add server https://ntfy.$EXPOSE_DOMAIN, log in as $NTFY_USER, subscribe to $topic"
  if [ "$SKIP_INIT" -eq 0 ]; then
    info "     Password: ${B}opsx notify info --show-password${N}   then test with ${B}opsx notify test${N}"
  else
    info "     Password: ${B}bash $PREFIX/skills/opsx-run/opsx-notify.sh info --show-password${N}   then test with: bash $PREFIX/skills/opsx-run/opsx-notify.sh test"
  fi
}

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

MEMORY_BLOCK_START='<!-- tmux-opsx:memory:start -->'
MEMORY_BLOCK_END='<!-- tmux-opsx:memory:end -->'

# The backticks are literal Markdown, not command substitutions.
# shellcheck disable=SC2016
memory_instruction_block() {
  printf '%s\n' "$MEMORY_BLOCK_START"
  printf '%s\n' '## Memory'
  printf '%s\n' 'Personal memory shared by all coding agents lives in `~/.agents/memory/`.'
  printf '%s\n' '- When past preferences or project context may matter, read `~/.agents/memory/MEMORY.md` and open only entries marked `global` or tagged with the current project.'
  printf '%s\n' '- After each user turn, check whether it contained something worth remembering (explicit request, correction, confirmed choice, lasting fact). If so, save it following the `memory` skill.'
  printf '%s\n' '- Use this store instead of any built-in or tool-specific memory.'
  printf '%s\n' "$MEMORY_BLOCK_END"
}

# Create, replace-between-markers, or append the memory instruction block in
# an instructions file. Keeps a .bak.<timestamp> when the file actually changes.
upsert_marked_block() {
  local dest=$1 blockfile
  blockfile=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  memory_instruction_block > "$blockfile"
  upsert_block_file "$dest" "$MEMORY_BLOCK_START" "$MEMORY_BLOCK_END" "$blockfile"
  rm -f "$blockfile"
}

LEARN_BLOCK_START='<!-- tmux-opsx:learn:start -->'
LEARN_BLOCK_END='<!-- tmux-opsx:learn:end -->'

# The backticks are literal Markdown, not command substitutions.
# shellcheck disable=SC2016
learn_instruction_block() {
  printf '%s\n' "$LEARN_BLOCK_START"
  printf '%s\n' '## Learned skills'
  printf '%s\n' 'Procedures learned in a project are saved as project skills in `<repo>/.opsx/skills/<name>/` (the main checkout, never a worktree), linked as `learned-<name>` for every CLI.'
  printf '%s\n' '- After finishing a task, check whether it taught a procedure that is multi-step, specific to this project, verified to work in this session, reusable (likely needed again), and not already covered by a skill, README or AGENTS.md. If so, save it with the `learn` skill (`learn.sh save <name>`); when a learned skill already covers the task, update it instead of adding a duplicate.'
  printf '%s\n' '- Facts and preferences stay in memory; only procedures become skills. Never save secrets.'
  printf '%s\n' '- Announce each save in one line naming the skill and its path. Edit `.gitignore` only when the user asks (`learn.sh ignore`).'
  printf '%s\n' "$LEARN_BLOCK_END"
}

# Create, replace-between-markers, or append the learn instruction block.
upsert_learn_block() {
  local dest=$1 blockfile
  blockfile=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  learn_instruction_block > "$blockfile"
  upsert_block_file "$dest" "$LEARN_BLOCK_START" "$LEARN_BLOCK_END" "$blockfile"
  rm -f "$blockfile"
}

# Insert or replace the block delimited by $start/$end in $dest with the
# contents of $blockfile (which must itself begin with $start and end with
# $end). Everything else in the file is left alone.
upsert_block_file() {
  local dest=$1 start=$2 end=$3 blockfile=$4 tmp
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"

  if [ ! -f "$dest" ]; then
    cp "$blockfile" "$tmp"
  elif grep -qF "$start" "$dest" 2>/dev/null; then
    awk -v start="$start" -v end="$end" -v blockfile="$blockfile" '
      $0 == start { while ((getline line < blockfile) > 0) print line; close(blockfile); skip=1; next }
      $0 == end { skip=0; next }
      skip==1 { next }
      { print }
    ' "$dest" > "$tmp"
  else
    cat "$dest" > "$tmp"
    [ -s "$tmp" ] && printf '\n' >> "$tmp"
    cat "$blockfile" >> "$tmp"
  fi

  if [ -f "$dest" ] && cmp -s "$dest" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi

  mkdir -p "$(dirname "$dest")" || die "cannot create $(dirname "$dest")"
  if [ -f "$dest" ] && [ "$BACKUP" -eq 1 ]; then
    local bak
    bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
    cp "$dest" "$bak" || die "cannot back up $dest"
    note "backed up existing $(basename "$dest") -> $(basename "$bak")"
  fi
  mv "$tmp" "$dest" || die "cannot write $dest"
}

# Remove a marked block (markers included) from an instructions file, leaving
# the rest of the file untouched. Defaults to the memory block.
remove_marked_block() {
  local dest=$1 start=${2:-$MEMORY_BLOCK_START} end=${3:-$MEMORY_BLOCK_END} label=${4:-memory} tmp
  [ -f "$dest" ] || return 0
  grep -qF "$start" "$dest" 2>/dev/null || return 0
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  awk -v start="$start" -v end="$end" '
    $0 == start { skip=1; next }
    $0 == end { skip=0; next }
    skip==1 { next }
    { print }
  ' "$dest" > "$tmp"
  if [ "$BACKUP" -eq 1 ]; then
    cp "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  fi
  mv "$tmp" "$dest" || die "cannot write $dest"
  ok "removed $label block from $(printf '%s' "$dest" | sed "s|$HOME|~|")"
}

# Create the store skeleton (type folders + MEMORY.md) without touching
# anything that already exists.
create_memory_store_skeleton() {
  local dest=$1
  mkdir -p "$dest/user" "$dest/feedback" "$dest/project" "$dest/reference" \
    || die "cannot create $dest"
  if [ ! -f "$dest/MEMORY.md" ]; then
    cp "$SRC/skills/memory/templates/MEMORY.md" "$dest/MEMORY.md" || die "cannot create $dest/MEMORY.md"
  fi
}

# Cursor subagents use a simpler frontmatter (name + description only). Reuse the
# body from agents/opsx-applier.md and strip Claude-specific YAML keys.
agent_frontmatter_name() {
  awk '
    /^---$/ { n++; next }
    n == 1 && /^name:/ {
      sub(/^name:[[:space:]]*/, "")
      gsub(/^"/, ""); gsub(/"$/, "")
      print
      exit
    }
  ' "$1"
}

agent_frontmatter_desc() {
  awk '
    /^---$/ { n++; next }
    n == 1 && /^description:/ {
      sub(/^description:[[:space:]]*/, "")
      gsub(/^"/, ""); gsub(/"$/, "")
      print
      exit
    }
  ' "$1"
}

# Per-agent default models. opsx-window.sh `models` is the one resolver: it
# reads agents/models.conf, merges ${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/models.conf
# and checks each value against the CLI. Invalid values come back as inherit
# with a warning on stderr, which is relayed here; install never fails on them.
# AGENT_MODELS_<cli> holds the "<agent> <model> <source>" lines.
# shellcheck disable=SC2034  # read through ${!var} in agent_model_for
AGENT_MODELS_claude="" AGENT_MODELS_agent="" AGENT_MODELS_opencode=""
load_agent_models() {
  local cli=$1 out errf line rc
  errf=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  out=$(OPSX_MODELS_CONF="$SRC/agents/models.conf" \
        bash "$SRC/skills/opsx-run/opsx-window.sh" models --agent-cli "$cli" 2>"$errf" </dev/null)
  rc=$?
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | LC_ALL=C tr '\000-\037\177' '?')
    [ -n "$line" ] && warn "${line#opsx-window: warning: }"
  done < "$errf"
  rm -f "$errf"
  if [ "$rc" -ne 0 ]; then
    warn "could not resolve agent models for $cli — agent files use inherit"
    out=""
  fi
  printf -v "AGENT_MODELS_$cli" '%s' "$out"
}

# Resolved model for agent $2 (applier|eval|reviewer|security|qa) on CLI $1.
agent_model_for() {
  local var="AGENT_MODELS_$1" m
  m=$(printf '%s\n' "${!var}" | awk -v a="$2" '$1==a { print $2; exit }')
  # Belt and braces: the resolver already rejects these, but never let a value
  # outside the safe model charset reach agent frontmatter.
  if [ -n "$m" ] && ! [[ "$m" =~ ^[A-Za-z0-9._:/@][A-Za-z0-9._:/@-]*$ ]]; then
    warn "unsafe $1.$2 model value — using inherit"
    m=inherit
  fi
  printf '%s' "${m:-inherit}"
}

# Claude Code agent: the source file with its frontmatter `model:` set to $3.
install_claude_agent() {
  local src=$1 dest=$2 model=${3:-inherit} tmp
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  # ENVIRON, not -v: awk -v would expand backslash escapes in the value.
  OPSX_AGENT_MODEL="$model" awk '
    BEGIN { m = ENVIRON["OPSX_AGENT_MODEL"] }
    /^---$/ { n++
              if (n == 2 && !done) { print "model: " m; done=1 }
              print; next }
    n == 1 && /^model:/ { if (!done) { print "model: " m; done=1 }; next }
    { print }
  ' "$src" > "$tmp"
  install_file "$tmp" "$dest"
  rm -f "$tmp"
}

install_cursor_agent() {
  local src=$1 dest=$2 model=${3:-inherit} tmp desc name
  name=$(agent_frontmatter_name "$src")
  [ -n "$name" ] || name=$(basename "$dest" .md)
  desc=$(agent_frontmatter_desc "$src")
  [ -n "$desc" ] || desc="OpenSpec subagent"
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  {
    printf '%s\n' '---'
    printf 'name: %s\n' "$name"
    printf 'description: %s\n' "$desc"
    printf 'model: %s\n' "$model"
    printf '%s\n' '---'
    awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$src"
  } > "$tmp"
  install_file "$tmp" "$dest"
  rm -f "$tmp"
}

# Quote a string as a TOML basic string (escape \ and ").
toml_basic_string() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# Codex custom agents are TOML under ~/.codex/agents/. Convert the markdown
# body of opsx-applier.md into developer_instructions.
install_codex_agent() {
  local src=$1 dest=$2 tmp desc name
  name=$(agent_frontmatter_name "$src")
  [ -n "$name" ] || name=$(basename "$dest" .toml)
  desc=$(agent_frontmatter_desc "$src")
  [ -n "$desc" ] || desc="OpenSpec subagent"
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  {
    printf 'name = %s\n' "$(toml_basic_string "$name")"
    printf 'description = %s\n' "$(toml_basic_string "$desc")"
    printf 'developer_instructions = """\n'
    awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$src"
    printf '"""\n'
  } > "$tmp"
  install_file "$tmp" "$dest"
  rm -f "$tmp"
}

# OpenCode agents are markdown under ~/.config/opencode/agents/ (filename = name).
install_opencode_agent() {
  local src=$1 dest=$2 model=${3:-inherit} tmp desc
  desc=$(agent_frontmatter_desc "$src")
  [ -n "$desc" ] || desc="OpenSpec subagent"
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  {
    printf '%s\n' '---'
    printf 'description: %s\n' "$desc"
    printf 'mode: subagent\n'
    # inherit = no model key, so OpenCode uses the window's model.
    [ "$model" = inherit ] || printf 'model: %s\n' "$model"
    printf 'permission:\n'
    printf '  edit: allow\n'
    printf '  bash: allow\n'
    printf '  read: allow\n'
    printf '  glob: allow\n'
    printf '  grep: allow\n'
    printf '  list: allow\n'
    printf '  task: allow\n'
    printf '  skill: allow\n'
    printf '  webfetch: allow\n'
    printf '  websearch: allow\n'
    printf '  todowrite: allow\n'
    printf '  lsp: allow\n'
    printf '  external_directory: allow\n'
    printf '%s\n' '---'
    awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$src"
  } > "$tmp"
  install_file "$tmp" "$dest"
  rm -f "$tmp"
}

# browser-use MCP (stdio via uvx). Same command Cursor already uses.
mcp_uvx() {
  if have uvx; then
    command -v uvx
  elif [ -x "$HOME/.local/bin/uvx" ]; then
    printf '%s' "$HOME/.local/bin/uvx"
  else
    return 1
  fi
}

mcp_env_lines() {
  printf 'BROWSER_USE_HEADLESS=false\n'
  local k
  for k in DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR XAUTHORITY DBUS_SESSION_BUS_ADDRESS; do
    eval "v=\${$k:-}"
    [ -n "$v" ] && printf '%s=%s\n' "$k" "$v"
  done
}

# Upsert browser-use into a JSON/JSONC config. kind=gemini|opencode
upsert_json_mcp() {
  local kind=$1 dest=$2 uvx=$3
  have python3 || return 1
  mkdir -p "$(dirname "$dest")" || return 1
  if [ -e "$dest" ] && [ "$BACKUP" -eq 1 ]; then
    cp "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  fi
  MCP_KIND=$kind MCP_DEST=$dest MCP_UVX=$uvx python3 <<'PY'
import json, os, re, sys

dest = os.environ["MCP_DEST"]
kind = os.environ["MCP_KIND"]
uvx = os.environ["MCP_UVX"]
args = ["--from", "browser-use[cli]", "browser-use", "--mcp"]
env = {}
for line in os.environ.get("MCP_ENV", "").splitlines():
    if not line or "=" not in line:
        continue
    k, v = line.split("=", 1)
    env[k] = v

raw = ""
if os.path.isfile(dest):
    raw = open(dest, encoding="utf-8").read()
    raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    raw = re.sub(r"(?m)^\s*//.*?$", "", raw)
obj = json.loads(raw) if raw.strip() else {}
if not isinstance(obj, dict):
    obj = {}

if kind == "gemini":
    servers = obj.setdefault("mcpServers", {})
    if not isinstance(servers, dict):
        servers = {}
        obj["mcpServers"] = servers
    servers["browser-use"] = {
        "command": uvx,
        "args": args,
        "env": env,
        "trust": True,
    }
elif kind == "opencode":
    mcp = obj.setdefault("mcp", {})
    if not isinstance(mcp, dict):
        mcp = {}
        obj["mcp"] = mcp
    entry = {
        "type": "local",
        "command": [uvx, *args],
        "enabled": True,
        "environment": env,
    }
    if isinstance(mcp.get("servers"), dict):
        v2 = {
            "type": "local",
            "command": [uvx, *args],
            "environment": env,
        }
        mcp["servers"]["browser-use"] = v2
    else:
        mcp["browser-use"] = entry
else:
    raise SystemExit("unknown kind")

tmp = dest + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
    f.write("\n")
os.replace(tmp, dest)
PY
}

# Replace [mcp_servers.browser-use] (+ nested .env) then append a fresh table.
upsert_codex_mcp() {
  local dest=$1 uvx=$2 tmp
  mkdir -p "$(dirname "$dest")" || return 1
  if [ -e "$dest" ] && [ "$BACKUP" -eq 1 ]; then
    cp "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  fi
  [ -f "$dest" ] || : > "$dest"
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || return 1
  awk '
    BEGIN { skip=0 }
    /^\[mcp_servers\.browser-use\]/ { skip=1; next }
    /^\[mcp_servers\.browser-use\./ { skip=1; next }
    /^\[/ { skip=0 }
    skip==0 { print }
  ' "$dest" > "$tmp"
  {
    cat "$tmp"
    printf '\n[mcp_servers.browser-use]\n'
    printf 'command = %s\n' "$(toml_basic_string "$uvx")"
    printf 'args = ["--from", "browser-use[cli]", "browser-use", "--mcp"]\n'
    printf '\n[mcp_servers.browser-use.env]\n'
    mcp_env_lines | while IFS='=' read -r k v; do
      printf '%s = %s\n' "$k" "$(toml_basic_string "$v")"
    done
  } > "$dest"
  rm -f "$tmp"
}

install_browser_use_mcp() {
  local uvx
  uvx=$(mcp_uvx) || {
    warn "uvx not on PATH — skipping browser-use MCP (install: uv tool install uv)"
    note "or: curl -LsSf https://astral.sh/uv/install.sh | sh"
    return 0
  }
  ok "uvx $uvx"
  export MCP_ENV
  MCP_ENV=$(mcp_env_lines)

  if upsert_json_mcp gemini "$GEMINI_SETTINGS" "$uvx"; then
    ok "browser-use MCP -> $GEMINI_SETTINGS (Gemini CLI)"
  else
    warn "could not write $GEMINI_SETTINGS"
  fi

  if upsert_codex_mcp "$CODEX_CONFIG" "$uvx"; then
    ok "browser-use MCP -> $CODEX_CONFIG (Codex CLI)"
  else
    warn "could not write $CODEX_CONFIG"
  fi

  if upsert_json_mcp opencode "$OPENCODE_CONFIG" "$uvx"; then
    ok "browser-use MCP -> $OPENCODE_CONFIG (OpenCode)"
  else
    warn "could not write $OPENCODE_CONFIG"
  fi
  note "restart Gemini / Codex / OpenCode so they load browser-use"
}

# ---------- uninstall ----------
if [ "$UNINSTALL" -eq 1 ]; then
  step "Uninstalling tmux-opsx from $PREFIX"
  rm -rf "$PREFIX/skills/opsx-run" && ok "removed skills/opsx-run (Claude Code)"
  rm -rf "$CURSOR_SKILLS_DIR" && ok "removed ~/.cursor/skills/opsx-run (Cursor CLI)"
  rm -rf "$AGENTS_SKILLS_DIR" && ok "removed ~/.agents/skills/opsx-run (Codex)"
  rm -rf "$CODEX_SKILLS_DIR" && ok "removed $CODEX_SKILLS_DIR (Codex home)"
  rm -rf "$OPENCODE_SKILLS_DIR" && ok "removed ~/.config/opencode/skills/opsx-run (OpenCode)"
  rm -rf "$GEMINI_SKILLS_DIR" && ok "removed ~/.gemini/skills/opsx-run (Gemini CLI)"
  rm -f  "$PREFIX/agents/opsx-applier.md" && ok "removed agents/opsx-applier.md (Claude Code)"
  rm -f  "$PREFIX/agents/opsx-qa.md" && ok "removed agents/opsx-qa.md (Claude Code)"
  rm -f  "$CURSOR_AGENTS_DIR/opsx-applier.md" && ok "removed ~/.cursor/agents/opsx-applier.md (Cursor)"
  rm -f  "$CURSOR_AGENTS_DIR/opsx-qa.md" && ok "removed ~/.cursor/agents/opsx-qa.md (Cursor)"
  rm -f  "$CODEX_AGENTS_DIR/ops-applier.toml" && ok "removed ~/.codex/agents/ops-applier.toml (Codex)"
  rm -f  "$CODEX_AGENTS_DIR/ops-qa.toml" && ok "removed ~/.codex/agents/ops-qa.toml (Codex)"
  rm -f  "$OPENCODE_AGENTS_DIR/ops-applier.md" && ok "removed ~/.config/opencode/agents/ops-applier.md (OpenCode)"
  rm -f  "$OPENCODE_AGENTS_DIR/ops-qa.md" && ok "removed ~/.config/opencode/agents/ops-qa.md (OpenCode)"
  rm -f  "$GEMINI_AGENTS_DIR/opsx-applier.md" && ok "removed ~/.gemini/agents/opsx-applier.md (Gemini CLI)"
  rm -f  "$GEMINI_AGENTS_DIR/opsx-qa.md" && ok "removed ~/.gemini/agents/opsx-qa.md (Gemini CLI)"
  rm -f  "$PREFIX/agents/opsx-reviewer.md" && ok "removed agents/opsx-reviewer.md (Claude Code)"
  rm -f  "$PREFIX/agents/opsx-security.md" && ok "removed agents/opsx-security.md (Claude Code)"
  rm -f  "$CURSOR_AGENTS_DIR/opsx-reviewer.md" && ok "removed ~/.cursor/agents/opsx-reviewer.md (Cursor)"
  rm -f  "$CURSOR_AGENTS_DIR/opsx-security.md" && ok "removed ~/.cursor/agents/opsx-security.md (Cursor)"
  rm -f  "$CODEX_AGENTS_DIR/ops-reviewer.toml" && ok "removed ~/.codex/agents/ops-reviewer.toml (Codex)"
  rm -f  "$CODEX_AGENTS_DIR/ops-security.toml" && ok "removed ~/.codex/agents/ops-security.toml (Codex)"
  rm -f  "$OPENCODE_AGENTS_DIR/ops-reviewer.md" && ok "removed ~/.config/opencode/agents/ops-reviewer.md (OpenCode)"
  rm -f  "$OPENCODE_AGENTS_DIR/ops-security.md" && ok "removed ~/.config/opencode/agents/ops-security.md (OpenCode)"
  rm -f  "$GEMINI_AGENTS_DIR/opsx-reviewer.md" && ok "removed ~/.gemini/agents/opsx-reviewer.md (Gemini CLI)"
  rm -f  "$GEMINI_AGENTS_DIR/opsx-security.md" && ok "removed ~/.gemini/agents/opsx-security.md (Gemini CLI)"
  rm -f  "$PREFIX/agents/opsx-eval.md" && ok "removed agents/opsx-eval.md (Claude Code)"
  rm -f  "$CURSOR_AGENTS_DIR/opsx-eval.md" && ok "removed ~/.cursor/agents/opsx-eval.md (Cursor)"
  rm -f  "$CODEX_AGENTS_DIR/ops-eval.toml" && ok "removed ~/.codex/agents/ops-eval.toml (Codex)"
  rm -f  "$OPENCODE_AGENTS_DIR/ops-eval.md" && ok "removed ~/.config/opencode/agents/ops-eval.md (OpenCode)"
  rm -f  "$GEMINI_AGENTS_DIR/opsx-eval.md" && ok "removed ~/.gemini/agents/opsx-eval.md (Gemini CLI)"
  remove_openspec_skills "$PREFIX/skills" "Claude Code"
  remove_openspec_skills "$HOME/.cursor/skills" "Cursor CLI"
  remove_openspec_skills "$AGENTS_OPENSPEC_SKILLS_DIR" "Agent Skills"
  remove_openspec_skills "$CODEX_OPENSPEC_SKILLS_DIR" "Codex"
  remove_openspec_skills "$OPENCODE_OPENSPEC_SKILLS_DIR" "OpenCode"
  remove_openspec_skills "$GEMINI_OPENSPEC_SKILLS_DIR" "Gemini CLI"
  remove_openspec_commands "$PREFIX/commands" "Claude Code"
  remove_openspec_commands "$CURSOR_COMMANDS_DIR" "Cursor CLI"
  remove_openspec_commands "$OPENCODE_COMMANDS_DIR" "OpenCode"
  remove_openspec_commands "$GEMINI_COMMANDS_DIR" "Gemini CLI"
  remove_graphify_skill "$PREFIX/skills/graphify" "Claude Code"
  remove_graphify_skill "$HOME/.cursor/skills/graphify" "Cursor CLI"
  remove_graphify_skill "$HOME/.agents/skills/graphify" "Agent Skills"
  remove_graphify_skill "$CODEX_HOME_DIR/skills/graphify" "Codex"
  remove_graphify_skill "$OPENCODE_CONFIG_DIR/skills/graphify" "OpenCode"
  remove_graphify_skill "$GEMINI_HOME_DIR/skills/graphify" "Gemini CLI"
  remove_marked_block "$GEMINI_MD" "$GRAPHIFY_BLOCK_START" "$GRAPHIFY_BLOCK_END" graphify
  remove_gemini_graphify_hook "$GEMINI_SETTINGS"
  if [ -f "$OPENCODE_GRAPHIFY_PLUGIN" ]; then
    rm -f "$OPENCODE_GRAPHIFY_PLUGIN" && ok "removed ~/.config/opencode/plugins/graphify.js (OpenCode)"
  fi
  rm -rf "$PREFIX/skills/memory" && ok "removed skills/memory (Claude Code)"
  rm -rf "$CURSOR_MEMORY_SKILLS_DIR" && ok "removed ~/.cursor/skills/memory (Cursor CLI)"
  rm -rf "$AGENTS_MEMORY_SKILLS_DIR" && ok "removed ~/.agents/skills/memory (Agent Skills)"
  rm -rf "$CODEX_MEMORY_SKILLS_DIR" && ok "removed $CODEX_MEMORY_SKILLS_DIR (Codex)"
  rm -rf "$OPENCODE_MEMORY_SKILLS_DIR" && ok "removed ~/.config/opencode/skills/memory (OpenCode)"
  rm -rf "$GEMINI_MEMORY_SKILLS_DIR" && ok "removed ~/.gemini/skills/memory (Gemini CLI)"
  rm -rf "$PREFIX/skills/learn" && ok "removed skills/learn (Claude Code)"
  rm -rf "$CURSOR_LEARN_SKILLS_DIR" && ok "removed ~/.cursor/skills/learn (Cursor CLI)"
  rm -rf "$AGENTS_LEARN_SKILLS_DIR" && ok "removed ~/.agents/skills/learn (Agent Skills)"
  rm -rf "$CODEX_LEARN_SKILLS_DIR" && ok "removed $CODEX_LEARN_SKILLS_DIR (Codex)"
  rm -rf "$OPENCODE_LEARN_SKILLS_DIR" && ok "removed ~/.config/opencode/skills/learn (OpenCode)"
  rm -rf "$GEMINI_LEARN_SKILLS_DIR" && ok "removed ~/.gemini/skills/learn (Gemini CLI)"
  rm -rf "$PREFIX/skills/fork" && ok "removed skills/fork (Claude Code)"
  rm -rf "$CURSOR_FORK_SKILLS_DIR" && ok "removed ~/.cursor/skills/fork (Cursor CLI)"
  rm -rf "$AGENTS_FORK_SKILLS_DIR" && ok "removed ~/.agents/skills/fork (Agent Skills)"
  rm -rf "$CODEX_FORK_SKILLS_DIR" && ok "removed $CODEX_FORK_SKILLS_DIR (Codex)"
  rm -rf "$OPENCODE_FORK_SKILLS_DIR" && ok "removed ~/.config/opencode/skills/fork (OpenCode)"
  rm -rf "$GEMINI_FORK_SKILLS_DIR" && ok "removed ~/.gemini/skills/fork (Gemini CLI)"
  rm -rf "$PREFIX/skills/explain" && ok "removed skills/explain (Claude Code)"
  rm -rf "$CURSOR_EXPLAIN_SKILLS_DIR" && ok "removed ~/.cursor/skills/explain (Cursor CLI)"
  rm -rf "$AGENTS_EXPLAIN_SKILLS_DIR" && ok "removed ~/.agents/skills/explain (Agent Skills)"
  rm -rf "$CODEX_EXPLAIN_SKILLS_DIR" && ok "removed $CODEX_EXPLAIN_SKILLS_DIR (Codex)"
  rm -rf "$OPENCODE_EXPLAIN_SKILLS_DIR" && ok "removed ~/.config/opencode/skills/explain (OpenCode)"
  rm -rf "$GEMINI_EXPLAIN_SKILLS_DIR" && ok "removed ~/.gemini/skills/explain (Gemini CLI)"
  rm -rf "$PREFIX/skills/opsx-review" && ok "removed skills/opsx-review (Claude Code)"
  rm -rf "$CURSOR_REVIEW_SKILLS_DIR" && ok "removed ~/.cursor/skills/opsx-review (Cursor CLI)"
  rm -rf "$AGENTS_REVIEW_SKILLS_DIR" && ok "removed ~/.agents/skills/opsx-review (Agent Skills)"
  rm -rf "$CODEX_REVIEW_SKILLS_DIR" && ok "removed $CODEX_REVIEW_SKILLS_DIR (Codex)"
  rm -rf "$OPENCODE_REVIEW_SKILLS_DIR" && ok "removed ~/.config/opencode/skills/opsx-review (OpenCode)"
  rm -rf "$GEMINI_REVIEW_SKILLS_DIR" && ok "removed ~/.gemini/skills/opsx-review (Gemini CLI)"
  rm -rf "$PREFIX/skills/opsx-pr" && ok "removed skills/opsx-pr (Claude Code)"
  rm -rf "$CURSOR_PR_SKILLS_DIR" && ok "removed ~/.cursor/skills/opsx-pr (Cursor CLI)"
  rm -rf "$AGENTS_PR_SKILLS_DIR" && ok "removed ~/.agents/skills/opsx-pr (Agent Skills)"
  rm -rf "$CODEX_PR_SKILLS_DIR" && ok "removed $CODEX_PR_SKILLS_DIR (Codex)"
  rm -rf "$OPENCODE_PR_SKILLS_DIR" && ok "removed ~/.config/opencode/skills/opsx-pr (OpenCode)"
  rm -rf "$GEMINI_PR_SKILLS_DIR" && ok "removed ~/.gemini/skills/opsx-pr (Gemini CLI)"
  rm -rf "$PREFIX/skills/opsx-task" && ok "removed skills/opsx-task (Claude Code)"
  rm -rf "$CURSOR_TASK_SKILLS_DIR" && ok "removed ~/.cursor/skills/opsx-task (Cursor CLI)"
  rm -rf "$AGENTS_TASK_SKILLS_DIR" && ok "removed ~/.agents/skills/opsx-task (Agent Skills)"
  rm -rf "$CODEX_TASK_SKILLS_DIR" && ok "removed $CODEX_TASK_SKILLS_DIR (Codex)"
  rm -rf "$OPENCODE_TASK_SKILLS_DIR" && ok "removed ~/.config/opencode/skills/opsx-task (OpenCode)"
  rm -rf "$GEMINI_TASK_SKILLS_DIR" && ok "removed ~/.gemini/skills/opsx-task (Gemini CLI)"
  rm -rf "$PREFIX/skills/opsx-init" && ok "removed skills/opsx-init (Claude Code)"
  rm -rf "$CURSOR_INIT_SKILLS_DIR" && ok "removed ~/.cursor/skills/opsx-init (Cursor CLI)"
  rm -rf "$AGENTS_INIT_SKILLS_DIR" && ok "removed ~/.agents/skills/opsx-init (Agent Skills)"
  rm -rf "$CODEX_INIT_SKILLS_DIR" && ok "removed $CODEX_INIT_SKILLS_DIR (Codex)"
  rm -rf "$OPENCODE_INIT_SKILLS_DIR" && ok "removed ~/.config/opencode/skills/opsx-init (OpenCode)"
  rm -rf "$GEMINI_INIT_SKILLS_DIR" && ok "removed ~/.gemini/skills/opsx-init (Gemini CLI)"
  for f in "$HOME/.local/bin/opsx" "$HOME/bin/opsx"; do
    if [ -f "$f" ] && grep -qxF "$OPSX_LAUNCHER_MARK" "$f" 2>/dev/null; then
      rm -f "$f" && ok "removed $(printf '%s' "$f" | sed "s|^$HOME|~|") (opsx command)"
    elif [ -e "$f" ]; then
      warn "left $f in place — it is not the tmux-opsx launcher"
    fi
  done
  remove_marked_block "$PREFIX/CLAUDE.md"
  remove_marked_block "$CODEX_AGENTS_MD"
  remove_marked_block "$OPENCODE_AGENTS_MD"
  remove_marked_block "$GEMINI_MD"
  for f in "$PREFIX/CLAUDE.md" "$CODEX_AGENTS_MD" "$OPENCODE_AGENTS_MD" "$GEMINI_MD"; do
    remove_marked_block "$f" "$LEARN_BLOCK_START" "$LEARN_BLOCK_END" learn
  done
  remove_claude_session_hook "$PREFIX/settings.json"
  for f in "$HOME/.tmux.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"; do
    remove_marked_block "$f" "$RESTORE_BLOCK_START" "$RESTORE_BLOCK_END" "session restore"
  done
  notify_settings_hooks remove
  notify_remove_unit
  notify_remove_route
  info ""
  info "The OpenSpec CLI was left installed. Remove it with:"
  info "  npm uninstall -g $NPM_PKG"
  info "The Graphify CLI was left installed. Remove it with:"
  info "  uv tool uninstall graphifyy"
  info "browser-use MCP entries in Gemini / Codex / OpenCode config were left in place."
  info "$MEMORY_STORE_DIR was left in place — your memories are never deleted."
  info "Learned skills in each project's .opsx/skills/ (and their learned-* links) were left in place."
  info "Fork state and /explain pages in \${XDG_STATE_HOME:-~/.local/state}/agent-forks/ were left in place."
  info "Session restore state in \${XDG_STATE_HOME:-~/.local/state}/tmux-opsx/sessions/ was left in place."
  [ -d "$NTFY_STATE_DIR" ] && info "The ntfy state in $(tilde "$NTFY_STATE_DIR") (user, token, cached pushes) and $(tilde "$NOTIFY_ENV") were left in place."
  exit 0
fi

info "${B}tmux-opsx${N} installer  ${D}($PLATFORM)${N}"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  warn "running via sudo — installing for ${SUDO_USER} (${HOME}), not /root"
  note "sudo is usually unnecessary; plain ./install.sh is enough for the skill files"
fi
info ""

# ---------- 1. prerequisites ----------
step "Checking prerequisites"
MISSING=0

if have tmux; then
  ok "tmux $(tmux -V 2>/dev/null | awk '{print $2}')"
else
  warn "tmux not found — required, /opsx-run runs each change in a tmux window"
  case "$PLATFORM" in
    macOS) note "install: brew install tmux" ;;
    Linux) note "install: sudo apt install tmux   (or dnf/pacman/zypper)" ;;
  esac
  MISSING=1
fi

if have git; then
  ok "git $(git --version 2>/dev/null | awk '{print $3}')"
else
  warn "git not found — required, the ops-applier agent works in git worktrees"
  MISSING=1
fi

if have node && have npm; then
  ok "node $(node --version 2>/dev/null) / npm $(npm --version 2>/dev/null)"
else
  warn "node/npm not found — required to install the OpenSpec CLI"
  case "$PLATFORM" in
    macOS) note "install: brew install node" ;;
    Linux) note "install: https://nodejs.org  (or your package manager)" ;;
  esac
  MISSING=1
fi

if have claude; then
  ok "claude $(claude --version 2>/dev/null | head -1)"
else
  warn "claude CLI not found — optional if you use another agent CLI"
  note "install: https://claude.com/claude-code"
fi

if have agent; then
  ok "agent $(agent --version 2>/dev/null | head -1)"
else
  warn "agent CLI not found — optional if you use another agent CLI"
  note "install: https://cursor.com/docs/cli"
fi

if have codex; then
  ok "codex $(codex --version 2>/dev/null | head -1)"
else
  warn "codex CLI not found — optional if you use another agent CLI"
  note "install: https://github.com/openai/codex"
fi

if have opencode; then
  ok "opencode $(opencode --version 2>/dev/null | head -1)"
else
  warn "opencode CLI not found — optional if you use another agent CLI"
  note "install: https://opencode.ai"
fi

if have gemini; then
  ok "gemini $(gemini --version 2>/dev/null | head -1)"
else
  warn "gemini CLI not found — optional if you use another agent CLI"
  note "install: https://github.com/google-gemini/gemini-cli"
fi

if [ "$SKIP_MCP" -eq 0 ]; then
  if mcp_uvx >/dev/null; then
    ok "uvx $(mcp_uvx)"
  else
    warn "uvx not on PATH — browser-use MCP will be skipped"
    note "install: curl -LsSf https://astral.sh/uv/install.sh | sh"
  fi
  if have python3; then
    ok "python3 $(python3 --version 2>/dev/null | awk '{print $2}')"
  else
    warn "python3 not found — needed to write Gemini/OpenCode MCP config"
  fi
fi

if ! have claude && ! have agent && ! have codex && ! have opencode && ! have gemini; then
  warn "none of claude, agent, codex, opencode or gemini is on PATH — required, each tmux window runs one of them"
  MISSING=1
fi

if [ "$SKIP_GRAPHIFY" -eq 1 ]; then
  if have graphify; then
    ok "graphify $(graphify_version) (skipped install)"
  else
    warn "graphify not on PATH — skipped (--skip-graphify)"
  fi
else
  if have graphify; then
    ok "graphify $(graphify_version) ($(command -v graphify))"
  else
    warn "graphify not found — will install it (uv tool / pipx / pip)"
    note "install: uv tool install graphifyy"
  fi
fi

if [ -n "$EXPOSE_DOMAIN" ]; then
  if have curl; then
    ok "curl $(curl --version 2>/dev/null | awk 'NR==1{print $2}') (for --expose-domain)"
  else
    warn "curl not found — required by --expose-domain (Caddy download, token check, expose.sh)"
    MISSING=1
  fi
  [ "$MISSING" -eq 0 ] || die "install the missing prerequisites above, then re-run this script."
  [ -f "$SRC/skills/expose/SKILL.md" ] && [ -f "$SRC/skills/expose/expose.sh" ] \
    || die "missing $SRC/skills/expose/ — run this script from the repo checkout"
  ok "expose domain: $EXPOSE_DOMAIN (URLs like https://3000--<project>.$EXPOSE_DOMAIN)"
  expose_token_intake
  expose_verify_token
fi

[ "$MISSING" -eq 0 ] || die "install the missing prerequisites above, then re-run this script."
info ""

# ---------- 2. OpenSpec CLI ----------
if [ "$SKIP_OPENSPEC" -eq 1 ]; then
  step "Skipping OpenSpec CLI (--skip-openspec)"
  have openspec || warn "openspec is not on PATH — the /opsx-run skill needs it at runtime"
else
  step "Installing the OpenSpec CLI"
  if have openspec; then
    note "found openspec $(openspec --version 2>/dev/null) on PATH"
  elif ! npm_prefix_writable; then
    note "npm prefix $(npm_global_prefix) is not writable — will try ~/.local if needed"
  fi
  install_openspec || die "could not install $NPM_PKG"
fi
info ""

# ---------- 3. global OpenSpec skills + /opsx:* commands ----------
if [ "$SKIP_COMMANDS" -eq 1 ]; then
  step "Skipping global OpenSpec skills / commands (--skip-commands)"
else
  step "Installing global OpenSpec skills and /opsx:* commands"
  if ! have openspec; then
    warn "openspec not on PATH — skipping (re-run without --skip-openspec)"
  else
    # Generate with the installed CLI rather than vendoring copies, so they
    # always match the OpenSpec version actually in use. Then copy into each
    # tool's *global* config dir (not a project checkout).
    TMPD=$(mktemp -d 2>/dev/null || mktemp -d -t tmuxopsx)
    [ -n "$TMPD" ] && [ -d "$TMPD" ] || die "could not create a temp directory"
    if (cd "$TMPD" && openspec init --tools claude,cursor,codex,opencode,gemini . >/dev/null 2>&1); then
      install_openspec_skills "$TMPD/.claude/skills" "$PREFIX/skills" "Claude Code"
      install_openspec_skills "$TMPD/.cursor/skills" "$HOME/.cursor/skills" "Cursor CLI"
      # `openspec init --tools codex` emits Agent Skills under .agents/skills
      # (older releases used .codex/skills). Codex reads both ~/.agents/skills
      # and $CODEX_HOME/skills, so install into each.
      CODEX_OPENSPEC_SRC=$TMPD/.agents/skills
      [ -d "$CODEX_OPENSPEC_SRC" ] || CODEX_OPENSPEC_SRC=$TMPD/.codex/skills
      install_openspec_skills "$CODEX_OPENSPEC_SRC" "$CODEX_OPENSPEC_SKILLS_DIR" "Codex"
      if [ "$AGENTS_OPENSPEC_SKILLS_DIR" != "$CODEX_OPENSPEC_SKILLS_DIR" ]; then
        install_openspec_skills "$CODEX_OPENSPEC_SRC" "$AGENTS_OPENSPEC_SKILLS_DIR" "Agent Skills"
      fi
      install_openspec_skills "$TMPD/.opencode/skills" "$OPENCODE_OPENSPEC_SKILLS_DIR" "OpenCode"
      install_openspec_skills "$TMPD/.gemini/skills" "$GEMINI_OPENSPEC_SKILLS_DIR" "Gemini CLI"

      install_openspec_commands "$TMPD/.claude/commands" "$PREFIX/commands" "Claude Code"
      install_openspec_commands "$TMPD/.cursor/commands" "$CURSOR_COMMANDS_DIR" "Cursor CLI"
      install_openspec_commands "$TMPD/.opencode/commands" "$OPENCODE_COMMANDS_DIR" "OpenCode"
      install_openspec_commands "$TMPD/.gemini/commands" "$GEMINI_COMMANDS_DIR" "Gemini CLI"
      note "available globally: /opsx:propose /opsx:apply /opsx:archive /opsx:explore"
      note "and skills: openspec-propose, openspec-apply-change, openspec-archive-change, openspec-explore"
      note "a project's own .claude/.cursor/.opencode/.gemini copies still take precedence when present"
    else
      warn "'openspec init' did not produce skills/commands — skipping"
      note "you can copy them from any OpenSpec project after: openspec init --tools claude,cursor,codex,opencode,gemini"
    fi
    rm -rf "$TMPD"
  fi
fi
info ""

# ---------- 3b. Graphify CLI + global /graphify skill ----------
if [ "$SKIP_GRAPHIFY" -eq 1 ]; then
  step "Skipping Graphify (--skip-graphify)"
  have graphify || warn "graphify is not on PATH — /graphify needs it at runtime"
else
  step "Verifying the Graphify CLI"
  install_graphify_cli || die "could not install graphify (try: uv tool install graphifyy)"
  step "Installing the /graphify skill globally"
  install_graphify_skills || die "could not install the graphify skill"
fi
info ""

# ---------- 4. ops-applier + ops-qa + ops-reviewer + ops-security + ops-eval subagents ----------
step "Installing the ops-applier, ops-qa, ops-reviewer, ops-security, and ops-eval subagents"
[ -f "$SRC/agents/opsx-applier.md" ] || die "missing $SRC/agents/opsx-applier.md — run this script from the repo checkout"
[ -f "$SRC/agents/opsx-qa.md" ] || die "missing $SRC/agents/opsx-qa.md — run this script from the repo checkout"
[ -f "$SRC/agents/opsx-reviewer.md" ] || die "missing $SRC/agents/opsx-reviewer.md — run this script from the repo checkout"
[ -f "$SRC/agents/opsx-security.md" ] || die "missing $SRC/agents/opsx-security.md — run this script from the repo checkout"
[ -f "$SRC/agents/opsx-eval.md" ] || die "missing $SRC/agents/opsx-eval.md — run this script from the repo checkout"
[ -f "$SRC/skills/opsx-run/opsx-eval.sh" ] || die "missing $SRC/skills/opsx-run/opsx-eval.sh — run this script from the repo checkout"
[ -f "$SRC/skills/opsx-run/opsx-preview.sh" ] || die "missing $SRC/skills/opsx-run/opsx-preview.sh — run this script from the repo checkout"
[ -f "$SRC/skills/opsx-run/opsx-dev.sh" ] || die "missing $SRC/skills/opsx-run/opsx-dev.sh — run this script from the repo checkout"
[ -f "$SRC/skills/opsx-run/opsx-sessions.sh" ] || die "missing $SRC/skills/opsx-run/opsx-sessions.sh — run this script from the repo checkout"
[ -f "$SRC/agents/models.conf" ] || die "missing $SRC/agents/models.conf — run this script from the repo checkout"
load_agent_models claude
load_agent_models agent
load_agent_models opencode
for a in applier qa reviewer security eval; do
  m=$(agent_model_for claude "$a")
  install_claude_agent "$SRC/agents/opsx-$a.md" "$PREFIX/agents/opsx-$a.md" "$m"
  ok "ops-$a -> $PREFIX/agents/opsx-$a.md (Claude Code, model: $m)"
  m=$(agent_model_for agent "$a")
  install_cursor_agent "$SRC/agents/opsx-$a.md" "$CURSOR_AGENTS_DIR/opsx-$a.md" "$m"
  ok "ops-$a -> $CURSOR_AGENTS_DIR/opsx-$a.md (Cursor CLI, model: $m)"
  install_codex_agent "$SRC/agents/opsx-$a.md" "$CODEX_AGENTS_DIR/ops-$a.toml"
  ok "ops-$a -> $CODEX_AGENTS_DIR/ops-$a.toml (Codex CLI)"
  m=$(agent_model_for opencode "$a")
  install_opencode_agent "$SRC/agents/opsx-$a.md" "$OPENCODE_AGENTS_DIR/ops-$a.md" "$m"
  ok "ops-$a -> $OPENCODE_AGENTS_DIR/ops-$a.md (OpenCode, model: $m)"
  install_file "$SRC/agents/opsx-$a.md" "$GEMINI_AGENTS_DIR/opsx-$a.md"
  ok "ops-$a -> $GEMINI_AGENTS_DIR/opsx-$a.md (Gemini CLI)"
done
note "agent models: agents/models.conf, overridden by ${XDG_CONFIG_HOME:-~/.config}/tmux-opsx/models.conf (re-run install after editing)"
note "applier implements in opsx/<change>; eval/reviewer/security/qa verify after apply (eval owns evals/)"
info ""

# ---------- 5. /opsx-run skill ----------
step "Installing the /opsx-run skill"
[ -f "$SRC/skills/opsx-run/SKILL.md" ] || die "missing $SRC/skills/opsx-run/SKILL.md — run this script from the repo checkout"
install_opsx_run_skill "$PREFIX/skills/opsx-run" "Claude Code"
install_opsx_run_skill "$CURSOR_SKILLS_DIR" "Cursor CLI"
install_opsx_run_skill "$AGENTS_SKILLS_DIR" "Codex/Agent Skills (~/.agents/skills)"
if [ "$CODEX_SKILLS_DIR" != "$AGENTS_SKILLS_DIR" ]; then
  install_opsx_run_skill "$CODEX_SKILLS_DIR" "Codex (\$CODEX_HOME/skills)"
fi
install_opsx_run_skill "$OPENCODE_SKILLS_DIR" "OpenCode (~/.config/opencode/skills)"
install_opsx_run_skill "$GEMINI_SKILLS_DIR" "Gemini CLI (~/.gemini/skills)"
info ""

# ---------- 6. browser-use MCP ----------
if [ "$SKIP_MCP" -eq 1 ]; then
  step "Skipping browser-use MCP (--skip-mcp)"
else
  step "Configuring browser-use MCP for Gemini, Codex, and OpenCode"
  install_browser_use_mcp
fi
info ""

# ---------- 7. memory skill + shared store ----------
if [ "$SKIP_MEMORY" -eq 1 ]; then
  step "Skipping memory (--skip-memory)"
else
  step "Installing the memory skill"
  [ -f "$SRC/skills/memory/SKILL.md" ] || die "missing $SRC/skills/memory/SKILL.md — run this script from the repo checkout"
  install_memory_skill "$PREFIX/skills/memory" "Claude Code"
  install_memory_skill "$CURSOR_MEMORY_SKILLS_DIR" "Cursor CLI"
  install_memory_skill "$AGENTS_MEMORY_SKILLS_DIR" "Codex/Agent Skills (~/.agents/skills)"
  if [ "$CODEX_MEMORY_SKILLS_DIR" != "$AGENTS_MEMORY_SKILLS_DIR" ]; then
    install_memory_skill "$CODEX_MEMORY_SKILLS_DIR" "Codex (\$CODEX_HOME/skills)"
  fi
  install_memory_skill "$OPENCODE_MEMORY_SKILLS_DIR" "OpenCode (~/.config/opencode/skills)"
  install_memory_skill "$GEMINI_MEMORY_SKILLS_DIR" "Gemini CLI (~/.gemini/skills)"
  info ""

  step "Writing the memory instruction block"
  upsert_marked_block "$PREFIX/CLAUDE.md"
  ok "memory block -> $(printf '%s' "$PREFIX/CLAUDE.md" | sed "s|$HOME|~|") (Claude Code)"
  upsert_marked_block "$CODEX_AGENTS_MD"
  ok "memory block -> $(printf '%s' "$CODEX_AGENTS_MD" | sed "s|$HOME|~|") (Codex CLI)"
  upsert_marked_block "$OPENCODE_AGENTS_MD"
  ok "memory block -> $(printf '%s' "$OPENCODE_AGENTS_MD" | sed "s|$HOME|~|") (OpenCode)"
  upsert_marked_block "$GEMINI_MD"
  ok "memory block -> $(printf '%s' "$GEMINI_MD" | sed "s|$HOME|~|") (Gemini CLI)"
  info ""

  step "Creating the shared memory store"
  create_memory_store_skeleton "$MEMORY_STORE_DIR"
  ok "$(printf '%s' "$MEMORY_STORE_DIR" | sed "s|$HOME|~|") (user/, feedback/, project/, reference/, MEMORY.md)"
  info ""

  step "Importing existing Claude Code memories"
  bash "$SRC/skills/memory/import-claude-memory.sh" "$MEMORY_STORE_DIR"
  info ""

  step "Cursor: add the memory block manually"
  note "Cursor has no known global instructions file — paste this into Cursor Settings -> Rules -> User Rules:"
  info ""
  memory_instruction_block
fi
info ""

# ---------- 7b. learn skill + instruction block ----------
if [ "$SKIP_LEARN" -eq 1 ]; then
  step "Skipping the learn skill (--skip-learn)"
else
  step "Installing the learn skill"
  [ -f "$SRC/skills/learn/SKILL.md" ] && [ -f "$SRC/skills/learn/learn.sh" ] \
    || die "missing $SRC/skills/learn/ — run this script from the repo checkout"
  install_learn_skill "$PREFIX/skills/learn" "Claude Code"
  install_learn_skill "$CURSOR_LEARN_SKILLS_DIR" "Cursor CLI"
  install_learn_skill "$AGENTS_LEARN_SKILLS_DIR" "Codex/Agent Skills (~/.agents/skills)"
  if [ "$CODEX_LEARN_SKILLS_DIR" != "$AGENTS_LEARN_SKILLS_DIR" ]; then
    install_learn_skill "$CODEX_LEARN_SKILLS_DIR" "Codex (\$CODEX_HOME/skills)"
  fi
  install_learn_skill "$OPENCODE_LEARN_SKILLS_DIR" "OpenCode (~/.config/opencode/skills)"
  install_learn_skill "$GEMINI_LEARN_SKILLS_DIR" "Gemini CLI (~/.gemini/skills)"
  info ""

  step "Writing the learn instruction block"
  upsert_learn_block "$PREFIX/CLAUDE.md"
  ok "learn block -> $(printf '%s' "$PREFIX/CLAUDE.md" | sed "s|$HOME|~|") (Claude Code)"
  upsert_learn_block "$CODEX_AGENTS_MD"
  ok "learn block -> $(printf '%s' "$CODEX_AGENTS_MD" | sed "s|$HOME|~|") (Codex CLI)"
  upsert_learn_block "$OPENCODE_AGENTS_MD"
  ok "learn block -> $(printf '%s' "$OPENCODE_AGENTS_MD" | sed "s|$HOME|~|") (OpenCode)"
  upsert_learn_block "$GEMINI_MD"
  ok "learn block -> $(printf '%s' "$GEMINI_MD" | sed "s|$HOME|~|") (Gemini CLI)"
  info ""

  step "Cursor: add the learn block manually"
  note "Cursor has no known global instructions file — paste this into Cursor Settings -> Rules -> User Rules:"
  info ""
  learn_instruction_block
fi
info ""

# ---------- 8. /fork skill ----------
if [ "$SKIP_FORK" -eq 1 ]; then
  step "Skipping the /fork skill (--skip-fork)"
else
  step "Installing the /fork skill"
  [ -f "$SRC/skills/fork/SKILL.md" ] || die "missing $SRC/skills/fork/SKILL.md — run this script from the repo checkout"
  install_fork_skill "$PREFIX/skills/fork" "Claude Code"
  install_fork_skill "$CURSOR_FORK_SKILLS_DIR" "Cursor CLI"
  install_fork_skill "$AGENTS_FORK_SKILLS_DIR" "Codex/Agent Skills (~/.agents/skills)"
  if [ "$CODEX_FORK_SKILLS_DIR" != "$AGENTS_FORK_SKILLS_DIR" ]; then
    install_fork_skill "$CODEX_FORK_SKILLS_DIR" "Codex (\$CODEX_HOME/skills)"
  fi
  install_fork_skill "$OPENCODE_FORK_SKILLS_DIR" "OpenCode (~/.config/opencode/skills)"
  install_fork_skill "$GEMINI_FORK_SKILLS_DIR" "Gemini CLI (~/.gemini/skills)"
fi
info ""

# ---------- 8b. /explain skill ----------
if [ "$SKIP_EXPLAIN" -eq 1 ]; then
  step "Skipping the /explain skill (--skip-explain)"
else
  step "Installing the /explain skill"
  [ -f "$SRC/skills/explain/SKILL.md" ] || die "missing $SRC/skills/explain/SKILL.md — run this script from the repo checkout"
  install_explain_skill "$PREFIX/skills/explain" "Claude Code"
  install_explain_skill "$CURSOR_EXPLAIN_SKILLS_DIR" "Cursor CLI"
  install_explain_skill "$AGENTS_EXPLAIN_SKILLS_DIR" "Codex/Agent Skills (~/.agents/skills)"
  if [ "$CODEX_EXPLAIN_SKILLS_DIR" != "$AGENTS_EXPLAIN_SKILLS_DIR" ]; then
    install_explain_skill "$CODEX_EXPLAIN_SKILLS_DIR" "Codex (\$CODEX_HOME/skills)"
  fi
  install_explain_skill "$OPENCODE_EXPLAIN_SKILLS_DIR" "OpenCode (~/.config/opencode/skills)"
  install_explain_skill "$GEMINI_EXPLAIN_SKILLS_DIR" "Gemini CLI (~/.gemini/skills)"
  [ "$SKIP_FORK" -eq 1 ] && note "/explain needs the /fork skill (installed without --skip-fork)"
fi
info ""

# ---------- 8c. /opsx-review skill ----------
if [ "$SKIP_REVIEW" -eq 1 ]; then
  step "Skipping the /opsx-review skill (--skip-review)"
else
  step "Installing the /opsx-review skill"
  [ -f "$SRC/skills/opsx-review/SKILL.md" ] || die "missing $SRC/skills/opsx-review/SKILL.md — run this script from the repo checkout"
  install_review_skill "$PREFIX/skills/opsx-review" "Claude Code"
  install_review_skill "$CURSOR_REVIEW_SKILLS_DIR" "Cursor CLI"
  install_review_skill "$AGENTS_REVIEW_SKILLS_DIR" "Codex/Agent Skills (~/.agents/skills)"
  if [ "$CODEX_REVIEW_SKILLS_DIR" != "$AGENTS_REVIEW_SKILLS_DIR" ]; then
    install_review_skill "$CODEX_REVIEW_SKILLS_DIR" "Codex (\$CODEX_HOME/skills)"
  fi
  install_review_skill "$OPENCODE_REVIEW_SKILLS_DIR" "OpenCode (~/.config/opencode/skills)"
  install_review_skill "$GEMINI_REVIEW_SKILLS_DIR" "Gemini CLI (~/.gemini/skills)"
fi
info ""

# ---------- 8d. /opsx-pr skill ----------
if [ "$SKIP_PR" -eq 1 ]; then
  step "Skipping the /opsx-pr skill (--skip-pr)"
else
  step "Installing the /opsx-pr skill"
  [ -f "$SRC/skills/opsx-pr/SKILL.md" ] || die "missing $SRC/skills/opsx-pr/SKILL.md — run this script from the repo checkout"
  [ -f "$SRC/skills/opsx-pr/pr.sh" ] || die "missing $SRC/skills/opsx-pr/pr.sh — run this script from the repo checkout"
  install_pr_skill "$PREFIX/skills/opsx-pr" "Claude Code"
  install_pr_skill "$CURSOR_PR_SKILLS_DIR" "Cursor CLI"
  install_pr_skill "$AGENTS_PR_SKILLS_DIR" "Codex/Agent Skills (~/.agents/skills)"
  if [ "$CODEX_PR_SKILLS_DIR" != "$AGENTS_PR_SKILLS_DIR" ]; then
    install_pr_skill "$CODEX_PR_SKILLS_DIR" "Codex (\$CODEX_HOME/skills)"
  fi
  install_pr_skill "$OPENCODE_PR_SKILLS_DIR" "OpenCode (~/.config/opencode/skills)"
  install_pr_skill "$GEMINI_PR_SKILLS_DIR" "Gemini CLI (~/.gemini/skills)"
  note "/opsx-pr windows push the PR branch (--force-with-lease) and post to the PR; they never merge"
fi
info ""

# ---------- 8e. /opsx-task skill ----------
if [ "$SKIP_TASK" -eq 1 ]; then
  step "Skipping the /opsx-task skill (--skip-task)"
else
  step "Installing the /opsx-task skill"
  [ -f "$SRC/skills/opsx-task/SKILL.md" ] || die "missing $SRC/skills/opsx-task/SKILL.md — run this script from the repo checkout"
  [ -f "$SRC/skills/opsx-task/opsx-task.sh" ] || die "missing $SRC/skills/opsx-task/opsx-task.sh — run this script from the repo checkout"
  install_task_skill "$PREFIX/skills/opsx-task" "Claude Code"
  install_task_skill "$CURSOR_TASK_SKILLS_DIR" "Cursor CLI"
  install_task_skill "$AGENTS_TASK_SKILLS_DIR" "Codex/Agent Skills (~/.agents/skills)"
  if [ "$CODEX_TASK_SKILLS_DIR" != "$AGENTS_TASK_SKILLS_DIR" ]; then
    install_task_skill "$CODEX_TASK_SKILLS_DIR" "Codex (\$CODEX_HOME/skills)"
  fi
  install_task_skill "$OPENCODE_TASK_SKILLS_DIR" "OpenCode (~/.config/opencode/skills)"
  install_task_skill "$GEMINI_TASK_SKILLS_DIR" "Gemini CLI (~/.gemini/skills)"
  note "/opsx-task sessions run the agent CLI with normal approvals; briefs go to <repo>/.opsx/tasks/ (git-ignored)"
fi
info ""

# ---------- 9. /expose skill + proxy (only with --expose-domain) ----------
if [ -n "$EXPOSE_DOMAIN" ]; then
  step "Setting up /expose for *.$EXPOSE_DOMAIN"
  expose_get_caddy
  [ "$SKIP_NOTIFY" -eq 1 ] || notify_get_ntfy
  expose_write_env
  expose_write_caddy_config
  expose_rewrite_records
  expose_service_step
  if [ "$NOTIFY_SERVER" -eq 1 ]; then
    info ""
    step "Setting up the push server for https://ntfy.$EXPOSE_DOMAIN"
    notify_write_server_config
    notify_credentials
    notify_service_step
  fi
  expose_dns_check
  expose_chown
  note "exposed URLs are PUBLIC with no authentication; bind apps to 127.0.0.1 and open only 443 (and 22) in the provider firewall"
  info ""
  step "Installing the /expose skill"
  install_expose_skill "$PREFIX/skills/expose" "Claude Code"
  install_expose_skill "$CURSOR_EXPOSE_SKILLS_DIR" "Cursor CLI"
  install_expose_skill "$AGENTS_EXPOSE_SKILLS_DIR" "Codex/Agent Skills (~/.agents/skills)"
  if [ "$CODEX_EXPOSE_SKILLS_DIR" != "$AGENTS_EXPOSE_SKILLS_DIR" ]; then
    install_expose_skill "$CODEX_EXPOSE_SKILLS_DIR" "Codex (\$CODEX_HOME/skills)"
  fi
  install_expose_skill "$OPENCODE_EXPOSE_SKILLS_DIR" "OpenCode (~/.config/opencode/skills)"
  install_expose_skill "$GEMINI_EXPOSE_SKILLS_DIR" "Gemini CLI (~/.gemini/skills)"
  info ""
fi

# ---------- 9b. push notifications (opsx-notify.sh + Claude Code hooks) ----------
if [ "$SKIP_NOTIFY" -eq 1 ]; then
  step "Skipping push notifications (--skip-notify)"
  notify_settings_hooks remove
  # A rerun takes out what an earlier install added, with or without --expose-domain.
  notify_remove_unit
  notify_remove_route
else
  step "Installing push notification hooks (Claude Code)"
  notify_settings_hooks add
  if [ -f "$NOTIFY_ENV" ]; then
    ok "pushes go to $(env_file_get "$NOTIFY_ENV" NTFY_URL 2>/dev/null || echo '?') ($(tilde "$NOTIFY_ENV"))"
  else
    note "no $(tilde "$NOTIFY_ENV") yet: write NTFY_URL / NTFY_TOPIC / NTFY_TOKEN there for any ntfy server, or let install.sh run its own (README: Notifications)"
  fi
  note "Cursor, Codex, OpenCode and Gemini windows push on mark / pr.sh note only (no question or turn-end hooks)"
fi
info ""

# ---------- 10. opsx command + /opsx-init skill ----------
if [ "$SKIP_INIT" -eq 1 ]; then
  step "Skipping the opsx command and /opsx-init skill (--skip-init)"
else
  step "Installing the opsx command and /opsx-init skill"
  [ -f "$SRC/skills/opsx-init/SKILL.md" ] && [ -f "$SRC/skills/opsx-init/opsx-init.sh" ] && [ -f "$SRC/bin/opsx" ] \
    || die "missing $SRC/skills/opsx-init/ or $SRC/bin/opsx — run this script from the repo checkout"
  install_opsx_init_skill "$PREFIX/skills/opsx-init" "Claude Code"
  install_opsx_init_skill "$CURSOR_INIT_SKILLS_DIR" "Cursor CLI"
  install_opsx_init_skill "$AGENTS_INIT_SKILLS_DIR" "Codex/Agent Skills (~/.agents/skills)"
  if [ "$CODEX_INIT_SKILLS_DIR" != "$AGENTS_INIT_SKILLS_DIR" ]; then
    install_opsx_init_skill "$CODEX_INIT_SKILLS_DIR" "Codex (\$CODEX_HOME/skills)"
  fi
  install_opsx_init_skill "$OPENCODE_INIT_SKILLS_DIR" "OpenCode (~/.config/opencode/skills)"
  install_opsx_init_skill "$GEMINI_INIT_SKILLS_DIR" "Gemini CLI (~/.gemini/skills)"
  OPSX_BIN_DIR=$(user_bin_dir)
  OPSX_BIN=$OPSX_BIN_DIR/opsx
  if [ -e "$OPSX_BIN" ] && ! grep -qxF "$OPSX_LAUNCHER_MARK" "$OPSX_BIN" 2>/dev/null; then
    warn "$OPSX_BIN exists and is not the tmux-opsx launcher — left it alone; run opsx-init.sh from the skill dir instead"
  else
    install_file "$SRC/bin/opsx" "$OPSX_BIN"
    chmod +x "$OPSX_BIN" || die "cannot chmod +x $OPSX_BIN"
    ok "opsx -> $(printf '%s' "$OPSX_BIN" | sed "s|^$HOME|~|")"
    case ":$PATH:" in
      *":$OPSX_BIN_DIR:"*) ;;
      *) warn "$OPSX_BIN_DIR is not on PATH — add it to use opsx:"
         note "  export PATH=\"$OPSX_BIN_DIR:\$PATH\"" ;;
    esac
  fi
fi
info ""

# ---------- 11. session restore ----------
RESTORE_BLOCK=""
if [ "$SKIP_RESTORE" -eq 1 ]; then
  step "Skipping session restore (--skip-restore)"
else
  step "Installing session restore (Claude Code + tmux-resurrect)"
  SESSIONS_SH=$PREFIX/skills/opsx-run/opsx-sessions.sh
  upsert_claude_session_hook "$PREFIX/settings.json" "$SESSIONS_SH"
  case $? in
    0) ok "SessionStart hook -> $(tilde "$PREFIX/settings.json") (records each Claude session's tmux pane)" ;;
    2) warn "$(tilde "$PREFIX/settings.json") is not valid JSON — left it alone (no SessionStart hook)" ;;
    *) warn "could not add the SessionStart hook to $PREFIX/settings.json (needs python3 and valid JSON)" ;;
  esac
  if [ "$SKIP_INIT" -eq 0 ] && [ -x "${OPSX_BIN:-}" ] && grep -qxF "$OPSX_LAUNCHER_MARK" "$OPSX_BIN" 2>/dev/null; then
    RESTORE_SAVE_CMD="$OPSX_BIN sessions save"
    RESTORE_RESTORE_CMD="$OPSX_BIN sessions restore"
  else
    RESTORE_SAVE_CMD="bash $SESSIONS_SH save"
    RESTORE_RESTORE_CMD="bash $SESSIONS_SH restore"
  fi
  TMUX_CONF=$(tmux_conf_path)
  install_restore_tmux_block "$TMUX_CONF" "$RESTORE_SAVE_CMD" "$RESTORE_RESTORE_CMD" "$RESTORE_AT_BOOT"
  case "$RESTORE_BLOCK" in
    installed) ok "session restore block -> $(tilde "$TMUX_CONF") (tmux-resurrect post-save/post-restore hooks)" ;;
    unchanged) ok "session restore block already in $(tilde "$TMUX_CONF")" ;;
  esac
  if [ "$RESTORE_AT_BOOT" -eq 1 ]; then
    restore_linger_check
  fi
  if [ "$RESTORE_BLOCK" = installed ] || [ "$RESTORE_AT_BOOT" -eq 1 ]; then
    note "load it into the running server:  tmux source $(tilde "$TMUX_CONF")"
  fi
  note "check what would come back:  opsx sessions list"
fi
info ""

# ---------- verify ----------
step "Verifying"
FAIL=0
for f in "$PREFIX/skills/opsx-run/SKILL.md" \
         "$PREFIX/skills/opsx-run/opsx-window.sh" \
         "$PREFIX/skills/opsx-run/opsx-merge.sh" \
         "$PREFIX/skills/opsx-run/opsx-land.sh" \
         "$PREFIX/skills/opsx-run/opsx-eval.sh" \
         "$PREFIX/skills/opsx-run/opsx-preview.sh" \
         "$PREFIX/skills/opsx-run/models.conf" \
         "$CURSOR_SKILLS_DIR/SKILL.md" \
         "$CURSOR_SKILLS_DIR/opsx-window.sh" \
         "$CURSOR_SKILLS_DIR/opsx-merge.sh" \
         "$CURSOR_SKILLS_DIR/opsx-land.sh" \
         "$CURSOR_SKILLS_DIR/opsx-eval.sh" \
         "$CURSOR_SKILLS_DIR/opsx-preview.sh" \
         "$AGENTS_SKILLS_DIR/SKILL.md" \
         "$AGENTS_SKILLS_DIR/opsx-window.sh" \
         "$CODEX_SKILLS_DIR/SKILL.md" \
         "$OPENCODE_SKILLS_DIR/SKILL.md" \
         "$OPENCODE_SKILLS_DIR/opsx-window.sh" \
         "$GEMINI_SKILLS_DIR/SKILL.md" \
         "$GEMINI_SKILLS_DIR/opsx-window.sh" \
         "$PREFIX/agents/opsx-applier.md" \
         "$CURSOR_AGENTS_DIR/opsx-applier.md" \
         "$CODEX_AGENTS_DIR/ops-applier.toml" \
         "$OPENCODE_AGENTS_DIR/ops-applier.md" \
         "$GEMINI_AGENTS_DIR/opsx-applier.md" \
         "$PREFIX/agents/opsx-qa.md" \
         "$CURSOR_AGENTS_DIR/opsx-qa.md" \
         "$CODEX_AGENTS_DIR/ops-qa.toml" \
         "$OPENCODE_AGENTS_DIR/ops-qa.md" \
         "$GEMINI_AGENTS_DIR/opsx-qa.md" \
         "$PREFIX/agents/opsx-reviewer.md" \
         "$CURSOR_AGENTS_DIR/opsx-reviewer.md" \
         "$CODEX_AGENTS_DIR/ops-reviewer.toml" \
         "$OPENCODE_AGENTS_DIR/ops-reviewer.md" \
         "$GEMINI_AGENTS_DIR/opsx-reviewer.md" \
         "$PREFIX/agents/opsx-security.md" \
         "$CURSOR_AGENTS_DIR/opsx-security.md" \
         "$CODEX_AGENTS_DIR/ops-security.toml" \
         "$OPENCODE_AGENTS_DIR/ops-security.md" \
         "$GEMINI_AGENTS_DIR/opsx-security.md" \
         "$PREFIX/agents/opsx-eval.md" \
         "$CURSOR_AGENTS_DIR/opsx-eval.md" \
         "$CODEX_AGENTS_DIR/ops-eval.toml" \
         "$OPENCODE_AGENTS_DIR/ops-eval.md" \
         "$GEMINI_AGENTS_DIR/opsx-eval.md"; do
  if [ -f "$f" ]; then ok "$(printf '%s' "$f" | sed "s|$HOME|~|")"; else warn "missing: $f"; FAIL=1; fi
done
if [ "$SKIP_GRAPHIFY" -eq 0 ]; then
  for f in "$PREFIX/skills/graphify/SKILL.md" \
           "$HOME/.cursor/skills/graphify/SKILL.md" \
           "$HOME/.agents/skills/graphify/SKILL.md" \
           "$CODEX_HOME_DIR/skills/graphify/SKILL.md" \
           "$OPENCODE_CONFIG_DIR/skills/graphify/SKILL.md" \
           "$GEMINI_HOME_DIR/skills/graphify/SKILL.md"; do
    if [ -f "$f" ]; then ok "$(printf '%s' "$f" | sed "s|$HOME|~|")"; else warn "missing: $f"; FAIL=1; fi
  done
  if have graphify; then
    ok "graphify CLI $(graphify_version)"
  else
    warn "graphify CLI not on PATH"; FAIL=1
  fi
  if [ -f "$GEMINI_MD" ] && grep -qF "$GRAPHIFY_BLOCK_START" "$GEMINI_MD" 2>/dev/null; then
    ok "graphify block in $(printf '%s' "$GEMINI_MD" | sed "s|$HOME|~|")"
  else
    warn "graphify block missing in $GEMINI_MD"; FAIL=1
  fi
  if [ -f "$GEMINI_SETTINGS" ] && grep -q 'hook-guard gemini' "$GEMINI_SETTINGS" 2>/dev/null; then
    ok "graphify BeforeTool hook in $(printf '%s' "$GEMINI_SETTINGS" | sed "s|$HOME|~|")"
  else
    warn "graphify BeforeTool hook missing in $GEMINI_SETTINGS"; FAIL=1
  fi
  if [ -f "$OPENCODE_GRAPHIFY_PLUGIN" ]; then
    ok "$(printf '%s' "$OPENCODE_GRAPHIFY_PLUGIN" | sed "s|$HOME|~|")"
  else
    warn "missing: $OPENCODE_GRAPHIFY_PLUGIN"; FAIL=1
  fi
  for f in GEMINI.md .gemini/settings.json .opencode/plugins/graphify.js; do
    [ -e "$SRC/$f" ] && warn "project-level $f found in $SRC — graphify wiring belongs in the global config dirs only"
  done
fi
if [ "$SKIP_COMMANDS" -eq 0 ] && have openspec; then
  for d in "$PREFIX/skills" "$HOME/.cursor/skills" "$AGENTS_OPENSPEC_SKILLS_DIR" \
           "$CODEX_OPENSPEC_SKILLS_DIR" "$OPENCODE_OPENSPEC_SKILLS_DIR" "$GEMINI_OPENSPEC_SKILLS_DIR"; do
    if [ -f "$d/openspec-propose/SKILL.md" ]; then
      ok "OpenSpec skills in $(printf '%s' "$d" | sed "s|$HOME|~|")"
    else
      warn "OpenSpec skills missing in $d"; FAIL=1
    fi
  done
fi
if [ "$SKIP_MEMORY" -eq 0 ]; then
  for f in "$PREFIX/skills/memory/SKILL.md" \
           "$CURSOR_MEMORY_SKILLS_DIR/SKILL.md" \
           "$AGENTS_MEMORY_SKILLS_DIR/SKILL.md" \
           "$CODEX_MEMORY_SKILLS_DIR/SKILL.md" \
           "$OPENCODE_MEMORY_SKILLS_DIR/SKILL.md" \
           "$GEMINI_MEMORY_SKILLS_DIR/SKILL.md" \
           "$MEMORY_STORE_DIR/MEMORY.md"; do
    if [ -f "$f" ]; then ok "$(printf '%s' "$f" | sed "s|$HOME|~|")"; else warn "missing: $f"; FAIL=1; fi
  done
  for d in user feedback project reference; do
    [ -d "$MEMORY_STORE_DIR/$d" ] || { warn "missing: $MEMORY_STORE_DIR/$d"; FAIL=1; }
  done
  for f in "$PREFIX/CLAUDE.md" "$CODEX_AGENTS_MD" "$OPENCODE_AGENTS_MD" "$GEMINI_MD"; do
    if [ -f "$f" ] && grep -qF "$MEMORY_BLOCK_START" "$f" 2>/dev/null; then
      ok "memory block in $(printf '%s' "$f" | sed "s|$HOME|~|")"
    else
      warn "memory block missing in $f"; FAIL=1
    fi
  done
fi
if [ "$SKIP_LEARN" -eq 0 ]; then
  for d in "$PREFIX/skills/learn" "$CURSOR_LEARN_SKILLS_DIR" "$AGENTS_LEARN_SKILLS_DIR" \
           "$CODEX_LEARN_SKILLS_DIR" "$OPENCODE_LEARN_SKILLS_DIR" "$GEMINI_LEARN_SKILLS_DIR"; do
    if [ -f "$d/SKILL.md" ] && [ -x "$d/learn.sh" ]; then
      ok "$(printf '%s' "$d" | sed "s|$HOME|~|")/{SKILL.md,learn.sh}"
    else
      warn "missing or not executable: $d/{SKILL.md,learn.sh}"; FAIL=1
    fi
  done
  if bash -n "$PREFIX/skills/learn/learn.sh" 2>/dev/null; then
    ok "learn.sh parses"
  else
    warn "learn.sh failed to parse"; FAIL=1
  fi
  for f in "$PREFIX/CLAUDE.md" "$CODEX_AGENTS_MD" "$OPENCODE_AGENTS_MD" "$GEMINI_MD"; do
    if [ -f "$f" ] && grep -qF "$LEARN_BLOCK_START" "$f" 2>/dev/null; then
      ok "learn block in $(printf '%s' "$f" | sed "s|$HOME|~|")"
    else
      warn "learn block missing in $f"; FAIL=1
    fi
  done
fi
if [ "$SKIP_FORK" -eq 0 ]; then
  for d in "$PREFIX/skills/fork" "$CURSOR_FORK_SKILLS_DIR" "$AGENTS_FORK_SKILLS_DIR" \
           "$CODEX_FORK_SKILLS_DIR" "$OPENCODE_FORK_SKILLS_DIR" "$GEMINI_FORK_SKILLS_DIR"; do
    if [ -f "$d/SKILL.md" ] && [ -x "$d/fork.sh" ]; then
      ok "$(printf '%s' "$d" | sed "s|$HOME|~|")/{SKILL.md,fork.sh}"
    else
      warn "missing or not executable: $d/{SKILL.md,fork.sh}"; FAIL=1
    fi
  done
  if bash -n "$PREFIX/skills/fork/fork.sh" 2>/dev/null; then
    ok "fork.sh parses"
  else
    warn "fork.sh failed to parse"; FAIL=1
  fi
fi
if [ "$SKIP_EXPLAIN" -eq 0 ]; then
  for d in "$PREFIX/skills/explain" "$CURSOR_EXPLAIN_SKILLS_DIR" "$AGENTS_EXPLAIN_SKILLS_DIR" \
           "$CODEX_EXPLAIN_SKILLS_DIR" "$OPENCODE_EXPLAIN_SKILLS_DIR" "$GEMINI_EXPLAIN_SKILLS_DIR"; do
    if [ -f "$d/SKILL.md" ] && [ -x "$d/explain.sh" ]; then
      ok "$(printf '%s' "$d" | sed "s|$HOME|~|")/{SKILL.md,explain.sh}"
    else
      warn "missing or not executable: $d/{SKILL.md,explain.sh}"; FAIL=1
    fi
  done
  if bash -n "$PREFIX/skills/explain/explain.sh" 2>/dev/null; then
    ok "explain.sh parses"
  else
    warn "explain.sh failed to parse"; FAIL=1
  fi
fi
if [ "$SKIP_REVIEW" -eq 0 ]; then
  for d in "$PREFIX/skills/opsx-review" "$CURSOR_REVIEW_SKILLS_DIR" "$AGENTS_REVIEW_SKILLS_DIR" \
           "$CODEX_REVIEW_SKILLS_DIR" "$OPENCODE_REVIEW_SKILLS_DIR" "$GEMINI_REVIEW_SKILLS_DIR"; do
    if [ -f "$d/SKILL.md" ] && [ -x "$d/opsx-review.sh" ]; then
      ok "$(printf '%s' "$d" | sed "s|$HOME|~|")/{SKILL.md,opsx-review.sh}"
    else
      warn "missing or not executable: $d/{SKILL.md,opsx-review.sh}"; FAIL=1
    fi
  done
  if bash -n "$PREFIX/skills/opsx-review/opsx-review.sh" 2>/dev/null; then
    ok "opsx-review.sh parses"
  else
    warn "opsx-review.sh failed to parse"; FAIL=1
  fi
fi
if [ "$SKIP_PR" -eq 0 ]; then
  for d in "$PREFIX/skills/opsx-pr" "$CURSOR_PR_SKILLS_DIR" "$AGENTS_PR_SKILLS_DIR" \
           "$CODEX_PR_SKILLS_DIR" "$OPENCODE_PR_SKILLS_DIR" "$GEMINI_PR_SKILLS_DIR"; do
    if [ -f "$d/SKILL.md" ] && [ -x "$d/pr.sh" ]; then
      ok "$(printf '%s' "$d" | sed "s|$HOME|~|")/{SKILL.md,pr.sh}"
    else
      warn "missing or not executable: $d/{SKILL.md,pr.sh}"; FAIL=1
    fi
  done
  if bash -n "$PREFIX/skills/opsx-pr/pr.sh" 2>/dev/null; then
    ok "pr.sh parses"
  else
    warn "pr.sh failed to parse"; FAIL=1
  fi
fi
if [ "$SKIP_TASK" -eq 0 ]; then
  for d in "$PREFIX/skills/opsx-task" "$CURSOR_TASK_SKILLS_DIR" "$AGENTS_TASK_SKILLS_DIR" \
           "$CODEX_TASK_SKILLS_DIR" "$OPENCODE_TASK_SKILLS_DIR" "$GEMINI_TASK_SKILLS_DIR"; do
    if [ -f "$d/SKILL.md" ] && [ -x "$d/opsx-task.sh" ]; then
      ok "$(printf '%s' "$d" | sed "s|$HOME|~|")/{SKILL.md,opsx-task.sh}"
    else
      warn "missing or not executable: $d/{SKILL.md,opsx-task.sh}"; FAIL=1
    fi
  done
  if bash -n "$PREFIX/skills/opsx-task/opsx-task.sh" 2>/dev/null; then
    ok "opsx-task.sh parses"
  else
    warn "opsx-task.sh failed to parse"; FAIL=1
  fi
fi
if [ "$SKIP_INIT" -eq 0 ]; then
  for d in "$PREFIX/skills/opsx-init" "$CURSOR_INIT_SKILLS_DIR" "$AGENTS_INIT_SKILLS_DIR" \
           "$CODEX_INIT_SKILLS_DIR" "$OPENCODE_INIT_SKILLS_DIR" "$GEMINI_INIT_SKILLS_DIR"; do
    if [ -f "$d/SKILL.md" ] && [ -x "$d/opsx-init.sh" ]; then
      ok "$(printf '%s' "$d" | sed "s|$HOME|~|")/{SKILL.md,opsx-init.sh}"
    else
      warn "missing or not executable: $d/{SKILL.md,opsx-init.sh}"; FAIL=1
    fi
  done
  if bash -n "$PREFIX/skills/opsx-init/opsx-init.sh" 2>/dev/null; then
    ok "opsx-init.sh parses"
  else
    warn "opsx-init.sh failed to parse"; FAIL=1
  fi
  if [ -x "$OPSX_BIN" ] && grep -qxF "$OPSX_LAUNCHER_MARK" "$OPSX_BIN" 2>/dev/null; then
    ok "$(printf '%s' "$OPSX_BIN" | sed "s|$HOME|~|")"
  else
    warn "opsx launcher not installed at $OPSX_BIN"
  fi
fi
if [ -n "$EXPOSE_DOMAIN" ]; then
  for d in "$PREFIX/skills/expose" "$CURSOR_EXPOSE_SKILLS_DIR" "$AGENTS_EXPOSE_SKILLS_DIR" \
           "$CODEX_EXPOSE_SKILLS_DIR" "$OPENCODE_EXPOSE_SKILLS_DIR" "$GEMINI_EXPOSE_SKILLS_DIR"; do
    if [ -f "$d/SKILL.md" ] && [ -x "$d/expose.sh" ]; then
      ok "$(tilde "$d")/{SKILL.md,expose.sh}"
    else
      warn "missing or not executable: $d/{SKILL.md,expose.sh}"; FAIL=1
    fi
  done
  if bash -n "$PREFIX/skills/expose/expose.sh" 2>/dev/null; then
    ok "expose.sh parses"
  else
    warn "expose.sh failed to parse"; FAIL=1
  fi
  if [ -f "$EXPOSE_ENV" ] && [ "$(file_mode "$EXPOSE_ENV")" = 600 ]; then
    ok "$(tilde "$EXPOSE_ENV") (mode 600)"
  else
    warn "$EXPOSE_ENV missing or not mode 600"; FAIL=1
  fi
  if [ -f "$EXPOSE_CADDY_JSON" ]; then
    ok "$(tilde "$EXPOSE_CADDY_JSON")"
  else
    warn "missing: $EXPOSE_CADDY_JSON"; FAIL=1
  fi
fi
if [ "$SKIP_NOTIFY" -eq 0 ]; then
  for d in "$PREFIX/skills/opsx-run" "$CURSOR_SKILLS_DIR" "$AGENTS_SKILLS_DIR" \
           "$CODEX_SKILLS_DIR" "$OPENCODE_SKILLS_DIR" "$GEMINI_SKILLS_DIR"; do
    [ -x "$d/opsx-notify.sh" ] || { warn "opsx-notify.sh is missing or not executable in $d"; FAIL=1; }
  done
  if bash -n "$PREFIX/skills/opsx-run/opsx-notify.sh" 2>/dev/null; then
    ok "opsx-notify.sh parses"
  else
    warn "opsx-notify.sh failed to parse"; FAIL=1
  fi
  if [ -f "$CLAUDE_SETTINGS" ] && grep -q 'opsx-notify.sh hook claude-stop' "$CLAUDE_SETTINGS" 2>/dev/null; then
    ok "notify hooks in $(tilde "$CLAUDE_SETTINGS")"
  else
    warn "notify hooks missing in $CLAUDE_SETTINGS"
  fi
  if [ "$NOTIFY_READY" -eq 1 ]; then
    if [ "$(file_mode "$NOTIFY_ENV")" = 600 ]; then
      ok "$(tilde "$NOTIFY_ENV") (mode 600)"
    else
      warn "$NOTIFY_ENV is not mode 600"; FAIL=1
    fi
  fi
fi
for sh in opsx-window.sh opsx-merge.sh opsx-land.sh opsx-eval.sh opsx-preview.sh opsx-sessions.sh; do
  [ -x "$PREFIX/skills/opsx-run/$sh" ] || { warn "$sh is not executable (Claude)"; FAIL=1; }
  [ -x "$CURSOR_SKILLS_DIR/$sh" ] || { warn "$sh is not executable (Cursor)"; FAIL=1; }
  [ -x "$AGENTS_SKILLS_DIR/$sh" ] || { warn "$sh is not executable (Codex ~/.agents)"; FAIL=1; }
  [ -x "$CODEX_SKILLS_DIR/$sh" ] || { warn "$sh is not executable (Codex home)"; FAIL=1; }
  [ -x "$OPENCODE_SKILLS_DIR/$sh" ] || { warn "$sh is not executable (OpenCode)"; FAIL=1; }
  [ -x "$GEMINI_SKILLS_DIR/$sh" ] || { warn "$sh is not executable (Gemini CLI)"; FAIL=1; }
  if bash -n "$PREFIX/skills/opsx-run/$sh" 2>/dev/null; then
    ok "$sh parses"
  else
    warn "$sh failed to parse"; FAIL=1
  fi
done
if [ "$SKIP_MCP" -eq 0 ]; then
  for f in "$GEMINI_SETTINGS" "$CODEX_CONFIG" "$OPENCODE_CONFIG"; do
    if [ -f "$f" ] && grep -q 'browser-use' "$f" 2>/dev/null; then
      ok "browser-use MCP in $(printf '%s' "$f" | sed "s|$HOME|~|")"
    else
      warn "browser-use MCP missing in $f"
    fi
  done
fi
if [ "$SKIP_RESTORE" -eq 0 ]; then
  if grep -q 'opsx-sessions.sh' "$PREFIX/settings.json" 2>/dev/null; then
    ok "session restore SessionStart hook in $(tilde "$PREFIX/settings.json")"
  elif ! settings_json_ok "$PREFIX/settings.json"; then
    warn "session restore SessionStart hook missing: $PREFIX/settings.json is not valid JSON"
  else
    warn "session restore SessionStart hook missing in $PREFIX/settings.json"; FAIL=1
  fi
  if [ -f "$TMUX_CONF" ] && grep -qxF "$RESTORE_BLOCK_START" "$TMUX_CONF" 2>/dev/null; then
    ok "session restore block in $(tilde "$TMUX_CONF")"
  else
    note "no session restore block in $(tilde "$TMUX_CONF") — add the lines printed above for automatic restores"
  fi
fi
[ "$FAIL" -eq 0 ] || die "installation finished with problems — see above."
info ""

info "${G}${B}Done.${N}"
info ""
info "${B}Next steps${N}"
if [ "$SKIP_INIT" -eq 0 ]; then
  info "  1. In a project:   ${B}opsx init${N}  (or ${B}/opsx-init${N} in your agent CLI to also write the OpenSpec context)"
else
  info "  1. In a project:   ${B}openspec init --tools none${N}"
fi
info "  2. Restart your agent CLI (Claude, Cursor, Codex, OpenCode, or Gemini) so it picks up the skill"
info "  3. Propose a change:  ${B}/opsx:propose \"add rate limiting\"${N}"
info "  4. From inside tmux:  ${B}/opsx-run add-rate-limiting${N}"
[ "$SKIP_FORK" -eq 1 ] || info "  5. Side questions in a read-only pane:  ${B}/fork \"where are retries handled?\"${N}"
[ -z "$EXPOSE_DOMAIN" ] || info "  6. Publish a local port (after the proxy is running):  ${B}/expose 3000${N}  ->  https://3000--<project>.$EXPOSE_DOMAIN"
[ "$NOTIFY_READY" -eq 0 ] || notify_setup_lines
info ""
[ -n "${TMUX:-}" ] || info "  ${Y}Note:${N} /opsx-run must be run from inside a tmux session."
