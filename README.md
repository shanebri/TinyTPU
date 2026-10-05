# TinyTPU

A signed integer, output-stationary matrix-multiply tile engine. The default
configuration multiplies two 4x4 int8 matrices into a 4x4 int32 result and stores
it in a four-entry accumulation buffer. Arithmetic wraps at `ACC_WIDTH` bits;
there is no saturation or quantization.

## Modules

- `processing_element.sv`: signed MAC with registered operand forwarding,
  accumulator-only clear, and compute enable.
- `systolic_array.sv`: rectangular PE grid. A moves right, B moves down, and
  each PE keeps one output element.
- `tile_controller.sv`: `IDLE -> CLEAR -> COMPUTE -> DRAIN -> STORE -> DONE`
  sequencing. DRAIN is skipped when either array dimension is one.
- `tile_engine.sv`: top-level operand capture, input staggering, controller,
  array, and accumulation buffer integration.
- `accumulation_buffer.sv`: register-backed tile storage with overwrite/add
  writes and synchronous reads.

## Tile interface

Parameters `ROWS`, `COLS`, and `INNER_DIM` describe
`C[ROWS][COLS] = A[ROWS][INNER_DIM] * B[INNER_DIM][COLS]`.
All dimensions, widths, and `TILE_COUNT` must be positive. Use
`ACC_WIDTH >= 2 * DATA_WIDTH` to retain a full product, and an `ADDR_WIDTH`
large enough for `TILE_COUNT`. Extra accumulator bits are needed to avoid
overflow when summing products. Dimensions are fixed at elaboration time.

1. Assert synchronous `clear` for at least one rising edge before use. It
   aborts an active operation and clears the array and all stored output tiles.
2. While `busy` is low, present `matrix_a`, `matrix_b`, `write_addr`, and
   `accumulate`, then assert `start`. `accept` is a combinational handshake:
   capture occurs on a rising edge with `accept` high. It is high only when
   idle, `start` is high, `clear` is low, and the destination is in range.
3. Inputs may change after that edge. Both matrices and write controls are
   latched. Starts while busy and invalid destinations are ignored, not queued.
   Deassert `start` after acceptance; keeping it high starts another transaction
   when the controller returns to IDLE.
4. `busy` stays high through DONE. `done` is high for one cycle, immediately
   after the result is committed to the buffer. The following rising edge
   returns to IDLE; another request can be accepted on a subsequent edge.
5. To read, assert `read_en` with an in-range `read_addr`. After the rising
   edge, `read_valid` is high and `read_data` contains that tile. Without an
   accepted read, data holds and valid is low. Reads work while computing.
   A read on the same edge as a write to that address returns the old tile;
   a read sampled while `done` is high returns the committed result.

`accumulate=0` overwrites the selected tile with A*B. `accumulate=1` adds A*B
to its existing contents. For a larger inner dimension, submit successive
K slices to the same address: overwrite with the first partial product, then
accumulate subsequent products. Starting another operation clears only the
array, preserving the buffer and previously stored tiles.

This interface captures entire input matrices in registers. It has no DMA,
streaming backpressure, or external memory interface.

## Timing and dataflow

On enabled array step `t`, row `r` receives `A[r][t-r]` and column `c`
receives `B[t-c][c]`; out-of-range indices produce zero. The matching k-th
operands meet at PE `(r,c)` on step `k+r+c`.

COMPUTE runs `INNER_DIM + max(ROWS,COLS) - 1` cycles, including the skewed
input tails. DRAIN runs `min(ROWS,COLS) - 1` zero-input cycles. Total enabled
array cycles are `INNER_DIM + ROWS + COLS - 2`. STORE occurs on the next edge,
after the final MAC update is visible.

Counting the acceptance edge as cycle 0, DONE begins after
`INNER_DIM + ROWS + COLS` rising edges (12 for the default 4x4x4 operation).
This includes one array-clear cycle and one buffer-store cycle.

At the PE/array interface, `compute_en=0` holds operands and accumulators.
`accumulator_clear` clears only sums and takes priority over compute; `clear`
resets both sums and operand registers and has highest priority. A standalone
array caller must pause its input schedule when compute is disabled and flush
old operands before a new independent operation. The engine uses full array
clear between operations, independently of the buffer's global clear.

The old stationary-weight `weights_loaded` interface has been replaced by
`accumulator_clear` and `compute_en`. Both operands now advance during compute.

## Compilation

Compile SystemVerilog sources in the order listed in `rtl.f`, with
`tile_engine` as the top module. For example, with Verilator installed:

```sh
verilator --lint-only --top-module tile_engine -f rtl.f
```

## Arty A7-100T / MicroBlaze integration

`arty_top.sv` is an AXI4-Lite accelerator peripheral for your MicroBlaze
block design, not a standalone board pin top. It wraps `tile_engine` with
operand/result registers, a local repetition sequencer, and hardware cycle
counters. Compile the sources in `arty.f`. You provide the UART server,
clock/reset connections, address assignment, and FPGA build.

The [integration and benchmark guide](docs/benchmarking.md) includes the
register map, packet format, MicroBlaze adapter, Pi setup, and interpretation
of the measurements. `firmware/tiny_tpu_server.c` is a transport-independent
packet handler you can call from your existing UART server.

`tools/benchmark.py` checks signed matrix multiplication and measures FPGA
execution, UART round trips, NumPy CPU baselines, and an optional native C
CPU baseline. Results include median/p95 timings and reproducible JSON.

```sh
python -m pip install -r tools/requirements.txt
python tools/benchmark.py --port /dev/serial/by-id/YOUR_UART_DEVICE \
    --repetitions 10000 --samples 20 --output results/pi.json
```

Run host protocol tests with `python -m unittest discover -s tests -v`.
`tests/arty_axi_tb.sv` is a register-level simulation testbench for you to run
in your simulator; hardware implementation and timing closure are separate
validation steps.
