from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "profile_run_capabilities.py"


class ProfileRunCapabilitiesTests(unittest.TestCase):
    def run_manifest(self, *args: str, expect_ok: bool = True):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "manifest.json"
            cmd = [sys.executable, str(SCRIPT), *args, "--out", str(out)]
            proc = subprocess.run(cmd, capture_output=True, text=True)
            if expect_ok:
                self.assertEqual(proc.returncode, 0, msg=proc.stderr)
                self.assertTrue(out.exists())
                return json.loads(out.read_text(encoding="utf-8"))
            self.assertNotEqual(proc.returncode, 0)
            return proc

    def test_msvc_opencppcoverage_msvcpgo_unified_allowed(self):
        data = self.run_manifest(
            "--compiler", "msvc",
            "--coverage-provider", "opencppcoverage",
            "--pgo-provider", "msvc-pgo",
            "--profile-run-mode", "pgo-gather-with-coverage",
        )
        self.assertTrue(data["unifiedExecution"])
        self.assertFalse(data["unifiedProfileData"])
        self.assertEqual(data["coverageSubject"], "pgo-instrumented-training-binary")

    def test_msvc_microsoft_msvcpgo_unified_rejected(self):
        proc = self.run_manifest(
            "--compiler", "msvc",
            "--coverage-provider", "microsoft-codecoverage",
            "--pgo-provider", "msvc-pgo",
            "--profile-run-mode", "pgo-gather-with-coverage",
            expect_ok=False,
        )
        self.assertIn(
            "MSVC unified PGO+coverage execution is only supported with OpenCppCoverage.",
            proc.stderr,
        )
        self.assertIn(
            "Microsoft.CodeCoverage.Console coverage output is not MSVC PGO training data.",
            proc.stderr,
        )

    def test_microsoft_server_mode_local_session_only(self):
        data = self.run_manifest(
            "--compiler", "msvc",
            "--coverage-provider", "microsoft-codecoverage",
            "--pgo-provider", "none",
            "--profile-run-mode", "coverage-all",
            "--microsoft-server-mode",
        )
        self.assertEqual(data["collectorScope"], "local-session-server")
        self.assertFalse(data["remoteTelemetry"])
        self.assertFalse(data["realUserProfile"])
        self.assertFalse(data["unifiedExecution"])
        self.assertFalse(data["unifiedProfileData"])

    def test_clang_llvm_unified_profile_data(self):
        data = self.run_manifest(
            "--compiler", "clang",
            "--coverage-provider", "llvm-cov",
            "--pgo-provider", "llvm-profdata",
            "--profile-run-mode", "pgo-gather-with-coverage",
        )
        self.assertTrue(data["unifiedExecution"])
        self.assertTrue(data["unifiedProfileData"])

    def test_split_lanes_allow_missing_other_provider(self):
        coverage = self.run_manifest(
            "--compiler", "msvc",
            "--coverage-provider", "opencppcoverage",
            "--pgo-provider", "none",
            "--profile-run-mode", "coverage-all",
        )
        self.assertTrue(coverage["splitLanes"])
        pgo = self.run_manifest(
            "--compiler", "msvc",
            "--coverage-provider", "none",
            "--pgo-provider", "msvc-pgo",
            "--profile-run-mode", "pgo-gather",
        )
        self.assertTrue(pgo["splitLanes"])


if __name__ == "__main__":
    unittest.main()
