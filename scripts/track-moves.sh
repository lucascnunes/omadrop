#!/usr/bin/env bash
# OmaDrop move tracker.
#
# usage: track-moves.sh OLDPATH [OLDPATH...]
#
# Watches $HOME recursively while a drag is in flight. When one of the given
# files is MOVED (disappears from its origin and reappears somewhere else
# with the same name and size), prints "OLDPATH<TAB>NEWPATH" so the shelf can
# rewrite the item to its new destination (active shelf, drag-all snapshot,
# and already-archived history). Copies produce no MOVED_TO and are left
# untouched.
# Self-terminates after 20s.

set -uo pipefail

declare -A want=()   # basename -> old path
declare -A sizes=()  # basename -> byte size

for old in "$@"; do
  base="$(basename -- "$old")"
  want["$base"]="$old"
  sizes["$base"]="$(stat -c %s -- "$old" 2>/dev/null || echo -1)"
done
[ "${#want[@]}" -gt 0 ] || exit 0

timeout 20 inotifywait -m -r -q \
  -e moved_to \
  --format '%w%f' \
  -- "$HOME" 2>/dev/null |
while IFS= read -r file; do
  base="$(basename -- "$file")"
  [ -n "${want[$base]:-}" ] || continue
  sz="$(stat -c %s -- "$file" 2>/dev/null || echo -2)"
  [ "$sz" = "${sizes[$base]}" ] || continue
  printf '%s\t%s\n' "${want[$base]}" "$file"
  unset "want[$base]"
  [ "${#want[@]}" -eq 0 ] && break
done
