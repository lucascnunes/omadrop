import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ShelfModel.js" as ShelfModel

// OmaDrop's bar icon. Left click toggles the floating shelf, right click
// opens the settings/history view, middle click clears the active shelf.
//
// The badge reads the state file instead of talking to the panel instance:
// the hybrid manifest means widget and panel are separate QML instances, so
// the file is the shared source of truth.
BarWidget {
  id: root
  moduleName: "lucas.omadrop"

  // The bar sizes this slot from the root's implicit size; the button fills
  // whatever that ends up being (same contract as omarchy.clock).
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")) + "/omadrop/shelf.json"

  property int itemCount: 0

  // Deterministic cross-version read: a tiny cat through Process every couple
  // of seconds keeps the badge honest regardless of FileView watch behavior.
  Process {
    id: counter
    stdout: StdioCollector {
      id: counterOut
      waitForEnd: true
    }
    stderr: StdioCollector {}
    onExited: root.itemCount = ShelfModel.countActiveItemsText(counterOut.text)
  }

  function recount() {
    counter.command = ["bash", "-c", 'cat "$0" 2>/dev/null || true', root.statePath]
    counter.running = true
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.recount()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰏗"
    labelVisible: true
    hasVisualContent: true
    tooltipText: "OmaDrop · esquerdo: shelf · direito: configurações · meio: limpar"

    onPressed: function(b) {
      // Bar.run is the first-party contract (see omarchy.microphone); the
      // bar's `shell` property is not guaranteed to be wired for plugins.
      if (!root.bar || typeof root.bar.run !== "function") return

      if (b === Qt.RightButton)
        root.bar.run("omarchy-shell omadrop settings")
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
      anchors.centerIn: parent
      text: root.itemCount > 99 ? "99+" : String(root.itemCount)
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Style.space(9)
      font.bold: true
    }
  }
}
