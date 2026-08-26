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
debug() { [[ -n ${OMADROP_DEBUG:-} ]] && say "DEBUG $*" || true; }

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

if wl-paste --type text/uri-list >"$SNAP/uri" 2>/dev/null && [[ -s $SNAP/uri ]]; then prev_uri="$SNAP/uri"; fi
if wl-paste --type image/png     >"$SNAP/png" 2>/dev/null && [[ -s $SNAP/png ]]; then prev_png="$SNAP/png"; fi
if wl-paste --type text          >"$SNAP/txt"  2>/dev/null && [[ -s $SNAP/txt ]]; then prev_txt="$SNAP/txt"; fi

# --------------------------------------------------------------------------
# The invisible internal copy.
if ! wtype -M ctrl -k c -m ctrl 2>>"$LOG"; then
  debug "wtype failed (continuing; clipboard may already hold a selection)"
fi
sleep 0.28

cap="$(wl-paste --type text/uri-list 2>/dev/null || true)"

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
}

# Nothing came back: restore what the user had and report quietly.
if [[ -z ${cap//[[:space:]]/} ]]; then
  restore_previous
  debug "empty uri-list after copy"
  finish true "no-selection" ""
  exit 0
fi

# If the clipboard already held this exact list there is nothing to undo.
if [[ -n $prev_uri ]] \
  && diff -q <(tr -d '\r' <"$prev_uri") <(printf '%s\n' "$cap" | tr -d '\r') >/dev/null 2>&1; then
  debug "clipboard already matched; no restore needed"
  finish true "" "$cap"
  exit 0
fi

restore_previous
debug "captured $(printf '%s\n' "$cap" | grep -c . ) entries; clipboard restored"
finish true "" "$cap"
