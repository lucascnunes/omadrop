import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ShelfModel.js" as ShelfModel
import "Strings.js" as Strings

// The floating OmaDrop zone: a small layer-shell window anchored near the
// cursor or a screen corner. Deliberately NOT a fullscreen scrim — the
// desktop around it stays interactive, like Dropover's bucket.
//
// Settings/history live in SettingsPanel.qml, hosted by the BAR WIDGET as a
// popout under the icon (house pattern); the gear here just summons it.
Item {
  id: panelRoot

  // ---- API used by OmaDrop.qml ---------------------------------------------
  property var controller: null
  property bool opened: false
  property int anchorX: 24
  property int anchorY: 24

  readonly property int cardWidth: Style.space(448)
  readonly property int edgeMargin: Style.space(10)
  readonly property int cardHeightPx: card.height

  // Derived from the controller's probed monitor — these MUST track it, the
  // drag/anchor clamps otherwise silently use the 1280x800 defaults (this
  // exact bug froze the zone at x=822 on wider displays).
  readonly property int monitorWidth: controller && controller.pendingMonitor ? controller.pendingMonitor.width : 1280
  readonly property int monitorHeight: controller && controller.pendingMonitor ? controller.pendingMonitor.height : 800
  property string screenName: ""

  function useScreen(name) {
    panelRoot.screenName = String(name || "")
    var screens = Quickshell.screens || []
    var names = []
    for (var i = 0; i < screens.length; i++) {
      names.push(screens[i].name)
      if (screens[i].name === panelRoot.screenName) { panel.screen = screens[i]; return }
    }
    console.warn("omadrop: screen '" + panelRoot.screenName + "' not found; have: " + names.join(", "))
  }

  function requestClose() { if (controller) controller.dismiss() }

  readonly property var items: controller ? controller.activeItems : []
  // Prefer the controller's reactive language so zone labels follow Settings.
  readonly property string uiLanguage: controller && controller.uiLanguage
                                       ? controller.uiLanguage
                                       : (controller && controller.settings ? controller.settings.language : "auto")

  readonly property bool dragInProgress: draggingZone || activeDragTile !== null

  // Tile being dragged, if any — Esc cancels the drag and returns the tile
  // instead of closing the zone.
  property var activeDragTile: null
  property bool dropWasInternal: false

  // Drag-all clears the shelf at pickup (empty UI during the gesture) but
  // keeps AllDragHandle visible so the drag source is never torn down.
  // Esc restores the snapshot; external drop archives + dismisses.
  // dropWasInternal alone is NOT cancel — stolen Wayland drops used to
  // restore the shelf. Inbound DropArea is suppressed for the outbound drag.
  property bool activeDragWasAll: false
  property var clearedSnapshot: []
  // Esc sets this; it is the ONLY cancel signal we trust for drag-all.
  property bool dragCancelRequested: false
  property int dragAllMoveHits: 0
  // Ignore inbound DropArea events for the whole outbound drag and a short
  // tail after finish — late drop events otherwise re-add the same URIs.
  property bool suppressInboundDrops: false

  Timer {
    id: inboundDropGate
    interval: 500
    repeat: false
    onTriggered: panelRoot.suppressInboundDrops = false
  }

  function beginOutboundDrag() {
    panelRoot.suppressInboundDrops = true
    inboundDropGate.stop()
  }

  function endOutboundDrag() {
    // Keep DropArea deaf briefly so a ghost drop after Drag.active flips
    // cannot addDroppedUris / restore the snapshot we just archived.
    panelRoot.suppressInboundDrops = true
    inboundDropGate.restart()
  }

  // Move tracker callback: rewrite paths on the in-flight drag-all snapshot
  // so finishDragAll archives the destination, not the origin.
  function repointClearedSnapshot(oldPath, newPath) {
    if (!Array.isArray(clearedSnapshot) || clearedSnapshot.length === 0) return
    if (ShelfModel.repointItemsPath(clearedSnapshot, oldPath, newPath)) {
      clearedSnapshot = ShelfModel.cloneJson(clearedSnapshot)
      dragAllMoveHits++
    }
  }

  // Hands the in-flight drag-all snapshot over and resets it. Lives here, not
  // in AllDragHandle: functions declared on an inline component's root cannot
  // reach the document root's properties (that is what broke the drag-all
  // teardown), so the safe move is to keep this logic on panelRoot itself.
  function takeClearedSnapshot() {
    var snap = ShelfModel.cloneJson(clearedSnapshot || []) || []
    clearedSnapshot = []
    return snap
  }

  function cancelActiveDrag() {
    if (!panelRoot.activeDragTile) return false
    panelRoot.dragCancelRequested = true
    panelRoot.dropWasInternal = true
    if (panelRoot.activeDragWasAll && controller
        && panelRoot.items.length === 0 && panelRoot.clearedSnapshot.length > 0)
      controller.restoreSnapshot(panelRoot.clearedSnapshot)
    panelRoot.activeDragTile.Drag.cancel()
    panelRoot.activeDragTile.finishDrag(false)
    return true
  }

  function handleEscape() {
    // One Esc entry point: cancel an in-flight drag (keep items + zone),
    // otherwise dismiss. Debounced so Shortcut + Keys.onPressed for the
    // same keystroke cannot cancel then immediately close.
    if (escapeGate.running) return
    escapeGate.restart()
    if (panelRoot.cancelActiveDrag()) return
    panelRoot.requestClose()
  }

  Timer {
    id: escapeGate
    interval: 50
    repeat: false
  }

  // Single Esc handler (also covers focus lost to the Wayland drag).
  Shortcut {
    sequence: "Escape"
    enabled: panelRoot.opened
    onActivated: panelRoot.handleEscape()
  }

  // ---- zone dragging ------------------------------------------------------
  // Local pointer coordinates are computed by the compositor against the
  // surface position at delivery time; while we reposition the surface those
  // go stale and the window orbits the cursor. The global cursor comes from
  // Hyprland's IPC socket instead, which is geometry-independent. The reply
  // is "x, y" with no trailing newline, hence splitMarker " " and a tiny
  // two-chunk state machine per connection (Hyprland closes after each
  // reply; the 16ms timer reconnects).
  property bool draggingZone: false
  property point zonePressAnchor: Qt.point(0, 0)
  property point zonePressCursor: Qt.point(-1, -1)

  // Global cursor source while dragging. A tiny python streamer prints
  // "x, y" lines (~60 Hz) straight from Hyprland's socket: local pointer
  // events go stale while the surface is repositioned under the pointer, and
  // the raw-socket variant in QML lost every reply's second number to the
  // line-splitting parser. The process lives only during the drag.
  Process {
    id: cursorStream
    stdout: SplitParser {
      onRead: function(data) {
        var parts = String(data).trim().split(",")
        if (parts.length !== 2) return
        var cx = parseFloat(parts[0])
        var cy = parseFloat(parts[1])
        if (!isFinite(cx) || !isFinite(cy) || !panelRoot.draggingZone) return
        if (panelRoot.zonePressCursor.x < 0) { panelRoot.zonePressCursor = Qt.point(cx, cy); return }
        var nx = panelRoot.zonePressAnchor.x + Math.round(cx - panelRoot.zonePressCursor.x)
        var ny = panelRoot.zonePressAnchor.y + Math.round(cy - panelRoot.zonePressCursor.y)
        panelRoot.anchorX = Math.min(Math.max(panelRoot.edgeMargin, nx),
                                     Math.max(panelRoot.edgeMargin, panelRoot.monitorWidth - panel.width - panelRoot.edgeMargin))
        panelRoot.anchorY = Math.min(Math.max(panelRoot.edgeMargin, ny),
                                     Math.max(panelRoot.edgeMargin, panelRoot.monitorHeight - panel.height - panelRoot.edgeMargin))
      }
    }
    stderr: StdioCollector {}
  }

  function glyphForKind(kind) {
    if (kind === "dir") return "󰉋"
    if (kind === "image") return "󰈟"
    if (kind === "video") return "󰈫"
    if (kind === "audio") return "󰎈"
    if (kind === "pdf") return "󰈦"
    if (kind === "archive") return "󰀪"
    if (kind === "text") return "󰈙"
    if (kind === "doc") return "󰈚"
    if (kind === "link") return "󰌹"
    return "󰈔"
  }

  // ---- the layer window -------------------------------------------------------
  // Anchored to the output's top-left with exact margins: deterministic across
  // compositors (no centering semantics).
  PanelWindow {
    id: panel
    visible: panelRoot.opened
    color: "transparent"

    anchors { left: true; top: true }
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "omadrop"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    // Width comes from the constant, never from card<->panel cross-references
    // (a binding cycle collapses the layer surface to 1px wide).
    implicitWidth: panelRoot.cardWidth
    implicitHeight: card.height

    readonly property int clampedX: Math.round(
      Math.min(Math.max(panelRoot.edgeMargin, panelRoot.anchorX),
               Math.max(panelRoot.edgeMargin, panelRoot.monitorWidth - width - panelRoot.edgeMargin)))
    readonly property int clampedY: Math.round(
      Math.min(Math.max(panelRoot.edgeMargin, panelRoot.anchorY),
               Math.max(panelRoot.edgeMargin, panelRoot.monitorHeight - height - panelRoot.edgeMargin)))

    // Fading out beats moving: parking the zone in a corner during the drag
    // just covered whatever lived in that corner, which is often the very
    // window the files are headed for.
    readonly property bool parkForDrag: panelRoot.activeDragTile !== null

    margins.left: clampedX
    margins.top: clampedY

    // Empty input region while a file drag is out: this Top layer must not
    // become the Wayland drop target under the cursor, or the DropArea steals
    // the drop from the destination app. Esc still works via Shortcut.
    Region { id: passThroughMask }
    Region { id: cardInputMask; item: card }
    mask: parkForDrag ? passThroughMask : cardInputMask

    // ---- card -----------------------------------------------------------------
    Rectangle {
      id: card
      anchors.top: parent.top
      anchors.left: parent.left
      width: panelRoot.cardWidth
      height: contentCol.implicitHeight + Style.space(14) * 2

      radius: Style.cornerRadius > 0 ? Style.cornerRadius : 8
      color: Color.popups.background
      border.width: 1
      border.color: dropArea.contains ? Color.accent : Color.popups.border

      // Get out of the way while the files are in flight — opacity, never
      // visible/enabled: hiding the drag source mid-gesture kills the drag.
      opacity: panel.parkForDrag ? 0 : 1

      Behavior on opacity { NumberAnimation { duration: 90 } }
      Behavior on border.color { ColorAnimation { duration: 120 } }

      // Keyboard escape hatch (works after the card takes OnDemand focus).
      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            panelRoot.handleEscape()
            event.accepted = true
          }
        }
      }

      // Files dragged from other apps land here and join the shelf.
      // During our own outbound drag (and a short tail after), ignore ALL
      // drops: the Top layer often still receives the Wayland drop under the
      // cursor, and treating it as inbound used to put every file back.
      DropArea {
        id: dropArea
        anchors.fill: parent
        enabled: !panelRoot.suppressInboundDrops && panelRoot.activeDragTile === null
        property bool contains: false
        onEntered: contains = true
        onExited: contains = false
        onDropped: function(drop) {
          contains = false
          if (panelRoot.suppressInboundDrops || panelRoot.activeDragTile
              || panelRoot.activeDragWasAll) {
            return
          }
          var urls = drop.urls || []
          if (urls.length > 0 && controller) controller.addDroppedUris(urls)
        }
      }

      Column {
        id: contentCol
        x: Style.space(14)
        y: Style.space(14)
        width: parent.width - Style.space(28)
        spacing: Style.space(10)

        // ---- header ---------------------------------------------------------
        // Grabbing any empty part of this row drags the whole zone around;
        // the buttons are later siblings, so their clicks win over the drag.
        Item {
          width: parent.width
          height: Style.space(30)

          MouseArea {
            id: windowDrag
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.SizeAllCursor
            onPressed: function(mouse) {
              panelRoot.zonePressAnchor = Qt.point(panelRoot.anchorX, panelRoot.anchorY)
              panelRoot.zonePressCursor = Qt.point(-1, -1)
              panelRoot.draggingZone = true
              if (panelRoot.controller) {
                cursorStream.command = ["python3", "-u", panelRoot.controller.scriptPath("cursor-stream")]
                cursorStream.running = true
              }
            }
            onReleased: function(mouse) {
              panelRoot.draggingZone = false
              cursorStream.running = false
            }
            onCanceled: {
              panelRoot.draggingZone = false
              cursorStream.running = false
            }
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: "󰏗"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: "OmaDrop"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              visible: panelRoot.items.length > 0
              width: countLabel.implicitWidth + Style.space(12)
              height: Style.space(18)
              radius: height / 2
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)

              Text {
                id: countLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: (panelRoot.items.length === 1 ? Strings.tLang(uiLanguage, "oneItem")
                                                   : Strings.tLang(uiLanguage, "manyItems").replace("%1", String(panelRoot.items.length)))
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            IconChip {
              glyph: "󰒓"
              tooltipText: Strings.tLang(uiLanguage, "gearTooltip")
              onClicked: if (panelRoot.controller) panelRoot.controller.openSettingsPopout()
            }

            IconChip {
              glyph: "󰅖"
              tooltipText: Strings.tLang(uiLanguage, "closeTooltip")
              onClicked: panelRoot.requestClose()
            }
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.12)
        }

        // ---- grid -------------------------------------------------------------
        Item {
          width: parent.width
          // Fixed height while empty: the hint fills this box, so sizing it
          // from its child would be circular.
          height: panelRoot.items.length > 0 ? grid.height : Style.space(140)

          GridView {
            id: grid
            width: parent.width
            height: Math.min(contentHeight, Style.space(296))
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            cellWidth: Style.space(103)
            cellHeight: Style.space(104)

            model: panelRoot.items

            delegate: Tile {
              tileData: modelData
              onRemoveRequested: if (controller) controller.removeTile(tileData.id)
              onOpenRequested: if (controller) controller.openPath(tileData.path)
            }
          }

          EmptyState {
            anchors.fill: parent
            visible: panelRoot.items.length === 0
          }
        }

        // ---- footer ------------------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(6)

          Row {
            spacing: Style.space(6)

            // Keep visible while drag-all is in flight even after clearActive
            // empties the model — hiding the drag source mid-gesture made Qt
            // deliver the drop back into our DropArea.
            AllDragHandle {
              visible: panelRoot.items.length > 0 || panelRoot.activeDragWasAll
            }

            ChipButton {
              label: Strings.tLang(uiLanguage, "newShelf")
              tooltipText: Strings.tLang(uiLanguage, "newShelfTooltip")
              onClicked: if (controller) controller.archiveCurrent()
            }

            ChipButton {
              label: Strings.tLang(uiLanguage, "clearShelf")
              tooltipText: Strings.tLang(uiLanguage, "clearShelfTooltip")
              enabled: panelRoot.items.length > 0
              onClicked: if (controller) controller.clearActive()
            }
          }

          // Wrapped on purpose: the hint reads as a caption under the buttons
          // instead of fighting them for one row's width.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: panelRoot.items.length > 0
                  ? Strings.tLang(uiLanguage, "dragHintWithItems")
                  : Strings.tLang(uiLanguage, "dragHintEmpty")
            color: Qt.darker(Color.popups.text, 1.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // ---- reusable bits -------------------------------------------------------------

  component IconChip: Rectangle {
    id: iconChip
    property string glyph: ""
    property string tooltipText: ""
    signal clicked()

    width: Style.space(26)
    height: Style.space(26)
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : 6
    color: chipMouse.containsMouse
           ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10)
           : "transparent"

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: iconChip.glyph
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: iconChip.clicked()
    }

    PanelToolTip {
      visible: chipMouse.containsMouse && iconChip.tooltipText !== ""
      text: iconChip.tooltipText
      fontFamily: Style.font.family
    }
  }

  component ChipButton: Rectangle {
    id: chipButton
    property string label: ""
    property string tooltipText: ""
    signal clicked()

    width: chipLabel.implicitWidth + Style.space(18)
    height: Style.space(26)
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : 6
    opacity: enabled ? 1.0 : 0.4
    color: {
      if (!enabled) return Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.05)
      if (chipMouse.containsMouse) return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
      return Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08)
    }

    Text {
      id: chipLabel
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: chipButton.label
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      enabled: chipButton.enabled
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chipButton.clicked()
    }

    PanelToolTip {
      visible: chipMouse.containsMouse && chipButton.tooltipText !== ""
      text: chipButton.tooltipText
      fontFamily: Style.font.family
    }
  }

  component Tile: Rectangle {
    id: tile
    property var tileData: null
    signal removeRequested()
    signal openRequested()

    width: grid.cellWidth - Style.space(7)
    height: grid.cellHeight - Style.space(7)
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : 8
    color: tileMouse.containsMouse
           ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.09)
           : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.045)
    border.width: 1
    border.color: tileMouse.containsMouse
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)
                  : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.12)

    // Native Wayland drag carrying this entry's URI, initiated imperatively
    // from a plain MouseArea (DragHandler's grab never returns after an
    // Automatic drag on Wayland).
    //
    // End-of-drag truth table (QtWayland):
    //   drop on another app   -> onDragFinished(any action) -> remove
    //   drop back on this zone-> DropArea sets dropWasInternal      -> keep
    //   Esc (keyboard is ours)-> keyCatcher calls finishDrag(false) -> keep
    // IgnoreAction is NOT a cancel: Wayland reports it for successful drops
    // too (same lesson as drag-all). Esc is the only reliable cancel path.
    property bool dragActive: false
    property bool dragEnding: false
    property bool dragArmed: false
    property bool imageBroken: false
    property string dragImageUrl: ""
    property point dragPressPos: Qt.point(0, 0)

    // Strong JS reference for the payload: a GC-collected QMimeData mid-transfer
    // segfaults QtWayland's data_source_send (crash report 52bbxq1dkt).
    property var dragMimeData: ({
      "text/uri-list": tileData ? (tileData.uri + "\r\n") : "",
      "text/plain": tileData ? (tileData.path || tileData.uri) : ""
    })

    Drag.active: dragActive
    Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    Drag.dragType: Drag.Automatic
    Drag.imageSource: dragImageUrl
    Drag.hotSpot: Qt.point(width / 2, height / 2)
    Drag.mimeData: dragMimeData

    opacity: dragActive ? 0.35 : 1.0
    Behavior on opacity { NumberAnimation { duration: 120 } }

    Connections {
      target: tile.Drag
      function onActiveChanged() {
        if (tile.Drag.active) tile.dragArmed = true
      }
    }

    // ALWAYS resets the drag state — internal drops included, or the tile
    // stays dimmed and the next drag inherits a poisoned data source.
    //
    // `remove` is a hint; cancel flags win. External finishes always drop
    // the tile (IgnoreAction is not cancel on QtWayland). Esc/DropArea set
    // dropWasInternal / dragCancelRequested first.
    function finishDrag(remove) {
      if (!dragActive || dragEnding) return
      dragEnding = true
      dragActive = false
      dragArmed = false
      if (panelRoot.activeDragTile === tile) panelRoot.activeDragTile = null
      // Esc only — a stolen Wayland drop must not keep the tile.
      var cancelled = panelRoot.dragCancelRequested
      panelRoot.dropWasInternal = false
      panelRoot.dragCancelRequested = false
      panelRoot.endOutboundDrag()
      // Inline components do not see the document root's properties, so every
      // controller hop here MUST go through panelRoot (bare `controller` threw
      // ReferenceError and silently aborted the rest of this function).
      var ctl = panelRoot.controller
      if (ctl) ctl.stopMoveTracking()
      if (!cancelled && remove !== false) {
        if (tileData && tileData.id) removeRequested()
        else if (tileData && tileData.path && ctl)
          ctl.removeTileByPath(tileData.path)
        if (ctl) ctl.maybeCloseOnEmpty()
      }
    }

    // Safety net: if Qt ends the drag without delivering onDragFinished (the
    // attached flag flips back), settle it — external unless it landed here.
    Timer {
      interval: 120
      running: tile.dragActive
      repeat: true
      onTriggered: if (tile.dragActive && tile.dragArmed && !tile.dragEnding && !tile.Drag.active)
                     tile.finishDrag(!panelRoot.dropWasInternal && !panelRoot.dragCancelRequested)
    }

    Drag.onDragFinished: function(action) {
      // action is ignored: QtWayland reports IgnoreAction for real drops.
      tile.finishDrag(!panelRoot.dropWasInternal && !panelRoot.dragCancelRequested)
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: tile.dragActive ? Qt.ClosedHandCursor : Qt.ArrowCursor
      onPressed: function(mouse) {
        tile.dragPressPos = Qt.point(mouse.x, mouse.y)
        tile.dragEnding = false
        tile.dragArmed = false
        // Pre-grab the drag preview so it is ready when the threshold hits.
        tile.grabToImage(function(result) { tile.dragImageUrl = result.url })
      }
      onPositionChanged: function(mouse) {
        if (!pressed || tile.dragActive || !tileData) return
        var dist = Math.abs(mouse.x - tile.dragPressPos.x) + Math.abs(mouse.y - tile.dragPressPos.y)
        if (dist < Qt.styleHints.startDragDistance) return
        panelRoot.dropWasInternal = false
        panelRoot.dragCancelRequested = false
        panelRoot.beginOutboundDrag()
        panelRoot.activeDragTile = tile
        tile.dragActive = true
        if (tileData.path && panelRoot.controller)
          panelRoot.controller.startMoveTracking([tileData.path])
      }
      // onCanceled is deliberately NOT an end: it fires when the system drag
      // takes the grab at start. The end arrives via onDragFinished or the
      // poll above.
      onDoubleClicked: openRequested()
    }

    Column {
      anchors.centerIn: parent
      spacing: Style.space(4)

      Loader {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(46)
        height: Style.space(46)
        active: tileData && tileData.kind === "image" && tileData.path !== null && !imageBroken
        // An inactive Loader still reserves its size in the Column, pushing
        // glyph tiles' captions out the bottom — hide it outright.
        visible: active
        sourceComponent: Image {
          // tileData.uri is already a properly percent-encoded file:// URL.
          source: tileData ? tileData.uri : ""
          asynchronous: true
          cache: false
          fillMode: Image.PreserveAspectFit
          sourceSize.width: Style.space(92)
          sourceSize.height: Style.space(92)
          onStatusChanged: if (status === Image.Error) tile.imageBroken = true
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !(tileData && tileData.kind === "image") || imageBroken
        text: glyphForKind(tileData ? tileData.kind : "file")
        color: tileData && tileData.kind === "dir" ? Color.accent : Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.space(34)
      }

      Text {
        textFormat: Text.PlainText
        width: tile.width - Style.space(8)
        horizontalAlignment: Text.AlignHCenter
        text: tileData ? tileData.name : ""
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }

    Rectangle {
      id: removeBadge
      visible: tileMouse.containsMouse
      width: Style.space(17)
      height: Style.space(17)
      radius: height / 2
      anchors.top: parent.top
      anchors.topMargin: Style.space(3)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(3)
      color: removeMouse.containsMouse ? Color.urgent : Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.75)

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: -1
        text: "󰅖"
        color: "#ffffff"
        font.family: Style.font.family
        font.pixelSize: Style.space(11)
      }

      MouseArea {
        id: removeMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: removeRequested()
      }
    }
  }

  // Press-and-drag handle that carries every shelf item at once. Same
  // imperative pattern as the tiles; an external finish clears the shelf,
  // dropping back in keeps it.
  component AllDragHandle: Rectangle {
    id: allHandle
    property bool dragActive: false
    property bool dragEnding: false
    property bool dragArmed: false
    property string dragImageUrl: ""
    property point pressPos: Qt.point(0, 0)
    property var dragMimeData: ({})

    width: allRow.implicitWidth + Style.space(18)
    height: Style.space(26)
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : 6
    opacity: enabled ? 1.0 : 0.4
    color: allMouse.containsMouse || dragActive
           ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
           : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08)
    border.width: dragActive ? 1 : 0
    border.color: Color.accent

    Drag.active: dragActive
    Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    Drag.dragType: Drag.Automatic
    Drag.imageSource: dragImageUrl
    Drag.hotSpot: Qt.point(width / 2, height / 2)
    Drag.mimeData: dragMimeData

    // Don't settle the drag until Qt has actually armed it — otherwise the
    // 120ms timer can finishDrag() before Drag.active flips true and we
    // archive/restore mid-pickup.
    Connections {
      target: allHandle.Drag
      function onActiveChanged() {
        if (allHandle.Drag.active) allHandle.dragArmed = true
      }
    }

    function finishDrag() {
      if (!dragActive || dragEnding) return
      dragEnding = true
      dragActive = false
      dragArmed = false
      // Inline components do not see the document root's properties: a bare
      // `controller` here threw ReferenceError and aborted the rest of this
      // function, which is why the drag-all drop never cleared or closed.
      var ctl = panelRoot.controller
      // Keep activeDragWasAll true until archive/restore is done so DropArea
      // and addDroppedUris still refuse stolen drops during this teardown.
      var wasAll = panelRoot.activeDragWasAll
      if (panelRoot.activeDragTile === allHandle) panelRoot.activeDragTile = null
      // Only Esc (dragCancelRequested) is a real cancel. dropWasInternal used
      // to fire when the zone stole the Wayland drop and wrongly restored.
      var cancelled = panelRoot.dragCancelRequested
      panelRoot.dropWasInternal = false
      panelRoot.dragCancelRequested = false
      panelRoot.endOutboundDrag()
      if (ctl) ctl.stopMoveTracking()
      panelRoot.dragAllMoveHits = 0
      // Taken after stopMoveTracking so any last MOVED_TO rewrite is included.
      var snapshot = panelRoot.takeClearedSnapshot()

      if (cancelled) {
        if (wasAll && snapshot && snapshot.length > 0 && ctl
            && panelRoot.items.length === 0)
          ctl.restoreSnapshot(snapshot)
        panelRoot.activeDragWasAll = false
        return
      }

      if (!wasAll || !ctl) {
        panelRoot.activeDragWasAll = false
        return
      }

      // Delivered: file the snapshot into history, wipe the shelf, close.
      ctl.finishDragAll(snapshot)
      panelRoot.activeDragWasAll = false
    }

    Timer {
      interval: 120
      running: allHandle.dragActive
      repeat: true
      onTriggered: if (allHandle.dragActive && allHandle.dragArmed
                       && !allHandle.dragEnding && !allHandle.Drag.active)
                     allHandle.finishDrag()
    }

    Drag.onDragFinished: function(action) {
      // Never restore here: QtWayland reports IgnoreAction even for
      // successful external drops. Restores happen from the DropArea
      // (internal drop) and the keyCatcher (Esc).
      allHandle.finishDrag()
    }

    Row {
      id: allRow
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: Strings.tLang(uiLanguage, "dragAll")
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    MouseArea {
      id: allMouse
      anchors.fill: parent
      hoverEnabled: true
      // Stay enabled for the whole drag-all even after clearActive empties
      // the shelf — disabling the MouseArea mid-gesture kills the drag.
      enabled: panelRoot.items.length > 0 || allHandle.dragActive || panelRoot.activeDragWasAll
      cursorShape: allHandle.dragActive ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      onPressed: function(mouse) {
        allHandle.pressPos = Qt.point(mouse.x, mouse.y)
        allHandle.dragEnding = false
        allHandle.dragArmed = false
        allHandle.grabToImage(function(result) { allHandle.dragImageUrl = result.url })
      }
      onPositionChanged: function(mouse) {
        if (!pressed || allHandle.dragActive) return
        var dist = Math.abs(mouse.x - allHandle.pressPos.x) + Math.abs(mouse.y - allHandle.pressPos.y)
        var ctl = panelRoot.controller
        if (dist < Qt.styleHints.startDragDistance || !ctl) return

        var uris = []
        var paths = []
        var items = panelRoot.items
        for (var i = 0; i < items.length; i++) {
          uris.push(items[i].uri)
          paths.push(items[i].path || items[i].uri)
        }
        // Strong ref for the lifetime of the drag (see crash 52bbxq1dkt).
        allHandle.dragMimeData = {
          "text/uri-list": uris.join("\r\n") + "\r\n",
          "text/plain": paths.join("\n")
        }
        // Optimistic clear for empty UI during the gesture. Keep this handle
        // visible (activeDragWasAll) so the drag source is not torn down.
        panelRoot.clearedSnapshot = ShelfModel.cloneJson(items)
        panelRoot.activeDragWasAll = true
        panelRoot.dragCancelRequested = false
        panelRoot.dragAllMoveHits = 0
        panelRoot.dropWasInternal = false
        panelRoot.beginOutboundDrag()
        panelRoot.activeDragTile = allHandle
        allHandle.dragActive = true
        var trackPaths = []
        for (var t = 0; t < items.length; t++)
          if (items[t].path) trackPaths.push(items[t].path)
        if (trackPaths.length > 0) ctl.startMoveTracking(trackPaths)
        ctl.clearActive(false)
      }
    }

    PanelToolTip {
      visible: allMouse.containsMouse
      text: Strings.tLang(uiLanguage, "dragAllTooltip")
      fontFamily: Style.font.family
    }
  }

  component EmptyState: Item {
    Column {
      anchors.centerIn: parent
      spacing: Style.space(6)
      width: parent.width

      Text {
        textFormat: Text.PlainText
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "󰋫"
        color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.35)
        font.family: Style.font.family
        font.pixelSize: Style.space(30)
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: Strings.tLang(uiLanguage, "emptyHint")
        color: Qt.darker(Color.popups.text, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
