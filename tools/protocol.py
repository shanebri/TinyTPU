"""TinyTPU UART protocol v1. No serial dependency needed for offline tests."""
from dataclasses import dataclass
import struct
import time

REQUEST_MAGIC = b"TP"
RESPONSE_MAGIC = b"TR"
RESPONSE_SIZE = 96
MAX_REPETITIONS = 1_000_000


def crc16(data):
    """CRC-16/CCITT-FALSE: poly 0x1021, init 0xffff, no reflection/xorout."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x1021 if crc & 0x8000 else 0)) & 0xFFFF
    return crc


def encode_request(a, b, repetitions=1):
    if not 1 <= repetitions <= MAX_REPETITIONS:
        raise ValueError(f"repetitions must be in 1..{MAX_REPETITIONS}")
    if len(a) != 16 or len(b) != 16:
        raise ValueError("each matrix must contain 16 row-major signed int8 values")
    payload = struct.pack("<BBI32b", 1, 1, repetitions, *a, *b)
    return REQUEST_MAGIC + payload + struct.pack("<H", crc16(payload))


@dataclass(frozen=True)
class Result:
    clock_hz: int
    repetitions: int
    kernel_cycles: int
    batch_cycles: int
    values: tuple


def decode_response(packet):
    if len(packet) != RESPONSE_SIZE or packet[:2] != RESPONSE_MAGIC:
        raise ValueError("invalid response length or magic")
    payload = packet[2:-2]
    if crc16(payload) != struct.unpack("<H", packet[-2:])[0]:
        raise ValueError("response CRC mismatch")
    version, status, rows, cols, inner, data_bits, acc_bits, reserved = payload[:8]
    if version != 1 or (rows, cols, inner, data_bits, acc_bits, reserved) != (4, 4, 4, 8, 32, 0):
        raise ValueError("unsupported FPGA configuration/protocol")
    if status:
        raise ValueError({1: "server rejected request CRC", 2: "server rejected command or repetitions",
                          3: "server timed out waiting for accelerator", 4: "accelerator busy",
                          5: "unsupported accelerator configuration", 6: "accelerator error"}.get(status, f"server error {status}"))
    clock, repetitions, kernel, batch = struct.unpack_from("<IIIQ", payload, 8)
    if not clock or not 1 <= repetitions <= MAX_REPETITIONS or not kernel or batch < kernel:
        raise ValueError("invalid FPGA timing metadata")
    return Result(clock, repetitions, kernel, batch, struct.unpack_from("<16i", payload, 28))


def reference(a, b):
    """Exact integer oracle, independent of NumPy and FPGA implementation."""
    return tuple(sum(int(a[r*4+k]) * int(b[k*4+c]) for k in range(4))
                 for r in range(4) for c in range(4))


class Client:
    def __init__(self, port, baud=115200, timeout=5.0):
        import serial
        self.timeout = timeout
        self.serial = serial.Serial(port, baud, timeout=min(timeout, 0.1), write_timeout=timeout)
        # Allow an abandoned partial request to expire before the first command.
        time.sleep(0.15)
        self.serial.reset_input_buffer()

    def close(self):
        self.serial.close()

    def run(self, a, b, repetitions=1):
        packet = encode_request(a, b, repetitions)
        deadline = time.monotonic() + self.timeout
        offset = 0
        while offset < len(packet):
            written = self.serial.write(packet[offset:])
            if not written or time.monotonic() >= deadline:
                raise TimeoutError("UART write timed out")
            offset += written
        # Search for the response header, then read the fixed body; no automatic
        # retry: a lost response must not silently execute the operation twice.
        received = bytearray()
        while time.monotonic() < deadline:
            received.extend(self.serial.read(1 if len(received) < 2 else RESPONSE_SIZE-len(received)))
            while len(received) >= 2 and received[:2] != RESPONSE_MAGIC:
                del received[0]
            if len(received) == RESPONSE_SIZE:
                result = decode_response(bytes(received))
                if result.repetitions != repetitions:
                    raise ValueError("response repetition count differs from request")
                return result
        raise TimeoutError(f"UART response timed out ({len(received)}/{RESPONSE_SIZE} bytes); check bitstream, baud, cable, and port")
