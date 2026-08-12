#!/usr/bin/env bash
# tmux-opsx installer — macOS and Linux.
#
# Installs:
#   1. the OpenSpec CLI            (npm -g @fission-ai/openspec)
#   2. the /opsx:* slash commands  -> ~/.claude/commands/opsx/
#   3. the ops-applier subagent    -> ~/.claude/agents/opsx-applier.md
#   4. the /opsx-run skill         -> ~/.claude/skills/opsx-run/
#      (opsx-window.sh + opsx-land.sh)
#
# Usage: ./install.sh [options]
#   --prefix <dir>     Claude config dir (default: ~/.claude, or $CLAUDE_CONFIG_DIR)
#   --skip-openspec    Don't install/upgrade the OpenSpec CLI
#   --skip-commands    Don't install the global /opsx:* commands
#   --no-backup        Overwrite existing files without keeping a .bak copy
#   --uninstall        Remove everything this script installs (except the CLI)
#   -h, --help         Show this help
#
# Run as your normal user — sudo is not needed. If openspec is already installed
# under /usr/local but that prefix is not writable, the upgrade is skipped and
# the skill files are still installed.

set -uo pipefail

EXPLICIT_PREFIX=0
SKIP_OPENSPEC=0
SKIP_COMMANDS=0
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
    --skip-commands) SKIP_COMMANDS=1; shift ;;
    --no-backup)     BACKUP=0; shift ;;
    --uninstall)     UNINSTALL=1; shift ;;
    -h|--help)       usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# Skill files belong in the invoking user's home. sudo drops ~/.local/bin from
# PATH and sets HOME=/root, which makes both the prefix and CLI checks wrong.
if [ "$(id -u)" -eq 0 ]; then
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6-)
    REAL_HOME=${REAL_HOME:-/home/$SUDO_USER}
    export HOME="$REAL_HOME"
    for d in "$HOME/.local/bin" "$HOME/bin"; do
      [ -d "$d" ] && PATH="$d:$PATH"
    done
    export PATH
  else
    die "do not run this installer as root — run ./install.sh as your normal user (sudo is not needed)."
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
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
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

# Copy a file, keeping a timestamped backup of anything it replaces.
install_file() {
  local src=$1 dest=$2
  mkdir -p "$(dirname "$dest")" || die "cannot create $(dirname "$dest")"
  if [ -e "$dest" ] && [ "$BACKUP" -eq 1 ]; then
    if ! cmp -s "$src" "$dest"; then
      local bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
      cp "$dest" "$bak" || die "cannot back up $dest"
      note "backed up existing $(basename "$dest") -> $(basename "$bak")"
    fi
  fi
  cp "$src" "$dest" || die "cannot write $dest"
}

# ---------- uninstall ----------
if [ "$UNINSTALL" -eq 1 ]; then
  step "Uninstalling tmux-opsx from $PREFIX"
  rm -rf "$PREFIX/skills/opsx-run" && ok "removed skills/opsx-run"
  rm -f  "$PREFIX/agents/opsx-applier.md" && ok "removed agents/opsx-applier.md"
  rm -rf "$PREFIX/commands/opsx" && ok "removed commands/opsx"
  info ""
  info "The OpenSpec CLI was left installed. Remove it with:"
  info "  npm uninstall -g $NPM_PKG"
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
  warn "claude CLI not found — optional if you use Cursor CLI instead"
  note "install: https://claude.com/claude-code"
fi

if have agent; then
  ok "agent $(agent --version 2>/dev/null | head -1)"
else
  warn "agent CLI not found — optional if you use Claude Code instead"
  note "install: https://cursor.com/docs/cli"
fi

if ! have claude && ! have agent; then
  warn "neither claude nor agent is on PATH — required, each tmux window runs one of them"
  MISSING=1
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

# ---------- 3. global /opsx:* commands ----------
if [ "$SKIP_COMMANDS" -eq 1 ]; then
  step "Skipping global /opsx:* commands (--skip-commands)"
else
  step "Installing the global /opsx:* commands"
  if ! have openspec; then
    warn "openspec not on PATH — skipping (re-run without --skip-openspec)"
  else
    # Generate the commands with the installed CLI rather than vendoring copies,
    # so they always match the OpenSpec version actually in use.
    TMPD=$(mktemp -d 2>/dev/null || mktemp -d -t tmuxopsx)
    [ -n "$TMPD" ] && [ -d "$TMPD" ] || die "could not create a temp directory"
    if (cd "$TMPD" && openspec init --tools claude . >/dev/null 2>&1) \
       && [ -d "$TMPD/.claude/commands/opsx" ]; then
      count=0
      for f in "$TMPD"/.claude/commands/opsx/*.md; do
        [ -e "$f" ] || continue
        install_file "$f" "$PREFIX/commands/opsx/$(basename "$f")"
        count=$((count + 1))
      done
      ok "$count commands -> $PREFIX/commands/opsx/"
      note "available everywhere: /opsx:propose /opsx:apply /opsx:archive /opsx:explore"
      note "a project's own .claude/commands/opsx/ still takes precedence"
    else
      warn "'openspec init' did not produce commands — skipping"
      note "you can copy them from any OpenSpec project's .claude/commands/opsx/"
    fi
    rm -rf "$TMPD"
  fi
fi
info ""

# ---------- 4. ops-applier subagent ----------
step "Installing the ops-applier subagent"
[ -f "$SRC/agents/opsx-applier.md" ] || die "missing $SRC/agents/opsx-applier.md — run this script from the repo checkout"
install_file "$SRC/agents/opsx-applier.md" "$PREFIX/agents/opsx-applier.md"
ok "ops-applier -> $PREFIX/agents/opsx-applier.md"
note "spawns a team of workers in isolated git worktrees to apply changes"
info ""

# ---------- 5. /opsx-run skill ----------
step "Installing the /opsx-run skill"
[ -f "$SRC/skills/opsx-run/SKILL.md" ] || die "missing $SRC/skills/opsx-run/SKILL.md — run this script from the repo checkout"
install_file "$SRC/skills/opsx-run/SKILL.md"       "$PREFIX/skills/opsx-run/SKILL.md"
install_file "$SRC/skills/opsx-run/opsx-window.sh" "$PREFIX/skills/opsx-run/opsx-window.sh"
install_file "$SRC/skills/opsx-run/opsx-land.sh"   "$PREFIX/skills/opsx-run/opsx-land.sh"
chmod +x "$PREFIX/skills/opsx-run/opsx-window.sh" || die "cannot chmod +x opsx-window.sh"
chmod +x "$PREFIX/skills/opsx-run/opsx-land.sh"   || die "cannot chmod +x opsx-land.sh"
ok "/opsx-run -> $PREFIX/skills/opsx-run/"
info ""

# ---------- verify ----------
step "Verifying"
FAIL=0
for f in "$PREFIX/skills/opsx-run/SKILL.md" \
         "$PREFIX/skills/opsx-run/opsx-window.sh" \
         "$PREFIX/skills/opsx-run/opsx-land.sh" \
         "$PREFIX/agents/opsx-applier.md"; do
  if [ -f "$f" ]; then ok "$(printf '%s' "$f" | sed "s|$HOME|~|")"; else warn "missing: $f"; FAIL=1; fi
done
for sh in opsx-window.sh opsx-land.sh; do
  [ -x "$PREFIX/skills/opsx-run/$sh" ] || { warn "$sh is not executable"; FAIL=1; }
  if bash -n "$PREFIX/skills/opsx-run/$sh" 2>/dev/null; then
    ok "$sh parses"
  else
    warn "$sh failed to parse"; FAIL=1
  fi
done
[ "$FAIL" -eq 0 ] || die "installation finished with problems — see above."
info ""

info "${G}${B}Done.${N}"
info ""
info "${B}Next steps${N}"
info "  1. In a project:   ${B}openspec init --tools claude${N}"
info "  2. Restart Claude Code so it picks up the new skill, agent and commands"
info "  3. Propose a change:  ${B}/opsx:propose \"add rate limiting\"${N}"
info "  4. From inside tmux:  ${B}/opsx-run add-rate-limiting${N}"
info ""
[ -n "${TMUX:-}" ] || info "  ${Y}Note:${N} /opsx-run must be run from inside a tmux session."
