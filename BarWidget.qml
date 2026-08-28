import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ShelfModel.js" as ShelfModel
import "Strings.js" as Strings

// OmaDrop's bar icon. Left click toggles the floating shelf, right click
// opens the settings/history POPOUT under the icon (hosted here, like every
// first-party bar widget's panel), middle click clears the active shelf.
//
// The badge reads the state file instead of talking to the panel instance:
// the hybrid manifest means widget and panel are separate QML instances, so
// the file is the shared source of truth.
BarWidget {
  id: root
  moduleName: "lucas.omadrop"

  // The bar sizes this slot from the root's implicit size; the button fills
  // whatever that ends up being (same contract as omarchy.microphone).
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")) + "/omadrop/shelf.json"

  function scriptPath(name) {
    var url = Qt.resolvedUrl("scripts/" + name).toString()
    return url.indexOf("file://") === 0 ? url.slice("file://".length) : url
  }

  property int itemCount: 0

  // ---- settings ---------------------------------------------------------------
  // The bar host injects this widget's layout entry into the base `settings`
  // property (it must stay writable — Bar.qml assigns it directly); we only
  // forward it down to the popout via injectPanel().

  // ---- badge count ------------------------------------------------------------
  // Deterministic cross-version read: a tiny cat through Process on a timer.
  Process {
    id: counter
    stdout: StdioCollector {
      id: counterOut
      waitForEnd: true
    }
    stderr: StdioCollector {}
    onExited: function(exitCode) {
      root.itemCount = exitCode === 0 ? ShelfModel.countActiveItemsText(counterOut.text) : 0
    }
  }

  readonly property string uiLanguage: ShelfModel.normalizeSettings(settings).language

  readonly property string barTooltip: Strings.tLang(root.uiLanguage, "barTooltip")

  function recount() {
    // The shared helper rejects symlinks and non-regular files before reading.
    counter.command = ["timeout", "--signal=KILL", "1s", "python3",
                       root.scriptPath("read-shelf-state"), root.statePath,
                       String(ShelfModel.STATE_BYTES_MAX)]
    counter.running = true
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.recount()
  }

  // ---- settings popout ----------------------------------------------------------
  Loader {
    id: settingsLoader
    active: false
    visible: false
    source: Qt.resolvedUrl("SettingsPanel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  function injectPanel() {
    var target = settingsLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: root.injectPanel()
  onSettingsChanged: root.injectPanel()

  // Shape contract expected by Bar.requestPopout / KeyboardPanel routing.
  readonly property bool opened: settingsLoader.item ? settingsLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing:
    settingsLoader.item ? settingsLoader.item.popoutSwitchClosing === true : false

  // Literal names required by Bar.findPanelWidget's duck-typing.
  function open() { if (settingsLoader.item) settingsLoader.item.open() }
  function close() { if (settingsLoader.item) settingsLoader.item.close() }
  function togglePanel() { if (settingsLoader.item) settingsLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (settingsLoader.item && typeof settingsLoader.item.closeForPopoutSwitch === "function")
      settingsLoader.item.closeForPopoutSwitch()
  }

  Component.onCompleted: {
    Qt.callLater(function() {
      settingsLoader.active = true
      root.injectPanel()
    })
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰏗"
    labelVisible: true
    hasVisualContent: true
    tooltipText: root.barTooltip

    onPressed: function(b) {
      if (!root.bar || typeof root.bar.run !== "function") return

      if (b === Qt.RightButton)
        root.togglePanel()
      else if (b === Qt.MiddleButton)
        root.bar.run("omarchy-shell omadrop clear")
      else
        root.bar.run("omarchy-shell omadrop toggle")
    }
  }

  Rectangle {
    visible: root.itemCount > 0 && !root.vertical
    anchors.top: parent.top
    anchors.topMargin: -Style.space(3)
    anchors.right: parent.right
    anchors.rightMargin: -Style.space(3)
    width: Math.max(Style.space(16), badgeLabel.implicitWidth + Style.space(8))
    height: Style.space(15)
    radius: height / 2
    color: Color.accent
    border.width: 1
    border.color: Color.bar.background

    Text {
      id: badgeLabel
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: root.itemCount > 99 ? "99+" : String(root.itemCount)
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Style.space(9)
      font.bold: true
    }
  }
}
