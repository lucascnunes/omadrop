# Changelog

All notable changes to OmaDrop. Versions follow [semantic versioning](https://semver.org/).

## [1.2.6] — 2026-08-26

### Fixed

**Dragging a file out of the shelf no longer crashes the shell.** Dragging a tile could take
down the whole Omarchy shell with a segfault, most often when the destination moved the file
instead of copying it. The drag payload was recomputed every time the shelf changed — and the
drag caused that change itself, by tracking the file it had just moved. Wayland was left
holding a payload that had already been destroyed, and read invalid memory when it asked for
the data. The payload is now frozen when the drag starts, the way "Drag all" already did it.

**A shelf file on disk can no longer stall the shell.** `shelf.json` lives in the user's state
directory and was read whole into the shell — every two seconds by the bar icon, and again when
the panel opened. A large enough file exhausted memory. Reads now stop at a 4 MB ceiling; past
that the shelf is ignored with a log warning, and the file is left untouched rather than
overwritten.

**Filenames are no longer interpreted as HTML.** A file named with tags inside the name was
rendered as formatted content in the shelf, which could trigger loading an external resource.
All interface text is now treated as plain text.

## [1.2.5] — 2026-08-26

### Fixed

**Drag-all actually delivers.** Dropping the full selection on a destination sent the files back
to the shelf and left the zone open. The cause was QML scoping, not drop logic: functions declared
at the root of an inline component cannot reach the document root object's properties, so an
unqualified `controller` threw `ReferenceError` and aborted `finishDrag` before it could archive
or close. Delivery now archives to history, clears the shelf, and closes the zone.

**Shake with nothing selected no longer repeats the previous capture.** The capture script could
not tell a fresh Ctrl+C from a file list its own restore step had left on the clipboard, so the
stale list survived indefinitely and was re-added on every shake. A leftover `text/uri-list` is
now cleared immediately before the synthetic copy.

**The zone no longer covers the destination.** During a drag it moved to the top-right corner —
exactly where the destination window usually sits. It now stays put and disappears.

**Shake no longer dies after a shell restart.** Orphan daemon cleanup ran in parallel with our own
startup, and `pkill` sometimes killed the freshly created process.

## [1.2.1] — 2026-08-26

### Fixed

**Select All / drag-all to another app no longer leaves items on an open shelf.** With
`shelfPosition: cursor`, the Top layer zone sat under the pointer and stole the Wayland drop;
DropArea treated it as "back home" and restored the snapshot.

### Changed

- Park the zone in the top-right while a file drag is in flight
- Empty input mask (click/drop-through) during outbound drag
- Disable DropArea during outbound drag
- Don't settle drag-all until Qt has actually armed `Drag.active`

## [1.2.0] — 2026-08-26

### Fixed

- Single-tile moves remove the item from the shelf (inotify `MOVED_TO`)
- Select All / drag-all external drop archives the shelf and closes the zone
- Esc during drag keeps items and leaves the zone open
- History paths update to the move destination when possible

## [1.1.0] — 2026-08-26

### Added

- Language setting (`auto` / `en` / `pt`) now updates the **entire UI live**: settings panel,
  floating shelf, and toasts.

### Changed

- i18n uses reactive `Strings.tLang(language, key)` bindings instead of module-global state and
  panel recreation.
- READMEs document `Strings.js` and clarify that language changes apply immediately.

## [1.0.0] — 2026-08-26

Initial release. Floating dropzone for Omarchy inspired by Dropover: shake the mouse over a file
selection (or press a hotkey) to collect files into a shelf, then drag them out anywhere.

[1.2.6]: https://github.com/lucascnunes/omadrop/releases/tag/v1.2.6
[1.2.5]: https://github.com/lucascnunes/omadrop/releases/tag/v1.2.5
[1.2.1]: https://github.com/lucascnunes/omadrop/releases/tag/v1.2.1
[1.2.0]: https://github.com/lucascnunes/omadrop/releases/tag/v1.2.0
[1.1.0]: https://github.com/lucascnunes/omadrop/releases/tag/v1.1.0
[1.0.0]: https://github.com/lucascnunes/omadrop/releases/tag/v1.0.0
