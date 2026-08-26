import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ShelfModel.js" as ShelfModel
import "Strings.js" as Strings

// The floating OmaDrop zone: a small layer-shell window anchored near the
// cursor or a screen corner. It is deliberately NOT a fullscreen scrim — the
// desktop around it stays interactive, like Dropover's bucket.
//
// Tiles drag out natively (text/uri-list over Wayland data-device drags);
// drops from other apps land on the DropArea and join the shelf. The gear
// flips the card into the settings/history view the bar icon's right-click
// also summons.
Item {
  id: panelRoot

  // ---- API used by OmaDrop.qml ---------------------------------------------
  property var controller: null
  property bool opened: false
  property int anchorX: 24
  property int anchorY: 24

  readonly property int cardWidth: Style.space(448)
  readonly property int edgeMargin: Style.space(10)
  readonly property int cardEstimatedHeight: Style.space(430)

  property int monitorWidth: 1280
  property int monitorHeight: 800
  property string screenName: ""

  function useScreen(name) {
    panelRoot.screenName = String(name || "")
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === panelRoot.screenName) { panel.screen = screens[i]; return }
    }
  }

  function requestClose() { if (controller) controller.dismiss() }
  function setView(v) { if (controller) controller.view = v }

  readonly property bool isSettingsView: controller ? controller.view !== "shelf" : false
  readonly property var settings: controller ? controller.settings : ShelfModel.normalizeSettings(null)
  readonly property var items: controller ? controller.activeItems : []

  readonly property var shelvesNewestFirst: {
    var source = controller ? controller.state.shelves : []
    var list = []
    for (var i = 0; i < source.length; i++) list.push(source[i])
    list.sort(function(a, b) { return (b.updatedAt || 0) - (a.updatedAt || 0) })
    return list
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
  // Anchored to the output's top-left with exact margins, which positions the
  // card deterministically across compositors (no centering semantics).
  PanelWindow {
    id: panel
    visible: panelRoot.opened
    color: "transparent"

    anchors { left: true; top: true }
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "omadrop"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    // Width comes from the constant, never from card↔panel cross-references
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
        Item {
          width: parent.width
          height: Style.space(30)

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
              visible: !panelRoot.isSettingsView && panelRoot.items.length > 0
              width: countLabel.implicitWidth + Style.space(12)
              height: Style.space(18)
              radius: height / 2
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)

              Text {
                id: countLabel
                anchors.centerIn: parent
                text: panelRoot.items.length === 1 ? Strings.t("oneItem") : Strings.t("manyItems").replace("%1", String(panelRoot.items.length))
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
              glyph: "󰤨"
              tooltipText: Strings.t("gearTooltip")
              activeGlyph: panelRoot.isSettingsView
              onClicked: panelRoot.setView(panelRoot.isSettingsView ? "shelf" : "settings")
            }

            IconChip {
              glyph: ""
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

        // ---- shelf view -------------------------------------------------------
        Item {
          width: parent.width
          height: panelRoot.isSettingsView ? 0 : shelfColumn.implicitHeight
          visible: !panelRoot.isSettingsView

          Column {
            id: shelfColumn
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              // Fixed height while empty: the hint fills this box, so sizing
              // it from its child would be circular.
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

                EmptyState {
                  anchors.fill: parent
                  visible: panelRoot.items.length === 0
                }
              }
            }

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

              Item { width: Style.space(4); height: 1 }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: panelRoot.items.length > 0
                      ? Strings.t("dragHintWithItems")
                      : Strings.t("dragHintEmpty")
                color: Qt.darker(Color.popups.text, 1.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---- settings view ------------------------------------------------------
        Column {
          id: settingsColumn
          width: parent.width
          spacing: Style.space(10)
          visible: panelRoot.isSettingsView
          enabled: visible

          SectionLabel { title: Strings.t("sectionShake") }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width - toggleRow.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: Strings.t("shakeRow")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Row {
              id: toggleRow
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              ToggleSwitch {
                id: shakeToggle
                checked: panelRoot.settings.shakeEnabled
                foreground: Color.popups.text
                accent: Color.accent
                onToggled: if (controller) controller.persistSettings({ shakeEnabled: !shakeToggle.checked })
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Column {
              width: parent.width - stepper.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2

              Text {
                text: Strings.t("intensityRow")
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Text {
                text: Strings.t("intensityCaption").replace("%1", String(panelRoot.settings.shakeReversals))
                color: Qt.darker(Color.popups.text, 1.45)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Stepper {
              id: stepper
              anchors.verticalCenter: parent.verticalCenter
              value: panelRoot.settings.shakeReversals
              minValue: ShelfModel.REVERSALS_MIN
              maxValue: ShelfModel.REVERSALS_MAX
              onStepped: function(next) {
                if (controller) controller.persistSettings({ shakeReversals: next })
              }
            }
          }

          SectionLabel { title: Strings.t("sectionPosition") }

          Row {
            spacing: Style.space(6)

            Repeater {
              model: [
                { key: "cursor", label: Strings.t("posCursor") },
                { key: "topLeft", label: "󰁛" },
                { key: "topRight", label: "󰁜" },
                { key: "bottomLeft", label: "󰁝" },
                { key: "bottomRight", label: "󰁘" }
              ]

              delegate: PositionChip {
                positionKey: modelData.key
                positionLabel: modelData.label
                active: panelRoot.settings.shelfPosition === modelData.key
                onSelectPosition: if (controller) controller.persistSettings({ shelfPosition: modelData.key })
              }
            }
          }

          SectionLabel { title: Strings.t("sectionHotkeys") }

          HotkeyRow {
            labelText: Strings.t("hotkeyCapture")
            combo: panelRoot.settings.hotkeyCapture
            hintText: "omadrop capture"
            onCopyLine: function(line) { if (controller) controller.copyText(line) }
          }

          HotkeyRow {
            labelText: Strings.t("hotkeyOpen")
            combo: panelRoot.settings.hotkeyOpen
            hintText: "omadrop open"
            onCopyLine: function(line) { if (controller) controller.copyText(line) }
          }

          SectionLabel { title: Strings.t("sectionGeneral") }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width - notifyToggle.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: Strings.t("notificationsRow")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            ToggleSwitch {
              id: notifyToggle
              anchors.verticalCenter: parent.verticalCenter
              checked: panelRoot.settings.showNotifications
              foreground: Color.popups.text
              accent: Color.accent
              onToggled: if (controller) controller.persistSettings({ showNotifications: !notifyToggle.checked })
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Column {
              width: parent.width - maxStepper.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2

              Text {
                text: Strings.t("limitRow")
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Text {
                text: Strings.t("limitCaption")
                color: Qt.darker(Color.popups.text, 1.45)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Stepper {
              id: maxStepper
              anchors.verticalCenter: parent.verticalCenter
              value: panelRoot.settings.maxItems
              minValue: 1
              maxValue: 100
              step: 5
              wrapValue: true
              onStepped: function(next) { if (controller) controller.persistSettings({ maxItems: next }) }
            }
          }

          SectionLabel { title: Strings.t("sectionHistory") }

          Item {
            width: parent.width
            height: historyList.visible ? Math.min(historyList.contentHeight, Style.space(170)) : emptyHistory.height

            ListView {
              id: historyList
              width: parent.width
              height: Math.min(contentHeight, Style.space(170))
              clip: true
              spacing: Style.space(4)
              boundsBehavior: Flickable.StopAtBounds
              model: panelRoot.shelvesNewestFirst

              delegate: HistoryRow {
                required property var modelData
                width: historyList.width
                shelf: modelData
                isActive: controller && modelData.archivedAt === null
                          && modelData.id === controller.state.activeShelfId
                onOpenRequested: function(id) { if (controller) controller.reopenShelf(id) }
                onDeleteRequested: function(id) { if (controller) controller.deleteShelfById(id) }
              }

              EmptyState {
                anchors.fill: parent
                visible: panelRoot.shelvesNewestFirst.length <= 1
                compact: true
              }
            }

            Text {
              id: emptyHistory
              visible: !historyList.visible || historyList.count === 0
              width: parent.width
              text: visible ? Strings.t("historyEmptyShort") : ""
              color: Qt.darker(Color.popups.text, 1.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
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
    property bool activeGlyph: false
    signal clicked()

    width: Style.space(26)
    height: Style.space(26)
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : 6
    color: chipMouse.containsMouse
           ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10)
           : (activeGlyph ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : "transparent")

    Text {
      anchors.centerIn: parent
      text: iconChip.glyph
      color: iconChip.activeGlyph ? Color.accent : Color.popups.text
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
    // Uses the built-in `enabled`: a custom property would shadow it, and a
    // disabled ancestor already blocks the inner MouseArea for us.
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

  component SectionLabel: Text {
    property string title: ""
    width: parent ? parent.width : implicitWidth
    text: title
    color: Qt.darker(Color.popups.text, 1.7)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1
  }

  component Stepper: Rectangle {
    property int value: 0
    property int minValue: 0
    property int maxValue: 99
    property int step: 1
    property bool wrapValue: false
    signal stepped(int next)

    width: minusBtn.width + valueLabel.width + plusBtn.width + Style.space(4) * 2
    height: Style.space(28)
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : 6
    color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06)

    function bump(delta) {
      var next = value + delta * step
      if (next < minValue) next = wrapValue ? maxValue : minValue
      if (next > maxValue) next = wrapValue ? minValue : maxValue
      if (next === value) return
      stepped(next)
    }

    Text {
      id: minusBtn
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: ""
      color: value <= minValue && !wrapValue ? Qt.darker(Color.popups.text, 1.9) : Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        cursorShape: Qt.PointingHandCursor
        onClicked: stepper.bump(-1)
      }
    }

    Text {
      id: valueLabel
      anchors.centerIn: parent
      width: Style.space(30)
      horizontalAlignment: Text.AlignHCenter
      text: String(value)
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Text {
      id: plusBtn
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: ""
      color: value >= maxValue && !wrapValue ? Qt.darker(Color.popups.text, 1.9) : Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        cursorShape: Qt.PointingHandCursor
        onClicked: stepper.bump(1)
      }
    }
  }

  component PositionChip: Rectangle {
    property string positionKey: ""
    property string positionLabel: ""
    property bool active: false
    signal selectPosition(string key)

    width: posLabel.implicitWidth + Style.space(16)
    height: Style.space(26)
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : 6
    color: active ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
                  : (posMouse.containsMouse
                     ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10)
                     : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06))
    border.width: active ? 1 : 0
    border.color: Color.accent

    Text {
      id: posLabel
      anchors.centerIn: parent
      text: positionLabel
      color: active ? Color.accent : Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: posMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: selectPosition(positionKey)
    }
  }

  component HotkeyRow: Row {
    property string labelText: ""
    property string combo: ""
    property string hintText: ""
    signal copyLine(string line)

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(8)

    Column {
      width: parent.width - copyChip.width - parent.spacing
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2

      Text {
        text: labelText
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Text {
        text: combo + "  ·  omarchy-shell " + hintText
        color: Qt.darker(Color.popups.text, 1.45)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
        width: Math.min(implicitWidth, parent.width)
      }
    }

    ChipButton {
      id: copyChip
      anchors.verticalCenter: parent.verticalCenter
      label: Strings.t("copyLine")
      tooltipText: "bind = " + combo + ", exec, omarchy-shell " + hintText
      onClicked: copyLine("bind = " + combo + ", exec, omarchy-shell " + hintText)
    }
  }

  component HistoryRow: Rectangle {
    property var shelf: null
    property bool isActive: false
    signal openRequested(string id)
    signal deleteRequested(string id)

    height: Style.space(32)
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : 6
    color: histMouse.containsMouse
           ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.07)
           : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.04)

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: shelf ? Qt.formatDateTime(new Date(shelf.updatedAt || Date.now()), "dd MMM HH:mm") : ""
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: shelf ? "· " + shelf.items.length + (shelf.items.length === 1 ? " item" : " itens") : ""
        color: Qt.darker(Color.popups.text, 1.45)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: isActive
        width: activeLabel.implicitWidth + Style.space(10)
        height: Style.space(16)
        radius: height / 2
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.20)

        Text {
          id: activeLabel
          anchors.centerIn: parent
          text: Strings.t("activeBadge")
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      IconChip {
        visible: !isActive && shelf !== null
        glyph: "󰌷"
        tooltipText: Strings.t("makeCurrent")
        onClicked: openRequested(shelf.id)
      }

      IconChip {
        visible: shelf !== null
        glyph: ""
        tooltipText: Strings.t("deleteShelfTip")
        onClicked: deleteRequested(shelf.id)
      }
    }

    MouseArea {
      id: histMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
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

    DragHandler {
      id: tileDrag
      acceptedButtons: Qt.LeftButton
    }

    TapHandler {
      onDoubleTapped: openRequested()
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton // clicks/double-clicks belong to TapHandler; drags to DragHandler
    }

    Column {
      anchors.centerIn: parent
      spacing: Style.space(4)

      Loader {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(46)
        height: Style.space(46)
        active: tileData && tileData.kind === "image" && tileData.path !== null
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
        text: ""
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
    property bool compact: false

    Column {
      anchors.centerIn: parent
      spacing: Style.space(6)
      width: parent.width

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        visible: !compact
        text: "󰋫"
        color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.35)
        font.family: Style.font.family
        font.pixelSize: Style.space(30)
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        visible: !compact
        text: Strings.t("emptyHint")
        color: Qt.darker(Color.popups.text, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        visible: compact
        text: Strings.t("historyEmptyShort")
        color: Qt.darker(Color.popups.text, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
