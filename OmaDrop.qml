import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "ShelfModel.js" as ShelfModel
import "Strings.js" as Strings

// OmaDrop panel root. Owns the shelf state, user settings, the shake daemon
// and the capture pipeline; ShelfWindow.qml draws the floating zone and
// BarWidget.qml mirrors the item count on the bar.
//
// Both consumers read the same state file (~/.local/state/omadrop/shell.json
// sibling shelf.json), because the hybrid manifest means widget and panel are
// separate instances that may outlive each other across reloads.
Item {
  id: root

  // ---- injected by the shell's panel loader -------------------------------
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string moduleId: (manifest && manifest.id) || "lucas.omadrop"

  // Absolute paths for the bundled scripts, resolved from this file's URL.
  function scriptPath(name) {
    var url = Qt.resolvedUrl("scripts/" + name).toString()
    return url.indexOf("file://") === 0 ? url.slice("file://".length) : url
  }

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")) + "/omadrop"
  readonly property string statePath: stateDir + "/shelf.json"

  // ---- runtime flags ------------------------------------------------------
  property bool opened: false
  property bool suspended: false       // session kill-switch for the shake daemon

  // ---- settings ------------------------------------------------------------
  // Live from this plugin's entry in shell.json (hybrid plugins live in
  // bar.layout). The local override echoes optimistic writes so controls
  // react on the click itself.
  property var localSettingsOverride: null
  readonly property var pluginEntry: {
    var cfg = shell ? shell.shellConfig : null
    return cfg ? ShelfModel.findBarEntry(cfg, root.moduleId) : null
  }
  readonly property var settings: ShelfModel.normalizeSettings(localSettingsOverride || pluginEntry)
  // Reactive language for toasts / zone: passed into Strings.tLang so bindings
  // re-evaluate when the user switches language in SettingsPanel.
  readonly property string uiLanguage: root.settings.language

  function persistSettings(values) {
    var entry = pluginEntry ? ShelfModel.cloneJson(pluginEntry) : { id: root.moduleId }
    entry.id = root.moduleId
    for (var key in values) entry[key] = values[key]

    localSettingsOverride = ShelfModel.normalizeSettings(entry)
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(root.moduleId, entry)
  }

  // ---- shelf state ----------------------------------------------------------
  property var state: ShelfModel.emptyState()
  readonly property var activeItems: {
    var shelf = ShelfModel.activeShelf(root.state)
    return shelf ? shelf.items : []
  }
  readonly property int itemCount: activeItems.length

  function adoptState(text) {
    root.state = ShelfModel.deserializeState(text)
  }

  // Read through a byte-bounded `head` rather than FileView: shelf.json is
  // user-writable and FileView has no size limit, so an oversized file would
  // land in the shell whole. One byte past the cap keeps "too big" detectable.
  // The panel owns writes and nothing else mutates the file behind us, so a
  // single read at startup is all this needs.
  Process {
    id: stateReader
    stdout: StdioCollector {
      id: stateReaderOut
      waitForEnd: true
    }
    stderr: StdioCollector {}
    onExited: {
      var text = stateReaderOut.text || ""
      if (ShelfModel.isOversizedState(text)) {
        // Refuse it, and do NOT write over it — a state this big is not ours,
        // and clobbering it would destroy whatever the user actually has.
        console.warn("omadrop: shelf state above", ShelfModel.STATE_BYTES_MAX, "bytes — ignored")
        return
      }
      root.adoptState(text)
      // First boot (missing or empty file): materialize a valid state file so
      // every later read is clean.
      if (text === "") root.saveState()
    }
  }

  function loadState() {
    stateReader.command = ["bash", "-c", 'head -c "$1" -- "$0" 2>/dev/null || true',
                           root.statePath, String(ShelfModel.STATE_BYTES_MAX + 1)]
    stateReader.running = true
  }

  // Atomic write through bash: JSON travels as an argv slot, never through a
  // shell-parsed string; mktemp+mv keeps partial writes unreachable.
  Process {
    id: stateWriter
    stderr: StdioCollector {
      onStreamFinished: if (text && text !== "") console.warn("omadrop state write:", text)
    }
    onExited: {
      root._writing = false
      if (root._pendingWrite !== "") root.saveState()
    }
  }
  property bool _writing: false
  property string _pendingWrite: ""

  // Mutation helpers reuse the same state object, and QML var bindings do not
  // re-fire on an identical reference — reassign a clone so views update.
  function commitState() {
    root.state = ShelfModel.cloneJson(root.state)
    root.saveState()
  }

  function saveState() {
    var json = ShelfModel.serializeState(root.state)
    if (root._writing) { root._pendingWrite = json; return }
    root._writing = true
    root._pendingWrite = ""
    stateWriter.command = [
      "bash", "-c",
      'd=$(dirname -- "$1"); mkdir -p "$d"; tmp=$(mktemp "$d/.shelf.XXXXXX") && printf \'%s\' "$2" >"$tmp" && mv "$tmp" "$1"',
      "omadrop-state", root.statePath, json
    ]
    stateWriter.running = true
  }

  // ---- move tracking ----------------------------------------------------------
  // While a tile/handle drag is out in the wild, this watcher watches $HOME
  // for the file being moved. A MOVE during single-tile drag removes the
  // item from the shelf (deliver). During drag-all it rewrites paths on the
  // in-flight snapshot / history so archive records the destination.
  Process {
    id: moveTracker
    stdout: SplitParser {
      onRead: function(data) {
        var parts = String(data).trim().split("\t")
        if (parts.length !== 2) return
        var oldPath = parts[0]
        var newPath = parts[1]

        // Single-tile deliver: QtWayland often never gives a usable drop
        // action, so inotify is the source of truth — drop the item now.
        var singleDrag = shelfWindow && shelfWindow.activeDragTile
                         && !shelfWindow.activeDragWasAll
                         && !shelfWindow.dragCancelRequested
        if (singleDrag) {
          // Tear down drag bookkeeping BEFORE commitState destroys the Tile.
          var t = shelfWindow.activeDragTile
          if (t) {
            if (t.dragEnding !== undefined) t.dragEnding = true
            if (t.dragActive !== undefined) t.dragActive = false
          }
          shelfWindow.activeDragTile = null
          shelfWindow.dropWasInternal = false
          shelfWindow.dragCancelRequested = false
          root.stopMoveTracking()
          if (ShelfModel.removeItemByPath(root.state, oldPath)
              || ShelfModel.removeItemByPath(root.state, newPath)) {
            root.commitState()
            root.maybeCloseOnEmpty()
            return
          }
        }

        var changed = ShelfModel.repointMovedPath(root.state, oldPath, newPath)
        if (shelfWindow && typeof shelfWindow.repointClearedSnapshot === "function")
          shelfWindow.repointClearedSnapshot(oldPath, newPath)
        if (changed) root.commitState()
      }
    }
    stderr: StdioCollector {}
  }

  function startMoveTracking(paths) {
    if (!paths || paths.length === 0) return
    moveTracker.command = ["bash", root.scriptPath("track-moves.sh")].concat(paths)
    moveTracker.running = true
  }

  function stopMoveTracking() {
    moveTracker.running = false
  }

  // ---- capture pipeline ------------------------------------------------------
  Process {
    id: captureProc
    stdout: StdioCollector {
      id: captureOut
      waitForEnd: true
    }
    stderr: StdioCollector {}
    onExited: root.handleCaptureOutput(captureOut.text)
  }

  function runCapture(mode) {
    captureProc.command = ["bash", root.scriptPath("capture-selection.sh"), mode]
    captureProc.running = true
  }

  function handleCaptureOutput(text) {
    var res = ShelfModel.parseCaptureResult(text)
    if (!res.ok) {
      if (res.reason === "terminal-focused") return // stay quiet in terminals
      if (res.reason === "no-selection") {
        if (root.settings.showNotifications) root.notify("OmaDrop", Strings.tLang(root.uiLanguage, "toastNothing"))
        return
      }
      if (root.settings.showNotifications) root.notify("OmaDrop", Strings.tLang(root.uiLanguage, "toastFailed").replace("%1", res.reason || "?"))
      return
    }

    var outcome = ShelfModel.addItems(root.state, res.paths, { maxItems: root.settings.maxItems })
    root.commitState()

    if (outcome.added > 0) {
      if (root.settings.showNotifications) {
        var toast = outcome.added === 1 ? Strings.tLang(root.uiLanguage, "toastShelvedOne")
                                        : Strings.tLang(root.uiLanguage, "toastShelvedMany").replace("%1", String(outcome.added))
        root.notify("OmaDrop", toast)
      }
      // Re-open (and re-anchor to the cursor) on every fresh capture — a
      // closed zone must never force the user to hunt for the bar icon.
      root.openShelf("shelf")
    } else if (outcome.duplicates > 0 && root.settings.showNotifications) {
      root.notify("OmaDrop", Strings.tLang(root.uiLanguage, "toastDuplicate"))
    }
  }

  // Files dropped straight onto the zone (drag-in from other apps).
  // Never re-accept during/after an outbound drag — stolen Wayland drops
  // used to put the drag-all snapshot right back on the shelf.
  function addDroppedUris(urlList, silent) {
    if (shelfWindow.suppressInboundDrops || shelfWindow.activeDragWasAll
        || shelfWindow.dragInProgress)
      return
    var strings = []
    for (var i = 0; i < urlList.length; i++) strings.push(String(urlList[i]))
    if (strings.length === 0) return
    var before = root.itemCount
    ShelfModel.addItems(root.state, strings, { maxItems: root.settings.maxItems })
    root.commitState()
    var addedCount = root.itemCount - before
    if (addedCount > 0 && !silent && root.settings.showNotifications)
      root.notify("OmaDrop", Strings.tLang(root.uiLanguage, "toastDroppedMany").replace("%1", String(addedCount)))
  }

  // ---- shelf mutations -------------------------------------------------------
  function clearActive(allowClose) {
    if (ShelfModel.clearActive(root.state)) {
      root.commitState()
      if (allowClose !== false) root.maybeCloseOnEmpty()
    }
  }

  function removeTile(itemId) {
    if (ShelfModel.removeItem(root.state, itemId)) {
      root.commitState()
      root.maybeCloseOnEmpty()
    }
  }

  function removeTileByPath(path) {
    if (ShelfModel.removeItemByPath(root.state, path)) {
      root.commitState()
      root.maybeCloseOnEmpty()
    }
  }

  // Esc / internal drop during drag-all: put the optimistic snapshot back.
  function restoreSnapshot(items) {
    if (!items || items.length === 0) return
    var shelf = ShelfModel.ensureActiveShelf(root.state)
    shelf.items = ShelfModel.cloneJson(items)
    shelf.updatedAt = Date.now()
    root.commitState()
  }

  // Drag-all was delivered: file the snapshot (with any MOVED_TO path rewrites
  // already applied) into history, then guarantee the end state the UX asks
  // for — empty shelf, closed zone — whatever the archive did.
  function finishDragAll(items) {
    var snap = items && items.length ? items : null
    if (snap) ShelfModel.archiveSnapshot(root.state, snap, {})
    ShelfModel.clearActive(root.state)
    root.commitState()
    root.dismiss()
  }

  // An emptied zone has no reason to keep floating around — unless a drag is
  // still in progress (drag-all clears optimistically at pickup).
  function maybeCloseOnEmpty() {
    if (root.opened && root.itemCount === 0 && !shelfWindow.dragInProgress)
      root.dismiss()
  }

  function archiveCurrent() {
    ShelfModel.archiveCurrent(root.state, {})
    root.commitState()
    if (root.settings.showNotifications) root.notify("OmaDrop", Strings.tLang(root.uiLanguage, "toastArchived"))
  }

  function reopenShelf(id) {
    if (ShelfModel.reopenShelf(root.state, id)) root.commitState()
  }

  function deleteShelfById(id) {
    if (ShelfModel.deleteShelf(root.state, id)) root.commitState()
  }

  function openPath(path) {
    if (!path) return
    Quickshell.execDetached(["xdg-open", path])
  }

  // ---- open/close lifecycle ----------------------------------------------------
  // shell.summon routes back into open(); the direct path is the fallback for
  // shells that predate the payload contract.
  // Settings/history live in the bar widget's popout (SettingsPanel.qml);
  // summoning them routes there instead of opening the floating zone.
  function routeToSettingsPopout() {
    if (shell && shell.bar && typeof shell.bar.summonBarWidget === "function") {
      shell.bar.summonBarWidget(root.moduleId)
      return true
    }
    return false
  }

  function openSettingsPopout() { root.routeToSettingsPopout() }

  function open(payloadJson) {
    var payload = ShelfModel.safeParse(payloadJson) || {}
    if (payload.view === "settings" || payload.view === "history") {
      if (root.routeToSettingsPopout()) return
    }
    root.probeAndShow()
  }

  function openShelf(targetView) {
    if ((targetView === "settings" || targetView === "history") && root.routeToSettingsPopout()) return
    root.probeAndShow()
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide(root.moduleId)
    else root.close()
  }

  function toggleShelf() {
    if (root.opened) root.dismiss()
    else root.openShelf("shelf")
  }

  // ---- geometry -----------------------------------------------------------------
  // One bash round-trip fetches cursor + monitor layout together, so the zone
  // lands on the right output at the configured spot.
  property var pendingMonitor: null // { name, x, y, width, height }

  Process {
    id: geomProbe
    stdout: StdioCollector {
      id: geomOut
      waitForEnd: true
    }
    stderr: StdioCollector {}
    onExited: root.applyGeometry(geomOut.text)
  }

  function probeAndShow() {
    geomProbe.command = ["bash", "-c",
      'echo "{\\"cursor\\":$(hyprctl cursorpos -j),\\"monitors\\":$(hyprctl monitors -j)}"']
    geomProbe.running = true
  }

  function applyGeometry(text) {
    var data = ShelfModel.safeParse(text)
    var monitors = data && Array.isArray(data.monitors) ? data.monitors : []
    var cursor = data && data.cursor ? data.cursor : null
    var monitor = ShelfModel.monitorFor(cursor ? cursor.x : -1, cursor ? cursor.y : -1, monitors)
    if (!monitor && monitors.length > 0) monitor = monitors[0]

    root.pendingMonitor = monitor ? {
      name: String(monitor.name || ""),
      x: Number(monitor.x) || 0,
      y: Number(monitor.y) || 0,
      width: Number(monitor.width) || 1280,
      height: Number(monitor.height) || 800
    } : null

    var pos = ShelfModel.shelfAnchor(
      root.settings.shelfPosition, monitor, cursor,
      shelfWindow.cardWidth,
      shelfWindow.cardHeightPx > 0 ? shelfWindow.cardHeightPx : shelfWindow.cardEstimatedHeight,
      shelfWindow.edgeMargin
    )
    shelfWindow.anchorX = Math.round(pos.x)
    shelfWindow.anchorY = Math.round(pos.y)
    if (monitor && monitor.name) shelfWindow.useScreen(String(monitor.name))

    root.opened = true
  }

  // ---- shake daemon lifecycle -----------------------------------------------------
  Process {
    id: shakeDaemon
    stdout: StdioCollector {}
    stderr: StdioCollector {
      onStreamFinished: if (text && text !== "") console.warn("omadrop-shaked:", text)
    }
  }
  property bool wantDaemon: false
  property string _daemonKey: ""
  Timer {
    id: daemonRestart
    interval: 80
    onTriggered: if (root.wantDaemon) shakeDaemon.running = true
  }

  // Shell restarts orphan older daemons (they hold their own flock after the
  // next fix, but stale-argument ones must still go before ours starts).
  Process {
    id: daemonReaper
    stdout: StdioCollector {}
    // Ours starts only once the sweep is done: pkill runs async, so starting
    // in parallel let it land on the daemon we had just spawned.
    onExited: if (root.wantDaemon) daemonRestart.restart()
  }

  function reapDaemons() {
    daemonReaper.command = ["bash", "-c", 'pkill -f "omadrop-shake[d]" 2>/dev/null || true']
    daemonReaper.running = true
  }

  function syncDaemon() {
    var want = root.settings.shakeEnabled && !root.suspended
    var args = [
      "python3", root.scriptPath("omadrop-shaked"),
      "--reversals", String(root.settings.shakeReversals),
      "--log", root.stateDir + "/shaked.log"
    ]
    var key = JSON.stringify(args) + "|" + String(want)
    if (key === root._daemonKey && shakeDaemon.running === want) return
    root._daemonKey = key
    root.wantDaemon = want
    shakeDaemon.command = args
    shakeDaemon.running = false
    if (want) root.reapDaemons()
  }

  onSettingsChanged: syncDaemon()
  onSuspendedChanged: syncDaemon()

  // ---- small helpers ------------------------------------------------------------------
  Process {
    id: notifier
    stdout: StdioCollector {}
  }

  function notify(title, body) {
    notifier.command = ["notify-send", "-a", "OmaDrop", "-u", "low", "-t", "2600",
                        String(title || "OmaDrop"), String(body || "")]
    notifier.running = true
  }

  Process {
    id: copier
    stdout: StdioCollector {}
  }

  function copyText(value) {
    copier.command = ["bash", "-c", 'printf "%s" "$1" | wl-copy --type text/plain', "omadrop", String(value)]
    copier.running = true
    root.notify("OmaDrop", Strings.tLang(root.uiLanguage, "toastCopied"))
  }

  // ---- IPC -------------------------------------------------------------------------------
  IpcHandler {
    target: "omadrop"

    function ping(): string { return "pong" }
    function capture(): void { root.runCapture("auto") }
    function clip(): void { root.runCapture("clipboard") }
    function open(): void { root.openShelf("shelf") }
    function close(): void { root.dismiss() }
    function toggle(): void { root.toggleShelf() }
    function settings(): void { root.openShelf("settings") }
    function history(): void { root.openShelf("settings") }
    function clear(): void { root.clearActive() }
    function archive(): void { root.archiveCurrent() }
    function suspend(): void { root.suspended = true }
    function resume(): void { root.suspended = false }
    function reopen(id: string): void { root.reopenShelf(String(id || "")) }
    function removeshelf(id: string): void { root.deleteShelfById(String(id || "")) }
    function copyline(value: string): void { root.copyText(String(value || "")) }
    function status(): string {
      return JSON.stringify({
        items: root.itemCount,
        shelves: root.state.shelves.length,
        opened: root.opened,
        suspended: root.suspended,
        daemonRunning: shakeDaemon.running,
        shakeEnabled: root.settings.shakeEnabled,
        position: root.settings.shelfPosition,
        screens: (Quickshell.screens || []).map(function(sc) { return sc.name }),
        pendingMonitor: root.pendingMonitor
      })
    }
  }

  // ---- wiring -----------------------------------------------------------------------------
  Component.onCompleted: {
    root.loadState()
    Qt.callLater(syncDaemon)
  }

  Component.onDestruction: {
    shakeDaemon.running = false
    stateWriter.running = false
    stateReader.running = false
  }

  ShelfWindow {
    id: shelfWindow
    controller: root
    opened: root.opened
  }
}
