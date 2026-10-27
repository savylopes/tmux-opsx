# Fork-checkout fixtures for pr-maintain checks (add-pr-forks). Sourced after pr.sh.
# Layout: bare repos under $EVAL_TMP/remotes/github.com/<owner>/app.git so remote URLs
# parse as owner/name. UP = acme/app (base), FK = me/app (user's fork, origin),
# DK = dany/app (teammate's fork). Checkout $F has origin=FK, upstream=UP, dany=DK.
# Fake gh serves PRs 50 (me:feat-f), 51 (dany:feat-d), 52 (me:main) of acme/app.
mk_fork_env() { # [noupstream]
  need_tools
  SP=$EVAL_TMP/sp; mkdir -p "$SP/work" "$SP/fakebin" "$SP/gh/checks" "$SP/gh/api" "$SP/gh/repos"
  GHD=$SP/gh
  local GHR=$SP/remotes/github.com
  UP=$GHR/acme/app.git; FK=$GHR/me/app.git; DK=$GHR/dany/app.git
  $G init -q --bare "$UP"
  $G clone -q "$UP" "$SP/upw" 2>/dev/null
  commit "$SP/upw" base.txt base init; $G -C "$SP/upw" push -q origin main
  $G clone -q --bare "$UP" "$FK" 2>/dev/null
  $G clone -q --bare "$UP" "$DK" 2>/dev/null
  F=$SP/work/app; R=$F
  $G clone -q "$FK" "$F" 2>/dev/null
  $G -C "$F" remote add upstream "$UP"; $G -C "$F" remote add dany "$DK"
  $G -C "$F" fetch -q upstream; $G -C "$F" fetch -q dany
  $G -C "$F" checkout -q -b feat-f
  commit "$F" f.txt F F
  SHA_F=$($G -C "$F" rev-parse HEAD)
  $G -C "$F" push -q origin feat-f
  $G -C "$F" checkout -q main; $G -C "$F" branch -q -D feat-f
  $G clone -q "$DK" "$SP/danyw" 2>/dev/null
  $G -C "$SP/danyw" checkout -q -b feat-d; commit "$SP/danyw" d.txt D D; $G -C "$SP/danyw" push -q origin feat-d
  SHA_D=$($G -C "$SP/danyw" rev-parse HEAD)
  SHA_FM=$($G -C "$F" rev-parse main)
  $G -C "$F" push -q origin main 2>/dev/null || true
  fo() { jq -nc --argjson n "$1" --arg o "$2" --arg h "$3" --arg s "$4" \
    '{number:$n,url:"https://github.com/acme/app/pull/\($n)",headRefName:$h,headRefOid:$s,baseRefName:"main",
      state:"OPEN",author:{login:$o},title:"t",isCrossRepository:true,
      headRepositoryOwner:{login:$o},headRepository:{name:"app"}}'; }
  { fo 50 me feat-f "$SHA_F"; fo 51 dany feat-d "$SHA_D"; fo 52 me main "$SHA_FM"; } | jq -s . > "$GHD/prs.json"
  echo '{"full_name":"me/app","fork":true,"parent":{"full_name":"acme/app"}}' > "$GHD/repos/repos_me_app.json"
  cat > "$SP/fakebin/gh" <<EOT
#!/usr/bin/env bash
D=$GHD
printf '%s\n' "\$*" >> "\$D/gh.log"
opt() { local k=\$1; shift; while [ \$# -gt 0 ]; do [ "\$1" = "\$k" ] && { printf '%s' "\$2"; return; }; shift; done; }
case "\$1 \$2" in
  "repo view") case "\$*" in *defaultBranchRef*) echo main ;; *) echo acme/app ;; esac ;;
  "pr view")
    n=\$(printf '%s' "\$3" | grep -Eo '[0-9]+\$')
    jq -c --argjson n "\$n" '.[] | select(.number==\$n)' "\$D/prs.json" | grep . || { echo "no pull requests found" >&2; exit 1; } ;;
  "pr list")
    h=\$(opt --head "\$@"); st=\$(opt --state "\$@")
    jq -c --arg h "\$h" --arg st "\$st" '[.[] | select((\$h=="" or .headRefName==\$h) and (\$st!="open" or .state=="OPEN"))]' "\$D/prs.json" ;;
  "pr create")
    h=\$(opt --head "\$@"); n=\$(jq '[.[].number] | max + 1' "\$D/prs.json")
    echo "https://github.com/acme/app/pull/\$n" ;;
  "pr checks") f="\$D/checks/\$3.json"; [ -f "\$f" ] || { echo "no checks reported" >&2; exit 1; }; cat "\$f" ;;
  "api --paginate") exit 0 ;;
  "api repos/"*)
    f="\$D/repos/\$(printf '%s' "\$2" | tr '/' '_').json"; [ -f "\$f" ] || { echo "HTTP 404" >&2; exit 1; }
    q=\$(opt --jq "\$@"); jq -r "\${q:-.}" "\$f" ;;
  *) exit 0 ;;
esac
EOT
  chmod +x "$SP/fakebin/gh"
  cat > "$SP/fakebin/opsx-window.sh" <<EOT
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SP/win.log"
exec "$WINSH" "\$@"
EOT
  chmod +x "$SP/fakebin/opsx-window.sh"
  printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$SP/fakebin/agent"; chmod +x "$SP/fakebin/agent"
  export PATH="$SP/fakebin:$PATH" OPSX_WINDOW="$SP/fakebin/opsx-window.sh"
  export XDG_STATE_HOME="$EVAL_TMP/state"; mkdir -p "$XDG_STATE_HOME"
  [ "${1:-}" = noupstream ] && $G -C "$F" remote remove upstream
  cd "$F"
}
fstate() { printf '%s/tmux-opsx/pr/acme-app-%s/state' "$XDG_STATE_HOME" "$1"; }
fstart() { "$PRSH" start "$1" --repo "$F" --agent-cli "$SP/fakebin/agent"; }
