import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "MapMath.js" as MapMath
import "BarDisplay.js" as BarDisplay

// Vehicle readings arrive over a persistent, read-only TeslaMate subscription.
Panel {
  id: root

  moduleName: "simbesh.teslamate"
  ipcTarget: "simbesh.teslamate"

  // The script that does the talking sits next to this file, so the plugin
  // runs from wherever it was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/tesla").toString().replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  // The bar exposes a foreground and a font, not an accent; the accent is a
  // theme-level colour, so it is read straight off Color.
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Omarchy's palette has a foreground, an accent, an urgent and a muted, and
  // no green. This is the one place a literal colour is right: a live
  // indicator is green everywhere, in every theme, and one that drifted to
  // whatever the accent happened to be would stop reading as "it is up" and
  // start reading as decoration. It marks the panel's status dot and the bar
  // mark while the car is moving, and nothing else.
  readonly property color liveGreen: "#4caf50"

  // And red while it is charging, for the same reason the live mark is a
  // literal green: "it is filling up" should read the same in every theme
  // rather than turning into whatever the accent is today. Material's red 500
  // to the green's 500, so the two sit at the same weight. The error state
  // keeps Commons.Color.urgent — a fault and a charge are both red, and the word
  // beside the dot is what tells them apart, the same way it already
  // distinguishes driving from parked.
  readonly property color chargeRed: "#f44336"

  // What the panel accents itself with: the charge colour while it is
  // charging, the theme's accent the rest of the time.
  readonly property color liveAccent: charging ? chargeRed : accent

  // ----------------------------------------------------------------- settings

  readonly property string mqttHost: setting("mqttHost", "10.1.1.10")
  readonly property int mqttPort: setting("mqttPort", 1883)
  readonly property string mqttTopic: setting("mqttTopic", "teslamate/cars/1")
  readonly property string tyreUnit: setting("tyreUnit", "psi")
  readonly property int panelWidth: setting("panelWidth", 380)
  readonly property int mapZoom: setting("mapZoom", 16)
  readonly property string mapStyle: setting("mapStyle", "Auto")
  readonly property bool showAddress: setting("showAddress", true)
  readonly property bool notifyOnDrive: setting("notifyOnDrive", true)
  readonly property string mapsUrl: setting("mapsUrl",
    "https://www.google.com/maps/search/?api=1&query={lat},{lon}")

  // Whether the theme in force is a light one, judged off the panel
  // background's luminance rather than off a theme name: a theme can be
  // called anything, but a background either reflects light or it does not.
  // The coefficients are the usual perceptual weights: green carries most of
  // what the eye reads as brightness.
  readonly property bool lightTheme: {
    var bg = Commons.Color.background
    return (0.2126 * bg.r + 0.7152 * bg.g + 0.0722 * bg.b) > 0.5
  }

  // OpenStreetMap's own tiles, because they are the ones that stay free
  // without an account. CARTO's matched light and dark pair used to be the
  // default and read better behind a marker, but CARTO now enforces an API
  // key on its basemaps and a keyless request comes back stamped "API KEY
  // NEEDED" across the map. A default that needs a signup is not a default.
  //
  // OSM ships one style and it is a pale one, so a dark theme gets it inverted
  // rather than swapped: a light map in a dark panel is a torch in the face.
  // Auto follows the theme; the explicit choices are for anyone who wants the
  // map to disagree on purpose.
  readonly property string effectiveMapStyle:
    mapStyle === "Auto" ? (lightTheme ? "Light" : "Dark") : mapStyle

  readonly property string tileUrl: "https://tile.openstreetmap.org/{z}/{x}/{y}.png"

  readonly property bool darkMap: effectiveMapStyle === "Dark"

  // Whether what is about to be drawn is a pale map. Anything painted on top
  // of it, the attribution and the ring around the marker, has to contrast with
  // the tiles rather than with the panel, and those two can disagree: a dark
  // theme with the map forced to Light is exactly where white-on-white went
  // missing.
  readonly property bool lightMap: effectiveMapStyle !== "Dark"

  // Qt decides for itself whether a string is markup, and a Text or tooltip in
  // that mode fetches `<img src="http://...">` for real, from inside the shell
  // process. The address comes from Nominatim and the error text from Tesla, so
  // neither is ours to vouch for. The panel's own Text elements are pinned to
  // PlainText; the bar tooltip belongs to the shell and is not ours to set, so
  // anything heading that way has its angle brackets taken off first — without
  // a `<` there is nothing for Qt to mistake for a tag.
  function plain(s) {
    return String(s === undefined || s === null ? "" : s).replace(/[<>]/g, "")
  }

  function cmd(args) {
    return [root.script, "--tile-url", root.tileUrl].concat(args)
  }

  // -------------------------------------------------------------------- state

  // TeslaMate vehicle state, independent of the MQTT connection state.
  property string carState: ""
  // Display name when published by TeslaMate; otherwise use the model.
  property string selectedCarName: "Tesla"
  // Latest assembled MQTT fields. Null until vehicle data arrives.
  property var reading: null
  // The tile plan for the position in `reading`.
  property var mapPlan: null
  // Parked line comes pre-joined from `tesla place` (number-first or
  // number-last by the country of the pin). Street and town are kept so a
  // moving car can drop the house number without another lookup.
  property string placeStreet: ""
  property string placeTown: ""
  property string placeParked: ""

  readonly property bool usEnglish: {
    var name = String(Qt.locale().name).replace(/-/g, "_").replace(/\.[^.]+$/, "")
    return name.indexOf("en_US") === 0 || name.indexOf("en_CA") === 0
  }

  // At speed the nearest address changes every second, so the number is
  // dropped and only the road is named. Parked, the script's `place` is the
  // whole line.
  readonly property string place: {
    if (driving)
      return [placeStreet, placeTown].filter(function(part) { return part !== "" }).join(", ")
    return placeParked
  }
  property string errorText: ""
  // The sentence behind the error, when the script has one. Kept apart so the
  // status word in the header can stay two words long while the line at the
  // bottom explains itself.
  property string errorHint: ""

  readonly property bool hasReading: reading !== null && reading.ok === true
  readonly property bool driving: hasReading && reading.driving === true
  readonly property bool charging: hasReading && reading.charging === "Charging"
  readonly property bool asleep: carState === "asleep" || carState === "offline"

  readonly property real lat: hasReading && reading.lat !== null ? reading.lat : 0
  readonly property real lon: hasReading && reading.lon !== null ? reading.lon : 0
  readonly property bool hasPosition: hasReading && reading.lat !== null && reading.lon !== null

  // Ticks so the "seen 4 minutes ago" line ages on screen instead of freezing
  // at whatever it said when the panel opened.
  property double now: Date.now()

  Timer {
    interval: 15000
    running: root.opened || root.driving
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  // One child process owns the subscription and reconnects with backoff.
  property bool initialized: false
  property bool testMode: false
  Process {
    id: mqttProc
    command: root.cmd(["stream", "--host", root.mqttHost,
                      "--port", String(root.mqttPort), "--topic", root.mqttTopic,
                      "--pressure", root.tyreUnit])
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        if (root.testMode) return
        try {
          var data = JSON.parse(line)
          root.errorText = data.error || ""
          root.errorHint = data.hint || ""
          root.carState = data.state || "unknown"
          root.now = Date.now()
          if (data.ok === true) {
            root.selectedCarName = data.name || "Tesla"
            root.reading = data
          } else {
            root.reading = null
          }
        } catch (e) {
          root.errorText = "Invalid MQTT reading"
        }
      }
    }
    onExited: {
      root.errorText = "MQTT reader stopped"
      root.carState = "unknown"
      root.reading = null
      reconnectTimer.restart()
    }
  }

  Timer {
    id: reconnectTimer
    interval: 5000
    onTriggered: mqttProc.running = true
  }

  function reconnect() {
    if (!root.initialized) return
    root.testMode = false
    root.reading = null
    root.errorText = "Connecting to MQTT"
    if (mqttProc.running) mqttProc.running = false
    else mqttProc.running = true
  }

  onMqttHostChanged: reconnect()
  onMqttPortChanged: reconnect()
  onMqttTopicChanged: reconnect()
  onTyreUnitChanged: reconnect()

  // ------------------------------------------------------------------ the map

  property bool followCar: true
  property real viewLat: 0
  property real viewLon: 0
  property int viewZoom: mapZoom
  readonly property real centerLat: followCar ? lat : viewLat
  readonly property real centerLon: followCar ? lon : viewLon
  property real requestLat: 0
  property real requestLon: 0
  property bool mapPending: false

  Process {
    id: mapProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok === true) {
            data.centerLat = root.requestLat
            data.centerLon = root.requestLon
            root.mapPlan = data
          }
        } catch (e) {}
      }
    }
    onExited: if (root.mapPending) mapDebounce.restart()
  }

  Timer {
    id: mapDebounce
    interval: 250
    onTriggered: {
      if (!root.opened || !root.hasPosition) return
      if (mapProc.running) { root.mapPending = true; return }
      var w = Math.round(mapArea.width)
      var h = Math.round(mapArea.height)
      if (w <= 0 || h <= 0) return
      root.mapPending = false
      root.requestLat = root.centerLat
      root.requestLon = root.centerLon
      mapProc.command = root.cmd(["map", String(root.requestLat), String(root.requestLon),
                                  String(root.viewZoom), String(w), String(h)])
      mapProc.running = true
    }
  }

  function planMap() {
    if (root.opened && root.hasPosition) mapDebounce.restart()
  }

  function recenterMap() {
    root.followCar = true
    planMap()
  }

  function zoomMap(step, x, y) {
    var next = Math.max(3, Math.min(19, viewZoom + step))
    if (next === viewZoom) return
    var point = MapMath.zoomAt(centerLat, centerLon, viewZoom, next,
                              x - mapArea.width / 2, y - mapArea.height / 2)
    viewLat = point.lat
    viewLon = point.lon
    followCar = false
    viewZoom = next
    planMap()
  }

  onMapZoomChanged: { viewZoom = mapZoom; planMap() }

  onOpenedChanged: {
    planMap()
    if (opened) placeDebounce.restart()
  }

  // The position moving is a reason to redraw the map and to look the new
  // spot up by name. Both are debounced, so a drive is not a thousand
  // requests.
  onLatChanged: { if (followCar) planMap(); if (!placeDebounce.running) placeDebounce.start() }
  onLonChanged: { if (followCar) planMap(); if (!placeDebounce.running) placeDebounce.start() }

  Process {
    id: placeProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          var ok = data.ok === true
          root.placeStreet = ok ? (data.street || "") : ""
          root.placeTown = ok ? (data.town || "") : ""
          root.placeParked = ok ? (data.place || "") : ""
        } catch (e) {
          root.placeStreet = ""
          root.placeTown = ""
          root.placeParked = ""
        }
      }
    }
  }

  Timer {
    id: placeDebounce
    interval: 1500
    onTriggered: {
      if (!root.opened || !root.showAddress || !root.hasPosition || placeProc.running) return
      placeProc.command = root.cmd(["place", String(root.lat), String(root.lon)])
      placeProc.running = true
    }
  }

  onHasPositionChanged: if (hasPosition) placeDebounce.restart()

  // ------------------------------------------------------------------ actions

  Process { id: browserProc }

  // ------------------------------------------------------------ pulling away

  // The same moment the mark turns green, said out loud once. Only a departure
  // this widget watched happen counts: a reading that said parked followed by
  // one that says driving. A car already moving when the bar starts, or a
  // switch to a car that is on the road, is not news, and neither is the
  // stream of driving readings that follow the first one.
  //
  // Where it is going rides along when the car already knows: a route set
  // before pulling away is in the first driving reading. A route set at the
  // first red light is not, so that one gets a second line of its own when it
  // turns up, and then nothing more for the rest of the drive.
  property bool lastKnown: false
  property bool lastDriving: false
  property bool etaAnnounced: false

  // Read off the reading itself rather than off `driving` and `etaText`:
  // this handler and those bindings both hang off the same change signal,
  // and nothing promises the bindings have caught up by the time this runs.
  onReadingChanged: {
    var r = reading
    var known = lastKnown
    var was = lastDriving
    var have = r !== null && r.ok === true
    var moving = have && r.driving === true
    var routed = moving && !!r.destination && !!r.eta
    lastKnown = have
    lastDriving = moving
    if (!moving) { etaAnnounced = false; return }
    if (known && !was) {
      etaAnnounced = routed
      if (notifyOnDrive) announceDriving(r, routed)
    } else if (known && was && routed && !etaAnnounced) {
      etaAnnounced = true
      if (notifyOnDrive) announce(carName + " is heading for " + r.destination, etaLine(r))
    }
  }

  Process { id: notifyProc }

  function announceDriving(r, routed) {
    var line = r.speed === null ? "Driving" : "Driving " + r.speed + " " + r.speed_unit
    if (routed) line += " · " + etaLine(r)
    announce(carName + " is on the move", line)
  }

  function announce(title, body) {
    if (notifyProc.running) return
    notifyProc.command = root.cmd(["notify", title, body])
    notifyProc.running = true
  }

  function openInMaps() {
    if (!hasPosition) return
    var url = mapsUrl.replace(/\{lat\}/g, String(lat)).replace(/\{lon\}/g, String(lon))
    browserProc.command = ["xdg-open", url]
    browserProc.running = true
    root.close()
  }

  // ------------------------------------------------------------------ wording

  // There is no compass anywhere in words. Which way the car is pointing is
  // worth a glance and not a sentence, so the marker on the map carries it and
  // nothing repeats it underneath.

  function agoOf(seconds) {
    var s = Math.max(0, Math.round(seconds))
    if (s < 45) return "just now"
    if (s < 90) return "a minute ago"
    if (s < 3600) return Math.round(s / 60) + " minutes ago"
    if (s < 7200) return "an hour ago"
    if (s < 86400) return Math.round(s / 3600) + " hours ago"
    if (s < 172800) return "yesterday"
    return Math.round(s / 86400) + " days ago"
  }

  readonly property real readingAge: hasReading && reading.at !== null ? Math.max(0, now / 1000 - reading.at) : 0
  // Dim retained-only, disconnected or quiet readings on the map.
  readonly property bool stale: hasReading && (reading.at === null || !reading.connected || readingAge > 300)

  // Use TeslaMate's display name when available, otherwise the model and trim.
  readonly property string carName: {
    if (selectedCarName !== "" && selectedCarName !== "Tesla") return selectedCarName
    if (!hasReading) return selectedCarName || "Tesla"
    if (reading.name && reading.name !== "Tesla") return reading.name
    var type = String(reading.car_type || "")
    var model = type.indexOf("models") === 0 ? "Model S"
              : type.indexOf("modelx") === 0 ? "Model X"
              : type.indexOf("model3") === 0 ? "Model 3"
              : type.indexOf("modely") === 0 ? "Model Y"
              : "Tesla"
    return reading.trim ? model + " " + String(reading.trim).toUpperCase() : model
  }

  readonly property string stateWord: {
    if (errorText !== "") return errorText
    if (driving) return "driving"
    if (charging) return "charging"
    if (carState === "") return "checking"
    return carState
  }

  // The one-line answer to the question in the plugin's name.
  readonly property string summary: {
    if (!hasReading) return errorText !== "" ? errorText : "No reading yet"
    var doing = !reading.connected ? "Disconnected" : carState === "unknown" ? "Unknown vehicle state" : driving
      ? (reading.speed === null ? "Driving" : "Driving " + reading.speed + " " + reading.speed_unit)
      : charging
        ? (reading.charger_power ? "Charging at " + Math.round(reading.charger_power) + " kW" : "Charging")
        : "Parked"
    var gear = String(reading.shift || "").toUpperCase()
    var gearText = ["P", "R", "N", "D"].indexOf(gear) >= 0 ? gear : "—"
    // This dates the latest live message, not every individual MQTT field.
    return doing + " · Gear " + gearText
      + (reading.at === null ? " · retained data, age unknown" : " · MQTT update " + agoOf(readingAge))
  }

  // Doors, boot and windows, as one sentence, and only when there is one to
  // make. Nearly always empty, which is exactly what earns it a place: a line
  // that is usually absent gets read on the day it appears.
  readonly property string openText: {
    if (!hasReading || !reading.open || reading.open.length === 0) return ""
    var items = reading.open.map(function(item) {
      return (root.usEnglish && item === "the boot") ? "the trunk" : item
    })
    var list = items.length === 1
      ? items[0]
      : items.slice(0, -1).join(", ") + " and " + items[items.length - 1]
    return list.charAt(0).toUpperCase() + list.slice(1)
      + (items.length === 1 ? " is open" : " are open")
  }

  // A destination can be known before a live route duration arrives.
  readonly property bool navigating:
    hasReading && !!reading.destination

  // The locale's own short time, with the seconds taken out of the pattern
  // rather than out of the string: some locales put them in ShortFormat and
  // some do not, and an arrival is not a number you read to the second. Taking
  // them from the pattern leaves everything else the locale asked for, the
  // twelve-hour clock and its AM included.
  readonly property string clockFormat:
    Qt.locale().timeFormat(Locale.ShortFormat).replace(/[.:]?\bs+\b/g, "")

  // "Home at 19:48 · 2.6 km". The clock time rather than "in six
  // minutes", because arriving is something you meet the car at, and a time is
  // what you compare against the one on your own wrist.
  readonly property string etaText: navigating ? etaLine(reading) : (hasReading ? "No active navigation route" : "")

  function etaLine(r) {
    var parts = [r.destination + (r.eta ? " · ETA " + Qt.formatTime(new Date(r.eta * 1000), clockFormat) : " · ETA awaiting live route")]
    if (r.eta_distance !== null && r.eta_distance !== undefined)
      parts.push(r.eta_distance + " " + r.range_unit)
    if (r.eta_delay) parts.push(r.eta_delay + " min of traffic")
    return parts.join(" · ")
  }

  readonly property string barSpeed:
    driving && reading.speed !== null ? reading.speed + " " + reading.speed_unit : ""

  // --------------------------------------------------------------------- bar

  // Pick the value in the widget settings; keep the unit visible in the bar.
  readonly property string barDisplay: setting("barDisplay", "Charge percentage")
  readonly property string barValue: {
    if (!hasReading || barDisplay === "Icon only") return ""
    var value = barDisplay === "Range" ? reading.range : reading.battery
    if (value === null || value === undefined) return ""
    var label = String(Math.round(value)) + (barDisplay === "Range" ? "km" : "%")
    return label
  }

  readonly property string barEta: barValue !== "" ? BarDisplay.homeEta(reading, now / 1000) : ""

  Process { id: displaySettingProc }
  function selectBarDisplay(mode) {
    if (displaySettingProc.running) return
    displaySettingProc.command = ["omarchy-shell", "shell", "setBarWidget",
                                  root.moduleName, "barDisplay", JSON.stringify(mode), "{}"]
    displaySettingProc.running = true
  }

  Component.onCompleted: root.initialized = true

  implicitWidth: barRow.implicitWidth
  implicitHeight: button.implicitHeight

  Row {
    id: barRow
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    spacing: 0

  BarIconButton {
    id: button
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar

    iconComponent: Component {
      TeslaMark {
        iconSize: Style.bar.iconFont
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }
    }

    // Three states and no more: green while the car is moving, plain while it
    // is parked and awake, dimmed while it sleeps. The mark is monochrome the
    // rest of the time on purpose, because a bar full of coloured glyphs is a
    // bar you stop reading.
    active: root.driving
    // Green rather than the shell's urgent red, which is what WidgetButton
    // reaches for by default. A car being driven is the ordinary use of a car,
    // not an alarm, and this is the same green as the panel's live dot so the
    // two agree about what it means.
    activeColor: root.liveGreen
    dimmed: root.asleep || root.errorText !== ""
    tooltipText: {
      if (root.errorText !== "") return root.plain("Dude, where's my car? " + root.errorText)
      if (!root.hasReading) return root.plain(root.carName)
      if (root.driving) return root.plain(root.carName + ": " + root.summary)
      if (root.place !== "") return root.plain(root.carName + ": parked at " + root.place)
      return root.plain(root.carName + ": " + root.summary)
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) {
        root.openInMaps()
        return
      }
      root.toggle()
    }
  }

  // The number. Same colour rules as the mark so the two read as one widget:
  // green while driving, dimmed while asleep. Its own cell rather than text
  // inside the icon slot because the mark is a Shape, not a glyph, and the
  // shell's icon button only knows how to typeset one or the other. The cell
  // is padded tight on the left so the two sit together as one thing rather
  // than as the Tesla widget and some number that happens to follow it.
  WidgetButton {
    id: rangeLabel
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    visible: root.barValue !== ""
    bar: root.bar
    text: root.barValue
    fontSize: Style.font.bodySmall
    horizontalMargin: 2
    active: root.driving
    activeColor: root.liveGreen
    dimmed: root.asleep || root.errorText !== ""
    tooltipText: button.tooltipText
    onPressed: function(b) { button.pressed(b) }
  }

  WidgetButton {
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    visible: root.barEta !== ""
    bar: root.bar
    text: root.barEta
    foreground: "#42a5f5"
    fontSize: Style.font.bodySmall
    horizontalMargin: 2
    tooltipText: button.tooltipText
    onPressed: function(b) { button.pressed(b) }
  }
  }

  // ------------------------------------------------------------------- panel

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    // Opening the panel fetches map tiles; vehicle updates stream independently.
    triggerMode: "click"
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      anchors.fill: parent
      // Generous on purpose. This panel is read in glances rather than
      // scanned, and every section in it answers a different question, so
      // they want visible daylight between them rather than a tidy list.
      spacing: Style.space(12)

      // ------------------------------------------------------------- header

      Item {
        width: parent.width
        height: Math.max(title.implicitHeight, badge.height)

        // The plugin is called Tesla everywhere it is listed, because that is
        // what you look for when you go hunting for it. The joke is here, at
        // the top of the panel, where it is the actual question being asked.
        PanelSectionHeader {
          id: title
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "DUDE, WHERE'S MY CAR?"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          id: badge
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          // No model name here. The panel is about one specific car and
          // naming it on every glance is noise; the bar's tooltip says which
          // one on the rare occasion that is the question.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: width
            radius: width / 2
            // Green for reachable, whatever it is doing: driving and
            // charging are both online, and the word beside the dot already
            // says which. The dot answers one question only: is the car
            // there to be asked.
            color: root.errorText !== "" ? Commons.Color.urgent
                 : root.asleep ? Commons.Color.muted
                 : root.carState === "" ? root.foreground
                 : root.charging ? root.chargeRed
                 : root.liveGreen
            opacity: root.asleep ? 0.7 : 1
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.stateWord
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.7
          }
        }
      }

      // ---------------------------------------------------------------- map

      Rectangle {
        id: mapArea
        width: parent.width
        // Three to two rather than sixteen to nine. A map is read outwards
        // from the middle, so at a narrow width the wide aspect spends the
        // panel on horizon and leaves you two streets of context; the squarer
        // one shows the block the car is parked on.
        height: Math.round(width * 2 / 3)
        radius: Style.space(6)
        color: Qt.rgba(0, 0, 0, 0.35)
        clip: true

        MapView {
          anchors.fill: parent
          plan: root.mapPlan
          centerLat: root.centerLat
          centerLon: root.centerLon
          zoom: root.viewZoom
          carLat: root.lat
          carLon: root.lon
          lightMap: root.lightMap
          darkMap: root.darkMap
          heading: root.hasReading && root.reading.heading !== null ? root.reading.heading : 0
          driving: root.driving
          stale: root.stale
          foreground: root.foreground
          accent: root.liveAccent
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: !root.hasPosition
          text: root.errorText !== "" ? root.errorText
              : root.hasReading ? "The car is not sharing its location"
              : "Waiting for the car"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.6
        }

        MouseArea {
          id: mapGesture
          anchors.fill: parent
          enabled: root.hasPosition
          cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          preventStealing: true
          property real startX: 0
          property real startY: 0
          property real startLat: 0
          property real startLon: 0
          onPressed: function(mouse) {
            startX = mouse.x; startY = mouse.y
            startLat = root.centerLat; startLon = root.centerLon
            root.viewLat = startLat; root.viewLon = startLon
            root.followCar = false
          }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            var point = MapMath.pan(startLat, startLon, root.viewZoom,
                                    mouse.x - startX, mouse.y - startY)
            root.viewLat = point.lat; root.viewLon = point.lon
                  }
          onReleased: root.planMap()
          onCanceled: root.planMap()
          onWheel: function(wheel) {
            var delta = wheel.angleDelta.y || wheel.pixelDelta.y
            if (delta !== 0) root.zoomMap(delta > 0 ? 1 : -1, wheel.x, wheel.y)
            wheel.accepted = true
          }
        }

        Row {
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: Style.space(6)
          spacing: Style.space(4)
          Button {
            text: "−"
            tooltipText: "Zoom out"
            enabled: root.hasPosition && root.viewZoom > 3
            background: Commons.Color.background
            onClicked: root.zoomMap(-1, mapArea.width / 2, mapArea.height / 2)
          }
          Button {
            text: "+"
            tooltipText: "Zoom in"
            enabled: root.hasPosition && root.viewZoom < 19
            background: Commons.Color.background
            onClicked: root.zoomMap(1, mapArea.width / 2, mapArea.height / 2)
          }
          Button {
            text: "Car"
            tooltipText: "Recenter and follow the car"
            enabled: root.hasPosition
            selected: root.followCar
            background: Commons.Color.background
            onClicked: root.recenterMap()
          }
          Button {
            text: "Open ↗"
            tooltipText: "Open car location in maps"
            enabled: root.hasPosition
            background: Commons.Color.background
            onClicked: root.openInMaps()
          }
        }

      }

      // -------------------------------------------------------------- where

      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.place !== ""
          text: root.place
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          color: root.foreground
        }

        // Above the summary rather than below it: the summary ends in how old
        // the reading is, which is the last thing on the panel worth reading
        // and so belongs last.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.etaText !== ""
          text: root.etaText
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.liveAccent
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.summary
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.65
        }
      }

      PanelSeparator { width: parent.width }

      // -------------------------------------------------------------- stats

      // Battery and range at the two ends of one line, with the bar spanning
      // both underneath. Three columns of figures was the first arrangement
      // and it only worked while the panel was wide: narrow it and each column
      // is too tight to hold a big number and its unit without them colliding.
      // Two figures and a full-width bar survives being made small, and reads
      // better wide as well.
      // The three read as one thing, so they are spaced as one thing. Left to
      // the panel's own rhythm the figures floated a long way above their own
      // bar and the block came apart.
      Column {
        width: parent.width
        spacing: Style.space(4)

        // The bar first and the numbers under it. They used to sit above at
        // display size, which made the battery the loudest thing on a panel
        // whose subject is where the car is. The bar already carries the
        // reading at a glance; the figures are there to be precise, not to
        // shout.
        Rectangle {
          width: parent.width
          height: Style.space(6)
          radius: height / 2
          color: Qt.rgba(1, 1, 1, 0.12)

          Rectangle {
            width: parent.width * Math.max(0, Math.min(1,
              (root.hasReading && root.reading.battery !== null ? root.reading.battery : 0) / 100))
            height: parent.height
            radius: parent.radius
            color: root.charging ? root.chargeRed : root.foreground
            opacity: root.charging ? 1 : 0.8

            Behavior on width {
              NumberAnimation { duration: 400; easing.type: Easing.OutCubic }
            }
          }

          // The charge limit is a notch rather than a third number on the
          // line below: what you read off a bar is how far the fill is from
          // the line, and the line only needs naming once.
          Rectangle {
            visible: root.hasReading && root.reading.charge_limit !== null
            x: parent.width * Math.max(0, Math.min(1,
              (root.hasReading && root.reading.charge_limit !== null ? root.reading.charge_limit : 100) / 100))
              - width / 2
            width: Math.max(1, Style.space(2))
            height: parent.height
            color: root.foreground
            opacity: 0.5
          }
        }

        // Charge on the left, what it is heading for in the middle, range on
        // the right. The three ends of the same sentence, under the bar that
        // draws it.
        Item {
          width: parent.width
          height: batteryLabel.implicitHeight

          Text {
            textFormat: Text.PlainText
            id: batteryLabel
            anchors.left: parent.left
            text: root.hasReading && root.reading.battery !== null
              ? root.reading.battery + "%" : "\u2014"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
          }

          // Nothing in the middle. The charge limit lived here, centred
          // between two aligned figures, which made it read as a third
          // unrelated item and shifted about as the numbers changed width.
          // The notch on the bar shows it, and the details grid names it.

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            text: root.hasReading && root.reading.range !== null
              ? Math.round(root.reading.range) + " " + root.reading.range_unit : "\u2014"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
          }
        }
      }

      PanelSeparator { width: parent.width }

      Column {
        width: parent.width
        spacing: Style.space(4)
        Text {
          text: "Status bar display"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
        }
        Row {
          id: displayChoices
          width: parent.width
          spacing: Style.space(6)
          readonly property real choiceWidth: (width - spacing * 2) / 3
          Button {
            width: displayChoices.choiceWidth
            text: "Charge %"
            selected: root.barDisplay === "Charge percentage"
            bordered: true
            onClicked: root.selectBarDisplay("Charge percentage")
          }
          Button {
            width: displayChoices.choiceWidth
            text: "Range km"
            selected: root.barDisplay === "Range"
            bordered: true
            onClicked: root.selectBarDisplay("Range")
          }
          Button {
            width: displayChoices.choiceWidth
            text: "Icon"
            selected: root.barDisplay === "Icon only"
            bordered: true
            onClicked: root.selectBarDisplay("Icon only")
          }
        }
      }

      // ------------------------------------------------------------ details

      // The things you look up rather than watch. Two columns of label-over-
      // value, because a label beside its value needs a leader line to stay
      // readable at this width and a label above it needs nothing at all.
      Grid {
        id: detailGrid
        width: parent.width
        columns: 2
        columnSpacing: Style.space(8)
        rowSpacing: Style.space(10)

        // Ordered by what you came for. Locked is what you check when you
        // cannot find the car; software is trivia. Left as eight cells of
        // equal weight in no particular order, nothing stood out because
        // everything looked equally worth reading. Pairs are kept together
        // across each row so the two halves explain each other.
        Detail {
          label: "locked"
          value: !root.hasReading || root.reading.locked === null ? "\u2014" : root.reading.locked ? "yes" : "no"
        }

        Detail {
          label: "sentry"
          value: !root.hasReading || root.reading.sentry === null ? "\u2014" : root.reading.sentry ? "on" : "off"
        }

        Detail {
          label: "odometer"
          value: root.hasReading && root.reading.odometer !== null
            ? Number(root.reading.odometer).toLocaleString(Qt.locale(), "f", 0)
              + " " + root.reading.range_unit
            : "\u2014"
        }

        Detail {
          label: root.usEnglish ? "tires" : "tyres"
          // A range rather than four numbers: what you act on is the lowest
          // one, and what tells you something is wrong is the spread.
          value: {
            if (!root.hasReading || !root.reading.tyres) return "\u2014"
            var t = root.reading.tyres
            var span = t.min === t.max ? String(t.min) : t.min + "\u2013" + t.max
            return span + " " + root.reading.tyre_unit
          }
        }

        Detail {
          label: "inside"
          value: root.hasReading && root.reading.inside_temp !== null
            ? root.reading.inside_temp + " " + root.reading.temp_unit : "\u2014"
        }

        Detail {
          label: "outside"
          value: root.hasReading && root.reading.outside_temp !== null
            ? root.reading.outside_temp + " " + root.reading.temp_unit : "\u2014"
        }

        Detail {
          label: "charge limit"
          value: root.hasReading && root.reading.charge_limit !== null
            ? root.reading.charge_limit + "%" : "\u2014"
        }

        Detail {
          label: "last charge"
          value: root.hasReading && root.reading.energy_added !== null
            ? Math.round((root.reading.energy_added || 0) * 10) / 10 + " kWh" : "\u2014"
        }

        Detail {
          label: "climate"
          value: !root.hasReading || root.reading.climate_on === null ? "\u2014" : root.reading.climate_on ? "on" : "off"
        }

        Detail {
          label: "software"
          value: root.hasReading && root.reading.software ? root.reading.software : "\u2014"
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.openText !== ""
        text: root.openText
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Commons.Color.urgent
      }

      PanelSeparator { width: parent.width }

      // ------------------------------------------------------------ actions

      Row {
        id: actions
        width: parent.width
        spacing: Style.space(6)

        // Split evenly rather than sized to their labels: at this width three
        // buttons hugging their text leave a ragged gap on the right, and a
        // row of equal buttons is easier to hit besides.
        readonly property int count: 1
        readonly property int buttonWidth:
          Math.floor((width - Style.space(6) * (count - 1)) / count)


        Button {
          width: actions.buttonWidth
          text: "Reconnect"
          tooltipText: "Reconnect to TeslaMate MQTT"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.reconnect()
        }

      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.errorText !== ""
        text: root.errorHint !== "" ? root.errorHint : root.errorText
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.foreground
        opacity: 0.6
      }
    }
  }

  // One looked-up fact: what it is, small and quiet, with the answer under it.
  component Detail: Column {
    property string label: ""
    property string value: ""

    width: Math.floor((detailGrid.width - Style.space(8)) / 2)
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      text: label
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.foreground
      opacity: 0.5
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: value
      elide: Text.ElideRight
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      color: root.foreground
    }
  }

  // Lets the panel be exercised without driving anywhere:
  //
  //   omarchy-shell simbesh.teslamate.test drive 87 243
  //   omarchy-shell simbesh.teslamate.test park
  //   omarchy-shell simbesh.teslamate.test sleep
  //   omarchy-shell simbesh.teslamate.test live
  //
  // Synthetic input does not reach this shell, so a test hook is the only way
  // to see what a moving car looks like without one.
  IpcHandler {
    target: "simbesh.teslamate.test"

    function drive(speed: int, heading: int): string {
      if (!root.hasReading) return "no reading to base a drive on yet"
      root.testMode = true
      var next = JSON.parse(JSON.stringify(root.reading))
      next.driving = true
      next.shift = "D"
      next.speed = speed
      next.heading = heading
      next.at = Math.round(Date.now() / 1000)
      root.carState = "online"
      root.reading = next
      return "driving " + speed + " " + next.speed_unit + " heading " + heading
    }

    // A synthetic route for checking the navigation line.
    function navigate(destination: string, minutes: int): string {
      if (!root.hasReading) return "no reading to navigate from yet"
      root.testMode = true
      var next = JSON.parse(JSON.stringify(root.reading))
      next.destination = destination
      next.eta = Math.round(Date.now() / 1000) + minutes * 60
      next.at = Math.round(Date.now() / 1000)
      root.carState = "online"
      root.reading = next
      return "arriving at " + destination + " in " + minutes + " minutes"
    }

    function park(): string {
      if (!root.hasReading) return "no reading to park yet"
      root.testMode = true
      var next = JSON.parse(JSON.stringify(root.reading))
      next.driving = false
      next.shift = "P"
      next.speed = null
      next.destination = null
      next.eta = null
      next.at = Math.round(Date.now() / 1000)
      root.carState = "online"
      root.reading = next
      return "parked"
    }

    function sleep(): string {
      root.testMode = true
      root.carState = "asleep"
      return "asleep"
    }

    // Back to whatever the car actually says, so a test never leaves the panel
    // lying about a real car.
    function live(): string {
      root.reconnect()
      return "refreshing"
    }
  }
}
