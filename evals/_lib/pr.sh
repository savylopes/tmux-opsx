# Shared helpers for pr-maintain checks: scratch git repo with a bare origin, a
# fake `gh` serving PR JSON from files, a logging wrapper around opsx-window.sh
# and a stub agent CLI. Sourced by checks; not a check itself.
PRSH="$EVAL_ROOT/skills/opsx-pr/pr.sh"
WINSH="$EVAL_ROOT/skills/opsx-run/opsx-window.sh"
G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
fail() { echo "FAIL: $*"; exit 1; }
need_tools() { command -v jq >/dev/null 2>&1 || { echo "jq missing"; exit 77; }; command -v git >/dev/null 2>&1 || exit 77; }
# private_tmux: true only when EVAL_TMUX_SOCKET is set and $TMUX points at that private
# socket (never the user's live server, whose TMUX the shell may have inherited).
private_tmux() {
  [ -n "${EVAL_TMUX_SOCKET:-}" ] && [ -n "${TMUX:-}" ] || return 1
  [ "$(basename "${TMUX%%,*}")" = "$EVAL_TMUX_SOCKET" ]
}
need_tmux() {
  command -v tmux >/dev/null 2>&1 || { echo "no tmux"; exit 77; }
  private_tmux || { echo "TMUX is not the private eval server (EVAL_TMUX_SOCKET=${EVAL_TMUX_SOCKET:-unset} TMUX=${TMUX:-unset}); refusing to launch windows"; exit 77; }
}
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
  "repo view") case "\$*" in *defaultBranchRef*) echo main ;; *) echo o/app ;; esac ;;
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
pr_start() { need_tmux; "$PRSH" start "$1" --repo "$R" --agent-cli "$SP/fakebin/agent" "${@:2}"; }
win_count() { T list-windows -a -F '#{@opsx_change}' 2>/dev/null | grep -cx "pr-$1" || true; }

# ---- change-window helpers (pr-in-change-window) -----------------------------
# mk_change_env: mk_env, PR 42's head becomes opsx/add-thing (branch pushed), and an
# open change window add-thing exists whose pane logs what is typed into it
# ($EVAL_TMP/typed.add-thing). CW = window id, CP = its pane id, OP = the pane of
# the setup window (a caller outside any change window).
mk_change_env() {
  OP=$TMUX_PANE
  clean_windows; trap clean_windows EXIT
  mk_env
  $G -C "$R" branch opsx/add-thing feat-a; $G -C "$R" push -q origin opsx/add-thing
  setpr 42 '.headRefName="opsx/add-thing"'
  mk_change_win add-thing "${1:-idle}"
}
# clean_windows: the eval tmux server is shared by all checks; drop every window
# except the setup window so a leftover add-thing / pr-42 never gets picked.
clean_windows() {
  local w keep; keep=$(T display -p -t "${OP:-$TMUX_PANE}" '#{window_id}' 2>/dev/null) || return 0
  for w in $(T list-windows -a -F '#{window_id}'); do [ "$w" = "$keep" ] || T kill-window -t "$w" 2>/dev/null; done
}
# mk_change_win <change> [status]: window tagged like an /opsx-run window
mk_change_win() {
  local f="$EVAL_TMP/typed.$1"; : > "$f"
  CW=$(T new-window -d -t "$EVAL_TMUX_SESSION:" -n "$1" -P -F '#{window_id}' "stty -echo; exec cat > '$f'") || fail "new-window $1"
  CP=$(T display -p -t "$CW" '#{pane_id}')
  T set-option -w -t "$CW" @opsx_change "$1"
  T set-option -w -t "$CW" @opsx_agent_cli claude
  T set-option -w -t "$CW" @opsx_status "${2:-idle}"
}
wopt() { T show-options -wqv -t "$1" "$2"; }
# wait_typed <change> <text> [secs]
wait_typed() { local i; for i in $(seq $(( ${3:-5} * 10 ))); do grep -qF -- "$2" "$EVAL_TMP/typed.$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

# ---- stack / ledger helpers (pr-stack-ledger) ---------------------------------
# mk_stack_env: mk_env, then PR 41 = feat-a (A,B) -> main and PR 42 = feat-b (A,B,C,D)
# -> main, both OPEN, so 42 is implicitly stacked on 41. SHA_A = 41's head, SHA_B = 42's.
mk_stack_env() {
  mk_env
  { pr_obj 41 feat-a "$SHA_A" main OPEN
    pr_obj 42 feat-b "$SHA_B" main OPEN; } | jq -s . > "$GHD/prs.json"
  LEDGER="$XDG_STATE_HOME/tmux-opsx/pr/o-app/ledger"
}
# put_entry <from> <to> <kind> [age seconds]: drop a ledger file by hand
put_entry() {
  mkdir -p "$LEDGER"
  local ts; ts=$(date -u -d "@$(( $(date +%s) - ${4:-0} ))" +%Y%m%dT%H%M%SZ)
  local f="$LEDGER/$ts-$(printf '%04x' $((RANDOM % 65536)))--$1--$2--$3.md"
  printf 'pr: %s\n' "${1#pr-}" > "$f"; echo "$f"
}
# start_stack <n>: pr.sh start with the stub agent; needs the private tmux server
start_stack() { need_tmux; clean_windows; trap clean_windows EXIT; pr_start "$@"; }

# ---- tmux-free helpers (L1): never reach any tmux server -----------------------
# pr <args>: pr.sh without TMUX/TMUX_PANE and with a scratch TMUX_TMPDIR, so a bare
# tmux inside pr.sh can only see an empty private directory, never a live server.
pr() { mkdir -p "$EVAL_TMP/notmux"; chmod 700 "$EVAL_TMP/notmux"
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$EVAL_TMP/notmux" "$PRSH" "$@" --repo "$R"; }
# seed <n> [parent|none]: state file for PR n through restart-input (no window), then
# declare the parent by hand
seed() { pr restart-input "$1" >/dev/null 2>&1 || fail "restart-input $1 failed"
  [ -z "${2:-}" ] || pr stack "$1" --stacked-on "$2" >/dev/null || fail "stack $1 --stacked-on $2 failed"; }
# st_set <n> <key> <value>: edit one line of the state file
st_set() { local f; f=$(state_file "$1"); grep -v "^$2=" "$f" > "$f.tmp"; echo "$2=$3" >> "$f.tmp"; mv "$f.tmp" "$f"; }
# tell_ok <args>: pr.sh tell that must succeed; waits 1 s after so names sort in order
tell_ok() { pr tell "$@" >/dev/null || fail "tell $* failed"; sleep 1; }
n_entries() { ls "$LEDGER" 2>/dev/null | grep -c '[.]md$' || true; }

# mk_moved_env: stack 41 (A,B) <- 42 (A,B,C,D), 42 records parent 41 with tip A..B. Then
# main gets a commit M and PR 41 is rewritten to A',B' on it and force-pushed: PAR_NEW =
# 41's new remote head, OLD_B = 42's head before. 42's local branch is unchanged.
mk_moved_env() {
  mk_stack_env; seed 41; seed 42 41
  $G -C "$R" checkout -q main; commit "$R" m.txt M M; $G -C "$R" push -q origin main
  $G -C "$R" checkout -q -b rw feat-a; $G -C "$R" rebase -q main 2>&1 | tail -2
  PAR_NEW=$($G -C "$R" rev-parse HEAD); $G -C "$R" push -q -f origin rw:feat-a
  $G -C "$R" checkout -q main; $G -C "$R" branch -q -D rw
  setpr 41 ".headRefOid=\"$PAR_NEW\""
  OLD_B=$SHA_B
}
