// Match only the requested home destinations, allowing common address spellings.
function isHome(destination) {
  var text = String(destination || "").toLowerCase()
    .replace(/[^a-z0-9]+/g, " ").trim()
    .replace(/stone bridge/g, "stonebridge")
  if (text === "home") return true
  return /^(?:1|one) stonebridge (?:place|pl)(?:$| (?:aspley|astley)(?: |$))/.test(text)
}

function homeEta(reading, nowSeconds) {
  if (!reading || !reading.connected || !reading.driving || !isHome(reading.destination)) return ""
  if (typeof reading.eta !== "number" || !isFinite(reading.eta) || reading.eta < nowSeconds) return ""
  return Math.ceil((reading.eta - nowSeconds) / 60) + "m"
}
