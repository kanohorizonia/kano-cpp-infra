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
REPORT_SKILL_ADAPTER_SH="$SCRIPT_DIR/../lib/report_skill_adapter.sh"

if [[ -f "$REPORT_SKILL_ADAPTER_SH" ]]; then
  # shellcheck disable=SC1090
  source "$REPORT_SKILL_ADAPTER_SH"
fi

resolve_test_skill_root() {
  local candidate skill_from_adapter
  local -a candidates=(
    "${KANO_CPP_TEST_SKILL_ROOT:-}"
    "${KANO_CPP_INFRA_TEST_SKILL_ROOT:-}"
    "$CPP_ROOT/../../../kano-cpp-test-skill"
    "$CPP_ROOT/../../../../kano-cpp-test-skill"
  )

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate/src/shell/reports/common/render_test_report.py" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v report_skill_find_root >/dev/null 2>&1; then
    skill_from_adapter="$(report_skill_find_root "${KANO_CPP_INFRA_REPO_ROOT:-$CPP_ROOT}" 2>/dev/null || true)"
    if [[ -n "$skill_from_adapter" ]] && [[ -f "$skill_from_adapter/src/shell/reports/common/render-test-report.py" ]]; then
      printf '%s\n' "$skill_from_adapter"
      return 0
    fi
  fi

  return 1
}

count_nonempty_cobertura_files() {
  local raw_dir="$1"
  python - "$raw_dir" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

raw = Path(sys.argv[1])
count = 0
for p in raw.glob("*.cobertura.xml"):
    try:
        root = ET.parse(p).getroot()
        if int(root.attrib.get("lines-valid", "0") or "0") > 0:
            count += 1
    except Exception:
        pass
print(count)
PY
}

salvage_windows_opencppcoverage_for_tui() {
  local in_candidate="$1"
  local in_reports_dir="$2"
  local in_coverage_dir="$3"
  local in_logs_dir="$4"

  [[ -f "$in_candidate" ]] || return 1
  _has_opencppcoverage || return 1

  local occ_bin
  occ_bin="$(_resolve_opencppcoverage)"
  local src_win="$(_to_win_path "$CPP_ROOT/code")"
  local cov_out="$in_coverage_dir/kano_git_tui_tests_salvage.cobertura.xml"
  local cov_win="$(_to_win_path "$cov_out")"
  local bin_win="$(_to_win_path "$in_candidate")"
  local junit_tmp="$(_to_win_path "$in_reports_dir/kano_git_tui_tests_salvage.xml.tmp")"
  local cov_lines_valid="0"

  _cov_lines_valid() {
    python - "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
    print(int(root.attrib.get("lines-valid", "0") or "0"))
except Exception:
    print(0)
PY
  }

  _run_salvage() {
    local mode="$1"
    if [[ "$mode" == "filtered" ]]; then
      MSYS2_ARG_CONV_EXCL='*' "$occ_bin" \
        --sources "$src_win" \
        --export_type "cobertura:$cov_win" \
        --quiet \
        -- "$bin_win" \
          --order lex --rng-seed 1337 --durations yes "[unit],[property]" \
          --reporter junit "--out=$junit_tmp" \
          >"$in_logs_dir/kano_git_tui_tests_salvage.log" 2>&1
    else
      MSYS2_ARG_CONV_EXCL='*' "$occ_bin" \
        --sources "$src_win" \
        --export_type "cobertura:$cov_win" \
        --quiet \
        -- "$bin_win" \
          --order lex --rng-seed 1337 --durations yes \
          --reporter junit "--out=$junit_tmp" \
          >"$in_logs_dir/kano_git_tui_tests_salvage.log" 2>&1
    fi
  }

  echo "[pgo-gather] attempting OpenCppCoverage salvage pass for kano_git_tui_tests" >&2
  if _run_salvage filtered; then
    cov_lines_valid="$(_cov_lines_valid "$cov_out")"
    if [[ "$cov_lines_valid" -gt 0 ]]; then
      mv -f "$in_reports_dir/kano_git_tui_tests_salvage.xml.tmp" "$in_reports_dir/kano_git_tui_tests_salvage.xml" 2>/dev/null || true
      echo "[pgo-gather] OpenCppCoverage salvage pass completed (lines-valid=$cov_lines_valid)" >&2
      return 0
    fi
    echo "[pgo-gather] salvage filtered run produced empty coverage, retrying without filter" >&2
  fi

  if _run_salvage all; then
    cov_lines_valid="$(_cov_lines_valid "$cov_out")"
    if [[ "$cov_lines_valid" -gt 0 ]]; then
      mv -f "$in_reports_dir/kano_git_tui_tests_salvage.xml.tmp" "$in_reports_dir/kano_git_tui_tests_salvage.xml" 2>/dev/null || true
      echo "[pgo-gather] OpenCppCoverage salvage (all-tests) completed (lines-valid=$cov_lines_valid)" >&2
      return 0
    fi
  fi

  echo "[pgo-gather] OpenCppCoverage salvage pass failed or still empty" >&2
  return 1
}

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

# Check if Microsoft.CodeCoverage.Console (dotnet global tool) is available
_has_microsoft_codecoverage() {
  command -v codecoverage >/dev/null 2>&1 || \
  command -v CodeCoverage >/dev/null 2>&1 || \
  command -v CodeCoverage.exe >/dev/null 2>&1 || \
  [[ -x "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/Team Tools/Dynamic Code Coverage Tools/CodeCoverage.exe" ]] || \
  [[ -x "/c/Program Files/Microsoft Visual Studio/2022/Professional/Team Tools/Dynamic Code Coverage Tools/CodeCoverage.exe" ]] || \
  [[ -x "/c/Program Files/Microsoft Visual Studio/2022/Community/Team Tools/Dynamic Code Coverage Tools/CodeCoverage.exe" ]] || \
  [[ -x "/c/Program Files/Microsoft Visual Studio/2022/BuildTools/Team Tools/Dynamic Code Coverage Tools/CodeCoverage.exe" ]]
}

# Resolve the Microsoft.CodeCoverage.Console executable path
_resolve_microsoft_codecoverage() {
  command -v codecoverage 2>/dev/null && return
  command -v CodeCoverage 2>/dev/null && return
  command -v CodeCoverage.exe 2>/dev/null && return
  for _vs_ed in Enterprise Professional Community BuildTools; do
    local _exe="/c/Program Files/Microsoft Visual Studio/2022/${_vs_ed}/Team Tools/Dynamic Code Coverage Tools/CodeCoverage.exe"
    [[ -x "$_exe" ]] && printf '%s\n' "$_exe" && return
  done
  return 1
}

# Check if OpenCppCoverage is available on PATH or at common install location
_has_opencppcoverage() {
  command -v OpenCppCoverage >/dev/null 2>&1 || \
  command -v OpenCppCoverage.exe >/dev/null 2>&1 || \
  [[ -x "/c/Program Files/OpenCppCoverage/OpenCppCoverage.exe" ]]
}

# Resolve OpenCppCoverage executable path
_resolve_opencppcoverage() {
  command -v OpenCppCoverage 2>/dev/null && return
  command -v OpenCppCoverage.exe 2>/dev/null && return
  local _exe="/c/Program Files/OpenCppCoverage/OpenCppCoverage.exe"
  [[ -x "$_exe" ]] && printf '%s\n' "$_exe" && return
  return 1
}

# Check if reportgenerator is available
_has_reportgenerator() {
  command -v reportgenerator >/dev/null 2>&1
}

# Check if LLVM coverage tools are available (llvm-profdata + llvm-cov)
_has_llvm_coverage() {
  command -v llvm-profdata >/dev/null 2>&1 && command -v llvm-cov >/dev/null 2>&1
}

# Convert a POSIX path (Git-Bash style /c/...) to a Windows native path (C:\...)
_to_win_path() {
  local p="$1"
  # Already a Windows path
  if [[ "$p" =~ ^[A-Za-z]:[/\\\\] ]]; then
    printf '%s\n' "${p//\//\\\\}"
    return
  fi
  # Git-Bash /drive/... form
  if [[ "$p" =~ ^/([a-zA-Z])(/.*)?$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]:-}"
    rest="${rest//\//\\\\}"
    printf '%s:\\%s\n' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "${rest#\\\\}"
    return
  fi
  printf '%s\n' "$p"
}

# Run a test binary, optionally wrapping with the selected coverage tool.
# Usage: _run_with_coverage <coverage_out|""> <binary> [args...]
_run_with_coverage() {
  local coverage_out="$1"
  shift

  local coverage_tool="${KANO_CPP_INFRA_COVERAGE_TOOL:-}"

  if [[ "$coverage_tool" == "microsoft" && -n "$coverage_out" ]] && _has_microsoft_codecoverage; then
    local codecov_bin
    codecov_bin="$(_resolve_microsoft_codecoverage)"
    local cobertura_out="${coverage_out%.cobertura.xml}.cobertura.xml"
    local exe="$1"
    local exe_win
    exe_win="$(_to_win_path "$exe")"
    shift
    local ps_script="& '${exe_win//\'/\'\'}'"
    local _arg _arg_esc
    for _arg in "$@"; do
      _arg_esc=${_arg//\'/\'\'}
      ps_script+=" '${_arg_esc}'"
    done
    local wrapped_command
    wrapped_command="powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"$ps_script\""
    mkdir -p "$(dirname "$cobertura_out")"
    "$codecov_bin" collect \
      --output-format cobertura \
      --output "$(cygpath -w "$cobertura_out" 2>/dev/null || printf '%s' "$cobertura_out")" \
      "$wrapped_command"

  elif [[ "$coverage_tool" == "opencppcoverage" && -n "$coverage_out" ]] && _has_opencppcoverage; then
    local occ_bin
    occ_bin="$(_resolve_opencppcoverage)"
    local src_win="$(_to_win_path "$CPP_ROOT/code")"
    local cov_win="$(_to_win_path "$coverage_out")"
    local binary="$1"
    shift
    local binary_win="$(_to_win_path "$binary")"

    mkdir -p "$(dirname "$coverage_out")"
    MSYS2_ARG_CONV_EXCL='*' "$occ_bin" \
      --sources "$src_win" \
      --cover_children \
      --export_type "cobertura:$cov_win" \
      --quiet \
      -- "$binary_win" "$@"

  elif [[ "$coverage_tool" == "llvm" && -n "$coverage_out" ]]; then
    # LLVM source-based coverage: write a .profraw file alongside the binary run.
    # The binary must have been compiled with -fprofile-instr-generate -fcoverage-mapping.
    mkdir -p "$(dirname "$coverage_out")"
    LLVM_PROFILE_FILE="$coverage_out" "$@"

  else
    "$@"
  fi
}

# Generate HTML coverage report from LLVM profraw files (Linux/macOS).
# Usage: generate_llvm_coverage_html <profraw_dir> <html_dir> <binary...>
generate_llvm_coverage_html() {
  local profraw_dir="$1"
  local html_dir="$2"
  shift 2
  local -a binaries=("$@")

  if ! _has_llvm_coverage; then
    echo "[pgo-gather] skipping LLVM coverage HTML: llvm-profdata/llvm-cov not available" >&2
    return 0
  fi

  local -a profraw_files=()
  while IFS= read -r -d '' f; do
    profraw_files+=("$f")
  done < <(find "$profraw_dir" -name "*.profraw" -type f -print0 2>/dev/null || true)

  if [[ ${#profraw_files[@]} -eq 0 ]]; then
    echo "[pgo-gather] no .profraw files found; skipping LLVM coverage HTML" >&2
    return 0
  fi

  local merged_profdata="$profraw_dir/merged.profdata"
  echo "[pgo-gather] merging ${#profraw_files[@]} .profraw file(s) ..." >&2
  llvm-profdata merge -sparse "${profraw_files[@]}" -o "$merged_profdata" || {
    echo "[pgo-gather] warning: llvm-profdata merge failed; skipping coverage HTML" >&2
    return 0
  }

  # Build llvm-cov show args: first binary as positional, rest as --object
  local primary_bin="${binaries[0]:-}"
  if [[ -z "$primary_bin" ]]; then
    echo "[pgo-gather] warning: no binaries for llvm-cov; skipping HTML" >&2
    return 0
  fi

  local -a show_args=(
    "$primary_bin"
    -instr-profile="$merged_profdata"
    -format=html
    -output-dir="$html_dir"
    -ignore-filename-regex='(ThirdParty|Intermediate|test)'
  )
  local b
  for b in "${binaries[@]:1}"; do
    [[ -f "$b" ]] && show_args+=(--object="$b")
  done

  mkdir -p "$html_dir"
  echo "[pgo-gather] generating LLVM coverage HTML ..." >&2
  llvm-cov show "${show_args[@]}" >/dev/null 2>&1 || {
    echo "[pgo-gather] warning: llvm-cov show failed; trying without ignore regex" >&2
    llvm-cov show "$primary_bin" -instr-profile="$merged_profdata" -format=html -output-dir="$html_dir" >/dev/null 2>&1 || {
      echo "[pgo-gather] warning: llvm-cov show failed entirely" >&2
      return 0
    }
  }
  echo "[pgo-gather] LLVM coverage HTML: $html_dir/index.html" >&2

  # Also export Cobertura XML for downstream tooling
  local cobertura_out="$profraw_dir/coverage.cobertura.xml"
  local llvm_json="$profraw_dir/coverage.json"
  local -a export_args=(
    "$primary_bin"
    -instr-profile="$merged_profdata"
    -format=text
  )
  for b in "${binaries[@]:1}"; do
    [[ -f "$b" ]] && export_args+=(--object="$b")
  done
  if llvm-cov export "${export_args[@]}" > "$llvm_json" 2>/dev/null; then
    python "$SCRIPT_DIR/../lib/llvm_json_to_cobertura.py" "$llvm_json" "$CPP_ROOT" "$cobertura_out" 2>/dev/null || true
  fi
}

# Generate HTML coverage report from Cobertura XML files (Windows: microsoft or opencppcoverage).
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
    return 1
  fi

  # Keep only non-empty Cobertura files (lines-valid > 0).
  local -a nonempty_xml_files=()
  local xml
  for xml in "${xml_files[@]}"; do
    if python - "$xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    raise SystemExit(1)

lines_valid = int(root.attrib.get("lines-valid", "0") or "0")
raise SystemExit(0 if lines_valid > 0 else 1)
PY
    then
      nonempty_xml_files+=("$xml")
    fi
  done

  if [[ ${#nonempty_xml_files[@]} -eq 0 ]]; then
    if [[ "${KANO_CPP_INFRA_PGO_GATHER_QUICK:-0}" == "1" ]]; then
      echo "[pgo-gather] quick mode: all Cobertura XML reports are empty; publishing placeholder coverage HTML for flow validation" >&2
      mkdir -p "$html_dir"
      cat > "$html_dir/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Coverage Report (Quick Mode Placeholder)</title>
  <style>
    body { font-family: Segoe UI, sans-serif; margin: 2rem; line-height: 1.5; }
    .box { border: 1px solid #d0d7de; border-radius: 8px; padding: 1rem 1.25rem; background: #f6f8fa; }
    h1 { margin-top: 0; }
    code { background: #eef2f6; padding: 0.1rem 0.3rem; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>Coverage Report Placeholder</h1>
  <div class="box">
    <p>This report was generated in quick mode for pipeline flow validation.</p>
    <p>No non-empty Cobertura XML input was produced, so real coverage metrics are not available.</p>
    <p>Run full gather mode (without <code>KANO_CPP_INFRA_PGO_GATHER_QUICK=1</code>) to publish real coverage.</p>
  </div>
</body>
</html>
HTML
      return 0
    fi
    echo "[pgo-gather] all Cobertura XML reports are empty; refusing to publish empty coverage HTML" >&2
    return 1
  fi

  local skill_root best_xml
  skill_root="$(resolve_test_skill_root 2>/dev/null || true)"
  if [[ -n "$skill_root" ]] && [[ -f "$skill_root/src/shell/reports/common/render_coverage_report.py" ]]; then
    best_xml="$(python - "${nonempty_xml_files[@]}" <<'PY'
import sys
import xml.etree.ElementTree as ET

best_file = ""
best_lines = -1
for p in sys.argv[1:]:
    try:
        root = ET.parse(p).getroot()
        lines_valid = int(root.attrib.get("lines-valid", "0") or "0")
    except Exception:
        continue
    if lines_valid > best_lines:
        best_lines = lines_valid
        best_file = p

print(best_file)
PY
)"
    if [[ -n "$best_xml" ]]; then
      echo "[pgo-gather] rendering coverage HTML with kano-cpp-test-skill renderer: $best_xml" >&2
      if python "$skill_root/src/shell/reports/common/render_coverage_report.py" "$best_xml" "$html_dir" "$CPP_ROOT"; then
        echo "[pgo-gather] coverage HTML: $html_dir/index.html" >&2
        return 0
      fi
      echo "[pgo-gather] warning: skill coverage renderer failed; falling back to reportgenerator" >&2
    fi
  fi

  echo "[pgo-gather] generating coverage HTML from ${#nonempty_xml_files[@]} non-empty Cobertura report(s)" >&2
  mkdir -p "$html_dir"

  local reports
  local reports_wildcard="$raw_dir/*.cobertura.xml"
  local target_dir_arg="$html_dir"
  if is_windows_host; then
    local -a xml_files_win=()
    local f
    for f in "${nonempty_xml_files[@]}"; do
      xml_files_win+=("$(_to_win_path "$f")")
    done
    printf -v reports '%s;' "${xml_files_win[@]}"
    reports="${reports%;}"
    reports_wildcard="$(_to_win_path "$raw_dir")\\*.cobertura.xml"
    target_dir_arg="$(_to_win_path "$html_dir")"
  else
    printf -v reports '%s;' "${nonempty_xml_files[@]}"
    reports="${reports%;}"
  fi

  local rg_log="$raw_dir/reportgenerator.log"
  if ! reportgenerator \
    -reports:"$reports" \
    -targetdir:"$target_dir_arg" \
    -reporttypes:Html \
    -title:"PGO Gather Coverage Report" \
    >"$rg_log" 2>&1; then
    echo "[pgo-gather] warning: reportgenerator failed (explicit list), retrying with wildcard" >&2
    if ! reportgenerator \
      -reports:"$reports_wildcard" \
      -targetdir:"$target_dir_arg" \
      -reporttypes:Html \
      -title:"PGO Gather Coverage Report" \
      >>"$rg_log" 2>&1; then
      echo "[pgo-gather] warning: reportgenerator failed; see $rg_log" >&2
      tail -n 40 "$rg_log" >&2 || true
      return 1
    fi
  fi

  echo "[pgo-gather] coverage HTML: $html_dir/index.html" >&2
}

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
    local _cov_ext=".cobertura.xml"
    if [[ "${KANO_CPP_INFRA_COVERAGE_TOOL:-}" == "llvm" ]]; then
      _cov_ext=".profraw"
    fi
    cov_filter="$in_coverage_dir/${in_label}_filter${_cov_ext}"
    cov_fallback="$in_coverage_dir/${in_label}_fallback${_cov_ext}"
  fi

  local -a args
  local report_path_arg="$report_path"
  local report_tmp_arg="$report_tmp"
  if is_windows_host; then
    report_path_arg="$(_to_win_path "$report_path")"
    report_tmp_arg="$(_to_win_path "$report_tmp")"
  fi

  # Use --out=<path> to avoid Windows '/c/..' style paths being parsed as options.
  local -a reporter_args=(--reporter junit "--out=${report_path_arg}")
  local -a reporter_args_tmp=(--reporter junit "--out=${report_tmp_arg}")
  args=(--order lex --rng-seed 1337 --durations yes)
  if [[ -n "$in_filter" ]]; then
    args+=("$in_filter")
  fi
  args+=("${reporter_args_tmp[@]}")

  rm -f "$report_tmp"

  echo "[pgo-gather] running $in_label (${in_filter:-all-tests})" >&2
  if _run_with_coverage "$cov_filter" "$in_candidate" "${args[@]}" >"$log_path" 2>&1; then
    if [[ -f "$report_tmp" ]]; then
      mv -f "$report_tmp" "$report_path"
      echo "[pgo-gather] pass $in_label" >&2
      return 0
    fi
    echo "[pgo-gather] warning: $in_label finished without junit output; treating as failure" >&2
  fi

  echo "[pgo-gather] warning: $in_label failed for filter '${in_filter:-all-tests}', retry full binary" >&2
  rm -f "$report_tmp"
  if _run_with_coverage "$cov_fallback" "$in_candidate" --order lex --rng-seed 1337 "${reporter_args_tmp[@]}" >"$log_path" 2>&1; then
    if [[ -f "$report_tmp" ]]; then
      mv -f "$report_tmp" "$report_path"
      echo "[pgo-gather] pass $in_label (fallback all-tests)" >&2
      return 0
    fi
    echo "[pgo-gather] warning: $in_label fallback finished without junit output; treating as failure" >&2
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

_render_junit_html_reports_fallback() {
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

render_junit_html_reports() {
  local in_reports_dir="$1"
  local html_root="$2"

  local skill_root="$(resolve_test_skill_root 2>/dev/null || true)"

  if [[ -z "$skill_root" || ! -f "$skill_root/src/shell/reports/common/render-test-report.py" ]]; then
    _render_junit_html_reports_fallback "$in_reports_dir" "$html_root"
    return
  fi

  local tmp_result_dir="$html_root/.tmp-test-result"
  mkdir -p "$tmp_result_dir" "$html_root"

  python - "$in_reports_dir" "$tmp_result_dir/ctest-report.xml" <<'PY'
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

in_dir = Path(sys.argv[1])
out_xml = Path(sys.argv[2])

site = ET.Element("Site")
testing = ET.SubElement(site, "Testing")

for junit_path in sorted(in_dir.glob("*.xml")):
    try:
        root = ET.parse(junit_path).getroot()
    except Exception:
        continue

    suites = []
    if root.tag == "testsuite":
        suites = [root]
    elif root.tag == "testsuites":
        suites = list(root.findall("testsuite"))

    for suite in suites:
        suite_name = suite.attrib.get("name", junit_path.stem)
        failures = int(suite.attrib.get("failures", "0") or "0")
        errors = int(suite.attrib.get("errors", "0") or "0")
        skipped = int(suite.attrib.get("skipped", "0") or "0")

        test_el = ET.SubElement(testing, "Test", {"Status": "failed" if failures or errors else ("notrun" if skipped else "passed")})
        ET.SubElement(test_el, "Name").text = suite_name
        ET.SubElement(test_el, "FullName").text = suite_name
        ET.SubElement(test_el, "CompletionStatus").text = "failed" if failures or errors else ("notrun" if skipped else "passed")
        ET.SubElement(test_el, "ExecutionTime").text = suite.attrib.get("time", "0")

        results = ET.SubElement(test_el, "Results")
        nm_w = ET.SubElement(results, "NamedMeasurement", {"name": "Warnings"})
        ET.SubElement(nm_w, "Value").text = "0"
        nm_e = ET.SubElement(results, "NamedMeasurement", {"name": "Errors"})
        ET.SubElement(nm_e, "Value").text = str(errors + failures)

out_xml.parent.mkdir(parents=True, exist_ok=True)
ET.ElementTree(site).write(out_xml, encoding="utf-8", xml_declaration=True)
PY

  if ! python "$skill_root/src/shell/reports/common/render-test-report.py" \
    "$tmp_result_dir/ctest-report.xml" \
    "$html_root"; then
    echo "[pgo-gather] warning: skill test renderer failed; using fallback html renderer" >&2
    _render_junit_html_reports_fallback "$in_reports_dir" "$html_root"
  fi
}

render_reports_homepage() {
  local reports_root="$1"
  local html_dir="$2"
  local coverage_html_dir="$3"
  local reports_dir="$4"
  local logs_dir="$5"

  mkdir -p "$reports_root"

  python - "$reports_root" "$html_dir" "$coverage_html_dir" "$reports_dir" "$logs_dir" "${KANO_CPP_INFRA_COVERAGE_TOOL:-none}" "${KANO_CPP_INFRA_PGO_GATHER_QUICK:-0}" <<'PY'
from __future__ import annotations

import datetime as dt
import html
import sys
from pathlib import Path

reports_root = Path(sys.argv[1])
html_dir = Path(sys.argv[2])
coverage_html_dir = Path(sys.argv[3])
reports_dir = Path(sys.argv[4])
logs_dir = Path(sys.argv[5])
coverage_tool = sys.argv[6]
quick_mode = sys.argv[7] == "1"

def rel_link(target: Path) -> str:
    try:
        return target.relative_to(reports_root).as_posix()
    except Exception:
        return target.as_posix()

test_index = html_dir / "index.html"
coverage_index = coverage_html_dir / "index.html"
junit_files = sorted(reports_dir.glob("*.xml"))
log_files = sorted(logs_dir.glob("*.log"))

rows = []

if test_index.is_file():
    rows.append('<tr><td>Test HTML</td><td>ready</td><td><a href="{0}">open</a></td></tr>'.format(html.escape(rel_link(test_index))))
else:
    rows.append('<tr><td>Test HTML</td><td>missing</td><td>-</td></tr>')

if coverage_index.is_file():
    rows.append('<tr><td>Coverage HTML</td><td>ready</td><td><a href="{0}">open</a></td></tr>'.format(html.escape(rel_link(coverage_index))))
else:
    rows.append('<tr><td>Coverage HTML</td><td>missing</td><td>-</td></tr>')

rows.append('<tr><td>JUnit XML</td><td>{0} file(s)</td><td><a href="{1}">open folder</a></td></tr>'.format(len(junit_files), html.escape(rel_link(reports_dir))))
rows.append('<tr><td>Logs</td><td>{0} file(s)</td><td><a href="{1}">open folder</a></td></tr>'.format(len(log_files), html.escape(rel_link(logs_dir))))

timestamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
mode_text = "quick" if quick_mode else "full"

doc = """<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>PGO Gather Report Index</title>
  <style>
    body {{ font-family: Segoe UI, sans-serif; margin: 2rem; line-height: 1.45; }}
    table {{ border-collapse: collapse; width: 100%; max-width: 960px; }}
    th, td {{ border: 1px solid #d0d7de; padding: 0.55rem 0.7rem; text-align: left; }}
    th {{ background: #f6f8fa; }}
    .meta {{ color: #57606a; margin-bottom: 1rem; }}
  </style>
</head>
<body>
  <h1>PGO Gather Report Index</h1>
  <p class=\"meta\">Generated: {timestamp} | mode: {mode} | coverage tool: {tool}</p>
  <table>
    <thead><tr><th>Report</th><th>Status</th><th>Link</th></tr></thead>
    <tbody>
      {rows}
    </tbody>
  </table>
</body>
</html>
""".format(
    timestamp=html.escape(timestamp),
    mode=html.escape(mode_text),
    tool=html.escape(coverage_tool),
    rows="\n      ".join(rows),
)

(reports_root / "index.html").write_text(doc, encoding="utf-8")
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

  if ! rm -rf "$reports_root" 2>/dev/null; then
    echo "[pgo-gather] warning: failed to remove $reports_root (likely file lock); cleaning files in-place" >&2
    find "$reports_root" -type f -delete 2>/dev/null || true
  fi
  mkdir -p "$reports_dir" "$logs_dir" "$html_dir" "$coverage_raw_dir"

  if is_windows_host; then
    exe_ext=".exe"
  fi

  if [[ "$gather_mode" == "pgo" ]]; then
    ensure_windows_pgo_runtime_path
  fi

  # Auto-select coverage tool based on platform (can be overridden by KANO_CPP_INFRA_COVERAGE_TOOL)
  local coverage_tool="${KANO_CPP_INFRA_COVERAGE_TOOL:-}"
  if [[ -z "$coverage_tool" ]]; then
    if is_windows_host; then
      if _has_microsoft_codecoverage; then
        coverage_tool="microsoft"
      elif _has_opencppcoverage; then
        coverage_tool="opencppcoverage"
      fi
    elif _has_llvm_coverage; then
      coverage_tool="llvm"
    fi
  fi
  export KANO_CPP_INFRA_COVERAGE_TOOL="${coverage_tool:-}"

  if [[ -n "$coverage_tool" ]]; then
    echo "[pgo-gather] coverage collection: $coverage_tool (output: $coverage_raw_dir)" >&2
  else
    echo "[pgo-gather] coverage collection: disabled (no supported tool found)" >&2
  fi

  echo "[pgo-gather] using gather mode: $gather_mode, preset: $preset_name" >&2
  # - CLI functional path
  # - commit-plan engine + properties
  # - export/archive paths
  # - TUI command-state/autocomplete paths
  local -a suite=(
    "kano_git_cli_tests|[functional]"
    "kano_git_commit_plan_tests|[unit],[property]"
    "kano_git_export_tests|[unit],[integration]"
    "kano_git_tui_tests|[unit],[property]"
  )

  # Quick mode keeps the full PGO workflow but reduces gather runtime by
  # running only a minimal representative test subset.
  if [[ "${KANO_CPP_INFRA_PGO_GATHER_QUICK:-0}" == "1" ]]; then
    echo "[pgo-gather] quick mode enabled: reduced gather suite" >&2
    suite=(
      "kano_git_tui_tests|[unit],[property]"
    )
  fi

  local -a collected_binaries=()

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

    collected_binaries+=("$candidate")

    if run_collect_case "$candidate" "$label" "$filter" "$reports_dir" "$logs_dir" "$coverage_raw_dir"; then
      passed_count=$((passed_count + 1))
    else
      failed_count=$((failed_count + 1))
    fi
  done

  if [[ "${KANO_CPP_INFRA_COVERAGE_TOOL:-}" == "opencppcoverage" ]] && is_windows_host; then
    local nonempty_count
    nonempty_count="$(count_nonempty_cobertura_files "$coverage_raw_dir")"
    if [[ "$nonempty_count" == "0" ]]; then
      salvage_windows_opencppcoverage_for_tui \
        "$bin_root/kano_git_tui_tests$exe_ext" \
        "$reports_dir" \
        "$coverage_raw_dir" \
        "$logs_dir" || true
    fi
  fi

  render_junit_html_reports "$reports_dir" "$html_dir"
  if [[ "${KANO_CPP_INFRA_COVERAGE_TOOL:-}" == "llvm" ]]; then
    generate_llvm_coverage_html "$coverage_raw_dir" "$coverage_html_dir" "${collected_binaries[@]}"
  else
    generate_coverage_html "$coverage_raw_dir" "$coverage_html_dir"
  fi

  render_reports_homepage "$reports_root" "$html_dir" "$coverage_html_dir" "$reports_dir" "$logs_dir"

  echo "[pgo-gather] reports root: $reports_root" >&2
  echo "[pgo-gather] html summary: $reports_root/index.html" >&2

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
