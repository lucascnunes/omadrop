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

  // Tile drags use "pick up" semantics: the tile leaves the grid the moment
  // the drag starts; dropping it back onto this window re-adds it from
  // lastDraggedUri (drop.urls can be empty for same-surface drops).
  property string lastDraggedUri: ""

  // ---- zone dragging ------------------------------------------------------
  // The layer surface's top-left IS (anchorX, anchorY), so anchor+local adds
  // up to true screen coordinates with zero feedback from the surface moving
  // under the pointer (local-only deltas stall exactly there).


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
            panelRoot.requestClose()
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
          var urls = drop.urls || []
          if (urls.length === 0 && panelRoot.lastDraggedUri !== "")
            urls = [panelRoot.lastDraggedUri] // same-surface drop: re-add the tile
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
            property point pressGlobal: Qt.point(0, 0)
            property point pressAnchor: Qt.point(0, 0)
            onPressed: function(mouse) {
              pressGlobal = Qt.point(panelRoot.anchorX + mouse.x, panelRoot.anchorY + mouse.y)
              pressAnchor = Qt.point(panelRoot.anchorX, panelRoot.anchorY)
            }
            onPositionChanged: function(mouse) {
              if (!pressed) return
              var gx = panelRoot.anchorX + mouse.x
              var gy = panelRoot.anchorY + mouse.y
              var nx = pressAnchor.x + Math.round(gx - pressGlobal.x)
              var ny = pressAnchor.y + Math.round(gy - pressGlobal.y)
              panelRoot.anchorX = Math.min(Math.max(panelRoot.edgeMargin, nx),
                                           Math.max(panelRoot.edgeMargin, panelRoot.monitorWidth - panel.width - panelRoot.edgeMargin))
              panelRoot.anchorY = Math.min(Math.max(panelRoot.edgeMargin, ny),
                                           Math.max(panelRoot.edgeMargin, panelRoot.monitorHeight - panel.height - panelRoot.edgeMargin))
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
                text: panelRoot.items.length === 1 ? Strings.t("oneItem")
                                                   : Strings.t("manyItems").replace("%1", String(panelRoot.items.length))
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
              tooltipText: Strings.t("gearTooltip")
              onClicked: if (panelRoot.controller) panelRoot.controller.openSettingsPopout()
            }

            IconChip {
              glyph: "󰅖"
              tooltipText: Strings.t("closeTooltip")
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

            ChipButton {
              label: Strings.t("newShelf")
              tooltipText: Strings.t("newShelfTooltip")
              onClicked: if (controller) controller.archiveCurrent()
            }

            ChipButton {
              label: Strings.t("clearShelf")
              tooltipText: Strings.t("clearShelfTooltip")
              enabled: panelRoot.items.length > 0
              onClicked: if (controller) controller.clearActive()
            }
          }

          // Wrapped on purpose: the hint reads as a caption under the buttons
          // instead of fighting them for one row's width.
          Text {
            width: parent.width
            text: panelRoot.items.length > 0
                  ? Strings.t("dragHintWithItems")
                  : Strings.t("dragHintEmpty")
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

    // Native Wayland drag carrying this entry's URI.
    Drag.active: tileDrag.active
    Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    Drag.dragType: Drag.Automatic
    Drag.mimeData: ({
      "text/uri-list": tileData ? (tileData.uri + "\r\n") : "",
      "text/plain": tileData ? (tileData.path || tileData.uri) : ""
    })

    // "Pick up" semantics: the drag start removes the tile from the grid
    // (Wayland never delivers Drag.onDragFinished, so end-of-drag hooks are
    // unreliable). Dropping back onto the shelf re-adds it via the DropArea.
    DragHandler {
      id: tileDrag
      acceptedButtons: Qt.LeftButton
      onActiveChanged: {
        if (!tileDrag.active || !tileData) return
        panelRoot.lastDraggedUri = tileData.uri
        removeRequested()
      }
    }

    TapHandler {
      onDoubleTapped: openRequested()
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton // clicks belong to TapHandler; drags to DragHandler
    }

    Column {
      anchors.centerIn: parent
      spacing: Style.space(4)

      Loader {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(46)
        height: Style.space(46)
        active: tileData && tileData.kind === "image" && tileData.path !== null
        // An inactive Loader still reserves its size in the Column, pushing
        // glyph tiles' captions out the bottom — hide it outright.
        visible: active
        sourceComponent: Image {
          // tileData.uri is already a properly percent-encoded file:// URL.
          source: tileData ? tileData.uri : ""
          asynchronous: true
          cache: true
          fillMode: Image.PreserveAspectFit
          sourceSize.width: Style.space(92)
          sourceSize.height: Style.space(92)
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !(tileData && tileData.kind === "image")
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
        text: Strings.t("emptyHint")
        color: Qt.darker(Color.popups.text, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
