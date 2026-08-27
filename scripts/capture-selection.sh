#!/usr/bin/env bash
# OmaDrop selection capture.
#
# Usage: capture-selection.sh [auto|clipboard]
#   auto       (default) snapshot clipboard -> synthesize Ctrl+C on the
#              focused window -> read text/uri-list -> restore the previous
#              clipboard content. The user never presses anything besides the
#              OmaDrop hotkey/shake; the copy here is an invisible internal
#              step because Wayland exposes no "list selected files" API.
#   clipboard  read-only: report whatever file list is already on the
#              clipboard right now (for people who prefer copying manually).
#
# Prints exactly one JSON line:
#   {"ok":bool,"paths":["/abs/path",...],"reason":""|"terminal-focused"|"no-selection"|...}

set -uo pipefail

MODE="${1:-auto}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omadrop"
mkdir -p "$STATE_DIR"
LOG="${OMADROP_CAPTURE_LOG:-$STATE_DIR/capture.log}"

say()   { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG" 2>/dev/null || true; }
debug() { say "DEBUG $*"; }

finish() { # $1 = ok ("true"/"false")  $2 = reason  $3 = raw uri-list
  RAW="$3" python3 - "$1" "$2" <<'PY' 2>>"$LOG"
import json, os, sys, urllib.parse

ok = sys.argv[1] == "true"
reason = sys.argv[2]
raw = os.environ.get("RAW", "")

paths = []
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    if line.startswith("file:"):
        rest = line[len("file://"):] if line.startswith("file://") else line[5:]
        if rest.startswith("localhost/"):
            rest = rest[len("localhost"):]
        rest = rest.split("?", 1)[0].split("#", 1)[0]
        try:
            paths.append(urllib.parse.unquote(rest))
        except Exception:
            paths.append(rest)
    elif line.startswith("/"):
        paths.append(line)

if ok and not paths:
    reason = reason or ("no-selection" if not raw.strip() else "no-local-files")

print(json.dumps({"ok": bool(ok and paths), "paths": paths, "reason": reason}))
PY
}

# --------------------------------------------------------------------------
# Read-only mode: hand back whatever is on the clipboard, untouched.
if [[ $MODE == "clipboard" ]]; then
  uris="$(wl-paste --type text/uri-list 2>/dev/null || true)"
  finish true "" "$uris"
  exit 0
fi

# --------------------------------------------------------------------------
# Focused-window gate: synthesizing Ctrl+C inside a terminal would send
# SIGINT to whatever is running there, so we stay quiet instead.
cls="$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // ""' 2>/dev/null || echo "")"
lcls="${cls,,}"
debug "focused class: ${cls:-<none>}"
case "$lcls" in
  *kitty*|*alacritty*|*foot*|*ghostty*|*wezterm*)
    debug "terminal focused -> skipping key synthesis"
    finish false "terminal-focused" ""
    exit 0 ;;
esac

# --------------------------------------------------------------------------
# Snapshot the interesting clipboard payloads so we can put them back.
SNAP="$(mktemp -d)"
trap 'rm -rf "$SNAP"' EXIT

prev_uri=""
prev_png=""
prev_txt=""
prev_pri=""

if wl-paste --type text/uri-list >"$SNAP/uri" 2>/dev/null && [[ -s $SNAP/uri ]]; then prev_uri="$SNAP/uri"; fi
if wl-paste --type image/png     >"$SNAP/png" 2>/dev/null && [[ -s $SNAP/png ]]; then prev_png="$SNAP/png"; fi
if wl-paste --type text          >"$SNAP/txt"  2>/dev/null && [[ -s $SNAP/txt ]]; then prev_txt="$SNAP/txt"; fi
if wl-paste --primary --type text/uri-list >"$SNAP/pri" 2>/dev/null && [[ -s $SNAP/pri ]]; then prev_pri="$SNAP/pri"; fi

cleared_clipboard="no"
cleared_primary="no"

restore_primary() {
  if [[ $cleared_primary == "yes" && -n $prev_pri ]]; then
    wl-copy --primary --type text/uri-list <"$prev_pri" >/dev/null 2>&1
    cleared_primary="no"
  fi
}

restore_previous() {
  # wl-copy forks and keeps serving the clipboard; without the redirects it
  # inherits our stdout/stderr and any caller waiting on pipe EOF hangs.
  if [[ -n $prev_uri ]]; then
    wl-copy --type text/uri-list <"$prev_uri" >/dev/null 2>&1
  elif [[ -n $prev_png ]]; then
    wl-copy --type image/png <"$prev_png" >/dev/null 2>&1
  elif [[ -n $prev_txt ]]; then
    wl-copy --type text <"$prev_txt" >/dev/null 2>&1
  fi
  cleared_clipboard="no"
  restore_primary
}

# --------------------------------------------------------------------------
# Drop any uri-list we are still holding from an earlier capture.
#
# With nothing selected the synthesized Ctrl+C is a no-op, so the read below
# would hand back the *previous* capture's file list — and restoring it
# afterwards kept that list alive forever, so every later shake re-shelved
# the same files. Clearing first means anything we read after the copy was
# published by our own keystroke. Clipboards holding no uri-list are left
# untouched: they cannot be mistaken for a selection.
clear_stale_uris() {
  if [[ -n $prev_uri ]] && wl-copy --clear >/dev/null 2>&1; then cleared_clipboard="yes"; fi
  if [[ -n $prev_pri ]] && wl-copy --primary --clear >/dev/null 2>&1; then cleared_primary="yes"; fi
  [[ $cleared_clipboard == "yes" || $cleared_primary == "yes" ]] \
    && debug "cleared stale uri-list (clipboard=$cleared_clipboard primary=$cleared_primary)"
  return 0
}

# --------------------------------------------------------------------------
# The invisible internal copy.
#
# wtype acts as a Wayland input method, and only one IM can own the seat —
# with fcitx5 running it connects fine but keystrokes may never land. ydotool
# synthesizes at kernel level (uinput) and is immune to that; its daemon is
# started on demand and left running (tiny, reused by later captures).
YDOTOOL_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ydotoold.socket"
copy_sent="no"

# ydotool injects discrete press and release events at the kernel (uinput)
# layer, so an interrupted sequence leaves the key HELD for the entire
# desktop, not just for us — a stuck modifier or letter survives this script
# and auto-repeats into whatever is focused. A held letter also drops file
# managers into type-ahead find, where Ctrl+C copies the search box instead of
# the selection, which is how a stuck key turns into a silent "no-selection".
#
# Releasing a key that is not currently held is a no-op, so this is safe to
# call at any point, including twice.
release_keys() {
  [ -S "$YDOTOOL_SOCKET" ] || return 0
  # ctrl/shift/alt/meta (both sides), C, and the F24 probe key below.
  YDOTOOL_SOCKET="$YDOTOOL_SOCKET" ydotool key -d 5 \
    29:0 97:0 42:0 54:0 56:0 100:0 125:0 126:0 46:0 194:0 2>>"$LOG" || true
  return 0
}

# Widen the existing cleanup so nothing stays latched even if this script is
# killed mid-sequence.
trap 'release_keys; rm -rf "$SNAP"' EXIT

# A dead daemon leaves the socket file behind; probe before trusting it.
probe_daemon() {
  [ -S "$YDOTOOL_SOCKET" ] || return 1
  YDOTOOL_SOCKET="$YDOTOOL_SOCKET" ydotool key -d 30 194:1 194:0 2>>"$LOG"
  local rc=$?
  release_keys
  return $rc
}
send_ctrl_c() {
  # 29 = LeftCtrl, 46 = C. -d 30 spaces the events: back-to-back key events
  # get dropped by some apps.
  release_keys   # start from a known-clean state, whatever ran before us
  YDOTOOL_SOCKET="$YDOTOOL_SOCKET" ydotool key -d 30 29:1 46:1 46:0 29:0 2>>"$LOG"
  local rc=$?
  release_keys   # and never leave anything held, including on failure
  return $rc
}
clear_stale_uris
if probe_daemon; then
  if send_ctrl_c; then
    copy_sent="ydotool"
  fi
else
  rm -f "$YDOTOOL_SOCKET"
  YDOTOOL_SOCKET="$YDOTOOL_SOCKET" nohup ydotoold -p "$YDOTOOL_SOCKET" >/dev/null 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$YDOTOOL_SOCKET" ] && break
    sleep 0.1
  done
  if probe_daemon && send_ctrl_c; then
    copy_sent="ydotool"
  else
    debug "ydotoold could not start; falling back to wtype"
  fi
fi
if [[ $copy_sent == "no" ]]; then
  if wtype -M ctrl -k c -m ctrl 2>>"$LOG"; then
    copy_sent="wtype"
  else
    debug "no key synthesis available (continuing; clipboard may already hold a selection)"
    # Without a copy of our own the pre-existing clipboard is all we have, so
    # hand it back and fall through to the read (legacy manual-copy path).
    restore_previous
  fi
fi
debug "copy sent via: $copy_sent"

# Wait for the copy to actually land instead of a fixed sleep: Nautilus and
# friends can take a few hundred ms to publish the new clipboard.
cap=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  cap="$(wl-paste --type text/uri-list 2>/dev/null || true)"
  [ -n "${cap//[[:space:]]/}" ] && break
  sleep 0.1
done
# Some apps only mirror the copy into the primary selection.
if [[ -z ${cap//[[:space:]]/} ]]; then
  cap="$(wl-paste --primary --type text/uri-list 2>/dev/null || true)"
  [[ -n ${cap//[[:space:]]/} ]] && debug "recovered from primary selection"
fi

# Nothing came back: restore what the user had and report quietly.
if [[ -z ${cap//[[:space:]]/} ]]; then
  restore_previous
  debug "empty uri-list after copy"
  finish true "no-selection" ""
  exit 0
fi

# The app just re-published the very list we snapshotted (same files selected
# again): its own offer is richer than our uri-list-only copy, so leave it.
if [[ -n $prev_uri ]] \
  && diff -q <(tr -d '\r' <"$prev_uri") <(printf '%s\n' "$cap" | tr -d '\r') >/dev/null 2>&1; then
  restore_primary
  debug "re-copied the same list; clipboard left as the app published it"
  finish true "" "$cap"
  exit 0
fi

restore_previous
debug "captured $(printf '%s\n' "$cap" | grep -c . ) entries; clipboard restored"
finish true "" "$cap"
