#!/usr/bin/env bash
# Scripted tests for per-agent models: agents/models.conf, `opsx-window.sh
# models`, window memory (@opsx_model_<agent>) and install.sh output.
#
# Runs on a private tmux server (tmux -L agent-models-test-$$) with fake agent
# CLIs (claude/agent/codex/opencode/gemini sleep; agent and opencode also answer
# `models`) and a scratch HOME / XDG_CONFIG_HOME, so it never touches your tmux
# session, your agent CLIs or your config.
# Usage: bash tests/test-agent-models.sh
# Assertions are eval'd strings, so variables read only there look unused.
# shellcheck disable=SC2034,SC2016,SC2086
set -u
command -v tmux >/dev/null 2>&1 || { echo "tmux is required"; exit 1; }
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
SELF=$REPO/tests/$(basename -- "$0")
W=$REPO/skills/opsx-run/opsx-window.sh
CONF=$REPO/agents/models.conf
SP=$(mktemp -d "${TMPDIR:-/tmp}/agent-models-test.XXXXXX")
SOCK=agent-models-test-$$
trap 'tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$SP"' EXIT

mkdir -p "$SP/fakebin" "$SP/home" "$SP/xdg/tmux-opsx" "$SP/proj"
for c in claude agent codex opencode gemini; do
  cat > "$SP/fakebin/$c" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$0")
if [ "${1:-}" = models ]; then
  f="$FAKE_MODELS_DIR/$name.models"
  [ -f "$f" ] || exit 1
  cat "$f"
  exit 0
fi
exec sleep 600
EOF
  chmod +x "$SP/fakebin/$c"
done
export FAKE_MODELS_DIR=$SP/models; mkdir -p "$FAKE_MODELS_DIR"
export HOME=$SP/home XDG_CONFIG_HOME=$SP/xdg
export PATH=$SP/fakebin:$PATH
unset OPSX_MODELS_CONF OPSX_AGENT_CLI OPSX_MODEL ANTHROPIC_MODEL
UF=$XDG_CONFIG_HOME/tmux-opsx/models.conf

L="tmux -L $SOCK"
$L kill-server 2>/dev/null
$L -f /dev/null new-session -d -s ms -x 200 -y 50 -c "$SP/proj" 'exec sleep 3000'
sock=$($L display -p '#{socket_path}'); pid=$($L display -p '#{pid}')
P=$($L display -p -t ms '#{pane_id}')
export TMUX="$sock,$pid,0" TMUX_PANE=$P
cd "$SP/proj" || exit 1
printf 'do the thing\n' > "$SP/p"

pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
# Window id tagged @opsx_change=$1 (empty if none).
winof(){ $L list-windows -t ms -F '#{window_id} #{@opsx_change}' | awk -v n="$1" '$2==n{print $1; exit}'; }
opt(){ $L show-options -wqv -t "$1" "$2"; }
line(){ printf '%s\n' "$1" | awk -v a="$2" '$1==a'; }

# ================================================================ 1.1 shipped file
ok "models.conf has all 15 keys" 'for c in claude agent opencode; do for a in applier eval reviewer security qa; do grep -Eq "^$c\.$a[[:space:]]*=" "$CONF" || exit 1; done; done'
ok "claude defaults opus/sonnet" 'grep -Eq "^claude\.applier *= *opus$" "$CONF" && grep -Eq "^claude\.reviewer *= *opus$" "$CONF" && grep -Eq "^claude\.security *= *opus$" "$CONF" && grep -Eq "^claude\.eval *= *sonnet$" "$CONF" && grep -Eq "^claude\.qa *= *sonnet$" "$CONF"'
ok "cursor/opencode inherit" '[ "$(grep -Ec "^(agent|opencode)\.[a-z]+ *= *inherit$" "$CONF")" -eq 10 ]'
ok "no codex/gemini keys" '! grep -Eq "^(codex|gemini)\." "$CONF"'

# ================================================================ 1.3/1.4 resolver
rm -f "$UF"
out=$($W models c1 --agent-cli claude 2>"$SP/err"); rc=$?
ok "no user file: exit 0" '[ $rc -eq 0 ]'
ok "shipped defaults" '[ "$out" = "applier opus config
eval sonnet config
reviewer opus config
security opus config
qa sonnet config" ]'
ok "no warnings without user file" '[ ! -s "$SP/err" ]'

printf '# mine\n\nclaude.qa = haiku\n' > "$UF"
out=$($W models c1 --agent-cli claude 2>/dev/null)
ok "user override one key" '[ "$(line "$out" qa)" = "qa haiku config" ] && [ "$(line "$out" reviewer)" = "reviewer opus config" ]'

printf 'claude.eval = gpt-5\n' > "$UF"
out=$($W models c1 --agent-cli claude 2>"$SP/err")
ok "claude rejects gpt-5" '[ "$(line "$out" eval)" = "eval inherit inherit" ] && grep -q "gpt-5" "$SP/err"'

printf 'opencode.qa = gpt-5\n' > "$UF"
out=$($W models c1 --agent-cli opencode 2>"$SP/err")
ok "opencode bare id rejected" '[ "$(line "$out" qa)" = "qa inherit inherit" ] && grep -q "gpt-5" "$SP/err"'

printf 'opencode.qa = openai/gpt-5\nopencode.eval = openai/nope\n' > "$UF"
printf 'openai/gpt-5\nanthropic/claude-sonnet-4\n' > "$FAKE_MODELS_DIR/opencode.models"
out=$($W models c1 --agent-cli opencode 2>"$SP/err")
ok "opencode listed id accepted" '[ "$(line "$out" qa)" = "qa openai/gpt-5 config" ]'
ok "opencode unlisted id rejected" '[ "$(line "$out" eval)" = "eval inherit inherit" ] && grep -q "openai/nope" "$SP/err"'
rm -f "$FAKE_MODELS_DIR/opencode.models"
out=$($W models c1 --agent-cli opencode 2>/dev/null)
ok "opencode list unavailable: provider/model accepted" '[ "$(line "$out" eval)" = "eval openai/nope config" ]'
printf 'Models:\nopenai/gpt-5\nsome header words\n' > "$FAKE_MODELS_DIR/opencode.models"
printf 'opencode.qa = some/header\n' > "$UF"
out=$($W models c1 --agent-cli opencode --eval-model openai/gpt-5 2>/dev/null)
ok "opencode list: one id per line accepted, words rejected" '[ "$(line "$out" eval)" = "eval openai/gpt-5 flag" ] && [ "$(line "$out" qa)" = "qa inherit inherit" ]'
rm -f "$FAKE_MODELS_DIR/opencode.models"

printf 'agent.qa = gpt-5\nagent.eval = bogus\n' > "$UF"
printf 'Available models\n\ngpt-5 - GPT-5\nsonnet-4 - Sonnet 4 (current)\n' > "$FAKE_MODELS_DIR/agent.models"
out=$($W models c1 --agent-cli agent 2>"$SP/err")
ok "cursor listed id accepted" '[ "$(line "$out" qa)" = "qa gpt-5 config" ]'
ok "cursor unlisted id rejected" '[ "$(line "$out" eval)" = "eval inherit inherit" ] && grep -q bogus "$SP/err"'
# F2: header and description words are not model ids.
for bad in current Available models GPT-5 '(current)'; do
  out=$($W models zz --agent-cli agent --qa-model "$bad" 2>"$SP/err")
  ok "cursor list: '$bad' is not a model" '[ "$(line "$out" qa)" = "qa gpt-5 config" ] && grep -q warning "$SP/err"'
done
out=$($W models zz --agent-cli agent --qa-model sonnet-4 2>/dev/null)
ok "cursor list: id column accepted" '[ "$(line "$out" qa)" = "qa sonnet-4 flag" ]'
rm -f "$FAKE_MODELS_DIR/agent.models"
out=$($W models c1 --agent-cli agent 2>/dev/null)
ok "cursor list unavailable: accepted" '[ "$(line "$out" eval)" = "eval bogus config" ]'

rm -f "$UF"
out=$($W models c1 --agent-cli claude --qa-model gpt-5 2>"$SP/err")
ok "invalid flag falls through" '[ "$(line "$out" qa)" = "qa sonnet config" ] && grep -q gpt-5 "$SP/err"'
out=$($W models c1 --agent-cli claude --reviewer-model haiku 2>/dev/null)
ok "valid flag wins" '[ "$(line "$out" reviewer)" = "reviewer haiku flag" ]'
out=$($W models c1 --agent-cli codex --qa-model gpt-5 2>/dev/null)
ok "codex: all inherit inherit" '[ "$(printf "%s\n" "$out" | grep -c " inherit inherit$")" -eq 5 ]'
out=$($W models c1 --agent-cli gemini 2>/dev/null)
ok "gemini: all inherit inherit" '[ "$(printf "%s\n" "$out" | grep -c " inherit inherit$")" -eq 5 ]'
$W models c1 --agent-cli claude --qa-model "" >/dev/null 2>&1; rc=$?
ok "models rejects empty flag value" '[ $rc -ne 0 ]'
out=$(OPSX_MODELS_CONF=$SP/none.conf $W models --agent-cli claude 2>/dev/null)
ok "OPSX_MODELS_CONF overrides shipped file" '[ "$(line "$out" applier)" = "applier inherit inherit" ]'
# F1: only [A-Za-z0-9._:/@-] is a model, at every layer.
printf '%s\n' 'claude.security = claude-x\npermissionMode:\040bypassPermissions' 'claude.qa = claude-$(id)' > "$UF"
out=$($W models c1 --agent-cli claude 2>"$SP/err")
ok "claude: escapes in config rejected" '[ "$(line "$out" security)" = "security inherit inherit" ] && grep -q claude.security "$SP/err"'
ok "claude: \$(...) in config rejected" '[ "$(line "$out" qa)" = "qa inherit inherit" ]'
for bad in 'claude-`id`' 'claude-a&b' "claude-a'b" 'claude-a"b'; do
  out=$($W models c1 --agent-cli claude --eval-model "$bad" 2>/dev/null)
  ok "claude: flag $bad rejected" '[ "$(line "$out" eval)" = "eval sonnet config" ]'
done
out=$($W models c1 --agent-cli claude --eval-model claude-sonnet-4.5@2025:x 2>/dev/null)
ok "claude: safe claude-* id accepted" '[ "$(line "$out" eval)" = "eval claude-sonnet-4.5@2025:x flag" ]'
printf 'claude.qa = claude-\033[31mx\n' > "$UF"
$W models c1 --agent-cli claude >/dev/null 2>"$SP/err"
ok "warnings carry no control characters" '! LC_ALL=C grep -q "$(printf "\033")" "$SP/err"'
rm -f "$UF"
# F5: unknown CLI warns.
out=$($W models c1 --agent-cli bogus 2>"$SP/err"); rc=$?
ok "unknown --agent-cli warns" '[ $rc -eq 0 ] && grep -q "unknown agent CLI bogus" "$SP/err" && [ "$(printf "%s\n" "$out" | grep -c " inherit inherit$")" -eq 5 ]'

# ================================================================ 2.x window memory
$W ensure c1 --prompt-file "$SP/p" --agent-cli claude --reviewer-model "--x" >/dev/null 2>&1; rc=$?
ok "unsafe value (leading -) rejected, no window" '[ $rc -ne 0 ] && [ -z "$(winof c1)" ]'
$W ensure c1 --prompt-file "$SP/p" --agent-cli claude --qa-model "a b" >/dev/null 2>&1; rc=$?
ok "unsafe value (whitespace) rejected, no window" '[ $rc -ne 0 ] && [ -z "$(winof c1)" ]'
$W ensure c1 --prompt-file "$SP/p" --agent-cli claude --qa-model "" >/dev/null 2>&1; rc=$?
ok "unsafe value (empty) rejected, no window" '[ $rc -ne 0 ] && [ -z "$(winof c1)" ]'

out=$($W ensure c1 --prompt-file "$SP/p" --agent-cli claude --qa-model haiku 2>&1); rc=$?
W1=$(winof c1)
ok "ensure with flag creates window" '[ $rc -eq 0 ] && [ -n "$W1" ]'
ok "flag stored, others unset" '[ "$(opt $W1 @opsx_model_qa)" = haiku ] && [ -z "$(opt $W1 @opsx_model_reviewer)" ]'

$W send c1 --prompt-file "$SP/p" >/dev/null 2>&1
out=$($W models c1 2>/dev/null)
ok "later send keeps it; models reports window" '[ "$(opt $W1 @opsx_model_qa)" = haiku ] && [ "$(line "$out" qa)" = "qa haiku window" ]'

$W send c1 --prompt-file "$SP/p" --reviewer-model sonnet >/dev/null 2>&1
out=$($W models c1 --reviewer-model haiku 2>/dev/null)
ok "flag beats remembered" '[ "$(line "$out" reviewer)" = "reviewer haiku flag" ]'
out=$($W models c1 2>/dev/null)
ok "remembered beats config" '[ "$(line "$out" reviewer)" = "reviewer sonnet window" ] && [ "$(line "$out" applier)" = "applier opus config" ]'
# F3: --agent-cli overridden by the window's CLI says so.
$W models c1 --agent-cli agent --qa-model gpt-5 >/dev/null 2>"$SP/err"
ok "models notes the window CLI beats --agent-cli" 'grep -q "window on claude" "$SP/err"'
$W models c1 --agent-cli claude >/dev/null 2>"$SP/err"
ok "models: no note when --agent-cli matches" '! grep -q "note:" "$SP/err"'
# F4: an invalid value is stored (spec) but warned about at send time.
$W send c1 --prompt-file "$SP/p" --eval-model gpt-5 >/dev/null 2>"$SP/err"; rc=$?
ok "send warns when storing a model the CLI rejects" '[ $rc -eq 0 ] && grep -q "gpt-5 is not a valid model for claude" "$SP/err" && [ "$(opt $W1 @opsx_model_eval)" = gpt-5 ]'
$W send c1 --prompt-file "$SP/p" --eval-model default >/dev/null 2>&1

out=$($W list 2>/dev/null)
ok "list shows qa=haiku" 'printf "%s\n" "$out" | grep "^$W1	" | grep -q "qa=haiku"'
out=$($W status c1 --lines 5 2>/dev/null)
ok "status shows models before capture" 'printf "%s\n" "$out" | head -1 | grep -q "qa=haiku" && printf "%s\n" "$out" | head -1 | grep -q "reviewer=sonnet"'

$W send c1 --prompt-file "$SP/p" --qa-model default >/dev/null 2>&1
out=$($W models c1 2>/dev/null)
ok "default clears remembered" '[ -z "$(opt $W1 @opsx_model_qa)" ] && [ "$(line "$out" qa)" = "qa sonnet config" ]'

$W send c1 --prompt-file "$SP/p" --qa-model haiku >/dev/null 2>&1
ok "send flag stores on existing window" '[ "$(opt $W1 @opsx_model_qa)" = haiku ]'
$W close c1 >/dev/null 2>&1
$W ensure c1 --prompt-file "$SP/p" --agent-cli claude >/dev/null 2>&1
W2=$(winof c1)
ok "close and recreate starts empty" '[ -n "$W2" ] && [ -z "$(opt $W2 @opsx_model_qa)" ] && [ -z "$(opt $W2 @opsx_model_reviewer)" ]'
out=$($W list 2>/dev/null)
ok "list: no pairs without memory" '! printf "%s\n" "$out" | grep "^$W2	" | grep -q "="'
$W close c1 >/dev/null 2>&1

$W ensure c2 --prompt-file "$SP/p" --agent-cli codex --qa-model gpt-5 --eval-model x >/dev/null 2>"$SP/err"; rc=$?
W3=$(winof c2)
ok "codex window ignores flags with one note" '[ $rc -eq 0 ] && [ -n "$W3" ] && [ "$(grep -c "per-agent models" "$SP/err")" -eq 1 ] && [ -z "$(opt $W3 @opsx_model_qa)" ]'
out=$($W models c2 2>/dev/null)
ok "codex window: models all inherit" '[ "$(printf "%s\n" "$out" | grep -c " inherit inherit$")" -eq 5 ]'
$W send c2 --prompt-file "$SP/p" --qa-model gpt-5 >/dev/null 2>"$SP/err"
ok "codex send ignores flags with one note" '[ "$(grep -c "per-agent models" "$SP/err")" -eq 1 ] && [ -z "$(opt $W3 @opsx_model_qa)" ]'
$W close c2 >/dev/null 2>&1

$W ensure c3 --prompt-file "$SP/p" --agent-cli claude --model haiku >/dev/null 2>&1
W4=$(winof c3)
ok "--model: launch has --model haiku" '[ -n "$W4" ] && $L list-panes -t "$W4" -F "#{pane_start_command}" | grep -q -- "--model haiku"'
ok "--model: no @opsx_model_* set" '! $L show-options -w -t "$W4" | grep -q "^@opsx_model_"'
out=$($W models c3 2>/dev/null)
ok "--model: applier still opus config" '[ "$(line "$out" applier)" = "applier opus config" ]'
$W close c3 >/dev/null 2>&1

$W send c4 --prompt-file "$SP/p" --agent-cli claude >/dev/null 2>&1; rc=$?
ok "send rejects --agent-cli as before" '[ $rc -ne 0 ]'
OPSX_AGENT_CLI=claude $W send c4 --prompt-file "$SP/p" --security-model haiku >/dev/null 2>&1
W5=$(winof c4)
ok "send creating a window stores the flag" '[ -n "$W5" ] && [ "$(opt $W5 @opsx_model_security)" = haiku ]'
$W close c4 >/dev/null 2>&1

# ================================================================ 3.x install
IH=$SP/ihome; mkdir -p "$IH" "$SP/ibin"
for b in claude node npm; do printf '#!/bin/sh\necho 1.0.0\n' > "$SP/ibin/$b"; chmod +x "$SP/ibin/$b"; done
run_install(){
  (cd "$REPO" && env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_HOME -u OPENCODE_CONFIG_DIR -u TMUX -u TMUX_PANE \
     -u SUDO_USER -u REAL_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u OPSX_MODELS_CONF \
     HOME="$IH" PATH="$SP/ibin:/usr/bin:/bin" bash ./install.sh --skip-openspec --skip-graphify \
     --skip-commands --skip-mcp --skip-memory --skip-fork --no-backup 2>&1)
}
fm(){ awk '/^---$/{n++; next} n==1' "$1"; }
out=$(run_install); rc=$?
ok "install (no user file) exits 0" '[ $rc -eq 0 ]'
ok "install: claude reviewer opus, qa sonnet" 'fm "$IH/.claude/agents/opsx-reviewer.md" | grep -qx "model: opus" && fm "$IH/.claude/agents/opsx-qa.md" | grep -qx "model: sonnet"'
ok "install: claude applier/security opus, eval sonnet" 'fm "$IH/.claude/agents/opsx-applier.md" | grep -qx "model: opus" && fm "$IH/.claude/agents/opsx-security.md" | grep -qx "model: opus" && fm "$IH/.claude/agents/opsx-eval.md" | grep -qx "model: sonnet"'
ok "install: one model line per claude file" 'for a in applier eval reviewer security qa; do [ "$(fm "$IH/.claude/agents/opsx-$a.md" | grep -c "^model:")" -eq 1 ] || exit 1; done'
ok "install: cursor model: inherit" 'for a in applier eval reviewer security qa; do fm "$IH/.cursor/agents/opsx-$a.md" | grep -qx "model: inherit" || exit 1; done'
ok "install: opencode applier has no model line" '! fm "$IH/.config/opencode/agents/ops-applier.md" | grep -q "^model:"'
ok "install: codex/gemini unchanged" '! grep -q "^model" "$IH/.codex/agents/ops-qa.toml" && cmp -s "$REPO/agents/opsx-qa.md" "$IH/.gemini/agents/opsx-qa.md"'
ok "install: models.conf next to opsx-window.sh" 'for d in .claude/skills .cursor/skills .agents/skills .codex/skills .config/opencode/skills .gemini/skills; do cmp -s "$CONF" "$IH/$d/opsx-run/models.conf" || exit 1; done'
out2=$(env -u XDG_CONFIG_HOME -u OPSX_MODELS_CONF HOME="$IH" "$IH/.claude/skills/opsx-run/opsx-window.sh" models --agent-cli claude 2>/dev/null)
ok "installed opsx-window.sh finds installed models.conf" '[ "$(line "$out2" applier)" = "applier opus config" ]'

mkdir -p "$IH/.config/tmux-opsx"
printf 'claude.reviewer = haiku\nclaude.security = gpt-5\n' > "$IH/.config/tmux-opsx/models.conf"
out=$(run_install); rc=$?
ok "install with invalid model still exits 0" '[ $rc -eq 0 ]'
ok "install: user override reaches reviewer" 'fm "$IH/.claude/agents/opsx-reviewer.md" | grep -qx "model: haiku"'
ok "install: invalid security warns and writes inherit" 'printf "%s\n" "$out" | grep "claude.security" | grep -q "gpt-5" && fm "$IH/.claude/agents/opsx-security.md" | grep -qx "model: inherit"'
ok "install never writes the user file" '[ "$(cat "$IH/.config/tmux-opsx/models.conf")" = "claude.reviewer = haiku
claude.security = gpt-5" ]'
# F1: backslash escapes never become frontmatter keys.
printf '%s\n' 'claude.security = claude-x\npermissionMode:\040bypassPermissions' > "$IH/.config/tmux-opsx/models.conf"
out=$(run_install); rc=$?
ok "install: escaped model rejected, no extra frontmatter key" '[ $rc -eq 0 ] && fm "$IH/.claude/agents/opsx-security.md" | grep -qx "model: inherit" && [ "$(fm "$IH/.claude/agents/opsx-security.md" | grep -v "^model:")" = "$(fm "$REPO/agents/opsx-security.md" | grep -v "^model:")" ] && printf "%s\n" "$out" | grep -q claude.security'

# ================================================================ 4.x skill + docs
SK=$REPO/skills/opsx-run/SKILL.md; RD=$REPO/README.md
ok "skill: five per-agent flags" 'for a in applier eval reviewer security qa; do grep -q -- "--$a-model" "$SK" || exit 1; done'
ok "skill: retry-once rule" 'grep -q "retry once without a model" "$SK"'
ok "skill: no model: inherit spawn instruction" '! grep -q "model: inherit" "$SK"'
ok "skill: every dispatcher template has a MODELS block" '[ "$(grep -c "^> <MODELS block" "$SK")" -ge 12 ]'
ok "readme: models.conf, --reviewer-model, order" 'grep -q "models.conf" "$RD" && grep -q -- "--reviewer-model" "$RD" && grep -q "flag > window > config > inherit" "$RD"'
ok "readme: Codex/Gemini gap + test listed" 'grep -q "Codex and Gemini\*\* windows do the work themselves without sub-agents" "$RD" && grep -q "tests/test-agent-models.sh" "$RD"'

ok "shellcheck (if installed)" '! command -v shellcheck >/dev/null || shellcheck -S warning "$W" "$REPO/install.sh" "$SELF"'

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
