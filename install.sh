#!/usr/bin/env bash
# tmux-opsx installer — macOS and Linux.
#
# Installs:
#   1. the OpenSpec CLI            (npm -g @fission-ai/openspec)
#   2. OpenSpec skills + /opsx:*   -> global dirs for Claude / Cursor / Codex / OpenCode / Gemini
#      (openspec-propose, openspec-apply-change, … plus slash commands)
#   3. Graphify CLI + /graphify    -> global dirs for Claude / Cursor / Codex / OpenCode / Gemini
#                                   -> ~/.agents/skills/graphify/
#   4. ops-applier + ops-qa + ops-reviewer + ops-security
#                                   -> ~/.claude/agents/opsx-{applier,qa,reviewer,security}.md
#                                   -> ~/.cursor/agents/opsx-{applier,qa,reviewer,security}.md
#                                   -> ~/.codex/agents/ops-{applier,qa,reviewer,security}.toml
#                                   -> ~/.config/opencode/agents/ops-{applier,qa,reviewer,security}.md
#                                   -> ~/.gemini/agents/opsx-{applier,qa,reviewer,security}.md
#   5. the /opsx-run skill         -> ~/.claude/skills/opsx-run/
#                                   -> ~/.cursor/skills/opsx-run/
#                                   -> ~/.agents/skills/opsx-run/   (Codex / Agent Skills)
#                                   -> ~/.codex/skills/opsx-run/    (Codex home)
#                                   -> ~/.config/opencode/skills/opsx-run/  (OpenCode)
#                                   -> ~/.gemini/skills/opsx-run/  (Gemini CLI)
#      (opsx-window.sh + opsx-merge.sh + opsx-land.sh)
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
SKIP_GRAPHIFY=0
SKIP_COMMANDS=0
SKIP_MCP=0
SKIP_MEMORY=0
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

# Install Graphify's packaged skill globally for Claude, Codex, OpenCode, Agent
# Skills. Cursor has no global `graphify install --platform cursor` (that writes
# a project rule), so copy the Claude skill tree into ~/.cursor/skills/graphify.
install_graphify_skills() {
  local p
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] || [ "$PREFIX" = "$HOME/.claude" ] || export CLAUDE_CONFIG_DIR=$PREFIX

  for p in claude codex opencode agents gemini; do
    if graphify install --platform "$p" >/dev/null 2>&1; then
      ok "graphify install --platform $p"
    else
      warn "graphify install --platform $p failed"
      return 1
    fi
  done

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
      local bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
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
CODEX_AGENTS_MD=$CODEX_HOME_DIR/AGENTS.md
OPENCODE_AGENTS_MD=$OPENCODE_CONFIG_DIR/AGENTS.md
GEMINI_MD=$GEMINI_HOME_DIR/GEMINI.md
if [ -f "$OPENCODE_CONFIG_DIR/opencode.jsonc" ]; then
  OPENCODE_CONFIG=$OPENCODE_CONFIG_DIR/opencode.jsonc
else
  OPENCODE_CONFIG=$OPENCODE_CONFIG_DIR/opencode.json
fi

# Copy every openspec-* skill folder from a generated tree into a global skills dir.
install_openspec_skills() {
  local src_skills=$1 dest_skills=$2 label=$3
  local d name count=0
  [ -d "$src_skills" ] || return 0
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
  chmod +x "$dest/opsx-window.sh" || die "cannot chmod +x $dest/opsx-window.sh"
  chmod +x "$dest/opsx-merge.sh"  || die "cannot chmod +x $dest/opsx-merge.sh"
  chmod +x "$dest/opsx-land.sh"   || die "cannot chmod +x $dest/opsx-land.sh"
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

MEMORY_BLOCK_START='<!-- tmux-opsx:memory:start -->'
MEMORY_BLOCK_END='<!-- tmux-opsx:memory:end -->'

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
  local dest=$1 tmp blockfile
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  blockfile=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  memory_instruction_block > "$blockfile"

  if [ ! -f "$dest" ]; then
    cp "$blockfile" "$tmp"
  elif grep -qF "$MEMORY_BLOCK_START" "$dest" 2>/dev/null; then
    awk -v start="$MEMORY_BLOCK_START" -v end="$MEMORY_BLOCK_END" -v blockfile="$blockfile" '
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
  rm -f "$blockfile"

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

# Remove the marked memory block (markers included) from an instructions file,
# leaving the rest of the file untouched.
remove_marked_block() {
  local dest=$1 tmp
  [ -f "$dest" ] || return 0
  grep -qF "$MEMORY_BLOCK_START" "$dest" 2>/dev/null || return 0
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  awk -v start="$MEMORY_BLOCK_START" -v end="$MEMORY_BLOCK_END" '
    $0 == start { skip=1; next }
    $0 == end { skip=0; next }
    skip==1 { next }
    { print }
  ' "$dest" > "$tmp"
  if [ "$BACKUP" -eq 1 ]; then
    cp "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  fi
  mv "$tmp" "$dest" || die "cannot write $dest"
  ok "removed memory block from $(printf '%s' "$dest" | sed "s|$HOME|~|")"
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

install_cursor_agent() {
  local src=$1 dest=$2 tmp desc name
  name=$(agent_frontmatter_name "$src")
  [ -n "$name" ] || name=$(basename "$dest" .md)
  desc=$(agent_frontmatter_desc "$src")
  [ -n "$desc" ] || desc="OpenSpec subagent"
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  {
    printf '%s\n' '---'
    printf 'name: %s\n' "$name"
    printf 'description: %s\n' "$desc"
    printf 'model: inherit\n'
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
  local src=$1 dest=$2 tmp desc
  desc=$(agent_frontmatter_desc "$src")
  [ -n "$desc" ] || desc="OpenSpec subagent"
  tmp=$(mktemp 2>/dev/null || mktemp -t tmuxopsx) || die "could not create a temp file"
  {
    printf '%s\n' '---'
    printf 'description: %s\n' "$desc"
    printf 'mode: subagent\n'
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
  local dest=$1 uvx=$2 tmp env_block=""
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
  local uvx env_export
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
  rm -rf "$PREFIX/skills/memory" && ok "removed skills/memory (Claude Code)"
  rm -rf "$CURSOR_MEMORY_SKILLS_DIR" && ok "removed ~/.cursor/skills/memory (Cursor CLI)"
  rm -rf "$AGENTS_MEMORY_SKILLS_DIR" && ok "removed ~/.agents/skills/memory (Agent Skills)"
  rm -rf "$CODEX_MEMORY_SKILLS_DIR" && ok "removed $CODEX_MEMORY_SKILLS_DIR (Codex)"
  rm -rf "$OPENCODE_MEMORY_SKILLS_DIR" && ok "removed ~/.config/opencode/skills/memory (OpenCode)"
  rm -rf "$GEMINI_MEMORY_SKILLS_DIR" && ok "removed ~/.gemini/skills/memory (Gemini CLI)"
  remove_marked_block "$PREFIX/CLAUDE.md"
  remove_marked_block "$CODEX_AGENTS_MD"
  remove_marked_block "$OPENCODE_AGENTS_MD"
  remove_marked_block "$GEMINI_MD"
  info ""
  info "The OpenSpec CLI was left installed. Remove it with:"
  info "  npm uninstall -g $NPM_PKG"
  info "The Graphify CLI was left installed. Remove it with:"
  info "  uv tool uninstall graphifyy"
  info "browser-use MCP entries in Gemini / Codex / OpenCode config were left in place."
  info "$MEMORY_STORE_DIR was left in place — your memories are never deleted."
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
      install_openspec_skills "$TMPD/.codex/skills" "$CODEX_OPENSPEC_SKILLS_DIR" "Codex"
      if [ "$AGENTS_OPENSPEC_SKILLS_DIR" != "$CODEX_OPENSPEC_SKILLS_DIR" ]; then
        install_openspec_skills "$TMPD/.codex/skills" "$AGENTS_OPENSPEC_SKILLS_DIR" "Agent Skills"
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

# ---------- 4. ops-applier + ops-qa + ops-reviewer + ops-security subagents ----------
step "Installing the ops-applier, ops-qa, ops-reviewer, and ops-security subagents"
[ -f "$SRC/agents/opsx-applier.md" ] || die "missing $SRC/agents/opsx-applier.md — run this script from the repo checkout"
[ -f "$SRC/agents/opsx-qa.md" ] || die "missing $SRC/agents/opsx-qa.md — run this script from the repo checkout"
[ -f "$SRC/agents/opsx-reviewer.md" ] || die "missing $SRC/agents/opsx-reviewer.md — run this script from the repo checkout"
[ -f "$SRC/agents/opsx-security.md" ] || die "missing $SRC/agents/opsx-security.md — run this script from the repo checkout"
install_file "$SRC/agents/opsx-applier.md" "$PREFIX/agents/opsx-applier.md"
ok "ops-applier -> $PREFIX/agents/opsx-applier.md (Claude Code)"
install_cursor_agent "$SRC/agents/opsx-applier.md" "$CURSOR_AGENTS_DIR/opsx-applier.md"
ok "ops-applier -> $CURSOR_AGENTS_DIR/opsx-applier.md (Cursor CLI)"
install_codex_agent "$SRC/agents/opsx-applier.md" "$CODEX_AGENTS_DIR/ops-applier.toml"
ok "ops-applier -> $CODEX_AGENTS_DIR/ops-applier.toml (Codex CLI)"
install_opencode_agent "$SRC/agents/opsx-applier.md" "$OPENCODE_AGENTS_DIR/ops-applier.md"
ok "ops-applier -> $OPENCODE_AGENTS_DIR/ops-applier.md (OpenCode)"
install_file "$SRC/agents/opsx-qa.md" "$PREFIX/agents/opsx-qa.md"
ok "ops-qa -> $PREFIX/agents/opsx-qa.md (Claude Code)"
install_cursor_agent "$SRC/agents/opsx-qa.md" "$CURSOR_AGENTS_DIR/opsx-qa.md"
ok "ops-qa -> $CURSOR_AGENTS_DIR/opsx-qa.md (Cursor CLI)"
install_codex_agent "$SRC/agents/opsx-qa.md" "$CODEX_AGENTS_DIR/ops-qa.toml"
ok "ops-qa -> $CODEX_AGENTS_DIR/ops-qa.toml (Codex CLI)"
install_opencode_agent "$SRC/agents/opsx-qa.md" "$OPENCODE_AGENTS_DIR/ops-qa.md"
ok "ops-qa -> $OPENCODE_AGENTS_DIR/ops-qa.md (OpenCode)"
install_file "$SRC/agents/opsx-applier.md" "$GEMINI_AGENTS_DIR/opsx-applier.md"
ok "ops-applier -> $GEMINI_AGENTS_DIR/opsx-applier.md (Gemini CLI)"
install_file "$SRC/agents/opsx-qa.md" "$GEMINI_AGENTS_DIR/opsx-qa.md"
ok "ops-qa -> $GEMINI_AGENTS_DIR/opsx-qa.md (Gemini CLI)"
install_file "$SRC/agents/opsx-reviewer.md" "$PREFIX/agents/opsx-reviewer.md"
ok "ops-reviewer -> $PREFIX/agents/opsx-reviewer.md (Claude Code)"
install_cursor_agent "$SRC/agents/opsx-reviewer.md" "$CURSOR_AGENTS_DIR/opsx-reviewer.md"
ok "ops-reviewer -> $CURSOR_AGENTS_DIR/opsx-reviewer.md (Cursor CLI)"
install_codex_agent "$SRC/agents/opsx-reviewer.md" "$CODEX_AGENTS_DIR/ops-reviewer.toml"
ok "ops-reviewer -> $CODEX_AGENTS_DIR/ops-reviewer.toml (Codex CLI)"
install_opencode_agent "$SRC/agents/opsx-reviewer.md" "$OPENCODE_AGENTS_DIR/ops-reviewer.md"
ok "ops-reviewer -> $OPENCODE_AGENTS_DIR/ops-reviewer.md (OpenCode)"
install_file "$SRC/agents/opsx-reviewer.md" "$GEMINI_AGENTS_DIR/opsx-reviewer.md"
ok "ops-reviewer -> $GEMINI_AGENTS_DIR/opsx-reviewer.md (Gemini CLI)"
install_file "$SRC/agents/opsx-security.md" "$PREFIX/agents/opsx-security.md"
ok "ops-security -> $PREFIX/agents/opsx-security.md (Claude Code)"
install_cursor_agent "$SRC/agents/opsx-security.md" "$CURSOR_AGENTS_DIR/opsx-security.md"
ok "ops-security -> $CURSOR_AGENTS_DIR/opsx-security.md (Cursor CLI)"
install_codex_agent "$SRC/agents/opsx-security.md" "$CODEX_AGENTS_DIR/ops-security.toml"
ok "ops-security -> $CODEX_AGENTS_DIR/ops-security.toml (Codex CLI)"
install_opencode_agent "$SRC/agents/opsx-security.md" "$OPENCODE_AGENTS_DIR/ops-security.md"
ok "ops-security -> $OPENCODE_AGENTS_DIR/ops-security.md (OpenCode)"
install_file "$SRC/agents/opsx-security.md" "$GEMINI_AGENTS_DIR/opsx-security.md"
ok "ops-security -> $GEMINI_AGENTS_DIR/opsx-security.md (Gemini CLI)"
note "applier implements in opsx/<change>; reviewer/security/qa verify after apply"
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

# ---------- verify ----------
step "Verifying"
FAIL=0
for f in "$PREFIX/skills/opsx-run/SKILL.md" \
         "$PREFIX/skills/opsx-run/opsx-window.sh" \
         "$PREFIX/skills/opsx-run/opsx-merge.sh" \
         "$PREFIX/skills/opsx-run/opsx-land.sh" \
         "$CURSOR_SKILLS_DIR/SKILL.md" \
         "$CURSOR_SKILLS_DIR/opsx-window.sh" \
         "$CURSOR_SKILLS_DIR/opsx-merge.sh" \
         "$CURSOR_SKILLS_DIR/opsx-land.sh" \
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
         "$GEMINI_AGENTS_DIR/opsx-security.md"; do
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
for sh in opsx-window.sh opsx-merge.sh opsx-land.sh; do
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
[ "$FAIL" -eq 0 ] || die "installation finished with problems — see above."
info ""

info "${G}${B}Done.${N}"
info ""
info "${B}Next steps${N}"
info "  1. In a project:   ${B}openspec init --tools claude${N}  (Claude Code)"
info "                     ${B}openspec init --tools cursor${N}  (Cursor CLI / IDE)"
info "  2. Restart your agent CLI (Claude, Cursor, Codex, OpenCode, or Gemini) so it picks up the skill"
info "  3. Propose a change:  ${B}/opsx:propose \"add rate limiting\"${N}"
info "  4. From inside tmux:  ${B}/opsx-run add-rate-limiting${N}"
info ""
[ -n "${TMUX:-}" ] || info "  ${Y}Note:${N} /opsx-run must be run from inside a tmux session."
