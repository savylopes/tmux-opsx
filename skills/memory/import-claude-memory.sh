#!/usr/bin/env bash
# One-time import of Claude Code's per-project memories into the shared
# ~/.agents/memory/ store. Idempotent: exits immediately once
# <store>/.claude-import-done exists. Never modifies Claude's original files.
#
# Usage: import-claude-memory.sh <store>

set -uo pipefail

STORE=${1:?usage: import-claude-memory.sh <store>}
CLAUDE_HOME=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
MARKER="$STORE/.claude-import-done"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=""; Y=""; D=""; N=""
fi
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
note() { printf '    %s%s%s\n' "$D" "$*" "$N"; }

if [ -f "$MARKER" ]; then
  note "already imported ($(cat "$MARKER" 2>/dev/null))"
  exit 0
fi

mkdir -p "$STORE/user" "$STORE/feedback" "$STORE/project" "$STORE/reference"

if [ ! -d "$CLAUDE_HOME/projects" ]; then
  note "no $CLAUDE_HOME/projects — nothing to import"
  printf '%s: imported 0 entries\n' "$(date +%Y-%m-%d)" > "$MARKER"
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  warn "python3 not found — skipping Claude memory import"
  note "re-run once python3 is available to import ${CLAUDE_HOME}/projects/*/memory/"
  exit 0
fi

CLAUDE_HOME="$CLAUDE_HOME" STORE="$STORE" python3 <<'PY'
import glob
import os
import re
import subprocess
import sys
from datetime import date

claude_home = os.environ["CLAUDE_HOME"]
store = os.environ["STORE"]

GREEN = "\033[32m" if sys.stdout.isatty() and not os.environ.get("NO_COLOR") else ""
YELLOW = "\033[33m" if sys.stdout.isatty() and not os.environ.get("NO_COLOR") else ""
DIM = "\033[2m" if sys.stdout.isatty() and not os.environ.get("NO_COLOR") else ""
RESET = "\033[0m" if (GREEN or YELLOW or DIM) else ""


def ok(msg):
    print(f"  {GREEN}✓{RESET} {msg}")


def warn(msg):
    print(f"  {YELLOW}!{RESET} {msg}")


def note(msg):
    print(f"    {DIM}{msg}{RESET}")


def parse_org_repo(url):
    url = (url or "").strip()
    if not url:
        return None
    url = re.sub(r"\.git$", "", url)
    m = re.search(r"[:/]([^/:]+/[^/:]+)$", url)
    return m.group(1) if m else None


def project_tag_for(path):
    try:
        remote = subprocess.run(
            ["git", "-C", path, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5,
        )
        if remote.returncode == 0:
            tag = parse_org_repo(remote.stdout)
            if tag:
                return tag
    except Exception:
        pass
    return os.path.basename(path.rstrip("/")) or path


def decode_project_dir(encoded_name):
    """Walk the filesystem from / to turn a Claude-encoded folder name (dashes
    standing in for /) back into a real path, picking the longest run of
    dash-separated tokens that exists as a subfolder at each level. Returns
    (resolved_path_or_None, leftover_tag_or_None)."""
    tokens = encoded_name.split("-")
    if tokens and tokens[0] == "":
        tokens = tokens[1:]
    current = os.sep
    i = 0
    n = len(tokens)
    while i < n:
        matched = False
        for j in range(n, i, -1):
            candidate = "-".join(tokens[i:j])
            candidate_path = os.path.join(current, candidate)
            if os.path.isdir(candidate_path):
                current = candidate_path
                i = j
                matched = True
                break
        if not matched:
            break
    if i == n:
        return current, None
    return None, "-".join(tokens[i:])


FRONTMATTER_RE = re.compile(r"^---\n(.*?\n)---\n(.*)$", re.S)


def parse_source_file(text):
    m = FRONTMATTER_RE.match(text)
    if not m:
        return None
    fm_block, body = m.group(1), m.group(2)
    top = {}
    metadata = {}
    in_metadata = False
    for line in fm_block.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            in_metadata = False
            if ":" in line:
                k, _, v = line.partition(":")
                k = k.strip()
                v = v.strip()
                top[k] = v
                if k == "metadata":
                    in_metadata = True
        elif in_metadata and ":" in line:
            k, _, v = line.strip().partition(":")
            metadata[k.strip()] = v.strip()
    return {
        "name": top.get("name", "").strip(),
        "description": top.get("description", "").strip(),
        "type": metadata.get("type", "").strip(),
        "source_id": metadata.get("originSessionId", "").strip(),
        "body": body,
    }


def existing_sources(store):
    sources = set()
    for path in glob.glob(os.path.join(store, "*", "*.md")):
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        m = re.search(r"^source:\s*(.+)$", text, re.M)
        if m:
            sources.add(m.group(1).strip())
    return sources


def title_from_name(name):
    words = name.replace("-", " ")
    return words[:1].upper() + words[1:] if words else words


def hook_from_description(description):
    hook = description.strip()
    if len(hook) >= 2 and hook[0] == '"' and hook[-1] == '"':
        hook = hook[1:-1]
    return hook


memory_dirs = sorted(glob.glob(os.path.join(claude_home, "projects", "*", "memory")))
sources = existing_sources(store)
index_lines = []
imported = skipped = warned = 0

for memory_dir in memory_dirs:
    project_dir_name = os.path.basename(os.path.dirname(memory_dir))
    resolved, leftover = decode_project_dir(project_dir_name)
    tag = project_tag_for(resolved) if resolved else leftover
    files = sorted(
        f for f in glob.glob(os.path.join(memory_dir, "*.md"))
        if os.path.basename(f) != "MEMORY.md"
    )
    if not files:
        continue

    folder_imported = folder_skipped = folder_warned = 0
    for path in files:
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        parsed = parse_source_file(text)
        if not parsed or not parsed["name"]:
            warn(f"could not parse frontmatter in {path} — skipping")
            folder_warned += 1
            warned += 1
            continue

        name = parsed["name"]
        mtype = parsed["type"]
        if not mtype:
            warn(f"{path}: no metadata.type — defaulting to 'project'")
            mtype = "project"
            folder_warned += 1
            warned += 1

        source_val = f"claude:{parsed['source_id']}" if parsed["source_id"] else None
        if source_val and source_val in sources:
            folder_skipped += 1
            skipped += 1
            continue

        type_dir = os.path.join(store, mtype)
        os.makedirs(type_dir, exist_ok=True)
        dest = os.path.join(type_dir, f"{name}.md")

        new_lines = ["---", f"name: {name}", f"description: {parsed['description']}", f"type: {mtype}"]
        if tag:
            new_lines.append(f"project: {tag}")
        if source_val:
            new_lines.append(f"source: {source_val}")
        new_lines.append("---")
        new_content = "\n".join(new_lines) + "\n" + parsed["body"]

        if os.path.exists(dest):
            try:
                existing_content = open(dest, encoding="utf-8").read()
            except OSError:
                existing_content = None
            if existing_content != new_content:
                slug = (tag or "unknown").replace("/", "-")
                dest = os.path.join(type_dir, f"{slug}--{name}.md")
            else:
                folder_skipped += 1
                skipped += 1
                continue

        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(new_content)

        rel = os.path.relpath(dest, store)
        title = title_from_name(os.path.splitext(os.path.basename(dest))[0])
        hook = hook_from_description(parsed["description"])
        line = f"- [{title}]({rel}) · {mtype} · {tag or 'global'} — {hook}"
        if len(line) > 200:
            line = line[:199] + "…"
        index_lines.append(line)
        folder_imported += 1
        imported += 1

    ok(f"{project_dir_name} -> project: {tag or 'global'} "
       f"(imported {folder_imported}, skipped {folder_skipped}, warnings {folder_warned})")

if index_lines:
    memory_index = os.path.join(store, "MEMORY.md")
    with open(memory_index, "a", encoding="utf-8") as fh:
        fh.write("\n".join(index_lines) + "\n")

marker = os.path.join(store, ".claude-import-done")
with open(marker, "w", encoding="utf-8") as fh:
    fh.write(f"{date.today().isoformat()}: imported {imported} entries\n")

note(f"total: imported {imported}, skipped {skipped}, warnings {warned}")
PY
