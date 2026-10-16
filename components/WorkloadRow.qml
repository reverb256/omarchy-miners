pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// One model-server / media / transcode workload: name, where it runs, its
// state, and a detail line (loaded model, queue depth, transcode count).
// Read-only — workload rows have no control surface by design.
Item {
  id: root

  required property string name
  property string hostText: ""
  property string stateText: ""
  property bool stateHealthy: true
  // Asleep = deliberately scaled to 0 (a k3s deployment): stated, not a
  // failure — the same vocabulary the miner rows use for a user pause.
  property bool stateDimmed: false
  property string detailText: ""
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color stateColor: stateDimmed ? dim : (stateHealthy ? foreground : urgent)

  function alpha(color, amount) {
    return Qt.rgba(color.r, color.g, color.b, amount)
  }

  implicitHeight: layout.implicitHeight + Style.spacing.lg * 2

  BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.alpha(root.foreground, root.stateDimmed ? 0.02 : 0.04)
    borderSpec: (!root.stateHealthy && !root.stateDimmed)
      ? Border.flat(root.alpha(root.urgent, 0.35), 1)
      : Border.none()
  }

  Column {
    id: layout
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(2)

    Item {
      width: parent.width
      implicitHeight: Math.max(title.implicitHeight, state.implicitHeight)

      Text {
        id: title
        anchors.left: parent.left
        anchors.right: state.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        text: root.name
        color: root.stateDimmed ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        id: state
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.stateText
        color: root.stateColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        textFormat: Text.PlainText
      }
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(hostLine.implicitHeight, detail.implicitHeight)

      Text {
        id: hostLine
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.hostText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        id: detail
        anchors.right: parent.right
        anchors.left: hostLine.right
        anchors.leftMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        text: root.detailText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideLeft
        textFormat: Text.PlainText
      }
    }
  }
}
