pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// Small-caps section heading with an optional right-aligned value — the same
// visual language as the host captions in the model-on-disk list, used between
// panel sections.
Item {
  id: root

  property string text: ""
  property string rightText: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.4)

  implicitHeight: Math.max(label.implicitHeight, value.implicitHeight)

  Text {
    id: label
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    text: root.text.toUpperCase()
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
    // Nerd Font outlines can paint above the box Text reserves; a bold
    // small-caps label at the top of a clipping Flickable loses the overshoot.
    topPadding: Math.ceil(Style.font.caption * 0.15)
    textFormat: Text.PlainText
  }

  Text {
    id: value
    anchors.right: parent.right
    anchors.left: label.right
    anchors.leftMargin: Style.spacing.sm
    anchors.verticalCenter: parent.verticalCenter
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    text: root.rightText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    textFormat: Text.PlainText
  }
}
