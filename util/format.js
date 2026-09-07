// Pure number formatting helpers — no QML dependency.
// Importable from any QML file via "import 'util/format.js' as Format".

function scaleNumber(value, units) {
  var rate = Number(value)
  if (!isFinite(rate) || rate <= 0) return "—"
  var tier = 0
  while (rate >= 1000 && tier < units.length - 1) {
    rate /= 1000
    tier++
  }
  return rate.toFixed(rate < 10 ? 2 : (rate < 100 ? 1 : 0)) + " " + units[tier]
}

function formatHashrate(value) {
  return scaleNumber(value, ["H/s", "kH/s", "MH/s", "GH/s", "TH/s", "PH/s", "EH/s"])
}

function formatPower(value) {
  var watts = Number(value)
  if (!isFinite(watts) || watts <= 0) return "—"
  return watts.toFixed(0) + "W"
}

function formatAgo(timestamp) {
  if (!timestamp) return "never"
  var seconds = (Date.now() - timestamp) / 1000
  if (seconds < 15) return "just now"
  if (seconds < 90) return Math.round(seconds) + "s ago"
  if (seconds < 3600) return Math.round(seconds / 60) + "m ago"
  return Math.round(seconds / 3600) + "h ago"
}

function formatTemp(value) {
  var temp = Number(value)
  if (!isFinite(temp) || temp <= 0) return "—"
  return temp.toFixed(0) + "°C"
}

function formatFan(value) {
  var fan = Number(value)
  if (!isFinite(fan) || fan <= 0) return "—"
  return fan.toFixed(0) + "%"
}

function formatPercent(value) {
  var pct = Number(value)
  if (!isFinite(pct)) return "—"
  return pct.toFixed(1) + "%"
}
