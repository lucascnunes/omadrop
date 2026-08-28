#!/usr/bin/env bash

set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
check() {
  local label="$1"
  shift
  if "$@"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label"
    failures=$((failures + 1))
  fi
}

run_writer() {
  python3 scripts/write-shelf-state "$1" "$2"
}

mkdir "$TMP/state"
chmod 0755 "$TMP/state"
printf 'old' >"$TMP/state/shelf.json"
chmod 0644 "$TMP/state/shelf.json"
run_writer "$TMP/state/shelf.json" '{"items":[1]}'
status=$?
check "regular destinations are replaced" test "$status" -eq 0
check "new state is complete" test "$(<"$TMP/state/shelf.json")" = '{"items":[1]}'
check "state files remain private" test "$(stat -c %a "$TMP/state/shelf.json")" = 600
check "state directories become private" test "$(stat -c %a "$TMP/state")" = 700
check "temporary files are removed" test -z "$(compgen -G "$TMP/state/.shelf.*.tmp")"

run_writer "$TMP/new/nested/shelf.json" '{}'
status=$?
check "missing state directories are created" test "$status" -eq 0
check "created state directories are private" test "$(stat -c %a "$TMP/new/nested")" = 700

(umask 0777; run_writer "$TMP/restrictive-umask/state/shelf.json" '{}')
status=$?
check "restrictive caller umasks do not block writes" test "$status" -eq 0
check "caller umasks cannot remove directory access" \
  test "$(stat -c %a "$TMP/restrictive-umask/state")" = 700
check "caller umasks cannot remove file access" \
  test "$(stat -c %a "$TMP/restrictive-umask/state/shelf.json")" = 600

mkdir "$TMP/real-parent"
ln -s "$TMP/real-parent" "$TMP/linked-parent"
run_writer "$TMP/linked-parent/shelf.json" '{}' 2>/dev/null
status=$?
check "symlink parents are rejected" test "$status" -ne 0
check "symlink parents receive no state" test ! -e "$TMP/real-parent/shelf.json"

mkdir "$TMP/destination-state"
printf 'victim' >"$TMP/victim"
ln -s "$TMP/victim" "$TMP/destination-state/shelf.json"
run_writer "$TMP/destination-state/shelf.json" '{}' 2>/dev/null
status=$?
check "symlink destinations are rejected" test "$status" -ne 0
check "symlink targets are untouched" test "$(<"$TMP/victim")" = victim
check "destination symlinks remain" test -L "$TMP/destination-state/shelf.json"

mkdir "$TMP/fifo-state"
mkfifo "$TMP/fifo-state/shelf.json"
run_writer "$TMP/fifo-state/shelf.json" '{}' 2>/dev/null
status=$?
check "non-regular destinations are rejected" test "$status" -ne 0
check "destination FIFOs remain" test -p "$TMP/fifo-state/shelf.json"

python3 tests/write-shelf-state-swap-test.py \
  "$PWD/scripts/write-shelf-state" "$TMP/swap-root"
status=$?
check "parent swaps cannot redirect replacement" test "$status" -eq 0

check "QML writer uses the descriptor-bound helper" \
  grep -q 'scriptPath("write-shelf-state")' OmaDrop.qml
check "pathname-based writer is gone" \
  test -z "$(grep -E 'mktemp|mv .*tmp' OmaDrop.qml)"

printf '\n'
if (( failures )); then
  printf '%s failed\n' "$failures"
  exit 1
fi
printf 'all passed\n'
