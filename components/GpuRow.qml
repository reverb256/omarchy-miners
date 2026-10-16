pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// One GPU: model, the workload that owns it, utilization headline, VRAM
// against its capacity, power, temperature/fan, clocks. Read-only — there is
// no control surface on a GPU row.
//
// Reliability: the 3090's fan/temp sensors (EVGA hybrid) are flagged in
// fleet.py (`gpu_notes`); its readings render dimmed with a trailing `~` and
// a note line, and never drive alerts.
Item {
  id: root

  required property var gpu
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property int tempWarnC: 70
  property int tempAlarmC: 80

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property real temp: gpu ? Number(gpu.temp || 0) : 0
  readonly property bool tempReliable: !gpu || !gpu.reliable || gpu.reliable.temp !== false
  readonly property bool fanReliable: !gpu || !gpu.reliable || gpu.reliable.fan !== false
  readonly property bool tempAlarming: tempReliable && temp >= tempAlarmC
  readonly property bool tempWarning: tempReliable && !tempAlarming && temp >= tempWarnC
  readonly property real vramRatio: (gpu && gpu.vramRatio !== undefined) ? Number(gpu.vramRatio) : -1
  readonly property bool vramAlarming: vramRatio >= 0.97
  readonly property string ownerText: gpu ? String(gpu.owner || "") : ""
  readonly property string noteText: gpu ? String(gpu.note || "") : ""

  function alpha(color, amount) {
    return Qt.rgba(color.r, color.g, color.b, amount)
  }

  implicitHeight: layout.implicitHeight + Style.spacing.lg * 2

  BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.alpha(root.foreground, 0.04)
    borderSpec: (root.tempAlarming || root.vramAlarming)
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
    spacing: Style.space(4)

    // ---- Identity, owner, utilization --------------------------------
    Item {
      width: parent.width
      implicitHeight: Math.max(identity.implicitHeight, util.implicitHeight)

      Column {
        id: identity
        anchors.left: parent.left
        anchors.right: util.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: root.gpu ? String(root.gpu.shortName || root.gpu.name || "") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }

        Text {
          width: parent.width
          visible: root.ownerText !== ""
          text: root.ownerText !== "" ? "used by " + root.ownerText : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
      }

      Text {
        id: util
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.gpu ? String(root.gpu.utilText || "—") : "—"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        textFormat: Text.PlainText
      }
    }

    // ---- VRAM against its capacity -----------------------------------
    Item {
      width: parent.width
      implicitHeight: Math.max(vramLabel.implicitHeight, powerText.implicitHeight)

      Text {
        id: vramLabel
        anchors.left: parent.left
        anchors.right: powerText.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        text: root.gpu ? "VRAM  " + String(root.gpu.vramText || "—") : "VRAM  —"
        color: root.vramAlarming ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: root.vramAlarming
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        id: powerText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.gpu ? String(root.gpu.powerText || "—") : "—"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        textFormat: Text.PlainText
      }
    }

    Item {
      id: meter
      width: parent.width
      visible: root.vramRatio >= 0
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
        width: track.width * Math.max(0, root.vramRatio)
        color: root.vramAlarming ? root.urgent : root.foreground

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    // ---- Temp, fan, clocks -------------------------------------------
    Item {
      width: parent.width
      implicitHeight: Math.max(tempText.implicitHeight, clockText.implicitHeight)

      Text {
        id: tempText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: {
          if (!root.gpu) return "—"
          var text = String(root.gpu.tempText || "—")
          if (!root.tempReliable) text += "~"
          var fan = Number(root.gpu.fan || 0)
          if (fan > 0 && root.fanReliable) text += "  ·  fan " + String(root.gpu.fanText || "")
          return text
        }
        color: root.tempAlarming ? root.urgent : ((root.tempWarning || !root.tempReliable) ? root.foreground : root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: root.tempWarning || root.tempAlarming || !root.tempReliable
        textFormat: Text.PlainText
      }

      Text {
        id: clockText
        anchors.right: parent.right
        anchors.left: tempText.right
        anchors.leftMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
        text: root.gpu && String(root.gpu.clockText || "") !== "" ? String(root.gpu.clockText) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        textFormat: Text.PlainText
      }
    }

    // ---- Reliability note (the EVGA-hybrid 3090) ----------------------
    Text {
      width: parent.width
      visible: root.noteText !== ""
      text: root.noteText !== "" ? "note: " + root.noteText : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
    }
  }
}
