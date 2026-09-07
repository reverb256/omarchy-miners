pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// A reusable stat display: label on the left, value on the right,
// with optional alarm state drawn from the theme (urgent).
Item {
  id: root

  property string label: ""
  property string value: ""
  property bool alarming: false
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.55)

  implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

  Text {
    id: labelText
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    text: root.label
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  textFormat: Text.PlainText
  }

  Text {
    id: valueText
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: root.value
    color: root.alarming ? root.urgent : root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  textFormat: Text.PlainText
  }
}