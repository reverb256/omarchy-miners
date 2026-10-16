// Mining-specific logic: thresholds, baselines, health assessment, and the
// miner -> GPU pairing the panel rows are built from.
// Pure JS — import in QML via "import 'Model.js' as Model".

// Health thresholds (from gpu-mining-operations skill).
var thresholds = {
  temp: { warn: 65, alarm: 72 },
  efficiency: { warn: 95, critical: 80 },
  invalidShares: { warn: 1, critical: 5 },
  lastShareMin: { warn: 10, critical: 60 },
  fan: { warn: 50, alarm: 75 }
}

// Expected PRL hashrate per card, in TH/s, at the FLEET power caps — the
// baseline the row meters are drawn against. Source: the
// gpu-mining-operations skill's "Expected TH/s" table (v2.x kernels):
//   RTX 4060     57-62 TH/s @ ~118W      RTX 3060 Ti  ~48-52 TH/s @ 120W
//   RTX 3090     ~95-98 TH/s @ 250W
// The v1.x-era numbers (3060 Ti ~33 TH/s @ 99W) are obsolete — a card sitting
// there is a power-cap/clock fault, not a healthy reading, and the meter must
// show that as an anomaly rather than a full bar.
var baselines = {
  "RTX 4060": { min: 57, max: 62 },
  "RTX 3060 Ti": { min: 48, max: 52 },
  "RTX 3090": { min: 95, max: 98 }
}

// A card under three quarters of its expected peak is the failure the skill
// describes (power-capped clocks, or a second app time-slicing the card).
var lowFraction = 0.75

function assessHealth(record) {
  var issues = []
  if (!record.online) {
    return { status: "offline", issues: ["Unit not running"] }
  }
  var temp = Number(record.temp || 0)
  if (temp >= thresholds.temp.alarm) {
    issues.push("Temp critical: " + temp + "°C")
  } else if (temp >= thresholds.temp.warn) {
    issues.push("Temp warning: " + temp + "°C")
  }
  var eff = Number(record.efficiency || 100)
  if (eff < thresholds.efficiency.critical) {
    issues.push("Efficiency critical: " + eff + "%")
  } else if (eff < thresholds.efficiency.warn) {
    issues.push("Efficiency low: " + eff + "%")
  }
  var inv = Number(record.invalidShares || 0)
  if (inv > thresholds.invalidShares.critical) {
    issues.push("Invalid shares high: " + inv)
  } else if (inv > thresholds.invalidShares.warn) {
    issues.push("Invalid shares: " + inv)
  }
  var fan = Number(record.fan || 0)
  if (fan >= thresholds.fan.alarm) {
    issues.push("Fan high: " + fan + "%")
  } else if (fan >= thresholds.fan.warn) {
    issues.push("Fan elevated: " + fan + "%")
  }
  return {
    status: issues.length === 0 ? "healthy" : "warning",
    issues: issues
  }
}

function baselineCheck(gpuName, hashrate) {
  var baseline = baselines[gpuName]
  if (!baseline) return null
  var hr = Number(hashrate || 0)
  if (hr < baseline.min * 0.5) return "critical"
  if (hr < baseline.min * 0.8) return "warning"
  return "normal"
}

// The baseline band for a card, or null when the model is not in the table.
function baselineFor(name) {
  return baselines[String(name || "")] || null
}

// Hashrate as a fraction of the expected peak (0..1). -1 when there is no
// baseline for the model or no reading, so callers can hide the meter instead
// of drawing an empty one that reads as a stopped miner.
function baselineRatio(name, hashrate) {
  var baseline = baselines[String(name || "")]
  if (!baseline) return -1
  var hr = Number(hashrate || 0)
  if (!isFinite(hr) || hr <= 0) return -1
  return Math.max(0, Math.min(1, hr / (baseline.max * 1e12)))
}

// Below the low band the card is not merely "a bit slow": meter and number
// turn urgent.
function baselineLow(name, hashrate) {
  var ratio = baselineRatio(name, hashrate)
  return ratio >= 0 && ratio < lowFraction
}

function baselineText(name) {
  var baseline = baselines[String(name || "")]
  if (!baseline) return ""
  return baseline.min + "-" + baseline.max + " TH/s expected"
}

// ---------------------------------------------------------------- GPU view
// The GPU fleet alerts: heat and VRAM pressure only. Power is normally
// pinned at the limit on a mining card — alerting on it would mark every
// healthy miner as a problem. Temperature alerts fire at the ALARM
// threshold only: a mining card sits near the warm threshold by design, and
// a warn-tier bar alert on every rig is noise, not signal (the reader still
// sees warn-level temps coloured in the panel rows). A GPU whose temp sensor
// is flagged unreliable (fleet.py gpu_notes; zephyr's 3090 EVGA hybrid) is
// skipped for temp entirely.

function gpuShortName(name) {
  return String(name || "").replace(/^NVIDIA GeForce /, "").replace(/^AMD Radeon /, "")
}

function gpuIssues(gpus, warnC, alarmC) {
  var out = []
  var list = gpus || []
  for (var i = 0; i < list.length; i++) {
    var gpu = list[i]
    var label = String(gpu.host || "?") + " " + gpuShortName(gpu.name)
    var tempReliable = !gpu.reliable || gpu.reliable.temp !== false
    var temp = Number(gpu.temp || 0)
    if (tempReliable && temp > 0 && temp >= alarmC)
      out.push(label + " · " + temp.toFixed(0) + "°C (hot)")
    var total = Number(gpu.vramTotal || 0)
    var used = Number(gpu.vramUsed || 0)
    if (total > 0 && used / total >= 0.97)
      out.push(label + " · VRAM " + Math.round(100 * used / total) + "% full")
  }
  return out
}

// -------------------------------------------------- miner <-> GPU pairing
// One peakminer instance drives one GPU (the fleet definition enforces the
// dedup), so every miner row can carry its card's own readings. Matching is
// by host + model, and each card is claimed exactly once: forge runs two
// identical RTX 4060s, so index-free matching would collapse them onto one
// card and the second miner would lose its GPU facts.

function normalizeName(value) {
  return String(value || "")
    .replace(/^NVIDIA GeForce /, "")
    .replace(/^NVIDIA /, "")
    .replace(/^AMD Radeon /, "")
    .replace(/[^a-zA-Z0-9 ]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase()
}

function gpuKey(gpu) {
  if (!gpu) return ""
  if (gpu.uuid) return String(gpu.uuid)
  return String(gpu.host || "") + ":" + String(gpu.index)
}

// The resolved facts one row shows — and the exception test the panel's
// ordering sorts by, so the row's colouring and the sort can never disagree.
// The card's own sensor is the independent measurement and wins when the
// record carries one and is not flagged unreliable (peakminer builds report
// null power, and zephyr's hybrid 3090 has no trustworthy die sensor); the
// miner's own reading is the fallback, and a missing reading stays missing
// rather than becoming a zero that reads as a stopped miner.
function rowFacts(miner, gpu, alarmC) {
  var online = !!miner && miner.online === true
  var tempReliable = !gpu || !gpu.reliable || gpu.reliable.temp !== false
  var gpuTemp = gpu ? Number(gpu.temp || 0) : 0
  var temp = (gpuTemp > 0 && tempReliable) ? gpuTemp : Number((miner && miner.temp) || 0)
  var gpuPower = gpu ? Number(gpu.power || 0) : 0
  var power = gpuPower > 0 ? gpuPower : Number((miner && miner.power) || 0)
  var vramTotal = gpu ? Number(gpu.vramTotal || 0) : 0
  var shortName = gpu && gpu.shortName ? String(gpu.shortName) : gpuShortName(miner ? miner.label : "")
  var hashrate = Number((miner && miner.hashrate) || 0)
  var alarm = Number(alarmC || 0)
  return {
    online: online,
    tempReliable: tempReliable,
    temp: temp,
    power: power,
    vramTotal: vramTotal,
    vramRatio: vramTotal > 0 ? Number(gpu.vramUsed || 0) / vramTotal : -1,
    shortName: shortName,
    hashrate: hashrate,
    ratio: online ? baselineRatio(shortName, hashrate) : -1,
    low: online && baselineLow(shortName, hashrate),
    hot: online && tempReliable && alarm > 0 && temp >= alarm,
    vramFull: vramTotal > 0 && Number(gpu.vramUsed || 0) / vramTotal >= 0.97
  }
}

// The GPU record a miner drives: exact model match first, then a token
// overlap (the poller labels a stopped miner from the fleet file, the card
// names itself), skipping cards already claimed by an earlier row. Returns
// null when the host reports no such card — the row then renders the miner's
// own numbers and hides the GPU-only facts.
function matchGpu(miner, gpus, claimed) {
  if (!miner) return null
  var list = gpus || []
  var host = String(miner.host || "")
  var want = normalizeName(miner.label)
  var wanted = want.split(" ").filter(function(part) { return part !== "" })
  var fallback = null
  for (var i = 0; i < list.length; i++) {
    var gpu = list[i]
    if (!gpu || String(gpu.host || "") !== host) continue
    var key = gpuKey(gpu)
    if (claimed && claimed[key] === true) continue
    var have = normalizeName(gpu.name)
    if (want !== "" && have === want) return gpu
    var haveTokens = have.split(" ")
    var overlap = 0
    for (var w = 0; w < wanted.length; w++)
      if (haveTokens.indexOf(wanted[w]) >= 0) overlap++
    if (wanted.length > 0 && overlap >= Math.min(2, wanted.length) && fallback === null)
      fallback = gpu
  }
  return fallback
}
