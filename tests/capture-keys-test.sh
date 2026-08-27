#!/usr/bin/env bash
# Guards the one invariant that matters in capture-selection.sh's key
# synthesis: a press is ALWAYS bracketed by releases.
#
# ydotool injects at the uinput layer, so a key left pressed stays pressed for
# the whole desktop — that is what stuck a user's `c` key and cost a reboot.
#
# Run: bash tests/capture-keys-test.sh

set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A fake ydotool that records its arguments instead of touching the kernel.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/ydotool" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$YDOTOOL_CALLS"
exit "${YDOTOOL_RC:-0}"
STUB
chmod +x "$TMP/bin/ydotool"

# release_keys refuses to run without a real socket, so make one.
python3 - "$TMP/sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
PY

# Pull the synthesis functions out of the script and load them in isolation:
# sourcing the whole file would touch the real clipboard.
sed -n '/^release_keys() {/,/^clear_stale_uris$/p' scripts/capture-selection.sh \
  | sed '$d' >"$TMP/funcs.sh"

failures=0
check() { # $1 = label, $2 = expected, $3 = actual
  if [[ "$2" == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

run_case() { # $1 = function to call, $2 = ydotool exit code
  export YDOTOOL_CALLS="$TMP/calls"
  export YDOTOOL_RC="$2"
  : >"$YDOTOOL_CALLS"
  (
    PATH="$TMP/bin:$PATH"
    YDOTOOL_SOCKET="$TMP/sock"
    LOG="$TMP/log"
    SNAP="$TMP/snap"
    # shellcheck disable=SC1090
    source "$TMP/funcs.sh"
    trap - EXIT          # the sourced trap is for the real script, not the test
    "$1" >/dev/null 2>&1
  )
  # Collapse each call to press/release by looking for any ":1" argument.
  awk '{ print (/:1/ ? "press" : "release") }' "$YDOTOOL_CALLS" | paste -sd, -
}

echo "--- capture-selection.sh key-release invariant ---"

check "send_ctrl_c brackets the press with releases" \
      "release,press,release" "$(run_case send_ctrl_c 0)"

check "send_ctrl_c still releases when ydotool fails" \
      "release,press,release" "$(run_case send_ctrl_c 1)"

check "probe_daemon releases its probe key" \
      "press,release" "$(run_case probe_daemon 0)"

# The EXIT trap is the last line of defence if the script is killed outright.
grep -q "trap 'release_keys; rm -rf \"\$SNAP\"' EXIT" scripts/capture-selection.sh \
  && printf 'ok   EXIT trap releases keys\n' \
  || { printf 'FAIL EXIT trap does not call release_keys\n'; failures=$((failures + 1)); }

echo
if (( failures )); then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
