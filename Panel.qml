pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "util/format.js" as Format
import "components"

// Panel content for the mining fleet.
//
// BarWidget.qml owns the bar button AND the Main data instance; this file is
// presentation and keyboard handling only. `data` resolves through hostWidget,
// never through this panel's own loader — that would be circular.
Panel {
  id: root

  readonly property string pluginId: "io.github.jkro.miners"

  moduleName: pluginId
  ipcTarget: pluginId
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The fleet data, owned by the bar widget. Null until injectPanel() runs.
  readonly property var fleet: hostWidget ? hostWidget.fleet : null

  function open() { root.controller.show(); if (root.fleet) root.fleet.refresh() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Called by the bar widget when a pause/resume fails.
  function reportActionError(message) {
    root.actionError = message
    errorTimer.restart()
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int tempWarnC: Number(setting("tempWarnC", 70))
  readonly property int tempAlarmC: Number(setting("tempAlarmC", 80))

  readonly property string minerGlyph: "\u{F08B7}"

  readonly property bool alarming: {
    if (!root.fleet) return false
    for (var i = 0; i < root.fleet.miners.length; i++) {
      if (root.fleet.miners[i].online && Number(root.fleet.miners[i].temp || 0) >= root.tempAlarmC) return true
    }
    return false
  }

  property int cursorIndex: -1
  property bool cursorActive: false
  // The miner row the keyboard has armed for a STOP (Enter twice commits).
  property int cursorConfirmIndex: -1
  property string actionError: ""

  // The failure stays up long enough to read, then clears itself: a panel that
  // keeps showing a stale error after the miner recovered is worse than none.
  Timer {
    id: errorTimer
    interval: 12000
    repeat: false
    onTriggered: root.actionError = ""
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = -1
    cursorConfirmIndex = -1
    if (panelFlick) panelFlick.contentY = 0
  }

  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value))
  }

  // Delegates reach the data object through root: inside a nested Repeater the
  // bare name resolves against the delegate's own scope. Reading busyRevision
  // keeps the binding live — a function call alone is not watchable.
  function dataBusy(unit) {
    if (!root.fleet) return false
    return root.fleet.busyRevision >= 0 && root.fleet.isBusy(unit)
  }

  function moveCursor(delta) {
    var rows = root.minerRows
    if (rows.length === 0) return
    cursorActive = true
    cursorConfirmIndex = -1
    cursorIndex = ((cursorIndex + delta) % rows.length + rows.length) % rows.length
  }

  // Keyboard stops follow the same rule as clicks: Enter arms the row's
  // stop, Enter again within 5 s confirms; moving or closing cancels.
  function activateCursor() {
    var rows = root.minerRows
    if (!cursorActive || cursorIndex < 0 || cursorIndex >= rows.length) return
    var row = rows[cursorIndex]
    var willStop = row.managed ? !row.paused : row.online
    if (willStop && root.cursorConfirmIndex !== cursorIndex) {
      root.cursorConfirmIndex = cursorIndex
      cursorConfirmTimer.restart()
      return
    }
    root.cursorConfirmIndex = -1
    if (root.fleet) root.fleet.toggle(row)
  }

  Timer {
    id: cursorConfirmTimer
    interval: 5000
    repeat: false
    onTriggered: root.cursorConfirmIndex = -1
  }

  // Hosts, each carrying its own miners. Nested Repeaters bind modelData from
  // their own model, which a Loader cannot do — sourceComponent never injects
  // a required property.
  readonly property var hostGroups: {
    if (!root.fleet) return []
    var out = []
    var hostNames = Object.keys(root.fleet.hosts)
    for (var h = 0; h < hostNames.length; h++) {
      var host = hostNames[h]
      var owned = []
      for (var m = 0; m < root.fleet.miners.length; m++) {
        if (String(root.fleet.miners[m].host) === host) owned.push(root.fleet.miners[m])
      }
      out.push({ host: host, stats: root.fleet.hosts[host], miners: owned })
    }
    return out
  }

  readonly property int hostCount: hostGroups.length

  // ---- GPU fleet groupings + display helpers -------------------------

  // GPU rows, same host-grouping shape as the miners.
  readonly property var gpuGroups: {
    var out = []
    if (!root.fleet) return out
    var index = ({})
    for (var i = 0; i < root.fleet.gpus.length; i++) {
      var gpu = root.fleet.gpus[i]
      var key = String(gpu.host)
      if (index[key] === undefined) {
        index[key] = out.length
        out.push({ host: key, gpus: [], vramUsed: 0, vramTotal: 0 })
      }
      var group = out[index[key]]
      group.gpus.push(gpu)
      group.vramUsed += Number(gpu.vramUsed || 0)
      group.vramTotal += Number(gpu.vramTotal || 0)
    }
    return out
  }

  readonly property var modelGroups: {
    var out = []
    if (!root.fleet) return out
    var index = ({})
    for (var i = 0; i < root.fleet.modelFiles.length; i++) {
      var file = root.fleet.modelFiles[i]
      var key = String(file.host)
      if (index[key] === undefined) {
        index[key] = out.length
        out.push({ host: key, files: [] })
      }
      out[index[key]].files.push(file)
    }
    return out
  }

  // The panel lists the first few GPU pods; the rest are a count.
  readonly property var k8sPodRows: {
    if (!root.fleet) return []
    return root.fleet.k8sPods.slice(0, 9)
  }

  function workloadState(workload) {
    if (!workload) return ""
    if (workload.asleep === true) return "asleep"
    if (workload.health === true) return String(workload.state || "ok")
    return workload.state === "unknown" ? "unknown" : "down"
  }

  function llmDetail(workload) {
    if (!workload) return ""
    if (workload.health !== true && workload.error) return String(workload.error)
    var parts = []
    var models = workload.models || []
    if (models.length > 0) {
      var first = models[0]
      var id = String(first.id || "")
      if (id.length > 40) id = id.slice(0, 38) + "…"
      parts.push(id)
      if (first.quant) parts.push(String(first.quant))
      if (first.context) parts.push("ctx " + Math.round(Number(first.context) / 1024) + "k")
      if (first.slots) parts.push("slots " + Number(first.slotsProcessing || 0) + "/" + Number(first.slots))
    }
    var loaded = Number(workload.loadedCount || 0)
    if (loaded > 1) parts.push(loaded + " loaded")
    if (Number(workload.catalogCount || 0) > 0) parts.push("catalog " + Number(workload.catalogCount))
    return parts.join("  ·  ")
  }

  function mediaDetail(workload) {
    if (!workload) return ""
    if (workload.type === "comfyui")
      return (workload.busy ? "busy" : "idle") + "  ·  queue "
        + Number(workload.queueRunning || 0) + "+" + Number(workload.queuePending || 0)
    if (workload.asleep === true) return "asleep (scale 0)"
    return String(workload.state || "")
  }

  function transcodeDetail(workload) {
    if (!workload) return ""
    var active = Number(workload.active || 0)
    return active > 0 ? active + " active" : "none active"
  }

  function k8sNodeText(node) {
    if (!node) return ""
    var parts = []
    if (node.gpuCap > 0) parts.push("nvidia.com/gpu ×" + Number(node.gpuCap))
    if (node.driCap > 0) parts.push("squat.ai/dri ×" + Number(node.driCap))
    return parts.join("  ·  ")
  }

  function k8sPodText(pod) {
    if (!pod) return ""
    var text = String(pod.ns) + "/" + String(pod.name) + "  →  " + String(pod.node)
    var resources = pod.resources || ({})
    var keys = Object.keys(resources)
    if (keys.length > 0)
      text += "  ·  " + keys.map(function(key) { return key + " ×" + resources[key] }).join(", ")
    if (pod.phase !== "Running" && pod.phase !== "") text += "  ·  " + pod.phase
    return text
  }

  readonly property var minerRows: {
    var out = []
    for (var h = 0; h < hostGroups.length; h++) {
      var owned = hostGroups[h].miners
      for (var m = 0; m < owned.length; m++) out.push(owned[m])
    }
    return out
  }

  IpcHandler {
    target: root.pluginId

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { if (root.fleet) root.fleet.refresh(); return "ok" }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        if (dx !== 0) {
          panelFlick.contentY = root.clamp(panelFlick.contentY + dx * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
        }
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if ((text === "r" || text === "R") && root.fleet) root.fleet.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.spacing.md

          PanelHero {
            width: parent.width
            title: "GPU Fleet"
            meta: root.fleet && root.fleet.anyOnline
              ? Format.formatHashrate(root.fleet.totalHashrate) + " · " + Format.formatPower(root.fleet.totalPower)
              : (root.fleet && root.fleet.initialized ? "Idle" : "Loading")
            // The count is of GPUs actually mining, not rows on screen: an
            // offline miner is still listed. Saying "of N" keeps the pill from
            // reading as a miscount against the list below it.
            detail: {
              if (!root.fleet) return ""
              var parts = []
              if (root.fleet.anyOnline) parts.push(root.fleet.gpuCount + " of " + root.fleet.configuredCount + " mining GPUs")
              if (root.fleet.gpuTotal > 0) parts.push(root.fleet.gpuTotal + " total")
              if (root.fleet.modelsLoaded > 0) parts.push(root.fleet.modelsLoaded + " models loaded")
              // A user pause is stated, not implied: rows read "Paused", and
              // the hero counts them, so 0-of-N never reads as a failure.
              if (root.fleet.pausedCount > 0) parts.push(root.fleet.pausedCount + " paused")
              return parts.join("  ·  ")
            }
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: root.minerGlyph
                color: root.alarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              textFormat: Text.PlainText
              }
            }
          }

          // ---- Poller failure -------------------------------------------
          ErrorBanner {
            visible: root.fleet ? root.fleet.lastError !== "" : false
            width: parent.width
            implicitHeight: Style.spacing.xl * 3
            message: root.fleet ? root.fleet.lastError : ""
            urgent: root.urgent
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // ---- A pause or resume that did not take -----------------------
          ErrorBanner {
            visible: root.actionError !== ""
            width: parent.width
            implicitHeight: Style.spacing.xl * 3
            message: root.actionError
            urgent: root.urgent
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // ---- Estimated earnings (pool rate x live PRL price) ----------
          // Hidden until the first successful fetch and when nothing is
          // mining: "$0.00/day" would look like a fact about the fleet.
          Column {
            visible: root.fleet && root.fleet.revenueReady && root.fleet.anyOnline && root.fleet.revenueError === ""
            width: parent.width
            spacing: Style.space(4)

            StatPill {
              width: parent.width
              label: "Est. per hour"
              value: Format.formatFiat(root.fleet.totalDayFiat / 24, root.fleet.revenueCurrency)
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            StatPill {
              width: parent.width
              label: "Est. per day"
              value: Format.formatFiat(root.fleet.totalDayFiat, root.fleet.revenueCurrency)
                + "  ·  " + Format.formatCoins(root.fleet.earningsDayCoins(root.fleet.totalHashrate)) + " PRL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            StatPill {
              width: parent.width
              label: "Est. per month"
              value: Format.formatFiat(root.fleet.totalDayFiat * 30, root.fleet.revenueCurrency)
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: {
                if (!root.fleet || !root.fleet.revenueReady) return ""
                var line = "PRL " + Number(root.fleet.revenuePrice).toFixed(4) + " " + root.fleet.revenueCurrency
                if (root.fleet.xmrRevenueReady)
                  line += "  ·  XMR " + Number(root.fleet.xmrRevenuePrice).toFixed(2)
                return line + "  ·  pool rates  ·  updated " + Format.formatAgo(root.fleet.revenueUpdatedAt)
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            textFormat: Text.PlainText
            }
          }

          Text {
            visible: root.fleet ? root.fleet.revenueError !== "" && root.fleet.anyOnline : false
            width: parent.width
            text: root.fleet ? "Earnings estimate unavailable: " + root.fleet.revenueError : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          }

          // ---- GPU alerts ------------------------------------------------
          // Unreliable sensors are excluded upstream (Model.js gpuIssues) —
          // heat and VRAM pressure only.
          Column {
            id: alertColumn
            visible: root.fleet ? root.fleet.gpuAlertList.length > 0 : false
            width: parent.width
            spacing: Style.space(2)

            SectionLabel {
              width: parent.width
              text: "GPU alerts"
              rightText: root.fleet ? String(root.fleet.gpuAlertList.length) : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.fleet ? root.fleet.gpuAlertList : []

              Text {
                required property var modelData

                width: alertColumn.width
                text: "! " + String(modelData)
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }
          }

          // ---- GPUs ------------------------------------------------------
          // Every card in the fleet, grouped by host: model, utilization,
          // VRAM against capacity, power, temperature, clocks and the
          // workload that owns it. Read-only.
          PanelSeparator {
            visible: root.gpuGroups.length > 0
            foreground: root.foreground
          }

          Column {
            id: gpuSection
            visible: root.gpuGroups.length > 0
            width: parent.width
            spacing: Style.spacing.md

            SectionLabel {
              width: parent.width
              text: "GPUs"
              rightText: root.fleet
                ? root.fleet.gpuTotal + (root.fleet.gpuTotal === 1 ? " GPU" : " GPUs")
                  + "  ·  " + Format.formatMiB(root.fleet.vramUsed) + " / " + Format.formatMiB(root.fleet.vramTotal)
                : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.gpuGroups

              Column {
                id: gpuHostColumn
                required property var modelData

                width: gpuSection.width
                spacing: Style.space(4)

                SectionLabel {
                  width: gpuHostColumn.width
                  text: modelData.host
                  rightText: modelData.gpus.length + (modelData.gpus.length === 1 ? " GPU" : " GPUs")
                    + "  ·  " + Format.formatMiB(modelData.vramUsed) + " / " + Format.formatMiB(modelData.vramTotal)
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: modelData.gpus

                  GpuRow {
                    required property var modelData

                    width: gpuHostColumn.width
                    gpu: modelData
                    foreground: root.foreground
                    urgent: root.urgent
                    fontFamily: root.fontFamily
                    tempWarnC: root.tempWarnC
                    tempAlarmC: root.tempAlarmC
                  }
                }
              }
            }
          }

          // ---- Miners ----------------------------------------------------
          SectionLabel {
            width: parent.width
            visible: root.hostCount > 0
            text: "Miners"
            rightText: root.fleet && root.fleet.anyOnline ? Format.formatHashrate(root.fleet.totalHashrate) : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.fleet && root.fleet.initialized && root.fleet.lastError === "" && root.hostCount === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No miners configured.\nAdd them to fleet.py in this plugin's directory."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          }

          PanelSeparator {
            visible: root.hostCount > 0
            foreground: root.foreground
          }

          // ---- Hosts and their miners ------------------------------------
          Repeater {
            model: root.hostGroups

            Column {
              required property var modelData

              width: column.width
              spacing: Style.spacing.md

              HostRow {
                width: parent.width
                host: modelData.host
                stats: modelData.stats
                foreground: root.foreground
                urgent: root.urgent
                fontFamily: root.fontFamily
                hashrateText: Format.formatHashrate(modelData.stats ? modelData.stats.hashrate : 0)
                earningsText: root.fleet && root.fleet.revenueReady && modelData.stats && modelData.stats.connected
                  ? Format.formatFiat(root.fleet.earningsDayFiat(modelData.stats.hashrate), root.fleet.revenueCurrency) + "/day"
                  : ""
              }

              Repeater {
                model: modelData.miners

                MinerRow {
                  required property var modelData

                  width: column.width
                  miner: modelData
                  foreground: root.foreground
                  urgent: root.urgent
                  fontFamily: root.fontFamily
                  tempWarnC: root.tempWarnC
                  tempAlarmC: root.tempAlarmC
                  busy: root.dataBusy(modelData.unit)
                  earningsText: root.fleet && root.fleet.revenueReady && modelData.online
                    ? Format.formatFiat(root.fleet.earningsDayFiat(modelData.hashrate), root.fleet.revenueCurrency) + "/day"
                    : ""
                  infoLines: root.fleet && modelData.online && Number(modelData.xmrigHashrate || 0) > 0
                    ? [
                        ("XMR " + modelData.xmrigText
                          + "  ·  " + Math.round(Number(modelData.xmrigShares || 0))
                          + "/" + Math.round(Number(modelData.xmrigSharesTotal || 0)) + " shares"
                          + (modelData.xmrigAlgo ? "  ·  " + modelData.xmrigAlgo : "")
                          + (modelData.xmrigRevenueText ? "  ·  " + modelData.xmrigRevenueText : "")),
                        [String(modelData.xmrigPool || ""),
                         String(modelData.xmrigCpu || "")].filter(function(part) { return part !== ""; }).join("  ·  "),
                      ].filter(function(line) { return line !== ""; })
                    : []
                  onToggleRequested: if (root.fleet) root.fleet.toggle(modelData)
                }
              }
            }
          }

          PanelSeparator {
            visible: root.hostCount > 0
            foreground: root.foreground
          }

          // ---- Model servers (LLM endpoints) ------------------------------
          PanelSeparator {
            visible: modelServerSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelServerSection
            visible: root.fleet ? root.fleet.llmWorkloads.length > 0 : false
            width: parent.width
            spacing: Style.spacing.md

            SectionLabel {
              width: parent.width
              text: "Model servers"
              rightText: root.fleet ? root.fleet.modelsLoaded + (root.fleet.modelsLoaded === 1 ? " loaded" : " loaded") : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.fleet ? root.fleet.llmWorkloads : []

              WorkloadRow {
                required property var modelData

                width: modelServerSection.width
                name: String(modelData.name || "")
                hostText: String(modelData.host || "") + "  ·  " + String(modelData.type || "")
                stateText: root.workloadState(modelData)
                stateHealthy: modelData.health === true
                stateDimmed: modelData.asleep === true
                detailText: root.llmDetail(modelData)
                foreground: root.foreground
                urgent: root.urgent
                fontFamily: root.fontFamily
              }
            }
          }

          // ---- Image & audio (ComfyUI, yue2, voice-models) ----------------
          PanelSeparator {
            visible: mediaSection.visible
            foreground: root.foreground
          }

          Column {
            id: mediaSection
            visible: root.fleet ? root.fleet.imageAudioWorkloads.length > 0 : false
            width: parent.width
            spacing: Style.spacing.md

            SectionLabel {
              width: parent.width
              text: "Image & audio"
              rightText: ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.fleet ? root.fleet.imageAudioWorkloads : []

              WorkloadRow {
                required property var modelData

                width: mediaSection.width
                name: String(modelData.name || "")
                hostText: String(modelData.host || "") + "  ·  " + String(modelData.type || "")
                stateText: root.workloadState(modelData)
                stateHealthy: modelData.health === true
                stateDimmed: modelData.asleep === true
                detailText: root.mediaDetail(modelData)
                foreground: root.foreground
                urgent: root.urgent
                fontFamily: root.fontFamily
              }
            }
          }

          // ---- Transcoding (Jellyfin on sentry) ---------------------------
          PanelSeparator {
            visible: transcodeSection.visible
            foreground: root.foreground
          }

          Column {
            id: transcodeSection
            visible: root.fleet ? root.fleet.transcodeWorkloads.length > 0 : false
            width: parent.width
            spacing: Style.spacing.md

            SectionLabel {
              width: parent.width
              text: "Transcoding"
              rightText: ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.fleet ? root.fleet.transcodeWorkloads : []

              WorkloadRow {
                required property var modelData

                width: transcodeSection.width
                name: String(modelData.name || "")
                hostText: String(modelData.host || "") + "  ·  VAAPI"
                stateText: root.workloadState(modelData)
                stateHealthy: modelData.health === true
                stateDimmed: false
                detailText: root.transcodeDetail(modelData)
                foreground: root.foreground
                urgent: root.urgent
                fontFamily: root.fontFamily
              }
            }
          }

          // ---- K8s GPU (node allocation + GPU pods) -----------------------
          PanelSeparator {
            visible: k8sSection.visible
            foreground: root.foreground
          }

          Column {
            id: k8sSection
            visible: root.fleet ? (root.fleet.k8sNodes.length + root.fleet.k8sPods.length) > 0 : false
            width: parent.width
            spacing: Style.space(3)

            SectionLabel {
              width: parent.width
              text: "K8s GPU"
              rightText: root.fleet
                ? root.fleet.k8sNodes.length + " nodes  ·  " + root.fleet.k8sPods.length + " pods"
                : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.fleet ? root.fleet.k8sNodes : []

              Item {
                required property var modelData

                width: k8sSection.width
                implicitHeight: Math.max(nodeName.implicitHeight, nodeValue.implicitHeight)

                Text {
                  id: nodeName
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(modelData.name)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  textFormat: Text.PlainText
                }

                Text {
                  id: nodeValue
                  anchors.right: parent.right
                  anchors.left: nodeName.right
                  anchors.leftMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideLeft
                  text: root.k8sNodeText(modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }
            }

            Repeater {
              model: root.k8sPodRows

              Text {
                required property var modelData

                width: k8sSection.width
                text: root.k8sPodText(modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }

            Text {
              width: parent.width
              visible: root.fleet && root.fleet.k8sPods.length > root.k8sPodRows.length
              text: "+" + (root.fleet ? root.fleet.k8sPods.length - root.k8sPodRows.length : 0) + " more"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }
          }

          // ---- Models on disk ---------------------------------------------
          PanelSeparator {
            visible: modelsSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelsSection
            visible: root.fleet ? root.fleet.modelFiles.length > 0 : false
            width: parent.width
            spacing: Style.spacing.md

            SectionLabel {
              width: parent.width
              text: "Models on disk"
              rightText: root.fleet ? root.fleet.modelsOnDisk + " files" : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.modelGroups

              Column {
                id: modelHostColumn
                required property var modelData

                width: modelsSection.width
                spacing: Style.space(2)

                SectionLabel {
                  width: modelHostColumn.width
                  text: modelData.host
                  rightText: modelData.files.length + (modelData.files.length === 1 ? " file" : " files")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: modelData.files.slice(0, 6)

                  ModelRow {
                    required property var modelData

                    width: modelHostColumn.width
                    name: String(modelData.name || "")
                    sizeText: String(modelData.sizeText || "")
                    loaded: modelData.loaded === true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }
                }

                Text {
                  width: modelHostColumn.width
                  visible: modelData.files.length > 6
                  text: "+" + (modelData.files.length - 6) + " more"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }
            }
          }

          Text {
            width: parent.width
            text: {
              if (!root.fleet) return ""
              if (root.fleet.refreshing) return "Refreshing…"
              if (root.fleet.lastUpdatedAt > 0)
                return "Updated " + Format.formatAgo(root.fleet.lastUpdatedAt) + "   ·   R to refresh"
              return ""
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          textFormat: Text.PlainText
          }
        }
      }
    }
  }
}