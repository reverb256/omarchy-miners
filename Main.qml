pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "util/format.js" as Format
import "Model.js" as Model

// The data side of the miners panel. All polling and shelling out lives here,
// so Panel.qml only binds to finished records — the same split the first-party
// agents plugin uses between Main.qml and Panel.qml.
//
// poll.py owns the fleet definition, including each miner's EXACT systemd unit
// name. Unit names are data per host, never derived from a port: zephyr runs
// Omarchy with hand-managed units, nexus and forge name theirs after their Nix
// instances. This QML never builds a systemctl command itself; miner-control
// resolves and validates every action.
Item {
  id: root
  visible: false

  property var settings: ({})
  property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 10)))

  // Latest poll, normalized by poll.py.
  property var miners: []
  property var hosts: ({})
  property real totalHashrate: 0
  property real totalPower: 0
  property int gpuCount: 0
  property int onlineCount: 0
  property int configuredCount: 0
  property int pausedCount: 0

  // GPU fleet view (read-only; produced by gpu.py, cached ~20 s there).
  property var gpus: []
  property var gpuHosts: ({})
  property var llmWorkloads: []
  property var imageAudioWorkloads: []
  property var transcodeWorkloads: []
  property var k8sNodes: []
  property var k8sPods: []
  property var modelFiles: []
  // AI rows — the k3s model servers the panel can control (poll.py's `ai`
  // section): managed / desired / paused, same contract as the miner rows.
  property var aiRows: []
  property int gpuTotal: 0
  property int modelsLoaded: 0
  property int modelsOnDisk: 0
  property real vramUsed: 0
  property real vramTotal: 0

  readonly property int tempWarnC: Number(setting("tempWarnC", 70))
  readonly property int tempAlarmC: Number(setting("tempAlarmC", 80))
  // The bar's alert list: unreliable sensors are already excluded inside.
  readonly property var gpuAlertList: Model.gpuIssues(gpus, tempWarnC, tempAlarmC)

  property bool initialized: false
  property bool refreshing: false
  property string lastError: ""
  property real lastUpdatedAt: 0

  // Units with an action in flight, so a row can show progress and refuse a
  // second click without a second process. busyUnits is a plain object, which
  // QML cannot watch for internal change, so every mutation bumps this counter
  // and bindings depend on the counter instead.
  property var busyUnits: ({})
  property int busyRevision: 0

  // Human text for the action each busy key is running ("Stopping…"), so a
  // row can say WHAT is happening instead of a bare pending mark.
  property var pendingActions: ({})

  readonly property bool anyOnline: onlineCount > 0
  readonly property string pluginDir:
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  signal actionFailed(string message)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function isBusy(unit) {
    return busyUnits[String(unit)] === true
  }

  function markBusy(unit, busy) {
    var next = ({})
    for (var key in busyUnits) next[key] = busyUnits[key]
    if (busy) next[String(unit)] = true
    else delete next[String(unit)]
    busyUnits = next
    busyRevision++
  }

  function setPending(keys, text) {
    var next = ({})
    for (var key in pendingActions) next[key] = pendingActions[key]
    for (var i = 0; i < keys.length; i++) next[String(keys[i])] = text
    pendingActions = next
    busyRevision++
  }

  function clearPending(keys) {
    var next = ({})
    for (var key in pendingActions) next[key] = pendingActions[key]
    for (var i = 0; i < keys.length; i++) delete next[String(keys[i])]
    pendingActions = next
    busyRevision++
  }

  function aiPending(id) {
    return String(pendingActions["ai:" + String(id)] || "")
  }

  // ------------------------------------------------------------------ poll

  function refresh() {
    if (pollProcess.running) return
    refreshing = true
    pollProcess.command = ["python3", pluginDir + "/poll.py"]
    pollProcess.running = true
    pollWatchdog.restart()
  }

  function applyPoll(text) {
    refreshing = false
    initialized = true

    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      lastError = "The miner poller returned something unreadable"
      return
    }

    if (parsed && parsed.error) {
      lastError = String(parsed.error)
      console.warn("miners: poll failed:", lastError)
      return
    }

    lastError = ""
    // Formatting happens once here rather than in every delegate binding, and
    // it keeps MinerRow free of the number-scaling rules.
    var records = Array.isArray(parsed.miners) ? parsed.miners : []
    for (var i = 0; i < records.length; i++) {
      records[i].hashrateText = Format.formatHashrate(records[i].hashrate)
      records[i].powerText = Format.formatPower(records[i].power)
      records[i].xmrigText = Format.formatHashrate(records[i].xmrigHashrate || 0)
      records[i].xmrigRevenueText = root.xmrRevenueReady && Number(records[i].xmrigHashrate || 0) > 0
        ? Format.formatFiat(root.earningsDayXmrFiat(records[i].xmrigHashrate), root.xmrRevenueCurrency) + "/day"
        : ""
    }
    miners = records
    hosts = parsed.hosts || ({})
    var totals = parsed.totals || ({})
    totalHashrate = Number(totals.hashrate || 0)
    totalPower = Number(totals.power || 0)
    gpuCount = Number(totals.gpus || 0)
    onlineCount = Number(totals.online || 0)
    configuredCount = Number(totals.configured || 0)
    pausedCount = Number(totals.paused || 0)

    // ---- GPU fleet view ------------------------------------------------
    var gpuRecords = Array.isArray(parsed.gpus) ? parsed.gpus : []
    for (var g = 0; g < gpuRecords.length; g++) {
      var gpu = gpuRecords[g]
      gpu.shortName = Model.gpuShortName(gpu.name)
      gpu.utilText = (gpu.util === null || gpu.util === undefined) ? "—" : Math.round(gpu.util) + "%"
      gpu.vramText = (!gpu.vramTotal) ? "—"
        : Format.formatMiB(gpu.vramUsed || 0) + " / " + Format.formatMiB(gpu.vramTotal)
      gpu.vramRatio = gpu.vramTotal > 0 ? Math.min(1, (gpu.vramUsed || 0) / gpu.vramTotal) : -1
      gpu.powerText = Format.formatPower(gpu.power)
      gpu.tempText = Format.formatTemp(gpu.temp)
      gpu.fanText = Format.formatFan(gpu.fan)
      var clocks = []
      if (gpu.clockCore) clocks.push(String(Math.round(gpu.clockCore)))
      if (gpu.clockMem) clocks.push(String(Math.round(gpu.clockMem)))
      gpu.clockText = clocks.length > 0 ? clocks.join("/") + " MHz" : ""
    }
    gpus = gpuRecords
    gpuHosts = parsed.gpuHosts || ({})
    var views = parsed.workloads || ({})
    llmWorkloads = Array.isArray(views.llm) ? views.llm : []
    var media = []
    if (Array.isArray(views.image)) media = media.concat(views.image)
    if (Array.isArray(views.audio)) media = media.concat(views.audio)
    imageAudioWorkloads = media
    transcodeWorkloads = Array.isArray(views.transcode) ? views.transcode : []
    var cluster = parsed.k8s || ({})
    k8sNodes = Array.isArray(cluster.nodes) ? cluster.nodes : []
    k8sPods = Array.isArray(cluster.pods) ? cluster.pods : []
    var files = Array.isArray(parsed.models) ? parsed.models : []
    for (var f = 0; f < files.length; f++)
      files[f].sizeText = Format.formatStorage(files[f].bytes)
    modelFiles = files
    var aiSection = parsed.ai || ({})
    aiRows = Array.isArray(aiSection.rows) ? aiSection.rows : []
    gpuTotal = Number(totals.gpuTotal || 0)
    modelsLoaded = Number(totals.modelsLoaded || 0)
    modelsOnDisk = Number(totals.modelsOnDisk || 0)
    vramUsed = Number(totals.vramUsed || 0)
    vramTotal = Number(totals.vramTotal || 0)
    lastUpdatedAt = Date.now()
  }

  Process {
    id: pollProcess
    running: false

    stdout: StdioCollector { id: pollStdout; waitForEnd: true }
    stderr: StdioCollector { id: pollStderr; waitForEnd: true }

    onExited: function(exitCode) {
      pollWatchdog.stop()
      if (exitCode === 0) {
        root.applyPoll(pollStdout.text)
        return
      }
      root.refreshing = false
      root.initialized = true
      var detail = String(pollStderr.text || "").replace(/\s+/g, " ").trim()
      root.lastError = detail !== "" ? detail : "The miner poller exited with code " + exitCode
    }
  }

  // A poll that never exits would freeze the panel for good: the refresh guard
  // skips every later tick while the process still runs. Kill a wedged poll and
  // let the next tick start a fresh one.
  Timer {
    id: pollWatchdog
    interval: 45000
    repeat: false
    onTriggered: {
      if (pollProcess.running) {
        pollProcess.running = false
        root.refreshing = false
        root.lastError = "The miner poller took too long — retrying"
      }
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---------------------------------------------------------------- revenue
  // Estimated PRL earnings: the pool's coins/day rate for a hashrate x the live
  // PRL price. prl-revenue does the fetching (keyless, from the same public
  // endpoints as the pool's own web calculator); this side scales the rate by
  // the CURRENT hashrate, so displayed numbers stay live between fetches.

  property var revenue: ({})
  property bool revenueInitialized: false
  property string revenueError: ""
  property real revenueUpdatedAt: 0

  readonly property real revenuePrice: Number(revenue.price || 0)
  readonly property real revenueRate: Number(revenue.rateCoinsPerHsDay || 0)
  readonly property string revenueCurrency: String(revenue.currency || "USD").toUpperCase()
  readonly property bool revenueReady: revenuePrice > 0 && revenueRate > 0

  function earningsDayCoins(hashrate) {
    return revenueRate * Number(hashrate || 0)
  }

  function earningsDayFiat(hashrate) {
    return earningsDayCoins(hashrate) * revenuePrice
  }

  function refreshRevenue() {
    if (revenueProcess.running) return
    revenueProcess.command = [
      "python3", pluginDir + "/prl-revenue",
      "--hashrate", String(Math.max(0, Math.round(totalHashrate))),
      "--currency", String(setting("revenueCurrency", "USD")),
    ]
    revenueProcess.running = true
  }

  function applyRevenue(text) {
    revenueInitialized = true
    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      revenueError = "The earnings fetch returned something unreadable"
      return
    }
    if (parsed && parsed.error) {
      revenueError = String(parsed.error)
      console.warn("miners: revenue fetch failed:", revenueError)
      return
    }
    // Keep the last good numbers on a failed refresh rather than blanking.
    revenueError = ""
    revenue = parsed
    revenueUpdatedAt = Date.now()
    // debug, not info: this shell routes qml DEBUG/WARN to the journal but
    // never emits INFO-level qml lines.
    console.debug("miners: revenue estimate loaded — "
      + Format.formatFiat(earningsDayFiat(totalHashrate), revenueCurrency) + "/day at PRL "
      + Number(parsed.price || 0).toFixed(4) + " " + revenueCurrency)
  }

  Process {
    id: revenueProcess
    running: false

    stdout: StdioCollector { id: revenueStdout; waitForEnd: true }
    stderr: StdioCollector { id: revenueStderr; waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyRevenue(revenueStdout.text)
        return
      }
      root.revenueInitialized = true
      var detail = String(revenueStderr.text || "").replace(/\s+/g, " ").trim()
      root.revenueError = detail !== "" ? detail : "The earnings fetch exited with code " + exitCode
      console.warn("miners: revenue fetch failed:", root.revenueError)
    }
  }

  Timer {
    id: revenueTimer
    interval: Math.max(60, Number(setting("revenueIntervalSec", 600))) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshRevenue()
  }

  // ------------------------------------------------------------- xmr revenue
  // The same idea for krash3's CPU miner: xmr-revenue probes Kryptex's XMR
  // coins/day rate + price (keyless; xmrchain chain stats as fallback); this
  // side scales the rate by the live xmrig hashrate so the row tracks the rig.

  property var xmrRevenue: ({})
  property bool xmrRevenueInitialized: false
  property string xmrRevenueError: ""

  readonly property real xmrRevenuePrice: Number(xmrRevenue.price || 0)
  readonly property real xmrRevenueRate: Number(xmrRevenue.rateCoinsPerHsDay || 0)
  readonly property string xmrRevenueCurrency: String(xmrRevenue.currency || "USD").toUpperCase()
  readonly property bool xmrRevenueReady: xmrRevenueRate > 0 && xmrRevenuePrice > 0

  readonly property real totalXmrigHashrate: {
    var sum = 0
    for (var i = 0; i < miners.length; i++) sum += Number(miners[i].xmrigHashrate || 0)
    return sum
  }

  // All-in fleet totals: PRL (the GPU fleet) + XMR (the krash3 CPU miner).
  // Per-row figures stay per-coin; only the fleet totals fold together.
  readonly property real xmrDayFiat: xmrRevenueReady ? earningsDayXmrFiat(totalXmrigHashrate) : 0
  readonly property real totalDayFiat: (revenueReady ? earningsDayFiat(totalHashrate) : 0) + xmrDayFiat

  function earningsDayXmrFiat(hashrate) {
    return xmrRevenueRate * Number(hashrate || 0) * xmrRevenuePrice
  }

  function refreshXmrRevenue() {
    if (xmrRevenueProcess.running) return
    xmrRevenueProcess.command = [
      "python3", pluginDir + "/xmr-revenue",
      "--hashrate", String(Math.max(0, Math.round(totalXmrigHashrate))),
      "--currency", String(setting("revenueCurrency", "USD")),
    ]
    xmrRevenueProcess.running = true
  }

  function applyXmrRevenue(text) {
    xmrRevenueInitialized = true
    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      xmrRevenueError = "The XMR earnings fetch returned something unreadable"
      return
    }
    if (parsed && parsed.error) {
      xmrRevenueError = String(parsed.error)
      console.warn("miners: xmr revenue fetch failed:", xmrRevenueError)
      return
    }
    xmrRevenueError = ""
    xmrRevenue = parsed
    console.debug("miners: xmr revenue loaded — "
      + Format.formatFiat(earningsDayXmrFiat(totalXmrigHashrate), xmrRevenueCurrency) + "/day at XMR "
      + Number(parsed.price || 0).toFixed(2) + " " + xmrRevenueCurrency)
  }

  Process {
    id: xmrRevenueProcess
    running: false

    stdout: StdioCollector { id: xmrRevenueStdout; waitForEnd: true }
    stderr: StdioCollector { id: xmrRevenueStderr; waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyXmrRevenue(xmrRevenueStdout.text)
        return
      }
      root.xmrRevenueInitialized = true
      var detail = String(xmrRevenueStderr.text || "").replace(/\s+/g, " ").trim()
      root.xmrRevenueError = detail !== "" ? detail : "The XMR earnings fetch exited with code " + exitCode
      console.warn("miners: xmr revenue fetch failed:", root.xmrRevenueError)
    }
  }

  Timer {
    id: xmrRevenueTimer
    interval: Math.max(60, Number(setting("revenueIntervalSec", 600))) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshXmrRevenue()
  }

  // ---------------------------------------------------------------- control

  // One Process per action, created from a declared component rather than
  // Qt.createQmlObject on a string, so the QML is compiled and the instance
  // is owned and destroyed properly.
  Component {
    id: actionComponent

    Process {
      id: action
      // Busy keys this action marks in flight (one for a miner action, the
      // pair for a model switch): every key settles when the helper exits.
      property var busyKeys: []
      property string label: ""
      running: false

      stdout: StdioCollector { id: actionStdout; waitForEnd: true }
      stderr: StdioCollector { id: actionStderr; waitForEnd: true }

      onExited: function(exitCode) {
        for (var k = 0; k < action.busyKeys.length; k++)
          root.markBusy(action.busyKeys[k], false)
        root.clearPending(action.busyKeys)

        var message = ""
        try {
          var parsed = JSON.parse(String(actionStdout.text || ""))
          if (parsed && parsed.ok === false) message = String(parsed.error || "")
        } catch (error) {
          if (exitCode !== 0) message = String(actionStderr.text || "").replace(/\s+/g, " ").trim()
        }

        if (exitCode !== 0 && message === "") message = "Exit " + exitCode
        if (message !== "") root.actionFailed(action.label + ": " + message)

        // A stop or start changes what the next poll should say: refresh as
        // soon as the helper exits (the k8s spec is already written), then
        // once more to catch slow pod transitions.
        settleTimer.start()
        settleAgain.restart()
        action.destroy()
      }
    }
  }

  Timer {
    id: settleTimer
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  // The second pass: a pod can take a few seconds to leave or become ready,
  // and the row must not look frozen in between.
  Timer {
    id: settleAgain
    interval: 4000
    repeat: false
    onTriggered: root.refresh()
  }

  function runAction(action, miner) {
    if (!miner || isBusy(miner.unit)) return
    markBusy(miner.unit, true)
    var process = actionComponent.createObject(root, {
      busyKeys: [String(miner.unit)],
      label: String(miner.host) + " " + String(miner.label),
      command: ["python3", pluginDir + "/miner-control", action, String(miner.host), String(miner.unit)]
    })
    if (!process) {
      markBusy(miner.unit, false)
      root.actionFailed("Could not start the miner control helper")
      return
    }
    process.running = true
  }

  function pause(miner) { runAction("stop", miner) }
  function resume(miner) { runAction("start", miner) }
  function toggle(miner) {
    if (!miner) return
    // Monitor-only rows (the Kryptex app rig) have no unit behind them.
    if (miner.controllable === false) return
    // The flip follows DESIRED state — the same signal the checkbox shows —
    // not live state: a managed miner that is down but not paused still reads
    // "on", so flipping it means pause; an unchecked box means resume.
    var shouldRun = miner.managed ? !miner.paused : miner.online
    if (shouldRun) pause(miner)
    else resume(miner)
  }

  // ------------------------------------------------------------- AI control
  // The model servers' privilege boundary, exactly like miner-control is the
  // miners': ai-control takes one action + one workload id and resolves
  // everything else itself. A switch marks BOTH rows busy (it stops the
  // sibling and starts the target), so neither can be flipped mid-flight.

  function runAiAction(action, row, busyRows) {
    if (!row) return
    var targets = busyRows || [row]
    var keys = []
    for (var i = 0; i < targets.length; i++) keys.push("ai:" + String(targets[i].id))
    for (var k = 0; k < keys.length; k++) if (isBusy(keys[k])) return
    for (var m = 0; m < keys.length; m++) markBusy(keys[m], true)
    setPending(keys, ({ stop: "Stopping…", start: "Starting…", restart: "Restarting…",
                        switch: "Switching…" })[action] || String(action))
    var process = actionComponent.createObject(root, {
      busyKeys: keys,
      label: String(row.host) + " " + String(row.id),
      command: ["python3", pluginDir + "/ai-control", action, String(row.id)]
    })
    if (!process) {
      for (var u = 0; u < keys.length; u++) markBusy(keys[u], false)
      root.actionFailed("Could not start the AI control helper")
      return
    }
    process.running = true
  }

  function aiToggle(row) {
    if (!row) return
    if (row.controllable === false || row.state === "unknown") return
    // Same desired-state rule as the miner rows: unchecked = the user wants
    // it running, checked = it should run (flipping = stop).
    var shouldRun = row.managed ? !row.paused : row.state === "active"
    if (shouldRun) runAiAction("stop", row)
    else runAiAction("start", row)
  }

  // Model switch: ONE ai-control invocation starts the picked variant and
  // stops its sibling(s); both rows show pending until the poll settles.
  function aiSwitch(fromRow, toRow) {
    if (!fromRow || !toRow) return
    runAiAction("switch", toRow, [fromRow, toRow])
  }

  // ---------------------------------------------------------------- format
  // Formatting lives in util/format.js — these are thin wrappers so existing
  // bindings in Panel.qml/MinerRow.qml keep working.

  function formatHashrate(value) { return Format.formatHashrate(value) }
  function formatPower(value) { return Format.formatPower(value) }
  function formatAgo(timestamp) { return Format.formatAgo(timestamp) }

  Component.onCompleted: refresh()
}