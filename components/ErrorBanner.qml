pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// A banner surface for poller/action failures.
BorderSurface {
  id: root

  property string message: ""
  property color urgent: Color.urgent
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
  borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
  radius: Style.cornerRadius

  Text {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    text: root.message
    color: Qt.darker(root.foreground, 1.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
