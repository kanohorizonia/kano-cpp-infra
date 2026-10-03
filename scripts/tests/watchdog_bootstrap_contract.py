#!/usr/bin/env python3
"""Focused bootstrap containment tests; run with an existing Python 3."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location(
    "watchdog_bootstrap", Path(__file__).resolve().parents[1] / "lib" / "watchdog-bootstrap.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class BootstrapContract(unittest.TestCase):
    def check_windows_argv(self, executable, bash=False):
        # This is the collector regression vector plus trailing-backslash and
        # Unicode cases. A real child reads argv; no serializer mirror is used.
        expected = ['target executable', '', 'white space', 'quote"value', 'literal; shell',
                    '$(shell)', 'back`tick', '&pipe|', 'trailing\\', 'quote"tail\\',
                    'slashes\\\\"quote\\\\', 'ÃƒÂ¥Ã‚ÂµÃ…â€™ÃƒÂ¥Ã¢â‚¬Â¦Ã‚Â¥"ÃƒÂ¥Ã‚Â¼Ã¢â‚¬Â¢ÃƒÂ¨Ã¢â€žÂ¢Ã…Â¸\\', 'ÃƒÅ½Ã‚Â» whitespace ÃƒÂ¥Ã‚Â°Ã‚Â¾\\']
        scratch_root = Path(bootstrap.__file__).resolve().parents[2] / "build" / "bootstrap-argv-contracts"
        scratch_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="argv space-", dir=scratch_root) as scratch:
            capture = Path(scratch) / "argv.bin"
            script = Path(scratch) / ("echo-argv.sh" if bash else "echo-argv.py")
            if bash:
                script.write_bytes(b'#!/usr/bin/env bash\nprintf \'%s\\0\' "$@" >"$KANO_BOOTSTRAP_ARGV_CAPTURE"\n')
            else:
                script.write_text('import json,os,sys\nfrom pathlib import Path\n'
                                  'Path(os.environ["KANO_BOOTSTRAP_ARGV_CAPTURE"]).write_text('
                                  'json.dumps(sys.argv[1:]),encoding="utf-8")\n', encoding="utf-8")
            with mock.patch.dict(os.environ, {"KANO_BOOTSTRAP_ARGV_CAPTURE": str(capture)}):
                buffers = [bytearray(), bytearray()]
                code, complete, truncated, elapsed = bootstrap.run_windows(
                    [executable, str(script)] + expected, 5, 0.5, buffers)
            self.assertEqual(code, 0, bytes(buffers[1]).decode(errors="replace"))
            self.assertTrue(complete)
            self.assertFalse(truncated)
            self.assertLess(elapsed, 5.5)
            actual = ([value.decode("utf-8") for value in capture.read_bytes().split(b"\0")[:-1]]
                      if bash else json.loads(capture.read_text(encoding="utf-8")))
            self.assertEqual(actual, expected)

    @unittest.skipUnless(os.name == "nt", "Windows CRT argv requires a Windows host")
    def test_windows_crt_argv(self):
        self.check_windows_argv(sys.executable)

    @unittest.skipUnless(os.name == "nt", "MSYS argv requires a Windows host")
    def test_windows_bash_argv(self):
        def is_msys_bash(candidate):
            path = Path(candidate)
            runtime_paths = (path.parent / "msys-2.0.dll", path.parent.parent / "usr/bin/msys-2.0.dll")
            return path.name.lower() in ("bash.exe", "bash") and path.is_absolute() and path.is_file() and any(runtime.is_file() for runtime in runtime_paths)

        configured = os.environ.get("KANO_TEST_BASH")
        if configured:
            self.assertTrue(is_msys_bash(configured), "KANO_TEST_BASH must identify an existing native MSYS Bash")
            executable = configured
        else:
            candidates = []
            current_bash = os.environ.get("BASH")
            if current_bash:
                candidates.append(current_bash)
            git = shutil.which("git.exe")
            if git:
                git_root = Path(git).parent.parent
                candidates.extend(str(git_root / relative) for relative in ("bin/bash.exe", "usr/bin/bash.exe"))
            path_bash = shutil.which("bash.exe") or shutil.which("bash")
            if path_bash and not any(part.lower() in ("system32", "windowsapps") for part in Path(path_bash).parts):
                candidates.append(path_bash)
            executable = next((candidate for candidate in candidates if is_msys_bash(candidate)), None)
            if executable is None:
                self.skipTest("MSYS Git Bash is unavailable; WSL shims are excluded and no dependency is installed")
        self.check_windows_argv(executable, bash=True)

    @unittest.skipUnless(os.name == "nt", "cmd payload parsing requires a Windows host")
    def test_windows_cmd_exit(self):
        buffers = [bytearray(), bytearray()]
        code, complete, _, elapsed = bootstrap.run_windows(
            [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", "exit /b 17"], 2, 0.5, buffers)
        self.assertEqual(code, 17, bytes(buffers[1]).decode(errors="replace"))
        self.assertTrue(complete)
        self.assertLess(elapsed, 2.5)

    @unittest.skipUnless(os.name == "nt", "PowerShell argv requires a Windows host")
    def test_windows_powershell_exit(self):
        executable = shutil.which("powershell.exe") or shutil.which("pwsh.exe")
        if executable is None:
            self.skipTest("PowerShell is not installed; no dependency is installed by this fixture")
        buffers = [bytearray(), bytearray()]
        code, complete, _, elapsed = bootstrap.run_windows(
            [executable, "-NoProfile", "-NonInteractive", "-Command", "exit 0"], 5, 0.5, buffers)
        self.assertEqual(code, 0, bytes(buffers[1]).decode(errors="replace"))
        self.assertTrue(complete)
        self.assertLess(elapsed, 5.5)

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
