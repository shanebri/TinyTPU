import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import benchmark
from protocol import Result, reference


class BenchmarkTests(unittest.TestCase):
    def test_cpu_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "cpu.json"
            argv = ["benchmark.py", "--cpu-only", "--samples", "2", "--warmup", "1",
                    "--repetitions", "8", "--output", str(output)]
            with patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
                benchmark.main()
            report = json.loads(output.read_text())
            self.assertNotIn("fpga", report)
            self.assertEqual(report["workload"]["integer_ops_per_tile"], 128)
            self.assertEqual(len(report["metrics"]), 3)
            for metric in report["metrics"].values():
                self.assertEqual(metric["unit"], "ns/tile")
                self.assertEqual(len(metric["raw_ns_per_tile"]), 2)

    def test_host_workflow_with_fake_server(self):
        # Exercise host orchestration only; these synthetic times are never
        # published as hardware measurements or written outside this test.
        class Server:
            closed = False
            def __init__(self, *args): pass
            def run(self, a, b, repetitions=1):
                return Result(100000000, repetitions, 12, 14*repetitions-2, reference(a, b))
            def close(self): Server.closed = True
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "mock.json"
            argv = ["benchmark.py", "--port", "FAKE", "--samples", "2", "--warmup", "1",
                    "--repetitions", "8", "--random-tests", "3", "--output", str(output)]
            with patch.object(sys, "argv", argv), patch.object(benchmark, "Client", Server), contextlib.redirect_stdout(io.StringIO()):
                benchmark.main()
            report = json.loads(output.read_text())
            self.assertEqual(report["correctness"]["passed"], 8)
            self.assertEqual(report["fpga"]["kernel_cycles"], 12)
            self.assertEqual(report["metrics"]["fpga_kernel_latency"]["median"], 120)
            self.assertEqual(report["metrics"]["fpga_resident_batch"]["median"], 137.5)
            self.assertTrue(Server.closed)


if __name__ == "__main__":
    unittest.main()
