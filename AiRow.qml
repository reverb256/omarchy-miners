pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// ONE row per k3s AI workload (a model server the panel can control), the
// same contract as MinerRow in a compact single line: state pill · workload
// id · optional switch chip · async checkbox.
//
// The checkbox shows the workload's DESIRED state — its Deployment spec,
// `!paused` — so a transient outage keeps the box checked while the workload
// self-heals. Flipping it OFF (a stop) asks for one more click first; the
// chip (model switch for variants that share one GPU) ALWAYS asks, because
// it starts one variant and stops its sibling. Both confirm states expire
// after 5 s. `busy` shows a pending mark and swallows further clicks, and
// the row settles when the next poll lands — never optimistically.
//
// Unknown (no apiserver answered) hides every control: the action would
// travel the same API the poll just failed to reach.
Item {
  id: root

  required property var workload
  // The sibling variant a switch would start (Model.switchOffer); null when
  // this row has no switch offer — the chip then renders nothing.
  property var switchTo: null
  // Tooltip detail, formatted by the Panel (llmDetail/mediaDetail over the
  // workload probe record) so number/state formatting stays in one place.
  property string detailText: ""
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property bool busy: false

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string stateLabel: Model.aiStateLabel(root.workload)
  readonly property bool online: root.stateLabel === "active"
  readonly property bool paused: root.stateLabel === "paused"
  // Nobody answered about this workload: state is unknown, not stopped.
  readonly property bool unknown: root.stateLabel === "unknown"
  readonly property bool controllable: !!root.workload
    && root.workload.controllable !== false && !root.unknown
  readonly property bool chipVisible: root.switchTo !== null && !root.unknown

  // MinerRow's wording and colours: paused is stated (dim), not flagged; a
  // row that should run and does not — or one nobody could be asked about —
  // is the failure.
  readonly property color stateColor: root.online ? root.foreground : (root.paused ? root.dim : root.urgent)
  readonly property bool stateFlagged: !root.online && !root.paused

  signal toggleRequested()
  signal switchRequested()

  // Stopping is deliberate (same rule as the miners): the first click ARMS
  // the stop, a second within 5 s commits, and an expired arm cancels.
  property bool stopConfirm: false
  // The switch chip always arms first: it stops the running variant, so it
  // is a stop-class action even when the target is already up.
  property bool switchConfirm: false

  function wouldStop() {
    if (!root.workload) return false
    return !root.paused
  }

  function requestToggle() {
    if (root.busy || !root.controllable) return
    if (root.wouldStop() && !root.stopConfirm) {
      root.stopConfirm = true
      stopConfirmTimer.restart()
      return
    }
    root.stopConfirm = false
    root.toggleRequested()
  }

  function requestSwitch() {
    if (root.busy || !root.chipVisible) return
    if (!root.switchConfirm) {
      root.switchConfirm = true
      switchConfirmTimer.restart()
      return
    }
    root.switchConfirm = false
    root.switchRequested()
  }

  Timer {
    id: stopConfirmTimer
    interval: 5000
    repeat: false
    onTriggered: root.stopConfirm = false
  }

  Timer {
    id: switchConfirmTimer
    interval: 5000
    repeat: false
    onTriggered: root.switchConfirm = false
  }

  function alpha(color, amount) {
    return Qt.rgba(color.r, color.g, color.b, amount)
  }

  implicitHeight: headline.implicitHeight + Style.spacing.lg

  BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    // Paused and idle rows recede rather than disappear: a stopped model
    // server is still a fact about the fleet.
    color: root.alpha(root.foreground, root.online ? 0.04 : 0.02)
    borderSpec: Border.none()
  }

  // ---- State, identity, switch chip, control ------------------------
  Item {
    id: headline
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    implicitHeight: Math.max(statePill.implicitHeight, nameText.implicitHeight,
                             controlsRow.implicitHeight)

    BorderSurface {
      id: statePill
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      // The same fixed-width pill as the miner rows, so the identity column
      // never shifts sideways when a workload pauses or drops.
      implicitWidth: Style.space(58)
      implicitHeight: statePillText.implicitHeight + Style.space(4)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, root.online ? 0.08 : 0.03)
      borderSpec: root.stateFlagged
        ? Border.flat(root.alpha(root.urgent, 0.4), 1)
        : Border.none()

      Text {
        id: statePillText
        anchors.centerIn: parent
        width: Math.max(0, parent.width - Style.space(8))
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: root.stateLabel
        color: root.stateColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: root.online
        textFormat: Text.PlainText
      }
    }

    // The workload id IS the k8s Deployment name — the precise, actionable
    // identity. The human label, card and loaded model live in the tooltip.
    Text {
      id: nameText
      anchors.left: statePill.right
      anchors.right: controlsRow.left
      anchors.leftMargin: Style.spacing.md
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      text: root.workload ? String(root.workload.id || "") : ""
      color: root.online ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }

    Row {
      id: controlsRow
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

      // ---- Model switch (only for variants sharing one GPU) ---------
      Item {
        id: chip
        visible: root.chipVisible
        implicitWidth: chipText.implicitWidth + Style.space(12)
        implicitHeight: control.boxSize
        opacity: root.busy ? 0.55 : 1

        BorderSurface {
          anchors.fill: parent
          radius: Style.cornerRadius > 0 ? Math.round(control.boxSize * 0.28) : 0
          color: Style.normalFillFor(root.foreground, Color.accent)
          borderSpec: root.switchConfirm
            ? Border.flat(root.alpha(root.urgent, 0.5), 1)
            : Border.controlSpec("normal", root.foreground, Color.accent)

          Text {
            id: chipText
            anchors.centerIn: parent
            text: root.busy
              ? "…"
              : (root.switchConfirm
                ? "switch?"
                : "→ " + Model.switchLabel(root.switchTo))
            color: root.switchConfirm ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: root.switchConfirm
            textFormat: Text.PlainText
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.requestSwitch()
        }
      }

      // ---- Async checkbox (the miner rows' control) -----------------
      Item {
        id: control
        visible: root.controllable
        readonly property int boxSize: Math.max(22, Math.round(Style.spacing.controlHeight * 0.55))
        readonly property bool checked: !!root.workload
          && (root.workload.managed ? !root.workload.paused : root.online)
        implicitWidth: boxSize
        implicitHeight: boxSize

        BorderSurface {
          id: box
          anchors.fill: parent
          radius: Style.cornerRadius > 0 ? Math.round(control.boxSize * 0.28) : 0
          color: control.checked
            ? Style.selectedFillFor(root.foreground, Color.accent)
            : Style.normalFillFor(root.foreground, Color.accent)
          borderSpec: root.stopConfirm
            ? Border.flat(root.alpha(root.urgent, 0.5), 1)
            : Border.controlSpec(control.checked ? "selected" : "normal", root.foreground, Color.accent)
          opacity: root.busy ? 0.55 : 1

          Behavior on color { ColorAnimation { duration: Style.duration(120) } }

          Text {
            anchors.centerIn: parent
            // The pending mark keeps the box honest while the helper runs:
            // the tick appears only once the poller confirms the new state.
            // "!" is the armed-to-stop state — a second click commits.
            text: root.busy ? "…" : (root.stopConfirm ? "!" : (control.checked ? "\u{F012C}" : ""))
            color: root.stopConfirm
              ? root.urgent
              : (control.checked ? Style.selectedStateColor(root.foreground, Color.accent) : root.dim)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.requestToggle()
        }
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
    text: {
      if (!root.workload) return ""
      var lines = []
      lines.push(String(root.workload.host || "") + " · " + String(root.workload.label || "")
        + "  ·  " + String(root.workload.ns || "") + "/" + String(root.workload.deploy || ""))
      if (root.online)
        lines.push("ready " + Number(root.workload.ready || 0) + "/" + Number(root.workload.desired || 0)
          + "  ·  " + String(root.workload.gpu || ""))
      else if (root.paused)
        lines.push("Paused by you — deployment scaled to 0")
      else if (root.unknown)
        lines.push("no apiserver answered — control hidden until one does")
      else
        lines.push("should be running — not ready")
      if (root.detailText !== "") lines.push(root.detailText)
      // A static card fact the reader needs before flipping the row (e.g.
      // the nexus 3060 Ti's arbitration by the pause machinery).
      if (String(root.workload.hint || "") !== "") lines.push(String(root.workload.hint))
      if (root.chipVisible && root.switchTo)
        lines.push((root.switchConfirm ? "click again to switch — " : "switch: ")
          + "stop " + String(root.workload.id || "") + ", start " + String(root.switchTo.id || ""))
      else if (root.controllable)
        lines.push(root.stopConfirm
          ? "click again to stop — stopping a model server needs confirmation"
          : "checkbox: stop (asks again) / start")
      return lines.join("\n")
    }
  }
}
