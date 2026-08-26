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

  // Drag-all uses optimistic clearing: the shelf empties the moment the
  // handle is picked up (Wayland reports IgnoreAction even for successful
  // moves, so waiting for onDragFinished to clear never fired). The snapshot
  // restores on Esc / drop-back-home, and is archived + zone dismissed on a
  // successful external drop. Late MOVED_TO still rewrites archived paths.
  property bool activeDragWasAll: false
  property var clearedSnapshot: []
  // Esc often cancels the Wayland drag without delivering Keys.onPressed;
  // this flag (set by our Esc handlers) distinguishes cancel from deliver.
  property bool dragCancelRequested: false
  property int dragAllMoveHits: 0

  // Move tracker callback: rewrite paths on the in-flight drag-all snapshot
  // so archiveDragAllSnapshot records the destination, not the origin.
  function repointClearedSnapshot(oldPath, newPath) {
    if (!Array.isArray(clearedSnapshot) || clearedSnapshot.length === 0) return
    if (ShelfModel.repointItemsPath(clearedSnapshot, oldPath, newPath)) {
      clearedSnapshot = ShelfModel.cloneJson(clearedSnapshot)
      dragAllMoveHits++
    }
  }

  function cancelActiveDrag() {
    if (!panelRoot.activeDragTile) return false
    panelRoot.dragCancelRequested = true
    panelRoot.dropWasInternal = true
    if (panelRoot.activeDragWasAll && controller)
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

    margins.left: clampedX
    margins.top: clampedY

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
      DropArea {
        id: dropArea
        anchors.fill: parent
        property bool contains: false
        onEntered: contains = true
        onExited: contains = false
        onDropped: function(drop) {
          contains = false
          // Any drop reaching this window is "back home": the dragged tile is
          // still in the model, so finishDrag() must keep it.
          panelRoot.dropWasInternal = true
          var wasAll = panelRoot.activeDragWasAll
          if (wasAll && controller) controller.restoreSnapshot(panelRoot.clearedSnapshot)
          if (panelRoot.activeDragTile) panelRoot.activeDragTile.finishDrag(false)
          if (!wasAll) {
            var urls = drop.urls || []
            if (urls.length > 0 && controller) controller.addDroppedUris(urls)
          }
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
              anchors.verticalCenter: parent.verticalCenter
              text: "󰏗"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
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

            AllDragHandle { visible: panelRoot.items.length > 0 }

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
      if (panelRoot.activeDragTile === tile) panelRoot.activeDragTile = null
      var cancelled = panelRoot.dropWasInternal || panelRoot.dragCancelRequested
      panelRoot.dropWasInternal = false
      panelRoot.dragCancelRequested = false
      if (controller) controller.stopMoveTracking()
      if (!cancelled && remove !== false) {
        // Prefer id remove; path fallback covers races with inotify.
        if (tileData && tileData.id) removeRequested()
        else if (tileData && tileData.path && controller)
          controller.removeTileByPath(tileData.path)
        if (controller) controller.maybeCloseOnEmpty()
      }
    }

    // Safety net: if Qt ends the drag without delivering onDragFinished (the
    // attached flag flips back), settle it — external unless it landed here.
    Timer {
      interval: 120
      running: tile.dragActive
      repeat: true
      onTriggered: if (tile.dragActive && !tile.dragEnding && !tile.Drag.active)
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
        // Pre-grab the drag preview so it is ready when the threshold hits.
        tile.grabToImage(function(result) { tile.dragImageUrl = result.url })
      }
      onPositionChanged: function(mouse) {
        if (!pressed || tile.dragActive || !tileData) return
        var dist = Math.abs(mouse.x - tile.dragPressPos.x) + Math.abs(mouse.y - tile.dragPressPos.y)
        if (dist < Qt.styleHints.startDragDistance) return
        panelRoot.dropWasInternal = false
        panelRoot.dragCancelRequested = false
        panelRoot.activeDragTile = tile
        tile.dragActive = true
        if (tileData.path) controller.startMoveTracking([tileData.path])
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
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !(tileData && tileData.kind === "image") || imageBroken
        text: glyphForKind(tileData ? tileData.kind : "file")
        color: tileData && tileData.kind === "dir" ? Color.accent : Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.space(34)
      }

      Text {
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

    function finishDrag() {
      if (!dragActive || dragEnding) return
      dragEnding = true
      dragActive = false
      var wasAll = panelRoot.activeDragWasAll
      panelRoot.activeDragWasAll = false
      if (panelRoot.activeDragTile === allHandle) panelRoot.activeDragTile = null
      var wasInternal = panelRoot.dropWasInternal
      var cancelled = wasInternal || panelRoot.dragCancelRequested
      panelRoot.dropWasInternal = false
      panelRoot.dragCancelRequested = false
      var snapshot = panelRoot.clearedSnapshot
      panelRoot.clearedSnapshot = []

      if (cancelled || !wasAll) {
        // Esc / drop-back-home: items should already be restored; if the Esc
        // key never reached us and only the compositor cancelled, restore now.
        if (wasAll && snapshot && snapshot.length > 0 && controller
            && panelRoot.items.length === 0)
          controller.restoreSnapshot(snapshot)
        if (controller) controller.stopMoveTracking()
        panelRoot.dragAllMoveHits = 0
        return
      }

      // External finish: always archive + dismiss. Do NOT treat "no MOVED_TO
      // yet" as cancel — copies never fire it, and moves often arrive after
      // drag-finished. Late MOVED_TO still rewrites archived paths via the
      // move tracker (left running on purpose).
      panelRoot.dragAllMoveHits = 0
      if (snapshot && snapshot.length > 0 && panelRoot.controller)
        panelRoot.controller.archiveDragAllSnapshot(snapshot)
      else if (panelRoot.controller)
        panelRoot.controller.dismiss()
    }

    Timer {
      interval: 120
      running: allHandle.dragActive
      repeat: true
      onTriggered: if (allHandle.dragActive && !allHandle.dragEnding && !allHandle.Drag.active)
                     allHandle.finishDrag() // already cleared optimistically
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
      enabled: panelRoot.items.length > 0
      cursorShape: allHandle.dragActive ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      onPressed: function(mouse) {
        allHandle.pressPos = Qt.point(mouse.x, mouse.y)
        allHandle.dragEnding = false
        allHandle.grabToImage(function(result) { allHandle.dragImageUrl = result.url })
      }
      onPositionChanged: function(mouse) {
        if (!pressed || allHandle.dragActive) return
        var dist = Math.abs(mouse.x - allHandle.pressPos.x) + Math.abs(mouse.y - allHandle.pressPos.y)
        if (dist < Qt.styleHints.startDragDistance || !controller) return

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
        // Optimistic clear: Wayland reports IgnoreAction even for successful
        // moves, so clearing on drag-finish never fired. Keep a FULL item
        // clone so MOVED_TO can rewrite destinations before we archive.
        panelRoot.clearedSnapshot = ShelfModel.cloneJson(items)
        panelRoot.activeDragWasAll = true
        panelRoot.dragCancelRequested = false
        panelRoot.dragAllMoveHits = 0
        panelRoot.dropWasInternal = false
        panelRoot.activeDragTile = allHandle
        allHandle.dragActive = true
        var trackPaths = []
        for (var t = 0; t < items.length; t++)
          if (items[t].path) trackPaths.push(items[t].path)
        if (trackPaths.length > 0) controller.startMoveTracking(trackPaths)
        // Skip maybeCloseOnEmpty: the shelf is empty only for the drag UI.
        controller.clearActive(false)
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
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "󰋫"
        color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.35)
        font.family: Style.font.family
        font.pixelSize: Style.space(30)
      }

      Text {
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
