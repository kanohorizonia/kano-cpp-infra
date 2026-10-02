#!/usr/bin/env python3
"""Focused bootstrap containment tests; run with an existing Python 3."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location(
    "watchdog_bootstrap", Path(__file__).resolve().parents[1] / "lib" / "watchdog-bootstrap.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class BootstrapContract(unittest.TestCase):
    def run_command(self, text, timeout=2):
        buffers = [bytearray(), bytearray()]
        runner = bootstrap.run_windows if os.name == "nt" else bootstrap.run_posix
        result = runner([sys.executable, "-c", text], timeout, 0.5, buffers)
        return result, buffers

    def test_success(self):
        (code, complete, truncated, elapsed), buffers = self.run_command("print('success')")
        self.assertEqual(code, 0)
        self.assertTrue(complete)
        self.assertFalse(truncated)
        self.assertIn(b"success", buffers[0])
        self.assertLess(elapsed, 2.5)

    def test_timeout(self):
        (code, complete, _, elapsed), _ = self.run_command("import time; time.sleep(30)", 0.1)
        self.assertEqual(code, 124)
        self.assertTrue(complete)
        self.assertLess(elapsed, 0.7)

    def test_bounded_capture(self):
        (code, complete, truncated, _), buffers = self.run_command(
            "import sys; sys.stdout.write('x'*2097152)")
        self.assertEqual(code, 0)
        self.assertTrue(complete)
        self.assertTrue(truncated)
        self.assertEqual(len(buffers[0]), bootstrap.CAPTURE_LIMIT)

    @unittest.skipIf(os.name == "nt", "POSIX process-group ownership requires a POSIX host")
    def test_group_kill_precedes_leader_reap(self):
        spawned = []
        kills = []
        original_popen = subprocess.Popen
        original_killpg = os.killpg

        def record_spawn(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            spawned.append(process)
            return process

        def check_kill(group, requested_signal):
            if requested_signal == signal.SIGKILL:
                self.assertIsNone(spawned[0].returncode)
                kills.append(group)
            return original_killpg(group, requested_signal)

        with mock.patch.object(bootstrap.subprocess, "Popen", side_effect=record_spawn), \
                mock.patch.object(bootstrap.os, "killpg", side_effect=check_kill):
            (code, complete, _, _), _ = self.run_command("print('early-exit')")
        self.assertEqual(code, 0)
        self.assertTrue(complete)
        self.assertEqual(kills, [spawned[0].pid])

    @unittest.skipIf(os.name == "nt", "POSIX process-group setup requires a POSIX host")
    def test_selector_setup_failure_cleans_spawned_child(self):
        spawned = []
        original_popen = subprocess.Popen

        def record_spawn(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            spawned.append(process)
            return process

        diagnostics = io.StringIO()
        arguments = ["watchdog-bootstrap.py", "--timeout-ms", "2000", "--cleanup-timeout-ms", "500",
                     "--", sys.executable, "-c", "import time; time.sleep(30)"]
        with mock.patch.object(bootstrap.subprocess, "Popen", side_effect=record_spawn), \
                mock.patch.object(bootstrap.selectors, "DefaultSelector", side_effect=OSError("injected selector failure")), \
                mock.patch.object(sys, "argv", arguments), contextlib.redirect_stderr(diagnostics):
            self.assertEqual(bootstrap.main(), 125)
        self.assertEqual(len(spawned), 1)
        self.assertIsNotNone(spawned[0].poll())
        with self.assertRaises(ProcessLookupError):
            os.killpg(spawned[0].pid, 0)
        self.assertIn("cleanup-unverified", diagnostics.getvalue())


if __name__ == "__main__":
    unittest.main()
