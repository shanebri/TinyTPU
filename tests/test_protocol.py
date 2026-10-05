import struct
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from protocol import Client, crc16, encode_request, decode_response, reference


def response(a, b, repetitions=1, status=0):
    body = bytes([1, status, 4, 4, 4, 8, 32, 0])
    body += struct.pack("<IIIQ16i", 100000000, repetitions, 12, 14*repetitions-2, *reference(a, b))
    return b"TR" + body + struct.pack("<H", crc16(body))


class ProtocolTests(unittest.TestCase):
    def test_crc_known_vector(self):
        self.assertEqual(crc16(b"123456789"), 0x29B1)

    def test_request_layout_and_signed_values(self):
        a, b = [-128, 127, -1, 0]*4, list(range(-8, 8))
        packet = encode_request(a, b, 123)
        self.assertEqual(len(packet), 42)
        self.assertEqual(struct.unpack("<BBI32b", packet[2:-2]), (1, 1, 123, *a, *b))
        self.assertEqual(struct.unpack("<H", packet[-2:])[0], crc16(packet[2:-2]))

    def test_request_rejects_invalid_inputs(self):
        for n in [0, -1, 1000001]:
            with self.assertRaises(ValueError): encode_request([0]*16, [0]*16, n)
        with self.assertRaises(ValueError): encode_request([0]*15, [0]*16)
        with self.assertRaises(struct.error): encode_request([128]*16, [0]*16)

    def test_response(self):
        a, b = [-128]*16, [127]*16
        result = decode_response(response(a, b, 3))
        self.assertEqual(result.values, (-65024,)*16)
        self.assertEqual(result.batch_cycles, 40)
        self.assertEqual(result.repetitions, 3)

    def test_corruption_and_device_error(self):
        packet = bytearray(response([0]*16, [0]*16))
        packet[30] ^= 1
        with self.assertRaisesRegex(ValueError, "CRC"): decode_response(packet)
        with self.assertRaises(ValueError): decode_response(packet[:-1])
        with self.assertRaisesRegex(ValueError, "rejected request CRC"):
            decode_response(response([0]*16, [0]*16, status=1))

    def test_reference_nonsymmetric(self):
        identity = [int(r == c) for r in range(4) for c in range(4)]
        b = list(range(-8, 8))
        self.assertEqual(reference(identity, b), tuple(b))

    def test_client_handles_short_io_and_noise(self):
        class Serial:
            def __init__(self):
                self.pending = bytearray(b"noiseT" + response([0]*16, [0]*16))
                self.written = bytearray()
            def write(self, data):
                self.written.extend(data[:3])
                return min(3, len(data))
            def read(self, count):
                data = self.pending[:min(2, count)]
                del self.pending[:len(data)]
                return data
        client = Client.__new__(Client)
        client.timeout = 1
        client.serial = Serial()
        self.assertEqual(client.run([0]*16, [0]*16).values, (0,)*16)
        self.assertEqual(client.serial.written, encode_request([0]*16, [0]*16))

    def test_client_times_out_without_retry(self):
        client = Client.__new__(Client)
        client.timeout = 0.001
        class Silent:
            writes = 0
            def write(self, data):
                self.writes += 1
                return len(data)
            def read(self, count): return b""
        client.serial = Silent()
        with self.assertRaises(TimeoutError): client.run([0]*16, [0]*16)
        self.assertEqual(client.serial.writes, 1)


if __name__ == "__main__":
    unittest.main()
