pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// One model file on disk: name, size, and whether it is currently loaded by
// some model server on the same host. Read-only.
Item {
  id: root

  required property string name
  property string sizeText: ""
  property bool loaded: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string loadedGlyph: "\u{25CF}"   // ● — plain Unicode, no Nerd Font needed

  implicitHeight: Math.max(nameText.implicitHeight, size.implicitHeight) + Style.space(1)

  Text {
    id: nameText
    anchors.left: parent.left
    anchors.right: size.left
    anchors.rightMargin: Style.spacing.sm
    anchors.verticalCenter: parent.verticalCenter
    text: (root.loaded ? root.loadedGlyph + " " : "") + root.name
    color: root.loaded ? root.foreground : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: root.loaded
    elide: Text.ElideMiddle
    textFormat: Text.PlainText
  }

  Text {
    id: size
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: root.sizeText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    textFormat: Text.PlainText
  }
}
