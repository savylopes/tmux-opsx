# Helpers for dev-container / opsx-preview container checks (sourced, not a
# check). Builds on preview.sh (scratch HOME, private tmux, fake expose.sh,
# repo `shop` + worktree wt-add-auth on branch opsx/add-auth) and adds a
# stateful FAKE docker on PATH that records every call as one JSON argv line in
# $DLOG. A real docker is never reachable: PATH is rebuilt without it.
. "$EVAL_ROOT/evals/_lib/preview.sh"
OPSX="$EVAL_ROOT/bin/opsx"
export OPSX_SKILLS_DIR="$EVAL_ROOT/skills"
export FAKE_DOCKER_DIR="$EVAL_TMP/fd" DLOG="$EVAL_TMP/fd/calls.jsonl"
mkdir -p "$FAKE_DOCKER_DIR/containers" "$FAKE_DOCKER_DIR/images"; : > "$DLOG"

# PATH = every dir on the old PATH, symlinked, minus docker; fake docker first.
SYSBIN="$EVAL_TMP/sysbin"; FAKEBIN="$EVAL_TMP/fakebin"; mkdir -p "$SYSBIN" "$FAKEBIN"
_oldifs=$IFS; IFS=:
for d in $PATH; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b=${f##*/}; [ "$b" = docker ] && continue
    [ -e "$SYSBIN/$b" ] || ln -s "$f" "$SYSBIN/$b" 2>/dev/null
  done
done
IFS=$_oldifs
cat > "$FAKEBIN/docker" <<'PY'
#!/usr/bin/env python3
# Fake docker (ops-eval): stateful, records argv, implements the subset needed.
import json, os, re, sys, subprocess
D = "@@FD@@"; a = sys.argv[1:]
with open("@@DLOG@@", "a") as f: f.write(json.dumps(a) + "\n")
cdir = D + "/containers"; idir = D + "/images"
def cpath(n): return cdir + "/" + n.replace("/", "_") + ".json"
def load(n):
    try: return json.load(open(cpath(n)))
    except Exception: return None
def sub():
    return a[0] if a else ""
VAL = {"--name","--entrypoint","-v","--volume","--label","-l","-e","--env","--network","--net","-u","--user","-w","--workdir","--mount","--hostname","-h","--cap-add","--add-host","--pid","--ipc","--restart","--env-file"}
s = sub()
if s in ("container","image","volume") and len(a) > 1:
    s2 = s + " " + a[1]; rest = a[2:]
else:
    s2 = s; rest = a[1:]
if s2 == "image inspect":
    sys.exit(0 if os.path.exists(idir + "/" + rest[-1].replace("/", "_").replace(":", "_")) else 1)
if s2 == "build":
    if os.environ.get("FAKE_DOCKER_FAIL_BUILD"): print("fake build failure", file=sys.stderr); sys.exit(1)
    tags = [rest[i+1] for i, x in enumerate(rest[:-1]) if x in ("-t", "--tag")]
    for t in tags: open(idir + "/" + t.replace("/", "_").replace(":", "_"), "w").write("1")
    sys.exit(0)
if s2 == "run":
    name = None; labels = {}; env = []; i = 0; detach = False
    while i < len(rest):
        x = rest[i]
        if x.startswith("-"):
            if "=" in x and x.startswith("--"):
                k, v = x.split("=", 1)
                if k == "--name": name = v
                if k == "--label": labels[v.split("=",1)[0]] = v.split("=",1)[1] if "=" in v else ""
                if k == "--env": env.append(v)
                i += 1; continue
            if x in ("-d", "--detach"): detach = True
            if x in VAL:
                v = rest[i+1]
                if x == "--name": name = v
                if x in ("--label", "-l"): labels[v.split("=",1)[0]] = v.split("=",1)[1] if "=" in v else ""
                if x in ("-e", "--env"): env.append(v)
                i += 2; continue
            i += 1; continue
        break
    image = rest[i] if i < len(rest) else ""
    cmd = rest[i+1:]
    if os.environ.get("FAKE_DOCKER_FAIL_RUN"): print("fake run failure", file=sys.stderr); sys.exit(125)
    if name and not detach:
        json.dump({"name": name, "image": image, "labels": labels}, open(cpath(name), "w"))
    if name and detach:
        json.dump({"name": name, "image": image, "labels": labels}, open(cpath(name), "w"))
        print("f" * 64); sys.exit(0)
    # foreground run (preview): serve $PORT on loopback until killed
    port = [e.split("=",1)[1] for e in env if e.startswith("PORT=")]
    if port:
        os.execvp("python3", ["python3", "-m", "http.server", port[0], "--bind", "127.0.0.1"])
    sys.exit(0)
if s2 == "exec":
    i = 0; user = ""
    while i < len(rest):
        x = rest[i]
        if x.startswith("-"):
            if x in ("-u","--user","-w","--workdir","-e","--env"):
                if x in ("-u","--user"): user = rest[i+1]
                i += 2; continue
            i += 1; continue
        break
    name = rest[i]; cmd = rest[i+1:]
    if load(name) is None: print("Error: No such container: " + name, file=sys.stderr); sys.exit(1)
    m = os.environ.get("FAKE_DOCKER_FAIL_EXEC_MATCH")
    if m and any(m in w for w in cmd): print("fake exec failure", file=sys.stderr); sys.exit(1)
    c = os.environ.get("FAKE_DOCKER_EXIT_CMD")
    if c and cmd and cmd[0] == c: sys.exit(int(os.environ.get("FAKE_DOCKER_EXIT", "0")))
    sys.exit(0)
if s2 == "container inspect":
    fmt = None; names = []; i = 0
    while i < len(rest):
        if rest[i] in ("-f", "--format"): fmt = rest[i+1]; i += 2; continue
        names.append(rest[i]); i += 1
    c = load(names[-1]) if names else None
    if c is None: print("Error: No such container", file=sys.stderr); sys.exit(1)
    if fmt:
        o = fmt
        o = re.sub(r'\{\{index \.Config\.Labels "([^"]+)"\}\}', lambda m: c["labels"].get(m.group(1), ""), o)
        o = o.replace("{{.State.Running}}", "true").replace("{{.State.Status}}", "running").replace("{{.Config.Image}}", c["image"]).replace("{{.Name}}", "/" + c["name"])
        print(o)
    sys.exit(0)
if s2 == "rm":
    rc = 0
    if os.environ.get("FAKE_DOCKER_FAIL_RM"): print("fake rm failure", file=sys.stderr); sys.exit(1)
    for n in [x for x in rest if not x.startswith("-")]:
        if load(n) is None: print("Error: No such container: " + n, file=sys.stderr); rc = 1
        else: os.remove(cpath(n))
    sys.exit(rc)
if s2 in ("start", "stop", "kill"):
    sys.exit(0)
if s2 in ("ps", "container ls"):
    flt = [rest[i+1] for i, x in enumerate(rest[:-1]) if x in ("--filter", "-f")]
    for fn in sorted(os.listdir(cdir)):
        c = json.load(open(cdir + "/" + fn)); ok = True
        for f in flt:
            if f.startswith("label="):
                k, _, v = f[6:].partition("=")
                if k not in c["labels"] or (v and c["labels"][k] != v): ok = False
            if f.startswith("name=") and f[5:] not in c["name"]: ok = False
        if ok: print(c["name"])
    sys.exit(0)
sys.exit(0)
PY
sed -i "s|@@FD@@|$FAKE_DOCKER_DIR|; s|@@DLOG@@|$DLOG|" "$FAKEBIN/docker"
chmod +x "$FAKEBIN/docker"
export PATH="$FAKEBIN:$SYSBIN"

# ---- helpers -----------------------------------------------------------
# dq <subcommand words...>: print the recorded docker calls (JSON argv lines)
# whose leading words equal the given ones.
dq() { python3 -I - "$DLOG" "$@" <<'PY'
import json, sys
log = sys.argv[1]; pre = sys.argv[2:]
for l in open(log):
    a = json.loads(l)
    if a[:len(pre)] == pre: print(json.dumps(a))
PY
}
dcount() { dq "$@" | grep -c . ; }
# devyaml <dir> lines...: write .opsx/dev.yaml
devyaml() { local d=$1; shift; mkdir -p "$d/.opsx"; printf '%s\n' "$@" > "$d/.opsx/dev.yaml"; }
# od <args...>: run `opsx dev args` in ${OD_CWD:-$WT}; sets out, rc
od() { out=$(cd "${OD_CWD:-$WT}" && "$OPSX" dev "$@" </dev/null 2>&1); rc=$?; }
cnames() { ls "$FAKE_DOCKER_DIR/containers" 2>/dev/null | sed 's/\.json$//'; }
