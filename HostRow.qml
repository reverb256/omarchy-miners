pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// One host's rollup: name, how many of its miners are up, and its combined
// hashrate. Sits above that host's miner rows as a section heading with
// numbers, so the panel reads fleet -> host -> GPU.
Item {
  id: root

  required property string host
  property var stats: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property string hashrateText: ""

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property bool connected: !!stats && stats.connected === true
  // A host we cannot reach is not the same as a host whose miners are stopped:
  // it tells us nothing either way, and saying "offline" would be a claim the
  // poll never made.
  readonly property bool reachable: !stats || stats.reachable !== false
  readonly property int online: stats ? Number(stats.online || 0) : 0
  readonly property int configured: stats ? Number(stats.configured || 0) : 0
  // Some miners up but not all is worth flagging: it usually means a unit died
  // rather than a host being deliberately idle.
  readonly property bool partial: connected && online < configured

  implicitHeight: Math.max(name.implicitHeight, value.implicitHeight) + Style.spacing.sm

  Text {
    id: name
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    text: root.host.toUpperCase()
    color: root.connected ? Qt.darker(root.foreground, 1.4) : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
    // Nerd Font outlines can paint above the box Text reserves, and a bold
    // small-caps label at the top of a clipping Flickable loses the overshoot.
    topPadding: Math.ceil(Style.font.caption * 0.15)
  }

  Text {
    id: value
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: {
      if (!root.reachable) return "unreachable"
      if (!root.connected) return root.configured > 0 ? "idle" : ""
      var text = root.hashrateText
      if (root.partial) text += "  ·  " + root.online + "/" + root.configured
      return text
    }
    color: (root.partial || !root.reachable) ? root.urgent : (root.connected ? root.foreground : root.dim)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
