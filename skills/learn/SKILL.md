---
name: learn
description: "Save a procedure learned in this project as a project skill in <repo>/.opsx/skills/<name>/, visible to Claude Code, Cursor CLI, Codex CLI, OpenCode and Gemini CLI through learned-<name> links. Use after finishing a task that taught a new, verified, repeatable multi-step procedure specific to this project (re-run a proof, regenerate a fixture, query a requirements document), to update an existing learned skill instead of adding a duplicate, and when the user asks to list, remove, re-link or keep learned skills private (git-ignore them)."
---

# learn

Turn a procedure you worked out in this project into a **project skill** that every coding agent finds on its own next time. Facts and preferences go to the `memory` skill; **procedures** (how to do something here, step by step) go here.

All work goes through the script next to this file:

```bash
L="$(dirname "<path of this SKILL.md>")/learn.sh"   # e.g. ~/.claude/skills/learn/learn.sh
"$L" root            # the project root: the main checkout, never a worktree
"$L" list            # existing learned skills: name, description, linked CLI folders
"$L" save <name>     # store a SKILL.md read from stdin, and link it for every CLI
"$L" sync            # recreate missing links, drop dangling learned-* links
"$L" remove <name>   # delete a skill and its links
"$L" ignore          # only when the user asks: git-ignore learned skills
```

## When to save (the bar)

After you finish a task, check whether it taught you a procedure that meets **all five**:

1. **multi-step**: more than one command or action, in an order that matters;
2. **specific to this project**: its paths, services, data, scripts; not general knowledge of a tool;
3. **verified**: you ran it in this session and it worked;
4. **reusable**: likely to be needed again (by you, another agent, another CLI);
5. **not already covered**: no existing skill, README, AGENTS.md / CLAUDE.md, or learned skill already describes it.

If any part fails, do not save. A one-off fix, a guess, or a fact ("the staging DB is on port 5433") is not a skill; a fact or preference belongs in memory.

## Update instead of duplicating

Run `"$L" list` first. If a learned skill already covers the task, update it: read `<root>/.opsx/skills/<name>/SKILL.md`, merge what you learned (fix wrong steps, add the new case), and save it again under the **same name**. Saving an existing name replaces it. Create a new skill only for a different task.

## Writing the SKILL.md

```markdown
---
name: rerun-zone-proof
description: "Re-run the zone proof against the staging cluster and read its verdict. Use when the user asks to re-check, re-prove or re-run the zone proof, or after changing anything under proofs/zone/."
---

# Re-run the zone proof

1. `make -C proofs/zone build`
2. `KUBECONFIG=~/.kube/staging ./proofs/zone/run.sh --cluster staging`
3. The verdict is the last line of `proofs/zone/out/latest.log` (`PROVED` or `FAILED: <step>`).

Pitfalls: the run needs the VPN; without it step 2 hangs at "connecting".
```

- `description` (required): what it does **and when to use it**, with the words a user would say. Discovery depends on it.
- Body: concrete commands, paths and expected output, as you actually ran them; pitfalls you hit.
- `name`: anything; `learn.sh save` sets it to `learned-<name>`.
- **No secrets**: never write tokens, passwords, keys, cookies or private URLs with credentials. Refer to where they come from (`$CLOUDFLARE_API_TOKEN`, `~/.config/...`) instead.
- `<name>`: kebab-case `[a-z0-9-]`, at most 40 characters, naming the task (`regen-fixtures`, `query-requirements`).

Save it by piping the file into the script (never write into `.opsx/skills/` or create links by hand):

```bash
"$L" save rerun-zone-proof <<'EOF'
---
name: rerun-zone-proof
description: "..."
---
...
EOF
```

Exit 2 means the input was refused (empty, bad name, or no `description` in the frontmatter); fix it and save again.

## Announce it

Saving is automatic, like memory: do not ask first. Announce each save in **one line** naming the skill and its path, e.g.

> Saved project skill `learned-rerun-zone-proof` (`.opsx/skills/rerun-zone-proof/SKILL.md`).

## Where things live

- The one real copy: `<root>/.opsx/skills/<name>/SKILL.md`, where `<root>` is the main checkout (`learn.sh root`). Saving from a worktree `../wt-<change>` still writes to the main checkout, so the skill survives the worktree.
- Links, created by `learn.sh` only: `learned-<name>` in `<root>/.claude/skills/`, `.agents/skills/`, `.cursor/skills/` and `.gemini/skills/`, each a relative symlink to `../../.opsx/skills/<name>`. OpenCode reads `.claude/skills/` and `.agents/skills/`, so it needs no link of its own.
- Other entries in those folders (skills the project commits) are never touched.

## Keeping learned skills out of git

Do nothing to `.gitignore` on your own. When the user asks to keep learned skills private, run `"$L" ignore`: it adds both `.opsx/skills/` and `**/skills/learned-*` (ignoring only the store would commit links pointing nowhere).

## Read-only sessions

A read-only fork or review session cannot save; mention the procedure in your result so the parent session saves it.
