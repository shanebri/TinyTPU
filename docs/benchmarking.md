# MicroBlaze integration and benchmarking

## Hardware boundary

`arty_top.sv` is an AXI4-Lite slave peripheral, despite its board-oriented name.
Add it alongside MicroBlaze, your UART peripheral, and AXI interconnect.
It implements the existing fixed 4x4x4 signed int8 matrix multiply with int32
outputs. It contains no UART, Ethernet, board constraints, or build automation.
Use `arty.f` for source ordering.

Connect the peripheral clock to the same AXI clock as MicroBlaze and its
interconnect. Connect `s_axi_aresetn` to the synchronized active-low peripheral
reset from your reset controller. Hold reset for at least one clock edge.
The default `CLK_HZ` is 100 MHz; set it to your actual accelerator/AXI clock.
This parameter reports frequency; it does not generate a clock. A correct
frequency and successful timing closure are required for ns/op numbers.

The address port uses eight offset bits. Assign a normal AXI peripheral
address segment (for example, a 4 KiB segment) in your block design; only
the first 256 bytes are used. Access the documented offsets only.
Map it as device/uncached memory if your MicroBlaze system has a data cache.
Use ordered `Xil_In32` / `Xil_Out32` accesses in firmware.

AW and W channels are buffered independently. B and R responses remain
stable under backpressure. WSTRB is honored for writable bytes. Accesses must
be word aligned; undefined/read-only writes and undefined reads return DECERR.
Operand/repetition writes and START while busy return SLVERR and set ERROR.
Simultaneous read/write of a register returns its pre-write value.

## Register map

Offsets are hexadecimal. All registers are 32 bits.

| Offset | Access | Meaning |
|---|---|---|
| `00` | W | CONTROL: bit 0 START, bit 1 CLEAR/ABORT; pulses, CLEAR takes priority |
| `04` | R | STATUS: bit 0 BUSY, bit 1 DONE, bit 2 ERROR |
| `08` | RW | Repetitions, reset value 1; valid range 1..MAX_REPETITIONS |
| `0c` | R | Accelerator clock Hz (`CLK_HZ`) |
| `10` | R | Kernel cycles: last tile acceptance through result commit |
| `14` | R | Batch cycles low 32 bits |
| `18` | R | Batch cycles high 32 bits |
| `1c` | R | Completed tile count |
| `20` | R | Configuration: `0x20080404` = accumulator 32, operand 8, cols 4, rows 4 |
| `24` | R | `0x00010004` = wrapper version 1, inner dimension 4 |
| `28` | R | Maximum repetitions, default 1,000,000 |
| `40..4c` | RW | Four packed rows of A |
| `50..5c` | RW | Four packed rows of B |
| `80..bc` | R | Sixteen row-major int32 output values |

A and B are row-major. In each operand word, column 0 occupies bits 7:0,
column 1 bits 15:8, and so on. Bytes are signed two's-complement int8 values.
B is not transposed. Results are signed two's-complement int32 words.

START clears DONE/ERROR, previous timings, and the visible result snapshot.
Inputs and repetitions cannot change while BUSY is set. Every repetition
overwrites tile zero with the same A*B; it does not accumulate repeated results.
DONE becomes sticky only after results have been copied to the result registers.
It stays set until START or CLEAR. CLEAR aborts and clears counters/results and
DONE/ERROR, retaining operands and the programmed repetition count.

To execute: CLEAR, write A/B, write repetitions, START, poll until BUSY=0 and
DONE=1, then read counters/results. Use a bounded timeout. Read batch low/high
only after completion so they are a coherent snapshot. Completed count is live
while running. Result registers remain zero until the final snapshot is ready.

Kernel latency is measured from the acceptance edge to the tile buffer commit
edge: 12 cycles with this engine. Batch cycles span first acceptance through
last commit and include gaps between tiles: `14*N - 2` cycles. Timing excludes
AXI operand writes, initial START handling, final snapshot reads, MicroBlaze
polling, and UART. At 100 MHz, kernel latency is 120 ns and sustained resident
batch time approaches 140 ns/tile. These are expected cycle counts, not verified
board timing or measured Pi performance.

## Connect your UART server

The Python client expects one binary request followed by one binary response.
There is no pipelining, auto-retry, or text console mixed into this channel.
Your server scans for `TP`, receives the remaining 40 bytes, and passes the
complete request to `tpu_handle_request` in `firmware/tiny_tpu_server.c`.
Then transmit all 96 response bytes, handling partial writes as appropriate.
Discard an incomplete packet after at least 100 ms of silence and restart
header scanning; discard UART framing-error packets. Use a longer timeout
if your server intentionally pauses between bytes. Embedded `TP` bytes in a
valid fixed-length body are data, not new headers.

The supplied packet handler does not own or initialize UART. Its callbacks
let you connect your existing BSP register access functions:

```c
#include "xil_io.h"
#include "tiny_tpu_server.h"

static uint32_t read_tpu(void *ctx, uint32_t offset) {
    return Xil_In32((UINTPTR)(*(uintptr_t *)ctx + offset));
}
static void write_tpu(void *ctx, uint32_t offset, uint32_t value) {
    Xil_Out32((UINTPTR)(*(uintptr_t *)ctx + offset), value);
}

/* Use your assigned accelerator address, not a UART address. */
uintptr_t tpu_base = YOUR_TPU_BASE_ADDRESS;
uint8_t request[TPU_REQUEST_BYTES], response[TPU_RESPONSE_BYTES];
/* After your server receives a complete request: */
tpu_handle_request(request, response, read_tpu, write_tpu, &tpu_base, 1000000);
/* Your server now transmits response[0..95]. */
```

The last argument bounds the number of status reads, not elapsed microseconds.
Choose it for your MicroBlaze clock and bus latency. The host has its own wall
timeout, default 5 s. The handler aborts hardware on a polling timeout, validates
configuration/repetition limits, and refuses to interrupt an already busy engine.

### Wire format v1

All multibyte fields are little endian. CRC-16/CCITT-FALSE uses polynomial
`0x1021`, initial value `0xffff`, no reflection, and no final XOR. The CRC
excludes the two magic bytes and the CRC itself; `123456789` gives `0x29b1`.

Request, 42 bytes:

| Byte offset | Field |
|---|---|
| 0..1 | ASCII `TP` |
| 2 | Version 1 |
| 3 | Command 1: run |
| 4..7 | Repetition count uint32 |
| 8..23 | A, sixteen signed int8 values |
| 24..39 | B, sixteen signed int8 values |
| 40..41 | CRC of bytes 2..39 |

Response, 96 bytes:

| Byte offset | Field |
|---|---|
| 0..1 | ASCII `TR` |
| 2 | Version 1 |
| 3 | Status: 0 success, 1 CRC, 2 bad command/count, 3 timeout, 4 busy, 5 incompatible configuration, 6 hardware error |
| 4..9 | Rows=4, cols=4, inner=4, operand bits=8, accumulator bits=32, reserved=0 |
| 10..13 | Clock Hz uint32 |
| 14..17 | Echoed repetitions uint32 |
| 18..21 | Kernel cycles uint32 |
| 22..29 | Batch cycles uint64 |
| 30..93 | Result, sixteen signed int32 values |
| 94..95 | CRC of bytes 2..93 |

Errors return zero timings/results. The host validates response CRC,
configuration, repetitions, cycle counts, and every matrix result. A missing
response raises an error without silently retrying execution.

## Run on the Pi

Use the Arty PROG/UART USB connection and your server's baud rate. Prefer the
stable device path in `/dev/serial/by-id/` over guessing `/dev/ttyUSB0`.
Install dependencies in a virtual environment:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r tools/requirements.txt

# Optional native baseline; separate translation units, no LTO.
gcc -O3 -march=native -std=c11 -Wall -Wextra \
    tools/cpu_benchmark.c tools/cpu_kernel.c -o tools/cpu_benchmark

OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 python tools/benchmark.py \
    --port /dev/serial/by-id/YOUR_UART_DEVICE --baud 115200 \
    --native tools/cpu_benchmark --repetitions 10000 --samples 20 \
    --output results/pi.json

# Exercise CPU tooling independently of the board/server.
python tools/benchmark.py --cpu-only --native tools/cpu_benchmark \
    --output results/cpu.json
```

The native program targets POSIX/Linux, including Raspberry Pi OS. The Python
client also supports Windows serial ports such as `--port COM5`.

Each FPGA run first checks five edge cases and 32 seeded random cases against
an independent integer reference. It then warms up, measures single-tile round
trips and resident batches, and benchmarks the same operands on the CPU.
Correctness checks, array allocation, and int8-to-int32 conversion are outside
CPU timing. Packet serialization/parsing are inside host round-trip timing.
Repetitions reuse the same input on the FPGA and native C baseline. NumPy's
batch baseline uses contiguous stacks of the same tiles, so its memory traffic
differs from the resident hardware path; it is reported separately.

Results include input matrices, expected output, seed, settings, host/Python/
NumPy/compiler versions, correctness count, raw samples, median/mean/p95/min/max, cycle
counts, and explicit time units. Save the native build flags, Pi model,
clock/governor, cooling, bitstream revision, synthesis resource use and timing
report alongside the JSON for reproducible comparisons. Keep the Pi workload
quiet and record throttling if it occurs. Integer NumPy matmul is not a claim
of optimized int8 NEON performance or BLAS GEMM performance.

## What to compare

| Metric | Useful comparison | What it tells you |
|---|---|---|
| FPGA kernel latency | Native C / NumPy single-call latency | Time for one already loaded tile; NumPy includes Python call overhead |
| FPGA resident batch ns/tile | Native C resident loop | Most direct initial compute comparison; includes FPGA scheduling gaps |
| FPGA resident batch ns/tile | NumPy batched int32 matmul | Practical CPU batch baseline with different data movement |
| UART single round trip | NumPy single-call latency | Actual cost of offloading one tile from Pi |
| UART batch round trip / N | CPU resident batch ns/tile | Amortized offload cost for repeated resident inputs |

Use **compiled C on the same Pi as the primary initial compute baseline**.
It performs 64 signed integer MACs per tile, with int32 sums. Compile at `-O3`
and allow the compiler to optimize/vectorize. Keeping the kernel in a separate
translation unit without LTO prevents the identical-input loop being eliminated.
The current C baseline includes a function call per tile; for such tiny tiles,
call overhead matters. For stronger performance claims, add an explicitly
optimized ARM NEON/int8 kernel and larger workload tests with matched layouts
and operand/result transfer included. A floating-point GEMM or a large neural
network benchmark is not an equivalent baseline for this fixed integer tile.

Each tile has 64 MACs, or 128 integer operations if multiply and add count
separately. Throughput in GOPS is `128 / ns_per_tile`; report the convention.
Repeated-resident throughput measures scheduling/compute, not fresh-input
streaming throughput. At 115200 8N1, the request and response alone require
about 12 ms of sequential wire time. MicroBlaze processing, polling, USB and
Python add overhead. Do not label the resident-batch ratio an application
speedup, or expect UART offloading one 4x4 tile to beat local CPU multiplication.

## Validation

`python -m unittest discover -s tests -v` tests packet encoding, known CRC,
signed arithmetic, malformed responses, short serial reads/writes, and timeout
behavior without an FPGA. `tests/arty_axi_tb.sv` exercises the peripheral in
simulation, including separated AXI channels, response backpressure, strobes,
signed results, timing counters, busy rejection and abort. Add it as your
simulation top with the sources from `arty.f`. No simulation/build is launched
by the benchmark scripts. Synthesis, timing closure, and hardware verification
remain part of your board integration workflow.
