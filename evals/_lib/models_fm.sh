# Frontmatter helpers for agent-models install checks (sourced, not a check).
frontmatter() { awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm' "$1"; }
fm_model_is() {  # fm_model_is <file> <model>
  [ -f "$1" ] || fail "$1 not installed"
  local got; got=$(frontmatter "$1" | sed -n 's/^model:[[:space:]]*//p' | tr -d '"'"'"' \r' | head -1)
  [ "$got" = "$2" ] || fail "$1 frontmatter model is '${got:-<none>}', expected $2"
  echo "ok: $(basename "$1") model: $got"
}
