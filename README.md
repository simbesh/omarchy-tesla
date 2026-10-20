# TeslaMate for Omarchy

An Omarchy bar widget fed by TeslaMate MQTT. Forked from
[jankeesvw/omarchy-tesla](https://github.com/jankeesvw/omarchy-tesla).
The original map, battery display, vehicle details and theme support are preserved.
The Tesla Owner API backend, credentials and wake action are replaced by a
read-only MQTT subscription.

## Install

Install Python 3 and Paho MQTT 2.x. On Omarchy:

```bash
sudo pacman -S python-paho-mqtt
omarchy plugin add https://github.com/simbesh/omarchy-tesla.git --enable
```

The plugin ID is `simbesh.teslamate`. It can coexist with the upstream plugin,
although you will probably want only one Tesla widget in the bar.

The configured defaults for this fork are:

- Broker: `10.1.1.10`, TCP port `1883`.
- Vehicle topic: `teslamate/cars/1`.
- Units: kilometres, Celsius and psi. Pressure can be changed to bar.

Change the host, port, vehicle topic and pressure unit in the widget settings.
This version supports the tested LAN broker without authentication or TLS.
It never publishes messages or calls Tesla's API.

For a Python virtual environment instead of the system package:

```bash
python3 -m venv ~/.local/share/omarchy-teslamate/venv
~/.local/share/omarchy-teslamate/venv/bin/pip install 'paho-mqtt>=2.0,<3'
```

Set `OMARCHY_TESLA_PYTHON` in the shell's launch environment to that environment's
absolute `bin/python` path. For a terminal test, prefix the command with the variable.

## Display

The bar shows the Tesla mark and optional rated range. Click for the map, current
state, speed, charge level, range, lock and sentry status, mileage, tyre pressure
range, temperatures, charge limit, energy added, climate status and firmware.
Open doors, windows, boot and frunk retain the upstream warning display.

Navigation appears beneath the location: destination, ETA as a local clock time,
remaining distance and traffic delay when supplied. With no route, it says
“No active navigation route”. The destination can appear before ETA is available.

MQTT values already use kilometres for speed, range and mileage. Route distance
is supplied in miles and converted to kilometres. Tyres arrive in bar and are
converted to the selected unit. The plugin does not infer the car's screen units.

## Updates and freshness

One child process subscribes to `teslamate/cars/1/+`, combines field updates, and
sends JSON readings to QML at most twice a second. It reconnects automatically
with a delay of 1–30 seconds and subscribes again after each connection. The panel's
Reconnect button reconnects to the broker. It does not wake the vehicle.

Retained MQTT messages provide the initial values but do not include their
publication time. The panel labels these as retained data of unknown age until a
live message arrives. The displayed update age is the latest live MQTT message;
individual fields may be older. A quiet subscription is not automatically treated
as a disconnected broker. Paho handles keepalive and connection loss.

The `active_route` JSON payload is authoritative. An error or cleared route removes
the destination and ETA. ETA is calculated once from receipt time plus
`minutes_to_arrival`, so unrelated speed updates cannot move it forward. A retained
route shows its destination but “ETA awaiting live route” until a non-retained
route update arrives. ETA expires after five minutes without a route update.
Sleeping, offline and disconnected states suppress navigation. This avoids showing
an arrival time calculated from an old retained duration.

Charging power and time remaining are valid only in the charging state. Unknown
lock, sentry and climate values display a dash rather than a false “off” or “no”.

The map still uses OpenStreetMap tiles and optionally Nominatim for street names.
Address lookup runs only with the panel open. Disable “Look the position up by
name” to stop reverse geocoding. No Tesla credentials are needed or read.

## Development and testing

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
OMARCHY_TESLA_PYTHON="$PWD/.venv/bin/python" test/all
OMARCHY_TESLA_PYTHON="$PWD/.venv/bin/python" bin/tesla stream --seconds 10
```

The test suite checks field mapping, unknown values, unit conversion, charging
state, ETA freshness and route clearing. A local fake broker verifies subscription,
disconnection and retained replay after reconnection. Tests never publish to the
configured vehicle broker. Existing address formatter tests are retained; QML is
checked with `qmllint` when installed.

To inspect another broker without changing widget settings:

```bash
bin/tesla stream --host 192.168.1.20 --port 1883 --topic teslamate/cars/2 --seconds 10
```

`bin/tesla` also retains the `map`, `place` and `notify` helpers. The old `login`,
`token`, `car`, `state` and `wake` commands have been removed.

See [tests/MANUAL.md](tests/MANUAL.md) for panel checks.
MQTT field definitions follow the
[TeslaMate documentation](https://github.com/teslamate-org/teslamate/blob/main/website/docs/integrations/mqtt.md).

## Licence

MIT. Original interface by Jankees van Woezik, MQTT adaptation by simbesh.
The Tesla name and mark belong to Tesla, Inc. This project is not affiliated with Tesla.
