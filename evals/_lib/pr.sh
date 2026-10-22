# Shared helpers for pr-maintain checks: scratch git repo with a bare origin, a
# fake `gh` serving PR JSON from files, a logging wrapper around opsx-window.sh
# and a stub agent CLI. Sourced by checks; not a check itself.
PRSH="$EVAL_ROOT/skills/opsx-pr/pr.sh"
WINSH="$EVAL_ROOT/skills/opsx-run/opsx-window.sh"
G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
fail() { echo "FAIL: $*"; exit 1; }
need_tools() { command -v jq >/dev/null 2>&1 || { echo "jq missing"; exit 77; }; command -v git >/dev/null 2>&1 || exit 77; }
need_tmux() { command -v tmux >/dev/null 2>&1 && [ -n "${TMUX:-}" ] || { echo "no private tmux server"; exit 77; }; }
T() { tmux -L "$EVAL_TMUX_SOCKET" "$@"; }
commit() { # dir file content msg
  printf '%s\n' "$3" > "$1/$2"; $G -C "$1" add "$2"; $G -C "$1" commit -qm "$4"
}
pr_obj() { # n head sha base state
  jq -nc --argjson n "$1" --arg h "$2" --arg s "$3" --arg b "$4" --arg st "$5" \
    '{number:$n,url:"https://github.com/o/app/pull/\($n)",headRefName:$h,headRefOid:$s,
      baseRefName:$b,state:$st,author:{login:"leo"},title:"t"}'
}
# setpr <n> <jq update expr on the object, e.g. '.state="MERGED"'>
setpr() { jq --argjson n "$1" "map(if .number==\$n then $2 else . end)" "$GHD/prs.json" > "$GHD/prs.tmp" && mv "$GHD/prs.tmp" "$GHD/prs.json"; }
# set_ids <api path> <id...>  (review comments etc.)
set_ids() { local p=$1; shift; printf '%s\n' "$@" > "$GHD/api/$(printf '%s' "$p" | tr '/' '_')"; }

# mk_env: repo $R (main, feat-a with A,B; feat-b on top with C,D), origin, fake gh.
# PRs: 41 MERGED (old-x), 42 OPEN feat-a->main, 43 OPEN feat-b->feat-a.
mk_env() {
  need_tools
  SP=$EVAL_TMP/sp; mkdir -p "$SP/work" "$SP/fakebin" "$SP/gh/api" "$SP/gh/checks"
  GHD=$SP/gh; ORIGIN=$SP/origin.git; R=$SP/work/app
  $G init -q --bare "$ORIGIN"
  $G clone -q "$ORIGIN" "$R" 2>/dev/null
  commit "$R" base.txt base init
  $G -C "$R" push -q origin main
  $G -C "$R" checkout -q -b feat-a
  commit "$R" a.txt A A; commit "$R" b.txt B B
  SHA_A=$($G -C "$R" rev-parse HEAD)
  $G -C "$R" checkout -q -b feat-b
  commit "$R" c.txt C C; commit "$R" d.txt D D
  SHA_B=$($G -C "$R" rev-parse HEAD)
  $G -C "$R" push -q origin feat-a feat-b
  $G -C "$R" checkout -q main
  { pr_obj 41 old-x "$SHA_A" main MERGED
    pr_obj 42 feat-a "$SHA_A" main OPEN
    pr_obj 43 feat-b "$SHA_B" feat-a OPEN; } | jq -s . > "$GHD/prs.json"
  cat > "$SP/fakebin/gh" <<EOF
#!/usr/bin/env bash
D=$GHD
printf '%s\n' "\$*" >> "\$D/gh.log"
opt() { local k=\$1; shift; while [ \$# -gt 0 ]; do [ "\$1" = "\$k" ] && { printf '%s' "\$2"; return; }; shift; done; }
case "\$1 \$2" in
  "repo view") echo o/app ;;
  "pr view")
    n=\$(printf '%s' "\$3" | grep -Eo '[0-9]+\$')
    jq -c --argjson n "\$n" '.[] | select(.number==\$n)' "\$D/prs.json" | grep . || { echo "no pull requests found" >&2; exit 1; } ;;
  "pr list")
    h=\$(opt --head "\$@"); st=\$(opt --state "\$@")
    jq -c --arg h "\$h" --arg st "\$st" '[.[] | select((\$h=="" or .headRefName==\$h) and (\$st!="open" or .state=="OPEN"))]' "\$D/prs.json" ;;
  "pr create")
    h=\$(opt --head "\$@"); n=\$(jq '[.[].number] | max + 1' "\$D/prs.json")
    jq --argjson n "\$n" --arg h "\$h" '. + [{number:\$n,url:"https://github.com/o/app/pull/\(\$n)",headRefName:\$h,headRefOid:"0",baseRefName:"main",state:"OPEN",author:{login:"leo"}}]' "\$D/prs.json" > "\$D/prs.tmp" && mv "\$D/prs.tmp" "\$D/prs.json"
    echo "https://github.com/o/app/pull/\$n" ;;
  "pr checks")
    f="\$D/checks/\$3.json"; [ -f "\$f" ] || { echo "no checks reported" >&2; exit 1; }; cat "\$f" ;;
  "api --paginate")
    f="\$D/api/\$(printf '%s' "\$3" | tr '/' '_')"; [ -f "\$f" ] || exit 0
    cat "\$f" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$SP/fakebin/gh"
  # logging wrapper around the real opsx-window.sh
  cat > "$SP/fakebin/opsx-window.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SP/win.log"
prev=""
for a in "\$@"; do
  case "\$prev" in
    --goal-file) cp "\$a" "$SP/goal.copy" ;;
    --prompt-file) cp "\$a" "$SP/prompt.copy" ;;
  esac
  prev=\$a
done
exec "$WINSH" "\$@"
EOF
  chmod +x "$SP/fakebin/opsx-window.sh"
  printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$SP/fakebin/agent"; chmod +x "$SP/fakebin/agent"
  export PATH="$SP/fakebin:$PATH"
  export OPSX_WINDOW="$SP/fakebin/opsx-window.sh"
  export XDG_STATE_HOME="$EVAL_TMP/state"; mkdir -p "$XDG_STATE_HOME"
  cd "$R"
}
state_file() { printf '%s/tmux-opsx/pr/o-app-%s/state' "$XDG_STATE_HOME" "$1"; }
pr_start() { "$PRSH" start "$1" --repo "$R" --agent-cli "$SP/fakebin/agent" "${@:2}"; }
win_count() { T list-windows -a -F '#{@opsx_change}' 2>/dev/null | grep -cx "pr-$1" || true; }
