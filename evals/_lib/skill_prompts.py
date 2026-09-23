"""Helpers for prompt-contract checks: extract the window prompt templates that
skills/opsx-run/SKILL.md tells the /opsx-run caller to send. Not a check."""
import os, re, sys

SKILL = os.path.join(os.environ["EVAL_ROOT"], "skills", "opsx-run", "SKILL.md")


def text():
    with open(SKILL, encoding="utf-8") as f:
        return f.read()


def prompt(name):
    """Lines (without '> ') of the quoted prompt that follows a '**<name>**' heading line."""
    lines = text().splitlines()
    for i, l in enumerate(lines):
        if re.match(r"^\*\*%s\*\*(\s|$)" % re.escape(name), l):
            out, started = [], False
            for m in lines[i + 1:]:
                if m.startswith(">"):
                    started = True
                    out.append(m.lstrip(">").strip())
                elif started:
                    break
                elif m.strip():
                    break
            if out:
                return out
    fail("no '**%s**' prompt template found in %s" % (name, SKILL))


def steps(lines):
    """{n: text} for numbered steps '1. ...' in a prompt."""
    st = {}
    for l in lines:
        m = re.match(r"^(\d+)\.\s+(.*)$", l)
        if m:
            st[int(m.group(1))] = m.group(2)
    return st


def action_row(action):
    for l in text().splitlines():
        if re.match(r"^\|\s*`%s`" % re.escape(action), l):
            return l
    fail("no Actions-table row for `%s`" % action)


def first_step(st, pattern):
    for n in sorted(st):
        if re.search(pattern, st[n], re.I):
            return n
    return None


def goto_targets(s):
    return [int(x) for x in re.findall(r"go to step (\d+)", s, re.I)]


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def show(lines):
    print("\n".join(lines))
