# OmaDrop

[🇧🇷 Português (Brasil)](README.pt-BR.md)

A floating dropzone for [Omarchy](https://omarchy.org/) inspired by
[Dropover](https://dropoverapp.com/) (macOS): *collect files in a temporary
shelf, then move, share, or process everything at once.*

Select files in your file manager, **shake the mouse** (or press a hotkey),
and a shelf appears near your cursor holding those files while you navigate
to the real destination — a browser, another app, another workspace — and
drag them out of it.

```
┌──────────────────────────────┐
│ 󰏗 OmaDrop   3 items    󰤨   │
├──────────────────────────────┤
│ ┌──────┐ ┌──────┐ ┌──────┐  │
│ │ 󰈟    │ │ 󰉋    │ │ 󰈦    │  │
│ │a.png │ │folder│ │rep.pdf│ │
│ └──────┘ └──────┘ └──────┘  │
│ [ New shelf ] [ Clear ]      │
└──────────────────────────────┘
```

## Install

```bash
omarchy plugin add git@github.com:lucascnunes/omadrop.git --enable
# or, while developing:
ln -s "$(pwd)" ~/.config/omarchy/plugins/lucas.omadrop
omarchy plugin enable lucas.omadrop
```

The **󰏗** icon joins the bar (right section). It is the body of the plugin:
removing it from the bar disables OmaDrop entirely.

## Usage

| Action | How |
|---|---|
| Capture the selection | Shake the mouse over selected files, **or** press `Super+Shift+D`, **or** right-click the bar icon |
| Open the current shelf | `Super+Shift+A` or left-click the icon |
| Collect by dragging | Drag files from any app **into** the shelf |
| Use the shelf | Drag a tile into any application (browser upload, e-mail attachment, file manager move…) — double-click opens the file |
| Configure | Right-click the bar icon (or the 󰤨 button on the shelf) |

The suggested hotkeys need one line each in `~/.config/hypr/bindings.lua`
(the settings panel copies ready-made lines):

```lua
bind = SUPER SHIFT, D, exec, omarchy-shell omadrop capture
bind = SUPER SHIFT, A, exec, omarchy-shell omadrop open
```

> **How capture works**: Wayland exposes no "selected files" API, so when you
> trigger the hotkey OmaDrop copies the selection behind the scenes (an
> invisible synthesized keypress), reads the list from the clipboard, and
> **restores your previous clipboard content**. You never press Ctrl+C; if
> you prefer copying manually, use `omarchy-shell omadrop clip`, which only
> reads whatever is already on the clipboard. In terminals the key synthesis
> is skipped automatically (avoids sending SIGINT).

## Settings

Available in the panel (the 󰤨 button) and persisted in your `shell.json`
(`~/.config/omarchy/shell.json`, inside this widget's entry):

| Setting | Default | What it does |
|---|---|---|
| `shakeEnabled` | `true` | Enables/disables shake detection |
| `shakeReversals` | `4` | Direction reversals that count as a shake (**lower = more sensitive**) |
| `shelfPosition` | `cursor` | `cursor`, `topLeft`, `topRight`, `bottomLeft`, `bottomRight` |
| `maxItems` | `20` | Item cap for the active shelf |
| `showNotifications` | `true` | "N files shelved" toasts |
| `hotkeyCapture` / `hotkeyOpen` | display only | Visual documentation; apply in bindings.lua |

### Shelf history ("New shelf")

*New shelf* archives the current one and starts fresh. The panel's **Recent
shelves** section lists everything: reopen any shelf (making it active again)
or delete old entries. State lives in `~/.local/state/omadrop/shelf.json` and
survives shell restarts.

## IPC (for scripts and keybinds)

```bash
omarchy-shell omadrop capture   # selection -> shelf (full pipeline)
omarchy-shell omadrop clip      # reads the current clipboard only
omarchy-shell omadrop open      # shows the shelf
omarchy-shell omadrop toggle    # toggles visibility
omarchy-shell omadrop settings  # opens the settings panel
omarchy-shell omadrop archive   # new shelf (archives the current one)
omarchy-shell omadrop clear     # empties the active shelf
omarchy-shell omadrop suspend   # pauses the shake detector (session-scoped)
omarchy-shell omadrop resume
omarchy-shell omadrop status    # JSON snapshot of current state
```

## Troubleshooting

- **Shake never fires** — check `~/.local/state/omadrop/shaked.log`; raise
  sensitivity (`shakeReversals: 3`). Smoke-test risk-free with
  `omarchy-shell omadrop capture`.
- **Shake fires too often** — raise `shakeReversals` to 5–6, or pause with
  `omarchy-shell omadrop suspend`.
- **Capture finds no files** — the focused app must respond to Ctrl+C with
  `text/uri-list` (Nautilus, Dolphin, Thunar and Nemo all do). Inspect
  `~/.local/state/omadrop/capture.log` with `OMADROP_DEBUG=1`.
- **Dragging into apps fails** — remote entries (e.g. `network://`) do not
  take part in native drags; local paths do.

## Architecture

```
manifest.json            hybrid bar-widget + panel (keepLoaded)
OmaDrop.qml              root: IPC, settings, state, daemon, geometry
BarWidget.qml            bar icon + badge (reads shelf.json)
ShelfWindow.qml          layer-shell window: drag-out tiles, DropArea, settings
ShelfModel.js            pure logic (URIs, dedupe, serialization), node-testable
scripts/capture-selection.sh   clipboard snapshot → wtype → uri-list → restore
scripts/omadrop-shaked         Python daemon (~80 Hz over Hyprland socket1)
tests/shelf-model-test.js      node tests/shelf-model-test.js
```

Why Python for the detector: the loop is I/O-bound (~0.02 ms/request
measured; asleep ~98% of the time) so CPU stays under 1% in any language,
and Python needs no build toolchain in a git-distributed plugin. Documented
future upgrades: an in-shell detector via `Quickshell.Io.Socket` (saves
~20 MB RSS) or a native Hyprland C++ plugin (pointer events and button state).

## Support

OmaDrop is free and open source. If it saves you time every day, consider
supporting the project:

- ⭐ Star the repo: [github.com/lucascnunes/omadrop](https://github.com/lucascnunes/omadrop)
- ☕ Buy a coffee: [ko-fi.com/lucascnunes](https://ko-fi.com/lucascnunes)

## License

MIT — see [LICENSE](LICENSE).
