pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// One collapsed section, exactly one line tall: a kit Button carrying the
// section name, with the section's own summary value on the trailing edge.
// Clicking (or tabbing onto it) toggles the section — the CALLER keeps the
// expanded content as siblings, so a collapsed section never contributes more
// than this line to the panel's height.
//
// The chevrons are Material Design codepoints: themes ship Nerd Font families
// whose geometric-shapes coverage varies, and those codepoints are the ones
// every patched family carries.
Item {
  id: root

  property string label: ""
  property string summaryText: ""
  property bool expanded: false
  property bool alarming: false
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal toggled()

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string chevronDown: "\u{F0140}"
  readonly property string chevronRight: "\u{F0142}"

  implicitHeight: headerButton.implicitHeight

  Button {
    id: headerButton

    anchors.left: parent.left
    anchors.right: summary.left
    anchors.rightMargin: Style.spacing.md
    anchors.verticalCenter: parent.verticalCenter

    leftAlign: true
    iconText: root.expanded ? root.chevronDown : root.chevronRight
    text: root.label
    iconSize: Style.font.caption
    fontSize: Style.font.bodySmall
    foreground: root.foreground
    fontFamily: root.fontFamily
    tooltipText: root.expanded ? "Collapse" : "Expand"
    onClicked: root.toggled()
  }

  Text {
    id: summary
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: root.summaryText
    color: root.alarming ? root.urgent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: root.alarming
    textFormat: Text.PlainText
  }
}
