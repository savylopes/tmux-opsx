# Shared helpers for question-research checks. Sourced by checks; not a check itself.
QSH="$EVAL_ROOT/skills/opsx-questions/questions.sh"
fail() { echo "FAIL: $*"; exit 1; }
mk_repo() {  # scratch git repo in $EVAL_TMP/repo
  R="$EVAL_TMP/repo"; mkdir -p "$R"
  git -C "$R" init -q . 2>/dev/null
  git -C "$R" config user.email e@e; git -C "$R" config user.name e
  : > "$R/.keep"; git -C "$R" add .keep; git -C "$R" commit -qm init
}
mk_change() {  # mk_change <name>: design with open questions and decisions, one requirement
  C="$R/openspec/changes/$1"; mkdir -p "$C/specs/foo"
  cat > "$C/design.md" <<'D'
# Design

## Decisions

### Use SQLite
Because.

### One window per change
Because.

## Open Questions

- Where does X write?
- Resolved: Y uses Z.
D
  printf '# Spec\n\n## ADDED Requirements\n\n### Requirement: Bar\nThe system SHALL bar.\n' > "$C/specs/foo/spec.md"
}
mk_questions() {  # mk_questions <n>: TSV file $EVAL_TMP/q.tsv
  : > "$EVAL_TMP/q.tsv"; i=1
  while [ "$i" -le "$1" ]; do printf 'Q%s\topen\tconversation\tQuestion %s?\n' "$i" "$i" >> "$EVAL_TMP/q.tsv"; i=$((i+1)); done
}
new_run() {  # new_run <mode> <nq> [extra args]: sets RUN
  m=$1; n=$2; shift 2; mk_questions "$n"
  RUN=$("$QSH" run new "$m" --questions-file "$EVAL_TMP/q.tsv" --repo "$R" "$@") || fail "run new failed: $RUN"
  RUN=$(printf '%s' "$RUN" | tail -1)
}
rec() { "$QSH" record "$RUN" "$@" --repo "$R"; }
st() { "$QSH" status "$RUN" --repo "$R"; }
