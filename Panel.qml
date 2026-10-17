pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "util/format.js" as Format
import "Model.js" as Model
import "components"

// Panel content for the mining fleet: ONE pane, no scrolling.
//
// The fleet runs one miner per GPU, so the old layout — a "GPUs" list and a
// "Miners" list, side by side — was the same seven cards drawn twice, and it
// was taller than any screen: the panel needed a Flickable and a scrollbar to
// be read at all. This version pairs each miner with its card (Model.matchGpu),
// renders one row per GPU, and keeps every secondary section (workloads,
// revenue, k8s, models on disk) to exactly one collapsed line. The natural
// height now fits the screen, so the panel is a fixed-geometry HUD: anomalies
// first, colour only on anomalies, and nothing off-screen.
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

  // Which secondary sections are open. Collapsed they cost one line each; the
  // panel is sized for the collapsed pane, so expanding is a deliberate act.
  property bool workloadsExpanded: false
  property bool revenueExpanded: false
  property bool k8sExpanded: false
  property bool modelsExpanded: false

  // The failure stays up long enough to read, then clears itself: a panel that
  // keeps showing a stale error after the miner recovered is worse than none.
  Timer {
    id: errorTimer
    interval: 12000
    repeat: false
    onTriggered: root.actionError = ""
  }

  // The poll age has to keep counting while nothing changes — a wedged poller
  // is exactly the case where the numbers stop moving, so the age cannot be
  // derived from the poll alone. One 5 s tick while the panel is open, read by
  // every age binding (the same companion-counter idiom Main.qml uses for
  // busyUnits).
  property int clockTick: 0

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.clockTick++
  }

  function now() {
    return root.clockTick >= 0 ? Date.now() : Date.now()
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = -1
    cursorConfirmIndex = -1
    clockTick++   // re-read the poll age the moment the panel opens
  }

  // Delegates reach the data object through root: inside a nested Repeater the
  // bare name resolves against the delegate's own scope. Reading busyRevision
  // keeps the binding live — a function call alone is not watchable.
  function dataBusy(unit) {
    if (!root.fleet) return false
    return root.fleet.busyRevision >= 0 && root.fleet.isBusy(unit)
  }

  function moveCursor(delta) {
    var rows = root.rows
    if (rows.length === 0) return
    cursorActive = true
    cursorConfirmIndex = -1
    cursorIndex = ((cursorIndex + delta) % rows.length + rows.length) % rows.length
  }

  // Keyboard stops follow the same rule as clicks: Enter arms the row's
  // stop, Enter again within 5 s confirms; moving or closing cancels.
  function activateCursor() {
    var rows = root.rows
    if (!cursorActive || cursorIndex < 0 || cursorIndex >= rows.length) return
    var row = rows[cursorIndex]
    if (!row || !row.miner) return
    var willStop = row.miner.managed ? !row.miner.paused : row.miner.online
    if (willStop && root.cursorConfirmIndex !== cursorIndex) {
      root.cursorConfirmIndex = cursorIndex
      cursorConfirmTimer.restart()
      return
    }
    root.cursorConfirmIndex = -1
    if (root.fleet) root.fleet.toggle(row.miner)
  }

  Timer {
    id: cursorConfirmTimer
    interval: 5000
    repeat: false
    onTriggered: root.cursorConfirmIndex = -1
  }

  // ------------------------------------------------------- rows + ordering
  // Every miner paired with the card it drives. Pairing is by host + model and
  // each card is claimed once (forge runs two identical 4060s), so the mapping
  // is stable: the same poll always produces the same pairs.
  readonly property var rows: {
    var out = []
    if (!root.fleet) return out
    var miners = root.fleet.miners || []
    var gpus = root.fleet.gpus || []
    var claimed = ({})
    for (var i = 0; i < miners.length; i++) {
      var miner = miners[i]
      var gpu = Model.matchGpu(miner, gpus, claimed)
      if (gpu) claimed[Model.gpuKey(gpu)] = true
      out.push({ miner: miner, gpu: gpu })
    }
    return root.sortedRows(out)
  }

  // 0 = not mining (paused / inactive / unknown), 1 = mining but breaching a
  // threshold, 2 = nominal. The exception rows go first.
  function rowRank(row) {
    var miner = row ? row.miner : null
    if (!miner) return 2
    if (miner.online !== true || miner.paused === true) return 0
    var facts = Model.rowFacts(miner, row.gpu, root.tempAlarmC)
    return (facts.hot || facts.vramFull || facts.low) ? 1 : 2
  }

  // Sorting is total (rank, then host, then card label), so an unchanged poll
  // renders an unchanged order: rows never swap places under the reader.
  function sortedRows(rows) {
    var decorated = []
    for (var i = 0; i < rows.length; i++) {
      var miner = rows[i].miner
      decorated.push({
        row: rows[i],
        rank: root.rowRank(rows[i]),
        host: miner ? String(miner.host || "") : "",
        label: miner ? String(miner.label || "") : "",
        index: i,
      })
    }
    decorated.sort(function(a, b) {
      if (a.rank !== b.rank) return a.rank - b.rank
      if (a.host !== b.host) return a.host < b.host ? -1 : 1
      if (a.label !== b.label) return a.label < b.label ? -1 : 1
      return a.index - b.index
    })
    var out = []
    for (var d = 0; d < decorated.length; d++) out.push(decorated[d].row)
    return out
  }

  // ------------------------------------------------------------- summary
  readonly property int okCount: root.fleet ? root.fleet.onlineCount : 0
  readonly property int pausedCount: root.fleet ? root.fleet.pausedCount : 0
  // A configured miner that is neither mining nor paused: the only count that
  // is a failure, so the only one that may be negative-clamped against a stale
  // poll.
  readonly property int downCount: root.fleet
    ? Math.max(0, root.fleet.configuredCount - root.fleet.onlineCount - root.fleet.pausedCount)
    : 0

  readonly property string countsText: {
    if (!root.fleet || !root.fleet.initialized) return "—"
    var text = root.okCount + " ok"
    if (root.pausedCount > 0) text += "  ·  " + root.pausedCount + " paused"
    if (root.downCount > 0) text += "  ·  " + root.downCount + " down"
    return text
  }

  readonly property string pollAgeText: {
    root.clockTick
    if (!root.fleet || !root.fleet.initialized) return "—"
    if (root.fleet.refreshing) return "refreshing"
    if (root.fleet.lastUpdatedAt <= 0) return "never"
    return Format.formatAgo(root.fleet.lastUpdatedAt)
  }

  // Three missed polls (or 30 s, whichever is longer) is stale: the numbers on
  // screen are no longer a reading.
  readonly property int staleAfterSec: Math.max(30, 3 * (root.fleet ? root.fleet.refreshIntervalSec : 10))
  readonly property bool pollStale: {
    root.clockTick
    if (!root.fleet || !root.fleet.initialized || root.fleet.lastUpdatedAt <= 0) return false
    return (Date.now() - root.fleet.lastUpdatedAt) / 1000 > root.staleAfterSec
  }

  readonly property string powerText: root.fleet && root.fleet.anyOnline
    ? Format.formatPower(root.fleet.totalPower)
    : (root.fleet && root.fleet.initialized ? "idle" : "")

  readonly property var gpuAlerts: root.fleet ? root.fleet.gpuAlertList : []

  // --------------------------------------------- secondary section summaries
  readonly property var llmList: root.fleet ? root.fleet.llmWorkloads : []
  readonly property var mediaList: root.fleet ? root.fleet.imageAudioWorkloads : []
  readonly property var transcodeList: root.fleet ? root.fleet.transcodeWorkloads : []

  // ---- AI section: the k3s model servers, controlled like the miners ----
  readonly property var aiList: root.fleet ? root.fleet.aiRows : []

  readonly property var aiCounts: {
    var out = { active: 0, paused: 0, inactive: 0, unknown: 0 }
    for (var i = 0; i < root.aiList.length; i++) {
      var state = String(root.aiList[i].state || "unknown")
      if (out[state] === undefined) state = "unknown"
      out[state]++
    }
    return out
  }

  readonly property string aiSummaryText: {
    if (!root.fleet || !root.fleet.initialized) return "—"
    var parts = [root.aiCounts.active + " active"]
    if (root.aiCounts.paused > 0) parts.push(root.aiCounts.paused + " paused")
    if (root.aiCounts.inactive > 0) parts.push(root.aiCounts.inactive + " inactive")
    if (root.aiCounts.unknown > 0) parts.push(root.aiCounts.unknown + " unknown")
    return parts.join("  ·  ")
  }

  function aiBusy(id) {
    if (!root.fleet) return false
    return root.fleet.busyRevision >= 0 && root.fleet.isBusy("ai:" + String(id))
  }

  // The tooltip detail for an AI row: the registry's probe record is a
  // workload record, so the same formatters the Workloads section uses
  // render it — one place for model/queue/state text.
  function aiDetailText(row) {
    var probe = row ? row.probe : null
    if (!probe) return ""
    if (String(probe.kind || "") === "llm") return root.llmDetail(probe)
    return root.mediaDetail(probe)
  }

  function workloadHealthy(workload) {
    return !!workload && (workload.health === true || workload.asleep === true)
  }

  readonly property var workloadSummary: {
    var list = root.llmList.concat(root.mediaList, root.transcodeList)
    var parts = []
    if (root.llmList.length > 0) parts.push(root.llmList.length + " LLM")
    if (root.mediaList.length > 0) parts.push(root.mediaList.length + " media")
    if (root.transcodeList.length > 0) parts.push(root.transcodeList.length + " transcode")
    var down = 0
    for (var i = 0; i < list.length; i++) if (!root.workloadHealthy(list[i])) down++
    return {
      text: parts.length > 0 ? parts.join("  ·  ") : "none",
      state: down > 0 ? down + " down" : "all ready",
      alarming: down > 0,
    }
  }

  readonly property var k8sNodes: root.fleet ? root.fleet.k8sNodes : []
  readonly property var k8sPods: root.fleet ? root.fleet.k8sPods : []
  readonly property var modelFiles: root.fleet ? root.fleet.modelFiles : []

  readonly property bool revenueReady: !!root.fleet && root.fleet.revenueReady && root.fleet.anyOnline
    && root.fleet.revenueError === ""

  // The revenue collapsed line is the whole point of the section: the $/day
  // number. The per-hour / per-month pills live in the expanded state.
  readonly property string revenueText: root.revenueReady
    ? Format.formatFiat(root.fleet.totalDayFiat, root.fleet.revenueCurrency)
      + "/day  ·  " + Format.formatCoins(root.fleet.earningsDayCoins(root.fleet.totalHashrate)) + " PRL"
    : (root.fleet && root.fleet.revenueError !== "" && root.fleet.anyOnline ? "unavailable" : "—")

  readonly property bool revenueError: !!root.fleet && root.fleet.revenueError !== "" && root.fleet.anyOnline

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

  function workloadState(workload) {
    if (!workload) return ""
    if (workload.asleep === true) return "asleep"
    if (workload.health === true) return String(workload.state || "ok")
    return workload.state === "unknown" ? "unknown" : "down"
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

  readonly property var modelGroups: {
    var out = []
    if (!root.fleet) return out
    var index = ({})
    for (var i = 0; i < root.modelFiles.length; i++) {
      var file = root.modelFiles[i]
      var key = String(file.host)
      if (index[key] === undefined) {
        index[key] = out.length
        out.push({ host: key, files: [] })
      }
      out[index[key]].files.push(file)
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
    contentWidth: panel.fittedContentWidth(Style.space(430))
    // Sized to the content, capped by what the screen allows — never by a
    // height that would clip a row: there is no scrolling to recover it.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(1000))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // No scrolling: vertical keys walk the miner rows, and every row is on
      // screen at once, so the cursor is always visible.
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if ((text === "r" || text === "R") && root.fleet) root.fleet.refresh()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.spacing.md

        PanelHero {
          width: parent.width
          title: "GPU Fleet"
          // Power is the reading that is not in the summary strip; the mining
          // count and the hashrate total are, and are not repeated here.
          meta: root.powerText === "" ? "" : root.powerText + " draw"
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

        // ---- Is the fleet fine, and is this reading current -----------
        SummaryStrip {
          width: parent.width
          totalText: root.fleet && root.fleet.initialized
            ? Format.formatHashrate(root.fleet.totalHashrate)
            : "—"
          countsText: root.countsText
          ageText: root.pollAgeText
          countsAlarming: root.downCount > 0
          ageAlarming: root.pollStale
          foreground: root.foreground
          urgent: root.urgent
          fontFamily: root.fontFamily
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

        // ---- Exceptions, above the rows --------------------------------
        // Heat and VRAM pressure across the whole fleet, including the cards
        // no miner drives (the two Navi cards on forge, sentry's). Unreliable
        // sensors are excluded upstream (Model.js gpuIssues). These are the
        // lines that must be read first, so they sit directly under the strip.
        Column {
          id: alertColumn
          visible: root.gpuAlerts.length > 0
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: root.gpuAlerts

            Text {
              required property var modelData

              width: alertColumn.width
              text: "!  " + String(modelData)
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }
          }
        }

        // No miners configured at all (a fresh install).
        Text {
          visible: root.fleet && root.fleet.initialized && root.fleet.lastError === "" && root.rows.length === 0
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

        // ---- One row per GPU: card facts + mining facts ----------------
        Repeater {
          model: root.rows

          MinerRow {
            required property var modelData

            // Not parent.width: a Repeater delegate's parent is null while it
            // is being created, and the rows array is rebuilt on every poll.
            width: column.width
            miner: modelData.miner
            gpu: modelData.gpu
            foreground: root.foreground
            urgent: root.urgent
            fontFamily: root.fontFamily
            tempWarnC: root.tempWarnC
            tempAlarmC: root.tempAlarmC
            busy: root.dataBusy(modelData.miner ? modelData.miner.unit : "")
            earningsText: root.fleet && root.fleet.revenueReady && modelData.miner && modelData.miner.online
              ? Format.formatFiat(root.fleet.earningsDayFiat(modelData.miner.hashrate), root.fleet.revenueCurrency) + "/day"
              : ""
            extraText: root.fleet && modelData.miner && modelData.miner.online
              && Number(modelData.miner.xmrigHashrate || 0) > 0
              ? "XMR " + modelData.miner.xmrigText + "  ·  " + Number(modelData.miner.xmrigShares || 0).toFixed(0)
                + "/" + Number(modelData.miner.xmrigSharesTotal || 0).toFixed(0) + " shares"
              : ""
            onToggleRequested: if (root.fleet && modelData.miner) root.fleet.toggle(modelData.miner)
          }
        }

        // ---- AI models: k3s model servers, controlled like the miners ----
        // One row per AI workload (llama.cpp / ComfyUI / YuE2 deployments in
        // ns mining). The checkbox is the same desired-state control the
        // miner rows carry: checked = the Deployment spec says it should
        // run; a stop arms first and commits on the second click. Rows stay
        // INDEPENDENT of the miner toggles — contention on a card is the
        // user's call. Only variants that share one GPU (switch group) get
        // the switch chip, which starts the picked variant and stops its
        // sibling in one confirmed action.
        PanelSeparator {
          visible: root.aiList.length > 0
          foreground: root.foreground
        }

        SectionLabel {
          visible: root.aiList.length > 0
          width: parent.width
          text: "AI models"
          rightText: root.aiSummaryText
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // The rows sit in their own tighter column (2 px gaps, like the
        // models-on-disk list): eight compact rows at the section gap would
        // push the pane against its height cap.
        Column {
          id: aiColumn
          visible: root.aiList.length > 0
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: root.aiList

            AiRow {
              id: aiRow
              required property var modelData

              // Not parent.width: a Repeater delegate's parent is null while
              // it is being created, and the list is rebuilt on every poll.
              width: aiColumn.width
              workload: modelData
              switchTo: Model.switchOffer(modelData, root.aiList)
              detailText: root.aiDetailText(modelData)
              foreground: root.foreground
              urgent: root.urgent
              fontFamily: root.fontFamily
              busy: root.aiBusy(modelData ? modelData.id : "")
              pendingText: root.fleet ? root.fleet.aiPending(modelData ? modelData.id : "") : ""
              onToggleRequested: if (root.fleet && modelData) root.fleet.aiToggle(modelData)
              onSwitchRequested: if (root.fleet && aiRow.switchTo)
                root.fleet.aiSwitch(modelData, aiRow.switchTo)
            }
          }
        }

        // ---- Workloads (collapsed to one line) -------------------------
        PanelSeparator {
          visible: root.workloadSummary.text !== "none"
          foreground: root.foreground
        }

        CollapseLine {
          visible: root.workloadSummary.text !== "none"
          width: parent.width
          label: "Workloads"
          summaryText: root.workloadSummary.text + "  ·  " + root.workloadSummary.state
          expanded: root.workloadsExpanded
          alarming: root.workloadSummary.alarming
          foreground: root.foreground
          urgent: root.urgent
          fontFamily: root.fontFamily
          onToggled: root.workloadsExpanded = !root.workloadsExpanded
        }

        Column {
          id: workloadSection
          visible: root.workloadsExpanded
          width: parent.width
          spacing: Style.spacing.md

          Repeater {
            model: root.llmList

            WorkloadRow {
              required property var modelData

              width: workloadSection.width
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

          Repeater {
            model: root.mediaList

            WorkloadRow {
              required property var modelData

              width: workloadSection.width
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

          Repeater {
            model: root.transcodeList

            WorkloadRow {
              required property var modelData

              width: workloadSection.width
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

        // ---- Estimated earnings (collapsed to one line) ----------------
        PanelSeparator {
          visible: root.revenueReady || root.revenueError
          foreground: root.foreground
        }

        CollapseLine {
          visible: root.revenueReady || root.revenueError
          width: parent.width
          label: "Earnings"
          summaryText: root.revenueText
          expanded: root.revenueExpanded
          alarming: root.revenueError
          foreground: root.foreground
          urgent: root.urgent
          fontFamily: root.fontFamily
          onToggled: root.revenueExpanded = !root.revenueExpanded
        }

        Column {
          id: revenueSection
          visible: root.revenueExpanded && root.revenueReady
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
          visible: root.revenueError
          width: parent.width
          text: root.fleet ? "Earnings estimate unavailable: " + root.fleet.revenueError : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }

        // ---- K8s GPU (collapsed to one line) ---------------------------
        PanelSeparator {
          visible: (root.k8sNodes.length + root.k8sPods.length) > 0
          foreground: root.foreground
        }

        CollapseLine {
          visible: (root.k8sNodes.length + root.k8sPods.length) > 0
          width: parent.width
          label: "K8s GPU"
          summaryText: root.k8sNodes.length + " nodes  ·  " + root.k8sPods.length + " pods"
          expanded: root.k8sExpanded
          foreground: root.foreground
          urgent: root.urgent
          fontFamily: root.fontFamily
          onToggled: root.k8sExpanded = !root.k8sExpanded
        }

        Column {
          id: k8sSection
          visible: root.k8sExpanded
          width: parent.width
          spacing: Style.space(3)

          Repeater {
            model: root.k8sNodes

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
            model: root.k8sPods

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
        }

        // ---- Models on disk (collapsed to one line) --------------------
        PanelSeparator {
          visible: root.modelFiles.length > 0
          foreground: root.foreground
        }

        CollapseLine {
          visible: root.modelFiles.length > 0
          width: parent.width
          label: "Models on disk"
          summaryText: (root.fleet ? root.fleet.modelsOnDisk : root.modelFiles.length)
            + " files  ·  " + (root.fleet ? root.fleet.modelsLoaded : 0) + " loaded"
          expanded: root.modelsExpanded
          foreground: root.foreground
          urgent: root.urgent
          fontFamily: root.fontFamily
          onToggled: root.modelsExpanded = !root.modelsExpanded
        }

        Column {
          id: modelsSection
          visible: root.modelsExpanded
          width: parent.width
          spacing: Style.spacing.md

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
            root.clockTick
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
