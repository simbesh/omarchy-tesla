import importlib.util
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('teslamate', ROOT / 'bin/teslamate.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ReadingTests(unittest.TestCase):
    def setUp(self):
        self.car = m.Vehicle()
        for key, value in {'state': 'driving', 'battery_level': 59, 'speed': 63,
                           'rated_battery_range_km': 249.32, 'locked': True,
                           'model': 'Y', 'tpms_pressure_fl': 3}.items():
            self.car.update(key, json.dumps(value), retained=True, now=1000)

    def test_units_and_unknowns(self):
        r = self.car.reading('1', now=1000)
        self.assertEqual((r['speed'], r['range']), (63, 249.32))
        self.assertEqual(r['tyres']['min'], 43.5)
        self.assertEqual(r['car_type'], 'modely')
        self.assertIsNone(r['sentry'])
        self.assertIsNone(r['lat'])
        self.assertIsNone(r['at'])
        self.assertFalse(r['fresh'])

    def route(self, retained=False):
        self.car.update('active_route', json.dumps(dict(destination='Home',
            minutes_to_arrival=12, miles_to_arrival=10, traffic_minutes_delay=2)), retained, 1000)

    def test_live_eta_does_not_drift_with_other_updates(self):
        self.route()
        self.car.update('speed', '42', now=1060)
        r = self.car.reading('1', now=1060)
        self.assertEqual(r['eta'], 1720)
        self.assertEqual(r['eta_distance'], 16.1)
        self.assertEqual(r['eta_delay'], 2)

    def test_retained_route_has_destination_but_no_invented_eta(self):
        self.route(retained=True)
        self.car.update('speed', '42', now=1060)
        r = self.car.reading('1', now=1060)
        self.assertEqual(r['destination'], 'Home')
        self.assertIsNone(r['eta'])

    def test_route_expiry_clear_and_offline(self):
        self.route()
        self.assertIsNone(self.car.reading('1', now=1301)['eta'])
        self.assertIsNone(self.car.reading('1', connected=False, now=1010)['destination'])
        self.assertFalse(self.car.reading('1', connected=False)['driving'])
        self.car.update('active_route_destination', 'Old destination', now=1010)
        self.car.update('active_route', '{"error":"No active route available"}', now=1010)
        self.assertIsNone(self.car.reading('1', now=1010)['destination'])

    def test_nil_malformed_and_nonfinite(self):
        self.car.update('locked', 'nil')
        self.car.update('battery_level', 'NaN')
        self.car.update('location', 'broken json')
        self.car.update('active_route', '{bad')
        r = self.car.reading('1')
        self.assertIsNone(r['locked'])
        self.assertIsNone(r['battery'])
        self.assertIsNone(r['lat'])
        json.dumps(r, allow_nan=False)

    def test_charging_values_only_while_charging(self):
        for key, value in {'charging_state': 'Charging', 'charger_power': 7,
                           'time_to_full_charge': 1.5}.items():
            self.car.update(key, json.dumps(value))
        self.assertIsNone(self.car.reading('1')['charger_power'])
        self.car.update('state', 'charging')
        r = self.car.reading('1')
        self.assertEqual(r['minutes_to_full'], 90)
        self.assertEqual(r['charger_power'], 7)


def packet_read(conn):
    def exact(n):
        result = b''
        while len(result) < n:
            part = conn.recv(n - len(result))
            if not part:
                raise EOFError()
            result += part
        return result
    kind = exact(1)[0]
    size, factor = 0, 1
    while True:
        byte = exact(1)[0]
        size += (byte & 127) * factor
        factor *= 128
        if byte < 128:
            break
    return kind, exact(size)


def publish(conn, key, value, retained=True):
    topic = ('teslamate/cars/1/' + key).encode()
    body = struct.pack('!H', len(topic)) + topic + json.dumps(value).encode()
    size, encoded = len(body), b''
    while True:
        byte = size % 128
        size //= 128
        encoded += bytes([byte | (128 if size else 0)])
        if not size:
            break
    conn.sendall(bytes([0x31 if retained else 0x30]) + encoded + body)


class TransportTests(unittest.TestCase):
    def test_subscription_disconnect_and_retained_replay(self):
        # Local fake broker only. Never publish synthetic data to the real car broker.
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(8)
        errors = []
        done = threading.Event()
        def broker():
            try:
                for battery in (59, 58):
                    conn, _ = listener.accept()
                    with conn:
                        conn.settimeout(5)
                        self.assertEqual(packet_read(conn)[0], 0x10)
                        conn.sendall(b'\x20\x02\x00\x00')
                        kind, body = packet_read(conn)
                        self.assertEqual(kind, 0x82)
                        self.assertIn(b'teslamate/cars/1/+', body)
                        conn.sendall(b'\x90\x03' + body[:2] + b'\x00')
                        publish(conn, 'state', 'driving')
                        publish(conn, 'battery_level', battery)
                        publish(conn, 'active_route', {'destination': 'Test', 'minutes_to_arrival': 5})
                        done.wait(1.2)
            except Exception as e:
                errors.append(e)
            finally:
                listener.close()
        thread = threading.Thread(target=broker)
        thread.start()
        result = subprocess.run([sys.executable, str(ROOT / 'bin/teslamate.py'),
             '--host', '127.0.0.1', '--port', str(listener.getsockname()[1]),
             '--seconds', '4.5'], capture_output=True, text=True, timeout=10)
        done.set()
        thread.join(10)
        self.assertFalse(errors, errors)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertTrue(any(r.get('battery') == 59 for r in rows))
        self.assertTrue(any(r.get('battery') == 58 for r in rows))
        self.assertTrue(any(not r['connected'] for r in rows))
        self.assertTrue(all(r.get('eta') is None for r in rows))


if __name__ == '__main__':
    unittest.main()
