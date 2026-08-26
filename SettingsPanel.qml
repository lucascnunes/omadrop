import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ShelfModel.js" as ShelfModel
import "Strings.js" as Strings

// OmaDrop's settings + history, hosted by the BAR WIDGET as a popout under
// the icon (same pattern as omarchy.clock's calendar). The panel instance
// (OmaDrop.qml) owns capture/state; this view reads the shared state file and
// routes every mutation back through the omadrop IPC verbs.
Panel {
  id: root

  // ---- injected by BarWidget.qml's injectPanel -----------------------------
  property var anchorItem: null
  property var hostWidget: null

  moduleName: "lucas.omadrop"
  manageIpc: false // IPC lives on the panel entry (omadrop target)

  // Optimistic settings echo so controls react before shell.json round-trips.
  property var localSettingsOverride: null
  readonly property var effectiveSettings:
    ShelfModel.normalizeSettings(localSettingsOverride || root.settings)

  function persistSettings(values) {
    var entry = ShelfModel.cloneJson(root.settings) || {}
    entry.id = root.moduleName
    for (var key in values) entry[key] = values[key]
    localSettingsOverride = ShelfModel.normalizeSettings(entry)
    var shellObj = root.bar ? root.bar.shell : null
    if (shellObj && typeof shellObj.updateEntryInline === "function")
      shellObj.updateEntryInline(root.moduleName, entry)
  }

  // ---- state file mirror (display only; mutations go through IPC) ----------
  property string stateText: ""
  readonly property var shelvesArchivedNewestFirst: {
    var parsed = ShelfModel.deserializeState(root.stateText)
    var out = []
    for (var i = 0; i < parsed.shelves.length; i++)
      if (parsed.shelves[i].archivedAt !== null) out.push(parsed.shelves[i])
    out.sort(function(a, b) { return (b.archivedAt || 0) - (a.archivedAt || 0) })
    return out
  }
  readonly property int archivedCount: shelvesArchivedNewestFirst.length

  Process {
    id: statePoll
    stdout: StdioCollector {
      id: pollOut
      waitForEnd: true
    }
    stderr: StdioCollector {}
    onExited: root.stateText = pollOut.text || ""
  }

  function pollState() {
    var home = Quickshell.env("HOME") || ""
    var path = (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omadrop/shelf.json"
    statePoll.command = ["bash", "-c", 'cat "$0" 2>/dev/null || true', path]
    statePoll.running = true
  }

  Timer {
    interval: 1500
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollState()
  }
  onOpenedChanged: if (root.opened) root.pollState()

  // ---- helpers ---------------------------------------------------------------
  function runIpc(args) {
    if (root.bar && typeof root.bar.run === "function")
      root.bar.run("omarchy-shell omadrop " + args)
  }

  Process {
    id: copier
    stdout: StdioCollector {}
  }

  function copyHotkey(line) {
    copier.command = ["bash", "-c", 'printf "%s" "$1" | wl-copy --type text/plain', "omadrop", String(line)]
    copier.running = true
  }

  readonly property int formWidth: Style.space(430)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.formWidth)
    contentHeight: panel.fittedContentHeight(flickCol.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
    }

    Flickable {
      anchors.fill: parent
      contentWidth: width
      contentHeight: flickCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      Column {
        id: flickCol
        width: parent.width
        spacing: Style.space(10)

        Text {
          text: Strings.t("settingsTitle")
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        SectionLabel { title: Strings.t("sectionShake") }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width - shakeToggleRow.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: Strings.t("shakeRow")
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Row {
            id: shakeToggleRow
            anchors.verticalCenter: parent.verticalCenter
            ToggleSwitch {
              id: shakeToggle
              checked: root.effectiveSettings.shakeEnabled
              foreground: Color.popups.text
              accent: Color.accent
              onToggled: root.persistSettings({ shakeEnabled: !shakeToggle.checked })
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
              text: Strings.t("intensityCaption").replace("%1", String(root.effectiveSettings.shakeReversals))
              color: Qt.darker(Color.popups.text, 1.45)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Stepper {
            id: stepper
            anchors.verticalCenter: parent.verticalCenter
            value: root.effectiveSettings.shakeReversals
            minValue: ShelfModel.REVERSALS_MIN
            maxValue: ShelfModel.REVERSALS_MAX
            onStepped: function(next) { root.persistSettings({ shakeReversals: next }) }
          }
        }

        SectionLabel { title: Strings.t("sectionPosition") }

        Row {
          spacing: Style.space(6)

          Repeater {
            model: [
              { key: "cursor", label: Strings.t("posCursor") },
              { key: "topLeft", label: "↖" },
              { key: "topCenter", label: "↑" },
              { key: "topRight", label: "↗" },
              { key: "bottomLeft", label: "↙" },
              { key: "bottomCenter", label: "↓" },
              { key: "bottomRight", label: "↘" }
            ]

            delegate: PositionChip {
              positionKey: modelData.key
              positionLabel: modelData.label
              active: root.effectiveSettings.shelfPosition === modelData.key
              onSelectPosition: function(key) { root.persistSettings({ shelfPosition: key }) }
            }
          }
        }

        SectionLabel { title: Strings.t("sectionHotkeys") }

        HotkeyRow {
          labelText: Strings.t("hotkeyCapture")
          combo: root.effectiveSettings.hotkeyCapture
          hintText: "capture"
          onCopyLine: function(line) { root.copyHotkey(line) }
        }

        HotkeyRow {
          labelText: Strings.t("hotkeyOpen")
          combo: root.effectiveSettings.hotkeyOpen
          hintText: "open"
          onCopyLine: function(line) { root.copyHotkey(line) }
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
            checked: root.effectiveSettings.showNotifications
            foreground: Color.popups.text
            accent: Color.accent
            onToggled: root.persistSettings({ showNotifications: !notifyToggle.checked })
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
            value: root.effectiveSettings.maxItems
            minValue: 1
            maxValue: 100
            step: 5
            wrapValue: true
            onStepped: function(next) { root.persistSettings({ maxItems: next }) }
          }
        }

        SectionLabel { title: Strings.t("sectionActions") }

        Row {
          spacing: Style.space(6)

          ChipButton {
            label: Strings.t("newShelf")
            tooltipText: Strings.t("newShelfTooltip")
            onClicked: root.runIpc("archive")
          }

          ChipButton {
            label: Strings.t("clearShelf")
            tooltipText: Strings.t("clearShelfTooltip")
            onClicked: root.runIpc("clear")
          }
        }

        SectionLabel { title: Strings.t("sectionHistory") }

        Item {
          width: parent.width
          height: historyList.visible ? Math.min(historyList.contentHeight, Style.space(180)) : emptyHintBox.height

          ListView {
            id: historyList
            width: parent.width
            height: Math.min(contentHeight, Style.space(180))
            visible: root.archivedCount > 0
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds
            model: root.shelvesArchivedNewestFirst

            delegate: HistoryRow {
              required property var modelData
              width: historyList.width
              shelf: modelData
              onOpenRequested: function(id) { root.runIpc("reopen " + id) }
              onDeleteRequested: function(id) { root.runIpc("removeshelf " + id) }
            }

          SectionLabel { title: Strings.t("sectionSupport") }

          Row {
            spacing: Style.space(6)

            ChipButton {
              label: "󰊗 github.com/lucascnunes/omadrop"
              tooltipText: "https://github.com/lucascnunes/omadrop"
              onClicked: Qt.openUrlExternally("https://github.com/lucascnunes/omadrop")
            }

            ChipButton {
              label: "󰅶 ko-fi.com/lucascnunes"
              tooltipText: "https://ko-fi.com/lucascnunes"
              onClicked: Qt.openUrlExternally("https://ko-fi.com/lucascnunes")
            }
          }
          }

          Item {
            id: emptyHintBox
            width: parent.width
            height: Style.space(44)
            visible: !historyList.visible

            Text {
              anchors.centerIn: parent
              text: Strings.t("historyEmptyShort")
              color: Qt.darker(Color.popups.text, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // ---- reusable bits -----------------------------------------------------------

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
      color: stepper.value <= stepper.minValue && !stepper.wrapValue ? Qt.darker(Color.popups.text, 1.9) : Color.popups.text
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
      color: stepper.value >= stepper.maxValue && !stepper.wrapValue ? Qt.darker(Color.popups.text, 1.9) : Color.popups.text
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
        text: combo + "  ·  omarchy-shell omadrop " + hintText
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
      tooltipText: "bind = " + combo + ", exec, omarchy-shell omadrop " + hintText
      onClicked: copyLine("bind = " + combo + ", exec, omarchy-shell omadrop " + hintText)
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

  component HistoryRow: Rectangle {
    property var shelf: null
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
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      IconChip {
        glyph: "󰌷"
        tooltipText: Strings.t("makeCurrent")
        onClicked: if (shelf !== null) openRequested(shelf.id)
      }

      IconChip {
        glyph: "󰆴"
        tooltipText: Strings.t("deleteShelfTip")
        onClicked: if (shelf !== null) deleteRequested(shelf.id)
      }
    }

    MouseArea {
      id: histMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }
  }

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
}