pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "util/format.js" as Format

// Bar widget for the mining fleet — entry point and data owner.
//
// The Main instance lives HERE, not in the panel: the bar widget is mounted
// for the whole session while the panel is created and destroyed. Polling has
// to outlive the panel, and the bar text needs data before the panel ever
// opens. Panel.qml reads it back through `hostWidget.fleet`.
//
// `data` is NOT usable as a property name — every QML Item already has a
// read-only `data` (its default children list), and assigning it silently
// fails, leaving every binding undefined.
BarWidget {
  id: root
  moduleName: "io.github.jkro.miners"

  readonly property string pluginId: "io.github.jkro.miners"

  // The single source of fleet data, owned by the bar widget.
  readonly property alias fleet: fleetData

  Main {
    id: fleetData
    settings: root.settings
    onActionFailed: function(message) {
      if (panelLoader.item && panelLoader.item.reportActionError)
        panelLoader.item.reportActionError(message)
    }
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() { fleetData.refresh() }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string barDisplay: String(setting("barDisplay", "Hashrate"))
  readonly property bool iconOnly: barDisplay === "Icon only"
  readonly property bool showPower: barDisplay === "Hashrate and power"
  readonly property int tempAlarmC: Number(setting("tempAlarmC", 80))

  // nf-md-pickaxe. JetBrainsMono Nerd Font has no U+26CF, so the Unicode
  // pickaxe fell through to a fallback font and sat off-baseline.
  readonly property string minerGlyph: "\u{F08B7}"

  // Heat is the one thing worth pulling the eye to the bar for.
  readonly property bool alarming: {
    var miners = fleetData.miners
    for (var i = 0; i < miners.length; i++) {
      if (miners[i].online && Number(miners[i].temp || 0) >= root.tempAlarmC) return true
    }
    return false
  }

  readonly property string barText: {
    if (iconOnly) return ""
    if (!fleetData.initialized) return ""
    if (!fleetData.anyOnline) return ""
    var text = Format.formatHashrate(fleetData.totalHashrate)
    if (showPower) text += "  " + Format.formatPower(fleetData.totalPower)
    return text
  }

  readonly property string tooltipSummary: {
    if (fleetData.lastError !== "") return "Miners: " + fleetData.lastError
    if (!fleetData.initialized) return "Miners: loading…"
    if (!fleetData.anyOnline) return "Miners: nothing running (" + fleetData.configuredCount + " configured)"
    var lines = ["Fleet  " + Format.formatHashrate(fleetData.totalHashrate)
      + "  ·  " + Format.formatPower(fleetData.totalPower)
      + "  ·  " + fleetData.gpuCount + " GPU" + (fleetData.gpuCount === 1 ? "" : "s")]
    for (var i = 0; i < fleetData.miners.length; i++) {
      var miner = fleetData.miners[i]
      if (!miner.online) continue
      lines.push(miner.host + " " + miner.label + "   " + miner.hashrateText
        + "  " + miner.powerText + "  " + Number(miner.temp || 0).toFixed(0) + "°C")
    }
    return lines.join("\n")
  }

  implicitWidth: iconButton.visible ? iconButton.implicitWidth : textButton.implicitWidth
  implicitHeight: iconButton.visible ? iconButton.implicitHeight : textButton.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Panel content, loaded from source (not sourceComponent) so the loader
  // resolves it the same way the first-party widgets do.
  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // One button that switches presentation: the icon-only form uses
  // BarIconButton's square slot, the labelled form uses WidgetButton.
  Item {
    id: button
    anchors.fill: parent

    BarIconButton {
      id: iconButton
      anchors.fill: parent
      visible: root.iconOnly || root.barText === ""
      bar: root.bar
      text: root.minerGlyph
      active: root.alarming || fleetData.lastError !== ""
      activeColor: root.urgent
      // Nothing running is worth saying quietly rather than loudly.
      dimmed: fleetData.initialized && !fleetData.anyOnline && fleetData.lastError === ""
      tooltipText: root.tooltipSummary
      slotSize: Style.bar.statusSlot

      onPressed: function(buttonCode) {
        if (buttonCode === Qt.MiddleButton) root.refresh()
        else root.togglePanel()
      }
    }

    WidgetButton {
      id: textButton
      anchors.fill: parent
      visible: !iconButton.visible
      bar: root.bar
      text: root.minerGlyph + "  " + root.barText
      active: root.alarming
      activeColor: root.urgent
      tooltipText: root.tooltipSummary

      onPressed: function(buttonCode) {
        if (buttonCode === Qt.MiddleButton) root.refresh()
        else root.togglePanel()
      }
    }
  }

  readonly property real iconWidth: iconButton.implicitWidth
  readonly property real textWidth: textButton.implicitWidth
}