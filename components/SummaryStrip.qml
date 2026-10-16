pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// The strip under the hero: the one line that answers "is the fleet fine right
// now" — total hashrate, the miner counts, and how old the newest poll is.
// Three fixed columns, so the numbers never shift sideways between polls.
// Colour is reserved for the two readings that ask for a decision: a miner
// that is not mining, and a poll that has gone stale.
Item {
  id: root

  property string totalText: ""
  property string countsText: ""
  property string ageText: ""
  property bool countsAlarming: false
  property bool ageAlarming: false
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.55)

  readonly property var cells: [
    { value: root.totalText, label: "FLEET", alarming: false },
    { value: root.countsText, label: "MINERS", alarming: root.countsAlarming },
    { value: root.ageText, label: "POLL", alarming: root.ageAlarming },
  ]

  implicitHeight: surface.implicitHeight

  BorderSurface {
    id: surface
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
    borderSpec: Border.none()
    implicitHeight: grid.implicitHeight + Style.spacing.lg * 2
  }

  Row {
    id: grid

    readonly property real cellWidth: Math.max(0, (width - spacing * 2) / 3)

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.spacing.md

    Repeater {
      model: root.cells

      Item {
        required property var modelData

        // Not parent.width: a Repeater delegate's parent is null while it is
        // being created, and the model array is rebuilt on every poll.
        width: grid.cellWidth
        implicitHeight: cell.implicitHeight

        Column {
          id: cell
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(1)

          Text {
            width: parent.width
            text: String(modelData.value || "")
            color: modelData.alarming ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }

          Text {
            width: parent.width
            text: String(modelData.label || "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
        }
      }
    }
  }
}
