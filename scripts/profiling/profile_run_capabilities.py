#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import List

REQUIRED_MSVC_MESSAGE = (
    "MSVC unified PGO+coverage execution is only supported with OpenCppCoverage. "
    "Microsoft.CodeCoverage.Console coverage output is not MSVC PGO training data."
)


@dataclass
class ProfileRunManifest:
    schemaVersion: str
    profileRunMode: str
    compiler: str
    coverageProvider: str
    pgoProvider: str
    unifiedExecution: bool
    unifiedProfileData: bool
    splitLanes: bool
    coverageSubject: str
    collectorScope: str
    remoteTelemetry: bool
    realUserProfile: bool
    pgoDataPaths: List[str]
    coverageReportPaths: List[str]
    trainingCommand: str
    coverageCommand: str
    notes: List[str]


def _csv(value: str) -> List[str]:
    if not value:
        return []
    return [p.strip() for p in value.split(",") if p.strip()]


def _resolve_defaults(args: argparse.Namespace) -> argparse.Namespace:
    if not args.compiler:
        args.compiler = os.environ.get("KANO_CXX_COMPILER", "") or "msvc"
    if not args.coverage_provider:
        args.coverage_provider = os.environ.get("KANO_CXX_COVERAGE_PROVIDER", "") or "none"
    if not args.pgo_provider:
        args.pgo_provider = os.environ.get("KANO_CXX_PGO_PROVIDER", "") or "none"
    if not args.profile_run_mode:
        args.profile_run_mode = os.environ.get("KANO_CXX_PROFILE_RUN_MODE", "") or "pgo-rebuild"

    args.compiler = args.compiler.lower()
    args.coverage_provider = args.coverage_provider.lower()
    args.pgo_provider = args.pgo_provider.lower()
    args.profile_run_mode = args.profile_run_mode.lower()

    return args


def resolve_manifest(args: argparse.Namespace) -> ProfileRunManifest:
    compiler = args.compiler
    coverage_provider = args.coverage_provider
    pgo_provider = args.pgo_provider
    mode = args.profile_run_mode

    notes: List[str] = []
    unified_execution = False
    unified_profile_data = False
    split_lanes = True
    coverage_subject = "normal-test-binary"
    collector_scope = "none"

    if mode == "pgo-gather-with-coverage":
        split_lanes = False
        if compiler == "msvc" and coverage_provider == "opencppcoverage" and pgo_provider == "msvc-pgo":
            unified_execution = True
            unified_profile_data = False
            coverage_subject = "pgo-instrumented-training-binary"
            collector_scope = "process-wrapper"
            notes.append("MSVC training run wrapped by OpenCppCoverage; coverage output remains separate from .pgd/.pgc data.")
        elif compiler == "msvc" and coverage_provider == "microsoft-codecoverage" and pgo_provider == "msvc-pgo":
            raise ValueError(REQUIRED_MSVC_MESSAGE)
        elif compiler == "clang" and coverage_provider == "llvm-cov" and pgo_provider == "llvm-profdata":
            unified_execution = True
            unified_profile_data = True
            coverage_subject = "llvm-instrumented-binary"
            collector_scope = "process-wrapper"
            notes.append("LLVM source-based instrumentation provides shared profile data for coverage and PGO.")
        else:
            raise ValueError(
                f"Unsupported unified profile combination: compiler={compiler}, coverageProvider={coverage_provider}, pgoProvider={pgo_provider}"
            )
    elif mode == "coverage-all":
        split_lanes = True
        unified_execution = False
        unified_profile_data = False
        if coverage_provider == "microsoft-codecoverage":
            coverage_subject = "instrumented-coverage-binary"
            collector_scope = "local-session-server" if args.microsoft_server_mode else "process-wrapper"
            if args.microsoft_server_mode:
                notes.append(
                    "Microsoft.CodeCoverage.Console server-mode is local/session detached collection, not remote telemetry."
                )
        elif coverage_provider == "opencppcoverage":
            coverage_subject = "normal-test-binary"
            collector_scope = "process-wrapper"
        elif coverage_provider == "llvm-cov":
            coverage_subject = "llvm-instrumented-binary"
            collector_scope = "process-wrapper"
        else:
            coverage_subject = "normal-test-binary"
            collector_scope = "none"
    elif mode in ("pgo-gather", "pgo-rebuild"):
        split_lanes = True
        unified_execution = False
        unified_profile_data = False
        coverage_subject = "normal-test-binary"
        collector_scope = "none"
        notes.append("PGO lane only; coverage reports are not treated as training data.")
    else:
        raise ValueError(f"Unsupported profile run mode: {mode}")

    if coverage_provider == "microsoft-codecoverage" and args.microsoft_server_mode and mode != "coverage-all":
        notes.append("microsoftServerMode requested outside coverage-all; collectorScope remains mode-derived.")

    manifest = ProfileRunManifest(
        schemaVersion="1.0",
        profileRunMode=mode,
        compiler=compiler,
        coverageProvider=coverage_provider,
        pgoProvider=pgo_provider,
        unifiedExecution=unified_execution,
        unifiedProfileData=unified_profile_data,
        splitLanes=split_lanes,
        coverageSubject=coverage_subject,
        collectorScope=collector_scope,
        remoteTelemetry=False,
        realUserProfile=False,
        pgoDataPaths=_csv(args.pgo_data_paths),
        coverageReportPaths=_csv(args.coverage_report_paths),
        trainingCommand=args.training_command or "",
        coverageCommand=args.coverage_command or "",
        notes=notes,
    )
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resolve C++ coverage/PGO profile run capabilities and emit manifest JSON")
    parser.add_argument("--compiler", default="")
    parser.add_argument("--coverage-provider", default="")
    parser.add_argument("--pgo-provider", default="")
    parser.add_argument("--profile-run-mode", default="")
    parser.add_argument("--microsoft-server-mode", action="store_true")
    parser.add_argument("--pgo-data-paths", default="")
    parser.add_argument("--coverage-report-paths", default="")
    parser.add_argument("--training-command", default="")
    parser.add_argument("--coverage-command", default="")
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def main() -> int:
    args = _resolve_defaults(parse_args())
    out_path = Path(args.out)
    try:
        manifest = resolve_manifest(args)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(asdict(manifest), indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
