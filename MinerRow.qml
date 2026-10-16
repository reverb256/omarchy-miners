pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "util/format.js" as Format

// ONE row per GPU: this card's own readings (temperature, power, VRAM) and
// the miner that drives it (state, hashrate against its model's baseline,
// share throughput), with the async pause/resume checkbox.
//
// The fleet runs one miner per card (the fleet definition enforces the dedup),
// so the old panel's separate "GPUs" and "Miners" lists were two views of the
// same seven cards — that duplication was most of the panel's height. The
// panel now pairs them (Model.matchGpu) and renders this one row.
//
// Fixed geometry: two text lines and a meter whose width does not move, so the
// numbers sit in the same column on every row and every poll. Colour is the
// theme's single signal colour (urgent) and is spent only on anomalies: a card
// not mining, a card above its temperature alarm, a hashrate under three
// quarters of its model's expected peak. Nominal readings stay dim.
//
// Every colour comes from the theme. The previous version hardcoded a grey
// surface and green/orange/red status colours, which fought every theme that
// was not dark.
Item {
  id: root

  required property var miner
  // The GPU record this miner drives (Model.matchGpu); null when the host
  // reports no such card.
  property var gpu: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property int tempWarnC: 70
  property int tempAlarmC: 80
  property bool busy: false
  // Fully formatted by Panel (e.g. "$1.15/day"), empty when unknown — number
  // formatting stays in one place, the same split the poller uses. Shown in
  // the hover detail, not the row lines.
  property string earningsText: ""
  // One extra trailing fact on the second line — the krash3 rig's xmrig
  // readout. Empty for peakminer rows.
  property string extraText: ""

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property bool online: !!miner && miner.online === true
  // Paused BY THE USER (the k3s Deployment is scaled to 0): a deliberate stop,
  // rendered differently from a failure. Read from the poller's spec-derived
  // flag, never inferred from "not online".
  readonly property bool paused: !!miner && miner.paused === true
  // Its host could not be reached, so this row's state is unknown rather than
  // stopped — offering "Resume" would imply we know it is not running.
  readonly property bool unknown: !!miner && miner.hostReachable === false && !online && !paused
  // Monitor-only rows (the Kryptex app rig) get no pause/resume at all.
  readonly property bool controllable: !root.miner || root.miner.controllable !== false

  // The card's readings resolved once, in one place (Model.rowFacts), so the
  // row and the panel's exception ordering can never disagree about whether
  // this card is an anomaly.
  readonly property var facts: Model.rowFacts(root.miner, root.gpu, root.tempAlarmC)
  readonly property string shortName: facts.shortName
  readonly property real temp: facts.temp
  readonly property real power: facts.power
  readonly property bool tempAlarming: facts.hot
  readonly property bool lowHashrate: facts.low

  readonly property string stateLabel: root.paused
    ? "paused"
    : (root.online ? "active" : (root.unknown ? "unknown" : "inactive"))
  // paused is stated (dim), not flagged: the user did it. A card that is not
  // mining and is not paused — or a host we cannot reach — is the failure.
  readonly property color stateColor: root.online ? root.foreground : (root.paused ? root.dim : root.urgent)
  readonly property bool stateFlagged: !root.online && !root.paused

  readonly property string rateText: root.online
    ? Format.formatHashrate(facts.hashrate)
    : root.stateLabel

  // Shares per hour is the throughput signal; when the pool has not accepted a
  // share recently the age of the last one is the useful number instead.
  readonly property string shareText: {
    if (!root.online || !root.miner) return ""
    var rate = Number(root.miner.shareRatePerHour || 0)
    if (rate > 0) return Math.round(rate) + " sh/h"
    var age = Number(root.miner.lastShareAgeSec || 0)
    if (age > 0) return "last share " + root.ageText(age)
    return ""
  }

  function ageText(seconds) {
    var value = Math.max(0, Number(seconds || 0))
    if (value < 90) return Math.round(value) + "s ago"
    if (value < 5400) return Math.round(value / 60) + "m ago"
    return Math.round(value / 3600) + "h ago"
  }

  signal toggleRequested()

  // Stopping a miner is deliberate: the first click ARMS this row (the box
  // turns urgent and shows "!"), a second click within 5 s commits, and the
  // arm expiring cancels. Resuming needs a single click. Nothing in this
  // panel can stop a miner without the explicit click-plus-confirm pair.
  property bool stopConfirm: false

  function wouldStop() {
    if (!root.miner) return false
    return root.miner.managed ? !root.miner.paused : root.online
  }

  function requestToggle() {
    if (root.busy) return
    if (root.wouldStop() && !root.stopConfirm) {
      root.stopConfirm = true
      stopConfirmTimer.restart()
      return
    }
    root.stopConfirm = false
    root.toggleRequested()
  }

  Timer {
    id: stopConfirmTimer
    interval: 5000
    repeat: false
    onTriggered: root.stopConfirm = false
  }

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

    // ---- State, identity, hashrate against baseline, control ----------
    Item {
      id: headline
      width: parent.width
      implicitHeight: Math.max(statePill.implicitHeight, nameText.implicitHeight, rate.implicitHeight, control.implicitHeight)

      BorderSurface {
        id: statePill
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        // Fixed width, one size for every state word: the rows' identity
        // column must not shift sideways when a miner pauses or drops.
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

      // Host and card, one line, elided from the right: the card model is the
      // part worth keeping when the panel is narrow.
      Text {
        id: nameText
        anchors.left: statePill.right
        anchors.right: rate.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        text: root.miner ? String(root.miner.host || "") + "  " + root.shortName : ""
        color: root.online ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      // The meter column is a fixed width so the bars line up down the list:
      // bar = hashrate against the model's expected peak (Model.js), number
      // right after it. The control's column is reserved even on the rows that
      // have no control at all (the monitor-only Kryptex rig), so the numbers
      // and bars line up across the whole list, not just the controllable rows.
      Item {
        id: rate
        anchors.right: parent.right
        anchors.rightMargin: control.implicitWidth + Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: Style.space(134)
        implicitHeight: Math.max(track.height, rateValue.implicitHeight)

        Rectangle {
          id: track
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.round(parent.width * 0.44)
          height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
          radius: height / 2
          color: Style.selectedFillFor(root.foreground, Color.accent)
        }

        Rectangle {
          anchors.left: track.left
          anchors.verticalCenter: track.verticalCenter
          height: track.height
          radius: track.radius
          // No baseline for the model (or no reading) -> an empty track, never
          // a full one: a full bar would read as "at expected".
          width: track.width * Math.max(0, root.facts.ratio)
          color: root.lowHashrate ? root.urgent : root.foreground

          Behavior on width {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
          }
        }

        Text {
          id: rateValue
          anchors.right: parent.right
          anchors.left: track.right
          anchors.leftMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignRight
          text: root.rateText
          color: root.lowHashrate ? root.urgent : (root.online ? root.foreground : root.dim)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
      }

      // The control is an async CHECKBOX, not a verb button: it shows the
      // miner's DESIRED state (a k3s miner: its Deployment spec — checked
      // means "should be running", so a transient outage keeps the box
      // checked while the fleet self-heals; unmanaged rows fall back to live
      // state). Flipping it OFF (a stop) asks for one more click first —
      // stopConfirm arms the box, and only the confirmed flip reaches
      // miner-control. A flip requests pause/resume through the one
      // in-flight action path; `busy` shows a pending mark and swallows
      // further flips, and the box settles when the next poll lands — never
      // optimistically.
      Item {
        id: control
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        // No control at all while the host is out of contact: the action would
        // travel the same connection the poll just failed to make.
        visible: !root.unknown && root.controllable
        readonly property int boxSize: Math.max(22, Math.round(Style.spacing.controlHeight * 0.55))
        readonly property bool checked: !!root.miner && (root.miner.managed ? !root.miner.paused : root.online)
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

    // ---- The readings that only appear when they mean something -------
    // Temperature (urgent only at/above the alarm threshold), power, share
    // throughput, and the row's one extra fact when it has one.
    Item {
      width: parent.width
      implicitHeight: Math.max(tempText.implicitHeight, rest.implicitHeight)

      Text {
        id: tempText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        // The temperature is the one reading worth the signal colour on its
        // own: heat is what kills a mining card.
        text: {
          if (!root.online) return ""
          if (root.temp <= 0) return "temp —"
          return root.temp.toFixed(0) + "°C"
        }
        color: root.tempAlarming ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: root.tempAlarming
        textFormat: Text.PlainText
      }

      Text {
        id: rest
        anchors.left: tempText.right
        anchors.right: parent.right
        anchors.leftMargin: tempText.text !== "" ? Style.spacing.sm : 0
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: {
          if (!root.online) return ""
          var parts = []
          if (root.power > 0) parts.push(Format.formatPower(root.power))
          if (root.shareText !== "") parts.push(root.shareText)
          if (root.extraText !== "") parts.push(root.extraText)
          // The collector's SRB window ratio: the miner is running at less
          // than half its own sustained rate (the gaming-rig signal). The
          // word is the marker; the tooltip carries the numbers.
          if (root.miner && root.miner.throttled === true) parts.push("throttled")
          var pressure = Model.baselineText(root.shortName)
          if (pressure !== "" && root.lowHashrate) parts.push("expected " + pressure)
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
    text: {
      if (!root.miner) return ""
      var lines = []
      lines.push(String(root.miner.host) + " · " + String(root.miner.unit)
        + (root.gpu && root.gpu.index !== undefined ? "  ·  GPU " + String(root.gpu.index) : "")
        + "  ·  port " + String(root.miner.port))
      lines.push(root.online
        ? root.miner.hashrateText + " · " + Format.formatPower(root.power) + " · " + root.temp.toFixed(0) + "°C"
        : root.stateLabel + (root.paused ? " (deployment scaled to 0)" : ""))
      // Collector facts, when the Windows host's payload carries them: who is
      // on the box, and the SRB window ratio that flags a throttled miner.
      if (String(root.miner.sessionText || "") !== "")
        lines.push("user session: " + String(root.miner.sessionText))
      if (root.miner.throttled === true) {
        var windows = root.miner.srbWindows || ({})
        var sustained = Number(windows["1hr"] || windows["6hr"] || 0)
        lines.push("throttled: 1min " + Format.formatHashrate(Number(windows["1min"] || 0))
          + " vs " + Format.formatHashrate(sustained) + " sustained")
      }
      if (root.gpu) {
        var vram = root.gpu.vramTotal > 0
          ? Format.formatMiB(root.gpu.vramUsed || 0) + " / " + Format.formatMiB(root.gpu.vramTotal)
          : ""
        var used = [String(root.gpu.utilText || ""), vram, String(root.gpu.fanText || "") !== "—" ? "fan " + root.gpu.fanText : ""]
          .filter(function(part) { return part !== "" })
          .join("  ·  ")
        if (used !== "") lines.push(used)
        if (root.gpu.owner) lines.push("on card: " + String(root.gpu.owner))
      }
      var expected = Model.baselineText(root.shortName)
      if (expected !== "" && root.online) lines.push(expected)
      if (root.gpu && root.gpu.note) lines.push(String(root.gpu.note))
      if (root.online && root.shareText !== "") lines.push(root.shareText + " accepted")
      // Stated, not implied: the two Windows rigs are polled over ssh, where
      // nothing reports share throughput.
      if (root.online && root.shareText === "") lines.push("no share data for this host")
      if (root.online && root.earningsText !== "") lines.push(root.earningsText + " at the current pool rate")
      if (root.online && Number(root.miner.xmrigHashrate || 0) > 0)
        lines.push("XMR " + root.miner.xmrigText + " · " + Number(root.miner.xmrigShares || 0).toFixed(0)
          + " shares of " + Number(root.miner.xmrigSharesTotal || 0).toFixed(0)
          + (root.miner.xmrigPool ? " · " + root.miner.xmrigPool : ""))
      if (root.controllable && !root.unknown)
        lines.push(root.stopConfirm
          ? "click again to pause — stopping a miner needs confirmation"
          : "checkbox: pause (asks again) / resume")
      return lines.join("\n")
    }
  }
}
