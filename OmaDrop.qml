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
  property string view: "shelf"        // shelf | settings
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

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false // the panel owns writes; the bar widget watches instead
    onLoaded: root.adoptState(text())
    onLoadFailed: {
      // First boot: materialize a valid state file so every later read is clean.
      root.adoptState("")
      root.saveState()
    }
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
        if (root.settings.showNotifications) root.notify("OmaDrop", Strings.t("toastNothing"))
        return
      }
      if (root.settings.showNotifications) root.notify("OmaDrop", Strings.t("toastFailed").replace("%1", res.reason || "?"))
      return
    }

    var outcome = ShelfModel.addItems(root.state, res.paths, { maxItems: root.settings.maxItems })
    root.state = outcome.state
    root.saveState()

    if (outcome.added > 0) {
      if (root.settings.showNotifications) {
        var toast = outcome.added === 1 ? Strings.t("toastShelvedOne")
                                        : Strings.t("toastShelvedMany").replace("%1", String(outcome.added))
        root.notify("OmaDrop", toast)
      }
      if (!root.opened) root.openShelf("shelf")
    } else if (outcome.duplicates > 0 && root.settings.showNotifications) {
      root.notify("OmaDrop", Strings.t("toastDuplicate"))
    }
  }

  // Files dropped straight onto the zone (drag-in from other apps).
  function addDroppedUris(urlList) {
    var strings = []
    for (var i = 0; i < urlList.length; i++) strings.push(String(urlList[i]))
    if (strings.length === 0) return
    var outcome = ShelfModel.addItems(root.state, strings, { maxItems: root.settings.maxItems })
    root.state = outcome.state
    root.saveState()
    if (outcome.added > 0 && root.settings.showNotifications)
      root.notify("OmaDrop", Strings.t("toastDroppedMany").replace("%1", String(outcome.added)))
  }

  // ---- shelf mutations -------------------------------------------------------
  function clearActive() {
    if (ShelfModel.clearActive(root.state)) root.saveState()
  }

  function removeTile(itemId) {
    if (ShelfModel.removeItem(root.state, itemId)) root.saveState()
  }

  function archiveCurrent() {
    root.state = ShelfModel.archiveCurrent(root.state, {})
    root.saveState()
    if (root.settings.showNotifications) root.notify("OmaDrop", Strings.t("toastArchived"))
  }

  function reopenShelf(id) {
    if (ShelfModel.reopenShelf(root.state, id)) {
      root.saveState()
      root.view = "shelf"
    }
  }

  function deleteShelfById(id) {
    if (ShelfModel.deleteShelf(root.state, id)) root.saveState()
  }

  function openPath(path) {
    if (!path) return
    Quickshell.execDetached(["xdg-open", path])
  }

  // ---- open/close lifecycle ----------------------------------------------------
  // shell.summon routes back into open(); the direct path is the fallback for
  // shells that predate the payload contract.
  function open(payloadJson) {
    var payload = ShelfModel.safeParse(payloadJson) || {}
    root.view = (payload.view === "settings" || payload.view === "history") ? payload.view : "shelf"
    root.probeAndShow()
  }

  function openShelf(targetView) {
    var payload = JSON.stringify({ view: targetView || "shelf" })
    if (shell && typeof shell.summon === "function") shell.summon(root.moduleId, payload)
    else root.open(payload)
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
      shelfWindow.cardWidth, shelfWindow.cardEstimatedHeight, shelfWindow.edgeMargin
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
    if (want) daemonRestart.restart()
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
    root.notify("OmaDrop", Strings.t("toastCopied"))
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
    function status(): string {
      return JSON.stringify({
        items: root.itemCount,
        shelves: root.state.shelves.length,
        opened: root.opened,
        suspended: root.suspended,
        daemonRunning: shakeDaemon.running,
        shakeEnabled: root.settings.shakeEnabled,
        position: root.settings.shelfPosition
      })
    }
  }

  // ---- wiring -----------------------------------------------------------------------------
  Component.onCompleted: {
    Qt.callLater(function() {
      syncDaemon()
      // FileView may still be loading; adopt whatever is there by then.
      if (root.state.shelves.length === 0) root.adoptState(stateFile.text())
    })
  }

  Component.onDestruction: {
    shakeDaemon.running = false
    stateWriter.running = false
  }

  ShelfWindow {
    id: shelfWindow
    controller: root
    opened: root.opened
  }
}
