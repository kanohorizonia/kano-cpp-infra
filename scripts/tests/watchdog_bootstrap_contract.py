#!/usr/bin/env python3
"""Focused bootstrap containment tests; run with an existing Python 3."""
import contextlib
import ctypes
import errno
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
import time
import types
import unittest
from unittest import mock

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location(
    "watchdog_bootstrap", Path(__file__).resolve().parents[1] / "lib" / "watchdog-bootstrap.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class BootstrapContract(unittest.TestCase):
    def darwin_observer(self, callback):
        library = types.SimpleNamespace(waitid=mock.Mock(side_effect=callback))
        with mock.patch.object(sys, "platform", "darwin"), \
                mock.patch.object(bootstrap.ctypes, "CDLL", return_value=library) as load:
            observer = bootstrap.darwin_exit_observer()
        load.assert_called_once_with(None, use_errno=True)
        return observer, library.waitid

    def test_darwin_waitid_abi_and_exit(self):
        calls = []

        def waitid(kind, pid, pointer, flags):
            info = ctypes.cast(pointer, ctypes.POINTER(bootstrap.DarwinSiginfo)).contents
            self.assertEqual(bytes(info), bytes(104))
            calls.append((kind, pid, flags))
            info.pid, info.code, info.status = pid, 1, 17
            return 0

        observer, native = self.darwin_observer(waitid)
        self.assertEqual(observer(123), 17)
        self.assertEqual(observer(123), 17)  # Each call has fresh zeroed storage.
        self.assertEqual(calls, [(1, 123, 37)] * 2)
        self.assertEqual(native.restype, ctypes.c_int)
        self.assertEqual(len(native.argtypes), 4)

    def test_darwin_waitid_signal_and_no_status(self):
        def waitid(kind, pid, pointer, flags):
            info = ctypes.cast(pointer, ctypes.POINTER(bootstrap.DarwinSiginfo)).contents
            info.pid, info.code, info.status = pid, 2, 9
            return 0
        observer, _ = self.darwin_observer(waitid)
        self.assertEqual(observer(123), -9)
        observer, _ = self.darwin_observer(lambda *args: 0)
        self.assertIsNone(observer(123))

    def test_darwin_waitid_errors(self):
        for requested_errno in (errno.EINTR, errno.ECHILD):
            def fail(*args):
                ctypes.set_errno(requested_errno)
                return -1
            observer, _ = self.darwin_observer(fail)
            if requested_errno == errno.EINTR:
                self.assertIsNone(observer(123))
            else:
                with self.assertRaises(OSError) as raised:
                    observer(123)
                self.assertEqual(raised.exception.errno, errno.ECHILD)

    def test_darwin_missing_python_api_selects_libc(self):
        # Replacing the module avoids assuming the development host has waitid.
        with mock.patch.object(bootstrap, "os", types.SimpleNamespace()), \
                mock.patch.object(bootstrap, "darwin_exit_observer", return_value="observer") as fallback:
            self.assertEqual(bootstrap.posix_exit_observer(), "observer")
        fallback.assert_called_once_with()

    def test_unsupported_observer_fails_before_spawn(self):
        with mock.patch.object(bootstrap, "os", types.SimpleNamespace()), \
                mock.patch.object(sys, "platform", "unsupported"), \
                mock.patch.object(bootstrap.subprocess, "Popen") as spawn:
            with self.assertRaises(RuntimeError):
                bootstrap.run_posix(["unused"], 1, 0.5, [bytearray(), bytearray()])
        spawn.assert_not_called()
        with mock.patch.object(sys, "platform", "darwin"), \
                mock.patch.object(bootstrap.ctypes, "sizeof", return_value=4), \
                mock.patch.object(bootstrap.ctypes, "CDLL") as load:
            with self.assertRaises(RuntimeError):
                bootstrap.darwin_exit_observer()
        load.assert_not_called()

    def test_darwin_missing_libc_symbol_fails_before_spawn(self):
        with mock.patch.object(bootstrap, "os", types.SimpleNamespace()), \
                mock.patch.object(sys, "platform", "darwin"), \
                mock.patch.object(bootstrap.ctypes, "CDLL", return_value=object()), \
                mock.patch.object(bootstrap.subprocess, "Popen") as spawn:
            with self.assertRaisesRegex(RuntimeError, "libc waitid"):
                bootstrap.run_posix(["unused"], 1, 0.5, [bytearray(), bytearray()])
        spawn.assert_not_called()

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
        events = []
        original_popen = subprocess.Popen
        original_killpg = os.killpg

        def record_spawn(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            spawned.append(process)
            original_wait = process.wait
            def check_wait(*wait_args, **wait_kwargs):
                events.append("wait")
                self.assertIn("kill", events)
                return original_wait(*wait_args, **wait_kwargs)
            process.wait = check_wait
            return process

        def check_kill(group, requested_signal):
            if requested_signal == signal.SIGKILL:
                self.assertIsNone(spawned[0].returncode)
                kills.append(group)
                events.append("kill")
            return original_killpg(group, requested_signal)

        with mock.patch.object(bootstrap.subprocess, "Popen", side_effect=record_spawn), \
                mock.patch.object(bootstrap.os, "killpg", side_effect=check_kill):
            (code, complete, _, _), _ = self.run_command("print('early-exit')")
        self.assertEqual(code, 0)
        self.assertTrue(complete)
        self.assertEqual(kills, [spawned[0].pid])
        self.assertEqual(events[0], "kill")

    @unittest.skipIf(os.name == "nt", "POSIX group probes require a POSIX host")
    def test_darwin_deferred_permission_requires_empty_group(self):
        original_killpg = os.killpg
        for remains_denied in (False, True):
            with self.subTest(remains_denied=remains_denied):
                kills = []
                def signal_group(group, requested_signal):
                    if requested_signal == signal.SIGKILL:
                        kills.append(group)
                        raise PermissionError(errno.EPERM, "injected zombie-only or denied group")
                    if remains_denied:
                        raise PermissionError(errno.EPERM, "injected denied live member")
                    return original_killpg(group, requested_signal)
                with mock.patch.object(sys, "platform", "darwin"), \
                        mock.patch.object(bootstrap.os, "killpg", side_effect=signal_group):
                    (code, complete, _, elapsed), _ = self.run_command("pass")
                self.assertEqual(code, 125 if remains_denied else 0)
                self.assertEqual(complete, not remains_denied)
                self.assertEqual(len(kills), 1)
                self.assertLess(elapsed, 0.8)

    @unittest.skipIf(os.name == "nt", "POSIX observer cleanup requires a POSIX host")
    def test_observer_failure_cleans_spawned_child(self):
        spawned = []
        original_popen = subprocess.Popen
        def record_spawn(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            spawned.append(process)
            return process
        with mock.patch.object(bootstrap.subprocess, "Popen", side_effect=record_spawn), \
                mock.patch.object(bootstrap, "posix_exit_observer", return_value=mock.Mock(side_effect=OSError(errno.EIO, "injected observer failure"))):
            with self.assertRaises(OSError):
                self.run_command("import time; time.sleep(30)")
        self.assertIsNotNone(spawned[0].returncode)
        with self.assertRaises(ProcessLookupError):
            os.killpg(spawned[0].pid, 0)

    @unittest.skipIf(os.name == "nt", "POSIX setup-exit race requires a POSIX host")
    def test_darwin_setup_exit_race_reaps_reserved_leader(self):
        spawned = []
        original_popen = subprocess.Popen
        observe = bootstrap.posix_exit_observer()
        original_killpg = os.killpg
        kills = []
        def record_spawn(*args, **kwargs):
            child = original_popen(*args, **kwargs)
            spawned.append(child)
            return child
        def fail_setup():
            deadline = time.monotonic() + 1
            while observe(spawned[0].pid) is None:
                if time.monotonic() >= deadline:
                    raise AssertionError("fixture did not exit before setup failure")
                time.sleep(0.001)
            raise OSError(errno.EIO, "injected setup failure after leader exit")
        def signal_group(group, requested_signal):
            if requested_signal == signal.SIGKILL:
                self.assertIsNone(spawned[0].returncode)
                kills.append(group)
                raise PermissionError(errno.EPERM, "injected Darwin zombie-only group")
            return original_killpg(group, requested_signal)
        with mock.patch.object(sys, "platform", "darwin"), \
                mock.patch.object(bootstrap.subprocess, "Popen", side_effect=record_spawn), \
                mock.patch.object(bootstrap.selectors, "DefaultSelector", side_effect=fail_setup), \
                mock.patch.object(bootstrap.os, "killpg", side_effect=signal_group):
            with self.assertRaisesRegex(OSError, "setup failure"):
                self.run_command("pass")
        self.assertEqual(spawned[0].returncode, 0)
        self.assertEqual(kills, [spawned[0].pid])
        with self.assertRaises(ProcessLookupError):
            os.killpg(spawned[0].pid, 0)

    @unittest.skipIf(os.name == "nt", "POSIX descendant ownership requires a POSIX host")
    def test_descendant_cleanup_preserves_unrelated_process(self):
        sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for early_exit in (False, True):
                for close_capture in (False, True):
                    with self.subTest(early_exit=early_exit, close_capture=close_capture):
                        source = (
                            "import os,time,json\n"
                            "r,w=os.pipe()\n"
                            "child=os.fork()\n"
                            "if child==0:\n"
                            " os.close(r)\n"
                            + (" os.close(1); os.close(2)\n" if close_capture else "") +
                            " grandchild=os.fork()\n"
                            " if grandchild==0:\n"
                            "  os.close(w); time.sleep(30); os._exit(0)\n"
                            " os.write(w,str(grandchild).encode()); os.close(w); time.sleep(30); os._exit(0)\n"
                            "os.close(w); grandchild=int(os.read(r,64)); os.close(r)\n"
                            "print(json.dumps({'root':os.getpid(),'child':child,'grandchild':grandchild}),flush=True)\n"
                            + ("os._exit(0)\n" if early_exit else "time.sleep(30)\n"))
                        (code, complete, _, elapsed), buffers = self.run_command(source, 0.3)
                        self.assertEqual(code, 0 if early_exit else 124)
                        self.assertTrue(complete)
                        self.assertLess(elapsed, 0.9)
                        identities = json.loads(buffers[0])
                        for pid in identities.values():
                            with self.assertRaises(ProcessLookupError):
                                os.kill(pid, 0)
                        self.assertIsNone(sentinel.poll())
        finally:
            sentinel.terminate()
            sentinel.wait(timeout=2)

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
