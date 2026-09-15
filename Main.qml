pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "util/format.js" as Format

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

  // ------------------------------------------------------------------ poll

  function refresh() {
    if (pollProcess.running) return
    refreshing = true
    pollProcess.command = ["python3", pluginDir + "/poll.py"]
    pollProcess.running = true
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
    }
    miners = records
    hosts = parsed.hosts || ({})
    var totals = parsed.totals || ({})
    totalHashrate = Number(totals.hashrate || 0)
    totalPower = Number(totals.power || 0)
    gpuCount = Number(totals.gpus || 0)
    onlineCount = Number(totals.online || 0)
    configuredCount = Number(totals.configured || 0)
    lastUpdatedAt = Date.now()
  }

  Process {
    id: pollProcess
    running: false

    stdout: StdioCollector { id: pollStdout; waitForEnd: true }
    stderr: StdioCollector { id: pollStderr; waitForEnd: true }

    onExited: function(exitCode) {
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

  // ---------------------------------------------------------------- control

  // One Process per action, created from a declared component rather than
  // Qt.createQmlObject on a string, so the QML is compiled and the instance
  // is owned and destroyed properly.
  Component {
    id: actionComponent

    Process {
      id: action
      property string unit: ""
      property string label: ""
      running: false

      stdout: StdioCollector { id: actionStdout; waitForEnd: true }
      stderr: StdioCollector { id: actionStderr; waitForEnd: true }

      onExited: function(exitCode) {
        root.markBusy(action.unit, false)

        var message = ""
        try {
          var parsed = JSON.parse(String(actionStdout.text || ""))
          if (parsed && parsed.ok === false) message = String(parsed.error || "")
        } catch (error) {
          if (exitCode !== 0) message = String(actionStderr.text || "").replace(/\s+/g, " ").trim()
        }

        if (exitCode !== 0 && message === "") message = "Exit " + exitCode
        if (message !== "") root.actionFailed(action.label + ": " + message)

        // A stop or start changes what the next poll should say, and the miner
        // needs a moment to settle before it reports it.
        settleTimer.start()
        action.destroy()
      }
    }
  }

  Timer {
    id: settleTimer
    interval: 1200
    repeat: false
    onTriggered: root.refresh()
  }

  function runAction(action, miner) {
    if (!miner || isBusy(miner.unit)) return
    markBusy(miner.unit, true)
    var process = actionComponent.createObject(root, {
      unit: String(miner.unit),
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
    if (miner.online) pause(miner)
    else resume(miner)
  }

  // ---------------------------------------------------------------- format
  // Formatting lives in util/format.js — these are thin wrappers so existing
  // bindings in Panel.qml/HostRow.qml/MinerRow.qml keep working.

  function formatHashrate(value) { return Format.formatHashrate(value) }
  function formatPower(value) { return Format.formatPower(value) }
  function formatAgo(timestamp) { return Format.formatAgo(timestamp) }

  Component.onCompleted: refresh()
}