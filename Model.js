// Mining-specific logic: thresholds, baselines, health assessment.
// Pure JS — import in QML via "import 'Model.js' as Model".

// Health thresholds (from gpu-mining-operations skill).
var thresholds = {
  temp: { warn: 65, alarm: 72 },
  efficiency: { warn: 95, critical: 80 },
  invalidShares: { warn: 1, critical: 5 },
  lastShareMin: { warn: 10, critical: 60 },
  fan: { warn: 50, alarm: 75 }
}

// Expected hashrate baselines per GPU (TH/s).
var baselines = {
  "RTX 4060": { min: 57, max: 61 },
  "RTX 3060 Ti": { min: 33, max: 34 },
  "RTX 3090": { min: 85, max: 86 }
}

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

function statusColor(status) {
  if (status === "healthy") return "#4caf50"
  if (status === "warning") return "#ff9800"
  return "#f44336"
}

function baselineCheck(gpuName, hashrate) {
  var baseline = baselines[gpuName]
  if (!baseline) return null
  var hr = Number(hashrate || 0)
  if (hr < baseline.min * 0.5) return "critical"
  if (hr < baseline.min * 0.8) return "warning"
  return "normal"
}
