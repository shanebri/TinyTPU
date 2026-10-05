"""Correctness and timing on a Raspberry Pi or any serial-connected host."""
import argparse
import json
import os
import platform
from pathlib import Path
import random
import statistics
import subprocess
import time

import numpy as np

from protocol import Client, MAX_REPETITIONS, reference


def summary(samples):
    ordered = sorted(samples)
    median = statistics.median(samples)
    return {"unit": "ns/tile", "samples": len(samples), "raw_ns_per_tile": samples,
            "integer_gops_at_median": 128/median if median else None,
            "median": median, "mean": statistics.mean(samples),
            "p95": float(np.percentile(ordered, 95)), "min": min(samples), "max": max(samples)}


def vectors(count, seed):
    rng = random.Random(seed)
    yield [0]*16, [127]*16
    yield [-128]*16, [-128]*16
    yield [127]*16, [-128]*16
    yield [int(r == c) for r in range(4) for c in range(4)], list(range(-8, 8))
    yield [-128, 127, -1, 0]*4, [127, 0, -128, 1]*4
    for _ in range(count):
        yield [rng.randrange(-128, 128) for _ in range(16)], [rng.randrange(-128, 128) for _ in range(16)]


def check(result, a, b):
    expected = reference(a, b)
    if result.values != expected:
        raise AssertionError(f"FPGA mismatch: expected {expected}, received {result.values}")
    # Protocol v1 targets this specific engine and wrapper schedule.
    if result.kernel_cycles != 12 or result.batch_cycles != 14*result.repetitions-2:
        raise AssertionError(f"unexpected engine timing: {result}")


def numpy_baselines(a, b, args):
    # Promote BEFORE multiplying: int8 @ int8 would overflow at int8 width.
    aa = np.array(a, dtype=np.int32).reshape(4, 4)
    bb = np.array(b, dtype=np.int32).reshape(4, 4)
    out = np.empty((4, 4), dtype=np.int32)
    expected = np.array(reference(a, b), dtype=np.int32).reshape(4, 4)
    for _ in range(args.warmup):
        np.matmul(aa, bb, out=out)
    single, repeated, batched = [], [], []
    # Contiguous stacks of the same resident tile, allocated outside timing.
    stack_a = np.repeat(aa[None], args.repetitions, axis=0)
    stack_b = np.repeat(bb[None], args.repetitions, axis=0)
    stack_out = np.empty_like(stack_a)
    for _ in range(args.warmup):
        np.matmul(stack_a, stack_b, out=stack_out)
    for _ in range(args.samples):
        start = time.perf_counter_ns()
        np.matmul(aa, bb, out=out)
        single.append(time.perf_counter_ns()-start)
        start = time.perf_counter_ns()
        for _ in range(args.repetitions):
            np.matmul(aa, bb, out=out)
        repeated.append((time.perf_counter_ns()-start)/args.repetitions)
        start = time.perf_counter_ns()
        np.matmul(stack_a, stack_b, out=stack_out)
        batched.append((time.perf_counter_ns()-start)/args.repetitions)
        np.testing.assert_array_equal(out, expected)
        np.testing.assert_array_equal(stack_out, np.broadcast_to(expected, stack_out.shape))
    return {"numpy_single_call": summary(single),
            "numpy_python_loop_resident": summary(repeated),
            "numpy_batched_int32": summary(batched)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="e.g. /dev/serial/by-id/... or COM5")
    parser.add_argument("--cpu-only", action="store_true", help="run CPU baselines without FPGA")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=5)
    parser.add_argument("--repetitions", type=int, default=10000)
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--random-tests", type=int, default=32)
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--native", help="path to compiled tools/cpu_benchmark executable")
    parser.add_argument("--output", default="results/benchmark.json")
    args = parser.parse_args()
    if not args.cpu_only and not args.port:
        parser.error("specify --port or --cpu-only")
    if args.samples < 1 or args.warmup < 0 or args.random_tests < 0 or not 1 <= args.repetitions <= MAX_REPETITIONS or args.baud <= 0 or args.timeout <= 0:
        parser.error("invalid count, baud, or timeout")
    rng = random.Random(args.seed)
    a, b = ([rng.randrange(-128, 128) for _ in range(16)] for _ in range(2))
    report = {"schema_version": 1, "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "host": {"platform": platform.platform(), "machine": platform.machine(),
                       "processor": platform.processor(), "python": platform.python_version(),
                       "numpy": np.__version__, "thread_environment": {k: os.getenv(k) for k in
                           ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS")}},
              "settings": vars(args), "workload": {"a": a, "b": b, "result": reference(a, b),
                  "shape": [4, 4, 4], "operand": "signed int8", "accumulator": "signed int32",
                  "macs_per_tile": 64, "integer_ops_per_tile": 128},
              "metrics": {}}
    cpuinfo = Path("/proc/cpuinfo")
    if cpuinfo.exists():
        report["host"]["cpu_model"] = [line.strip() for line in cpuinfo.read_text().splitlines()
                                        if line.startswith(("Model", "model name", "Hardware"))]
    client = None
    try:
        if not args.cpu_only:
            client = Client(args.port, args.baud, args.timeout)
            cases = list(vectors(args.random_tests, args.seed))
            for va, vb in cases:
                check(client.run(va, vb), va, vb)
            report["correctness"] = {"passed": len(cases), "seed": args.seed}
            for _ in range(args.warmup):
                check(client.run(a, b, 1), a, b)
                check(client.run(a, b, args.repetitions), a, b)
            single, batch_host, kernel, batch_fpga = [], [], [], []
            for _ in range(args.samples):
                start = time.perf_counter_ns()
                result = client.run(a, b, 1)
                single.append(time.perf_counter_ns()-start)
                check(result, a, b)
                start = time.perf_counter_ns()
                result = client.run(a, b, args.repetitions)
                batch_host.append((time.perf_counter_ns()-start)/args.repetitions)
                check(result, a, b)
                kernel.append(result.kernel_cycles*1e9/result.clock_hz)
                batch_fpga.append(result.batch_cycles*1e9/result.clock_hz/args.repetitions)
            report["fpga"] = {"clock_hz": result.clock_hz, "kernel_cycles": result.kernel_cycles,
                              "batch_cycles": result.batch_cycles,
                              "payload_wire_floor_ns": 138*10*1e9/args.baud}
            report["metrics"].update({"fpga_kernel_latency": summary(kernel),
                "fpga_resident_batch": summary(batch_fpga),
                "uart_single_round_trip": summary(single),
                "uart_resident_batch_amortized": summary(batch_host)})
        report["metrics"].update(numpy_baselines(a, b, args))
        if args.native:
            raw = subprocess.run([str(Path(args.native).resolve()), str(args.repetitions),
                                  str(args.samples), str(args.warmup)],
                                 input=bytes(x & 255 for x in a+b), capture_output=True, check=True)
            native = json.loads(raw.stdout)
            if tuple(native["result"]) != reference(a, b):
                raise AssertionError("native CPU result mismatch")
            report["native"] = native
            report["metrics"]["native_c_resident"] = summary(native["ns_per_tile"])
        if client:
            cpu = report["metrics"].get("native_c_resident", report["metrics"]["numpy_batched_int32"])["median"]
            report["ratios"] = {"cpu_over_fpga_resident_time": cpu/report["metrics"]["fpga_resident_batch"]["median"],
                "numpy_single_over_uart_single_time": report["metrics"]["numpy_single_call"]["median"]/report["metrics"]["uart_single_round_trip"]["median"]}
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2)+"\n")
        for name, metric in report["metrics"].items():
            print(f"{name:36s} {metric['median']:12.1f} ns/tile (median)")
        print(f"Saved {output}")
    finally:
        if client:
            client.close()


if __name__ == "__main__":
    main()
