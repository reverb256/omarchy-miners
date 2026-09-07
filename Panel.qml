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
    cursorIndex = ((cursorIndex + delta) % rows.length + rows.length) % rows.length
  }

  function activateCursor() {
    var rows = root.minerRows
    if (!cursorActive || cursorIndex < 0 || cursorIndex >= rows.length) return
    if (root.fleet) root.fleet.toggle(rows[cursorIndex])
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
            title: "Mining Fleet"
            meta: root.fleet && root.fleet.anyOnline
              ? Format.formatHashrate(root.fleet.totalHashrate) + " · " + Format.formatPower(root.fleet.totalPower)
              : (root.fleet && root.fleet.initialized ? "Idle" : "Loading")
            // The count is of GPUs actually mining, not rows on screen: an
            // offline miner is still listed. Saying "of N" keeps the pill from
            // reading as a miscount against the list below it.
            detail: root.fleet && root.fleet.anyOnline
              ? root.fleet.gpuCount + " of " + root.fleet.configuredCount + " GPUs"
              : ""
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
                  onToggleRequested: if (root.fleet) root.fleet.toggle(modelData)
                }
              }
            }
          }

          PanelSeparator {
            visible: root.hostCount > 0
            foreground: root.foreground
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