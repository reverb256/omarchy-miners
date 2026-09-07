pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// One miner: label and host, hashrate, a power meter against its limit, a
// temperature reading, and a pause/resume control.
//
// Every colour comes from the theme. The previous version hardcoded a grey
// surface and green/orange/red status colours, which fought every theme that
// was not dark. Themes define one signal colour — urgent — so heat and an
// over-limit draw use it, and everything nominal reads in the panel
// foreground at the usual dim/full split.
Item {
  id: root

  required property var miner
  property var host: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property int tempWarnC: 70
  property int tempAlarmC: 80
  property bool busy: false

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property bool online: !!miner && miner.online === true
  // Its host could not be reached, so this row's state is unknown rather than
  // stopped — offering "Resume" would imply we know it is not running.
  readonly property bool unknown: !!miner && miner.hostReachable === false && !online
  readonly property real temp: miner ? Number(miner.temp || 0) : 0
  readonly property real power: miner ? Number(miner.power || 0) : 0
  readonly property real powerLimit: miner ? Number(miner.powerLimit || 0) : 0
  readonly property real powerRatio: powerLimit > 0 ? Math.max(0, Math.min(1, power / powerLimit)) : -1

  readonly property bool tempAlarming: online && temp >= tempAlarmC
  readonly property bool tempWarning: online && !tempAlarming && temp >= tempWarnC
  // A card pinned against its power limit is the same class of signal as heat.
  readonly property bool powerAlarming: online && powerRatio >= 0.98

  signal toggleRequested()

  function alpha(color, amount) {
    return Qt.rgba(color.r, color.g, color.b, amount)
  }

  implicitHeight: layout.implicitHeight + Style.spacing.xl * 2

  BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    // Offline rows recede rather than disappear: a stopped miner is still a
    // fact about the fleet.
    color: root.alpha(root.foreground, root.online ? 0.05 : 0.02)
    borderSpec: root.tempAlarming
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
    spacing: Style.space(6)

    // ---- Identity, headline hashrate, control -------------------------
    Item {
      width: parent.width
      implicitHeight: Math.max(identity.implicitHeight, rate.implicitHeight, control.implicitHeight)

      Column {
        id: identity
        anchors.left: parent.left
        anchors.right: rate.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: root.miner ? String(root.miner.label || "") : ""
          color: root.online ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        textFormat: Text.PlainText
        }

        Text {
          width: parent.width
          text: root.miner ? String(root.miner.host || "") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        textFormat: Text.PlainText
        }
      }

      Text {
        id: rate
        anchors.right: control.visible ? control.left : parent.right
        anchors.rightMargin: control.visible ? Style.spacing.md : 0
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: root.online && root.miner ? root.miner.hashrateText : (root.unknown ? "Unknown" : "Offline")
        color: root.online ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      textFormat: Text.PlainText
      }

      Button {
        id: control
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(74)
        // No control at all while the host is out of contact: the action would
        // travel the same connection the poll just failed to make, and qs.Ui's
        // Button has no disabled state — its MouseArea always accepts clicks,
        // so a dimmed-looking button would still fire.
        visible: !root.unknown
        text: root.busy ? "…" : (root.online ? "Pause" : "Resume")
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        verticalPadding: Style.spacing.controlPaddingY
        opacity: root.busy ? 0.55 : 1
        onClicked: if (!root.busy) root.toggleRequested()
      }
    }

    // ---- Power against its limit -------------------------------------
    Item {
      width: parent.width
      visible: root.online
      implicitHeight: Math.max(powerLabel.implicitHeight, powerValue.implicitHeight)

      Text {
        id: powerLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "Power"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      }

      Text {
        id: powerValue
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.miner
          ? root.miner.powerText + (root.powerLimit > 0 ? " / " + root.powerLimit.toFixed(0) + "W" : "")
          : ""
        color: root.powerAlarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      textFormat: Text.PlainText
      }
    }

    Item {
      id: meter
      width: parent.width
      visible: root.online && root.powerRatio >= 0
      implicitHeight: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

      Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        color: Style.selectedFillFor(root.foreground, Color.accent)
      }

      Rectangle {
        anchors.left: track.left
        anchors.verticalCenter: track.verticalCenter
        height: track.height
        radius: track.radius
        width: track.width * Math.max(0, root.powerRatio)
        color: root.powerAlarming ? root.urgent : root.foreground

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    // ---- Temperature, fan, utilisation -------------------------------
    Item {
      width: parent.width
      visible: root.online
      implicitHeight: Math.max(tempText.implicitHeight, detailText.implicitHeight)

      Text {
        id: tempText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.temp > 0 ? root.temp.toFixed(0) + "°C" : "—"
        color: root.tempAlarming ? root.urgent : (root.tempWarning ? root.foreground : root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: root.tempWarning || root.tempAlarming
      textFormat: Text.PlainText
      }

      Text {
        id: detailText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: {
          if (!root.miner) return ""
          var parts = []
          var fan = Number(root.miner.fan || 0)
          var util = Number(root.miner.util || 0)
          if (fan > 0) parts.push("fan " + fan.toFixed(0) + "%")
          if (util > 0) parts.push("util " + util.toFixed(0) + "%")
          return parts.join("  ·  ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      }
    }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
  }

  PanelToolTip {
    visible: hover.containsMouse
    fontFamily: root.fontFamily
    text: root.miner
      ? String(root.miner.host) + " · " + String(root.miner.unit)
        + "\nport " + String(root.miner.port)
        + (root.online ? "\n" + root.miner.hashrateText + " · " + root.miner.powerText : "\nstopped")
      : ""
  }
}