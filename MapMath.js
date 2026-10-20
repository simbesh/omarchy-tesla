// Web Mercator coordinates in pixels at an integer zoom level.
function world(lat, lon, zoom) {
  var size = 256 * Math.pow(2, zoom)
  var sine = Math.sin(Math.max(-85.05112878, Math.min(85.05112878, lat)) * Math.PI / 180)
  return { x: (lon + 180) / 360 * size,
           y: (0.5 - Math.log((1 + sine) / (1 - sine)) / (4 * Math.PI)) * size }
}
function coordinate(x, y, zoom) {
  var size = 256 * Math.pow(2, zoom)
  y = Math.max(0, Math.min(size, y))
  return { lon: ((x / size * 360) % 360 + 360) % 360 - 180,
           lat: Math.atan(Math.sinh(Math.PI * (1 - 2 * y / size))) * 180 / Math.PI }
}
function deltaX(x, center, zoom) {
  var size = 256 * Math.pow(2, zoom)
  return ((x - center + size / 2) % size + size) % size - size / 2
}
function pan(lat, lon, zoom, dx, dy) {
  var p = world(lat, lon, zoom)
  return coordinate(p.x - dx, p.y - dy, zoom)
}
function zoomAt(lat, lon, zoom, nextZoom, dx, dy) {
  var p = world(lat, lon, zoom)
  var scale = Math.pow(2, nextZoom - zoom)
  return coordinate((p.x + dx) * scale - dx, (p.y + dy) * scale - dy, nextZoom)
}
