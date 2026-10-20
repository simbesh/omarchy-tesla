#!/usr/bin/env python3
"""Read-only TeslaMate MQTT subscriber. Emits newline-delimited panel readings."""
import argparse
import json
import math
import signal
import threading
import time


def number(value):
    if isinstance(value, bool):
        return None
    try:
        value = float(value)
        return value if math.isfinite(value) else None
    except (TypeError, ValueError):
        return None


def boolean(value):
    return value if isinstance(value, bool) else None


class Vehicle:
    def __init__(self):
        self.values = {}
        self.last_live = None
        self.route_at = None
        self.received_at = None

    def update(self, key, payload, retained=False, now=None):
        now = time.time() if now is None else now
        try:
            value = json.loads(payload)
        except (ValueError, UnicodeError):
            value = payload.decode('utf-8', errors='replace') if isinstance(payload, bytes) else payload
        if value in ('nil', ''):
            value = None
        self.values[key] = value
        self.received_at = now
        if not retained:
            self.last_live = now
        if key == 'active_route':
            # MQTT retained payloads have no publication timestamp. Do not turn
            # an old duration into a falsely precise arrival time on reconnect.
            self.route_at = None if retained else now

    def reading(self, car_id, connected=True, pressure='psi', now=None):
        now = time.time() if now is None else now
        v = self.values
        n = lambda key: number(v.get(key))
        b = lambda key: boolean(v.get(key))
        state = v.get('state', 'unknown')
        driving = connected and state == 'driving'
        location = v.get('location')
        location = location if isinstance(location, dict) else {}
        route = v.get('active_route')
        route = route if isinstance(route, dict) else {}
        # Prefer the atomic route payload; do not resurrect a cleared route
        # from separately retained legacy destination topics.
        destination = route.get('destination') if not route.get('error') else None
        if 'active_route' not in v:
            destination = v.get('active_route_destination')
        route_fresh = self.route_at is not None and now - self.route_at <= 300
        minutes = number(route.get('minutes_to_arrival'))
        eta = round(self.route_at + minutes * 60) if (
            connected and state == 'driving' and route_fresh and destination
            and minutes is not None and minutes >= 0) else None
        if state not in ('driving', 'online') or not connected:
            destination = None
        factor = 14.5038 if pressure == 'psi' else 1
        tyres = [n('tpms_pressure_' + corner) for corner in ('fl', 'fr', 'rl', 'rr')]
        tyres = [x * factor for x in tyres if x is not None and x > 0]
        opens = [label for key, label in [('doors_open', 'a door'), ('frunk_open', 'the frunk'),
                 ('trunk_open', 'the boot'), ('windows_open', 'a window')] if b(key) is True]
        charging = v.get('charging_state', 'Unknown')
        if state != 'charging' or not connected:
            charging = 'Disconnected' if b('plugged_in') is False else 'Unknown'
        miles = number(route.get('miles_to_arrival'))
        delay = number(route.get('traffic_minutes_delay'))
        return dict(ok=bool(v), connected=connected, fresh=self.last_live is not None,
                    at=self.last_live, received_at=self.received_at,
                    state=state if connected else 'unknown', car_id=car_id,
                    name=v.get('display_name') or 'Tesla',
                    lat=number(location.get('latitude', v.get('latitude'))),
                    lon=number(location.get('longitude', v.get('longitude'))),
                    heading=n('heading'), driving=driving, shift=v.get('shift_state'),
                    speed=n('speed') if driving else None, speed_unit='km/h',
                    destination=destination, eta=eta,
                    eta_distance=round(miles * 1.609344, 1) if miles is not None and destination else None,
                    eta_delay=round(delay) if delay is not None and delay >= 1 and destination else None,
                    battery=n('battery_level'), battery_usable=n('usable_battery_level'),
                    charge_limit=n('charge_limit_soc'), charging=charging,
                    charger_power=n('charger_power') if charging == 'Charging' else None,
                    energy_added=n('charge_energy_added'),
                    minutes_to_full=n('time_to_full_charge') * 60 if n('time_to_full_charge') is not None and charging == 'Charging' else None,
                    range=n('rated_battery_range_km'), range_unit='km', odometer=n('odometer'),
                    locked=b('locked'), sentry=b('sentry_mode'), climate_on=b('is_climate_on'),
                    inside_temp=n('inside_temp'), outside_temp=n('outside_temp'), temp_unit='°C',
                    tyres=dict(min=round(min(tyres), 1), max=round(max(tyres), 1)) if tyres else None,
                    tyre_unit=pressure, software=v.get('version'), open=opens,
                    car_type='model' + str(v.get('model', '')).lower(), trim=v.get('trim_badging'))


def emit(value):
    print(json.dumps(value, ensure_ascii=False, allow_nan=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='10.1.1.10')
    parser.add_argument('--port', type=int, default=1883)
    parser.add_argument('--topic', default='teslamate/cars/1')
    parser.add_argument('--pressure', choices=('psi', 'bar'), default='psi')
    parser.add_argument('--seconds', type=float, help='Stop after this many seconds, for diagnostics')
    args = parser.parse_args()
    topic = args.topic.rstrip('/')
    if '+' in topic or '#' in topic or not topic:
        parser.error('--topic must identify one car, without MQTT wildcards')
    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        emit(dict(ok=False, error='MQTT dependency missing', hint='Install python-paho-mqtt, or use the virtualenv setup in README.md.'))
        return 1
    vehicle = Vehicle()
    lock = threading.Lock()
    stop = threading.Event()
    status = dict(connected=False, error='Connecting to MQTT', dirty=True)
    api_v2 = hasattr(mqtt, "CallbackAPIVersion")
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2) if api_v2 else mqtt.Client()
    client.reconnect_delay_set(min_delay=1, max_delay=30)

    def on_connect(client, userdata, flags, reason, properties):
        with lock:
            status.update(connected=False, error='MQTT connection refused' if reason != 0 else 'Waiting for vehicle data', dirty=True)
            # Clear old state before replaying retained values from this session.
            vehicle.__init__()
        if reason == 0:
            client.subscribe(topic + '/+', qos=0)

    def on_subscribe(client, userdata, mid, reasons, properties):
        with lock:
            failed = not reasons or any((r.value if hasattr(r, "value") else r) >= 128 for r in reasons)
            status.update(connected=not failed, error='MQTT subscription refused' if failed else '', dirty=True)

    def on_disconnect(client, userdata, flags, reason, properties):
        with lock:
            status.update(connected=False, error='MQTT disconnected; reconnecting', dirty=True)

    def on_connect_fail(client, userdata):
        with lock:
            status.update(connected=False, error='MQTT unavailable; retrying', dirty=True)

    def on_message(client, userdata, message):
        if not message.topic.startswith(topic + '/'):
            return
        key = message.topic[len(topic) + 1:]
        if '/' in key:
            return
        with lock:
            vehicle.update(key, message.payload, message.retain)
            status['dirty'] = True

    client.on_connect = on_connect if api_v2 else lambda c, u, f, r: on_connect(c, u, f, r, None)
    client.on_subscribe = on_subscribe if api_v2 else lambda c, u, mid, r: on_subscribe(c, u, mid, r, None)
    client.on_disconnect = on_disconnect if api_v2 else lambda c, u, r: on_disconnect(c, u, None, r, None)
    client.on_connect_fail = on_connect_fail
    client.on_message = on_message
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    client.connect_async(args.host, args.port, keepalive=30)
    client.loop_start()
    start = time.monotonic()
    last_emit = 0
    try:
        while not stop.wait(0.5):
            elapsed = time.monotonic() - start
            with lock:
                if status['dirty'] or elapsed - last_emit >= 15:
                    reading = vehicle.reading(topic.rsplit('/', 1)[-1], status['connected'], args.pressure)
                    reading['error'] = status['error'] or ('' if reading['ok'] else 'Waiting for vehicle data')
                    emit(reading)
                    status['dirty'] = False
                    last_emit = elapsed
            if args.seconds is not None and elapsed >= args.seconds:
                break
    finally:
        client.disconnect()
        client.loop_stop()
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        pass
