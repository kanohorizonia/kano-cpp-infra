#!/usr/bin/env bash
# ============================================================================
# PGO Gather Script - Unified PGO + Coverage Profile Collection
# ============================================================================
# Runs representative test suites with instrumentation to collect profile data
# for Profile-Guided Optimization (PGO) or code coverage analysis.
#
# USAGE:
#   ./pgo-gather.sh                    # Default: PGO mode
#   KANO_CPP_INFRA_PGO_GATHER_MODE=coverage ./pgo-gather.sh  # Coverage mode
#
# MODES:
#   pgo (default)  - Uses *-pgo-collect presets for PGO optimization profiling
#   coverage       - Uses *-coverage presets for code coverage instrumentation
#                    (unified gathering, produces both PGO and coverage reports)
#
# ENVIRONMENT VARIABLES:
#   KANO_CPP_INFRA_PGO_GATHER_MODE
#       Set to 'coverage' to use coverage presets instead of PGO presets.
#       Useful for obtaining complete test coverage data while gathering profiles.
#
#   KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET
#       Override the auto-detected preset name.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)}"

resolve_collect_preset() {
  local gather_mode="${KANO_CPP_INFRA_PGO_GATHER_MODE:-pgo}"
  
  if [[ -n "${KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET:-}" ]]; then
    printf '%s\n' "$KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET"
    return 0
  fi

  if [[ "$gather_mode" == "coverage" ]]; then
    # Use coverage presets to gather data (unified with PGO collect for comprehensive testing)
    if [[ "$(uname -s 2>/dev/null || true)" == MINGW* || "$(uname -s 2>/dev/null || true)" == MSYS* || "$(uname -s 2>/dev/null || true)" == CYGWIN* ]]; then
      printf '%s\n' "windows-ninja-msvc-coverage"
      return 0
    elif [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
      if [[ "$(uname -m 2>/dev/null || true)" == "arm64" ]]; then
        printf '%s\n' "macos-ninja-clang-arm64-coverage"
      else
        printf '%s\n' "macos-ninja-clang-x64-coverage"
      fi
      return 0
    fi
    printf '%s\n' "linux-ninja-clang-coverage"
    return 0
  fi

  # Default: PGO collect mode
  if [[ "$(uname -s 2>/dev/null || true)" == MINGW* || "$(uname -s 2>/dev/null || true)" == MSYS* || "$(uname -s 2>/dev/null || true)" == CYGWIN* ]]; then
    printf '%s\n' "windows-ninja-msvc-pgo-collect"
    return 0
  fi

  printf '%s\n' "linux-ninja-gcc-pgo-collect"
}

is_windows_host() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_windows_pgo_runtime_path() {
  if ! is_windows_host; then
    return 0
  fi

  if command -v where.exe >/dev/null 2>&1 && where.exe pgort140.dll >/dev/null 2>&1; then
    return 0
  fi

  local tool_bin
  shopt -s nullglob
  for tool_bin in /c/Program\ Files/Microsoft\ Visual\ Studio/*/*/VC/Tools/MSVC/*/bin/Hostx64/x64; do
    if [[ -f "$tool_bin/pgort140.dll" ]]; then
      export PATH="$tool_bin:$PATH"
      echo "[pgo-gather] added MSVC PGO runtime path: $tool_bin" >&2
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob

  echo "[pgo-gather] warning: pgort140.dll not found on PATH; some collect tests may fail to start" >&2
  return 0
}

# ─── Coverage helpers ────────────────────────────────────────────────────────

_has_opencppcoverage() {
  command -v OpenCppCoverage.exe >/dev/null 2>&1 || \
    [[ -x "/c/Program Files/OpenCppCoverage/OpenCppCoverage.exe" ]]
}

_has_reportgenerator() {
  command -v reportgenerator >/dev/null 2>&1
}

# Convert MSYS2/Unix path to Windows path for tools that need it.
_to_win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    # Fallback: convert /c/Foo → C:\Foo
    printf '%s' "$1" | sed 's|^/\([a-zA-Z]\)/|\1:\\|;s|/|\\|g'
  fi
}

# Run a test binary, optionally wrapping with OpenCppCoverage for coverage collection.
# Usage: _run_with_coverage <coverage_xml_out|""> <binary> [args...]
# When coverage_xml_out is non-empty and OpenCppCoverage is available the binary
# is executed under OpenCppCoverage --export-type cobertura.
# The child exit code is forwarded so callers can still detect test failures.
_run_with_coverage() {
  local coverage_out="$1"
  shift
  if [[ -n "$coverage_out" ]] && _has_opencppcoverage; then
    local occ_bin
    if command -v OpenCppCoverage.exe >/dev/null 2>&1; then
      occ_bin="$(command -v OpenCppCoverage.exe)"
    else
      occ_bin="/c/Program Files/OpenCppCoverage/OpenCppCoverage.exe"
    fi

    local src_win
    src_win="$(_to_win_path "$CPP_ROOT/code")"
    local cov_win
    cov_win="$(_to_win_path "$coverage_out")"

    # Extract binary (first arg) and convert its path; keep remaining args as-is.
    local binary="$1"; shift
    local binary_win
    binary_win="$(_to_win_path "$binary")"

    mkdir -p "$(dirname "$coverage_out")"
    "$occ_bin" \
      --sources "$src_win" \
      --export_type "cobertura:$cov_win" \
      --quiet \
      -- "$binary_win" "$@"
  else
    "$@"
  fi
}

# Generate HTML coverage report from all .cobertura.xml files in raw_dir.
generate_coverage_html() {
  local raw_dir="$1"
  local html_dir="$2"

  if ! _has_reportgenerator; then
    echo "[pgo-gather] skipping coverage HTML: reportgenerator not available" >&2
    return 0
  fi

  local -a xml_files=()
  while IFS= read -r -d '' f; do
    xml_files+=("$f")
  done < <(find "$raw_dir" -name "*.cobertura.xml" -type f -print0 2>/dev/null || true)

  if [[ ${#xml_files[@]} -eq 0 ]]; then
    echo "[pgo-gather] no .cobertura.xml files found; skipping coverage HTML" >&2
    return 0
  fi

  echo "[pgo-gather] generating coverage HTML from ${#xml_files[@]} report(s)" >&2
  mkdir -p "$html_dir"

  # Build semicolon-separated report list for reportgenerator
  local reports
  printf -v reports '%s;' "${xml_files[@]}"
  reports="${reports%;}"

  reportgenerator \
    -reports:"$reports" \
    -targetdir:"$html_dir" \
    -reporttypes:Html \
    -title:"PGO Gather Coverage Report" \
    >/dev/null 2>&1 || {
    echo "[pgo-gather] warning: reportgenerator failed" >&2
    return 0
  }

  echo "[pgo-gather] coverage HTML: $html_dir/index.html" >&2
}

# ─────────────────────────────────────────────────────────────────────────────

run_collect_case() {
  local in_candidate="$1"
  local in_label="$2"
  local in_filter="$3"
  local in_reports_dir="$4"
  local in_logs_dir="$5"
  local in_coverage_dir="${6:-}"

  local report_path="$in_reports_dir/$in_label.xml"
  local report_tmp="$report_path.tmp"
  local log_path="$in_logs_dir/$in_label.log"

  local cov_filter=""
  local cov_fallback=""
  if [[ -n "$in_coverage_dir" ]]; then
    cov_filter="$in_coverage_dir/${in_label}_filter.cobertura.xml"
    cov_fallback="$in_coverage_dir/${in_label}_fallback.cobertura.xml"
  fi

  local -a args
  local -a reporter_args=(--reporter junit --out "$report_path")
  local -a reporter_args_tmp=(--reporter junit --out "$report_tmp")
  args=(--order lex --rng-seed 1337 --durations yes)
  if [[ -n "$in_filter" ]]; then
    args+=("$in_filter")
  fi
  args+=("${reporter_args_tmp[@]}")

  rm -f "$report_tmp"

  echo "[pgo-gather] running $in_label (${in_filter:-all-tests})" >&2
  if _run_with_coverage "$cov_filter" "$in_candidate" "${args[@]}" >"$log_path" 2>&1; then
    mv -f "$report_tmp" "$report_path"
    echo "[pgo-gather] pass $in_label" >&2
    return 0
  fi

  echo "[pgo-gather] warning: $in_label failed for filter '${in_filter:-all-tests}', retry full binary" >&2
  rm -f "$report_tmp"
  if _run_with_coverage "$cov_fallback" "$in_candidate" --order lex --rng-seed 1337 "${reporter_args_tmp[@]}" >"$log_path" 2>&1; then
    mv -f "$report_tmp" "$report_path"
    echo "[pgo-gather] pass $in_label (fallback all-tests)" >&2
    return 0
  fi

  rm -f "$report_tmp"
  # Keep the output machine-readable even on failures.
  cat > "$report_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="$in_label" errors="0" failures="1" skipped="0" tests="1" time="0">
    <testcase classname="$in_label" name="pgo-gather-run" time="0">
      <failure message="pgo-gather execution failed; inspect $log_path"/>
    </testcase>
  </testsuite>
</testsuites>
EOF

  echo "[pgo-gather] warning: $in_label fallback failed; see $log_path" >&2
  return 1
}

render_junit_html_reports() {
  local in_reports_dir="$1"
  local html_root="$2"

  mkdir -p "$html_root"

  python - "$in_reports_dir" "$html_root" <<'PY'
from __future__ import annotations

import html
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

reports_dir = Path(sys.argv[1])
html_root = Path(sys.argv[2])

rows = []
for xml_path in sorted(reports_dir.glob("*.xml")):
    tests = failures = errors = skipped = 0
    name = xml_path.stem
    try:
        root = ET.parse(xml_path).getroot()
        suite = root.find("testsuite")
        if suite is not None:
            name = suite.attrib.get("name", name)
            tests = int(suite.attrib.get("tests", "0"))
            failures = int(suite.attrib.get("failures", "0"))
            errors = int(suite.attrib.get("errors", "0"))
            skipped = int(suite.attrib.get("skipped", "0"))
    except Exception:
        failures = 1

    passed = max(0, tests - failures - errors - skipped)
    rate = (passed / tests * 100.0) if tests > 0 else 0.0
    leaf = html_root / xml_path.stem
    leaf.mkdir(parents=True, exist_ok=True)
    leaf_index = leaf / "index.html"
    leaf_index.write_text(
        """<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\"><title>{title}</title></head>
<body><h1>{title}</h1>
<p>tests={tests} passed={passed} failures={failures} errors={errors} skipped={skipped} pass_rate={rate:.2f}%</p>
<p><a href=\"../../junit/{xml}\">Open JUnit XML</a></p>
</body></html>
""".format(
            title=html.escape(name),
            tests=tests,
            passed=passed,
            failures=failures,
            errors=errors,
            skipped=skipped,
            rate=rate,
            xml=html.escape(xml_path.name),
        ),
        encoding="utf-8",
    )

    rows.append(
        f"<tr><td><a href=\"{html.escape(xml_path.stem)}/index.html\">{html.escape(name)}</a></td>"
        f"<td>{tests}</td><td>{passed}</td><td>{failures}</td><td>{errors}</td><td>{skipped}</td><td>{rate:.2f}%</td></tr>"
    )

index = html_root / "index.html"
index.write_text(
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>PGO Gather Test Report</title></head>"
    "<body><h1>PGO Gather Test Report</h1><table border=\"1\" cellpadding=\"6\" cellspacing=\"0\">"
    "<thead><tr><th>Suite</th><th>Tests</th><th>Passed</th><th>Failures</th><th>Errors</th><th>Skipped</th><th>Pass rate</th></tr></thead>"
    f"<tbody>{''.join(rows)}</tbody></table></body></html>",
    encoding="utf-8",
)
PY
}

run_collect_tests_default() {
  local preset_name
  local bin_root
  local exe_ext=""
  local test_bin
  local passed_count=0
  local failed_count=0
  local reports_root
  local reports_dir
  local logs_dir
  local html_dir
  local suite_entry
  local label
  local filter
  local candidate
  local gather_mode="${KANO_CPP_INFRA_PGO_GATHER_MODE:-pgo}"

  preset_name="$(resolve_collect_preset)"
  bin_root="$CPP_ROOT/out/bin/$preset_name/debug"
  reports_root="$CPP_ROOT/.kano/tmp/pgo/gather-reports"
  reports_dir="$reports_root/junit"
  logs_dir="$reports_root/logs"
  html_dir="$reports_root/html"
  local coverage_raw_dir="$reports_root/coverage/raw"
  local coverage_html_dir="$reports_root/coverage/html"

  mkdir -p "$reports_dir" "$logs_dir" "$html_dir" "$coverage_raw_dir"

  if is_windows_host; then
    exe_ext=".exe"
  fi

  if [[ "$gather_mode" == "pgo" ]]; then
    ensure_windows_pgo_runtime_path
  fi

  if _has_opencppcoverage; then
    echo "[pgo-gather] coverage collection: OpenCppCoverage (output: $coverage_raw_dir)" >&2
  else
    echo "[pgo-gather] coverage collection: disabled (OpenCppCoverage not found)" >&2
  fi

  echo "[pgo-gather] using gather mode: $gather_mode, preset: $preset_name" >&2
  # - CLI functional path
  # - commit-plan engine + properties
  # - export/archive paths
  # - TUI command-state/autocomplete paths
  local -a suite=(
    "kano_git_cli_tests|[Functional]"
    "kano_git_commit_plan_tests|[Unit],[Property]"
    "kano_git_export_tests|[Unit],[Integration]"
    "kano_git_tui_tests|[Unit],[Property]"
  )

  for suite_entry in "${suite[@]}"; do
    IFS='|' read -r test_bin filter <<< "$suite_entry"
    label="${test_bin}"
    candidate="$bin_root/$test_bin$exe_ext"

    if [[ ! -f "$candidate" ]]; then
      echo "[pgo-gather] missing collect test binary: $candidate" >&2
      exit 1
    fi

    # Catch2 v3 uses --list-tests. Keep a cheap preflight list to confirm binary health.
    if ! "$candidate" --list-tests >"$logs_dir/${label}.list.log" 2>&1; then
      echo "[pgo-gather] warning: $label failed --list-tests preflight; continuing" >&2
    fi

    if run_collect_case "$candidate" "$label" "$filter" "$reports_dir" "$logs_dir" "$coverage_raw_dir"; then
      passed_count=$((passed_count + 1))
    else
      failed_count=$((failed_count + 1))
    fi
  done

  render_junit_html_reports "$reports_dir" "$html_dir"
  generate_coverage_html "$coverage_raw_dir" "$coverage_html_dir"

  echo "[pgo-gather] reports root: $reports_root" >&2
  echo "[pgo-gather] html summary: $html_dir/index.html" >&2

  if [[ "$passed_count" -eq 0 ]]; then
    echo "[pgo-gather] all collect workloads failed; cannot gather usable profile" >&2
    exit 1
  fi

  if [[ "$failed_count" -gt 0 ]]; then
    echo "[pgo-gather] completed with partial failures: passed=$passed_count failed=$failed_count" >&2
  else
    echo "[pgo-gather] all collect workloads passed" >&2
  fi
}

if [[ -n "${KANO_CPP_INFRA_PGO_GATHER_COMMAND:-}" ]]; then
  (
    cd "$CPP_ROOT"
    eval "$KANO_CPP_INFRA_PGO_GATHER_COMMAND"
  )
  exit 0
fi

if [[ -n "${KOG_PGO_GATHER_COMMAND:-}" ]]; then
  (
    cd "$CPP_ROOT"
    eval "$KOG_PGO_GATHER_COMMAND"
  )
  exit 0
fi

run_collect_tests_default "$@"
