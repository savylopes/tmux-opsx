#!/usr/bin/env bash
# Fake ntfy CLI for tests/test-notify.sh (install.sh through $OPSX_NTFY_BIN).
# Keeps users, grants and tokens as files under $FAKE_NTFY_DIR, logs every call
# (argv) to $FAKE_NTFY_DIR/calls.log, and prints what the real ntfy 2.34 prints
# for the commands install.sh uses: --version, user list|add|change-pass,
# access <user> <topic> <perm>, token list|add <user>. Never serves anything.
set -u
D=${FAKE_NTFY_DIR:?FAKE_NTFY_DIR is not set}
mkdir -p "$D"
printf '%s\n' "$*" >> "$D/calls.log"
args=()
while [ $# -gt 0 ]; do
  case $1 in
    --config|-c) shift 2 ;;
    --config=*)  shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
touch "$D/users" "$D/access" "$D/tokens"
# Like ntfy 2.34 (cmd/user.go): NTFY_PASSWORD, else the password and its
# confirmation as two lines on stdin. Logs where the password came from.
read_pw() {
  local p c
  if [ -n "${NTFY_PASSWORD:-}" ]; then printf 'pw-from env\n' >> "$D/calls.log"; PW=$NTFY_PASSWORD; return 0; fi
  IFS= read -r p || true; IFS= read -r c || true
  [ -n "$p" ] || { echo "password cannot be empty" >&2; exit 1; }
  [ "$p" = "$c" ] || { echo "passwords do not match" >&2; exit 1; }
  printf 'pw-from stdin\n' >> "$D/calls.log"; PW=$p
}
case "${1:-} ${2:-}" in
  "--version "*) echo "ntfy version 2.34.0 (fake)" ;;
  "user list")
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      printf 'user %s (role: user, tier: none)\n' "$u"
      awk -v u="$u" '$1 == u { print "- read-write access to topic " $2; n++ } END { if (!n) print "- no topic-specific permissions" }' "$D/access"
    done < "$D/users"
    printf 'user * (role: anonymous, tier: none)\n- no topic-specific permissions\n- no access to any (other) topics (server config)\n' ;;
  "user add")
    u=${3:?}
    if grep -qx "$u" "$D/users"; then echo "user $u already exists" >&2; exit 1; fi
    read_pw
    printf '%s\n' "$u" >> "$D/users"; printf '%s\n' "$PW" > "$D/pw-$u"
    echo "user $u added with role user" ;;
  "user change-pass")
    u=${3:?}; grep -qx "$u" "$D/users" || { echo "user $u does not exist" >&2; exit 1; }
    read_pw; printf '%s\n' "$PW" > "$D/pw-$u"; echo "changed password for user $u" ;;
  "access "*)
    u=${2:?} t=${3:?}
    grep -qx "$u" "$D/users" || { echo "user $u does not exist" >&2; exit 1; }
    printf '%s %s\n' "$u" "$t" >> "$D/access"
    echo "granted read-write access to topic $t" ;;
  "token list")
    u=${3:-}; printf 'user %s\n' "$u"
    awk -v u="$u" '$1 == u { print "- " $2 ", never expires" }' "$D/tokens" ;;
  "token add")
    u=${3:?}; grep -qx "$u" "$D/users" || { echo "user $u does not exist" >&2; exit 1; }
    t=tk_$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
    printf '%s %s\n' "$u" "$t" >> "$D/tokens"
    echo "token $t created for user $u, never expires" ;;
  "serve "*) exec sleep 3600 ;;
  *) echo "fake ntfy: unsupported: $*" >&2; exit 2 ;;
esac
