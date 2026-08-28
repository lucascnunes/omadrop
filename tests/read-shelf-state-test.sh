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

run_reader() {
  timeout --signal=KILL 1s python3 scripts/read-shelf-state "$1" "$2"
}

rejected_without_timeout() {
  (( $1 != 0 && $1 != 124 && $1 != 137 ))
}

printf 'abcdef' >"$TMP/regular"
output="$(run_reader "$TMP/regular" 10)"
check "regular files are read" test "$output" = "abcdef"

output="$(run_reader "$TMP/regular" 3)"
check "reads stop at limit plus one" test "$output" = "abcd"

output="$(run_reader "$TMP/missing" 10)"
status=$?
check "missing files remain an empty first-run state" test "$status" -eq 0
check "missing files emit nothing" test -z "$output"

ln -s "$TMP/regular" "$TMP/symlink"
run_reader "$TMP/symlink" 10 >"$TMP/output"
status=$?
check "symlinks are rejected" test "$status" -ne 0
check "rejected symlinks emit nothing" test ! -s "$TMP/output"

mkfifo "$TMP/fifo"
run_reader "$TMP/fifo" 10 >"$TMP/output"
status=$?
check "FIFOs are rejected without blocking" rejected_without_timeout "$status"
check "rejected FIFOs emit nothing" test ! -s "$TMP/output"

run_reader /dev/random 10 >"$TMP/output"
status=$?
check "blocking special files are rejected" rejected_without_timeout "$status"

ln -s /dev/random "$TMP/blocking-special-link"
run_reader "$TMP/blocking-special-link" 10 >"$TMP/output"
status=$?
check "blocking special-file symlinks are rejected" rejected_without_timeout "$status"

reader_uses="$(grep -l 'read-shelf-state' OmaDrop.qml BarWidget.qml SettingsPanel.qml | wc -l)"
check "all three QML readers use the helper" test "$reader_uses" -eq 3
deadline_uses="$(grep -l '"timeout", "--signal=KILL", "1s"' OmaDrop.qml BarWidget.qml SettingsPanel.qml | wc -l)"
check "all three QML readers enforce a deadline" test "$deadline_uses" -eq 3
check "direct head readers are gone" test -z "$(grep -l 'head -c' OmaDrop.qml BarWidget.qml SettingsPanel.qml)"

printf '\n'
if (( failures )); then
  printf '%s failed\n' "$failures"
  exit 1
fi
printf 'all passed\n'
