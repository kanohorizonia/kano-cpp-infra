#!/usr/bin/env bash
# ============================================================================
# PGO Gather Script - PGO/Coverage Profile Collection
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
#   coverage       - Uses *-coverage presets for coverage-first instrumentation
#                    (for Microsoft coverage, runs instrument+collect flow)
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
PYTHON_RESOLVER_SH="$SCRIPT_DIR/../lib/python_resolver.sh"

if [[ -f "$REPORT_SKILL_ADAPTER_SH" ]]; then
  # shellcheck disable=SC1090
  source "$REPORT_SKILL_ADAPTER_SH"
fi

# shellcheck source=/dev/null
source "$PYTHON_RESOLVER_SH"
PYTHON_BIN="$(kano_resolve_python_bin)"

cmake_preset_exists() {
  local preset_name="$1"
  [[ -f "$CPP_ROOT/CMakePresets.json" ]] || return 1
  kano_python "$PYTHON_BIN" - "$CPP_ROOT/CMakePresets.json" "$preset_name" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
name = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
presets = []
for section in ("configurePresets", "buildPresets"):
    presets.extend(str(item.get("name", "")) for item in data.get(section, []))
raise SystemExit(0 if name in presets else 1)
PY
}

first_existing_preset() {
  local candidate
  for candidate in "$@"; do
    if [[ -n "$candidate" ]] && cmake_preset_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

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

is_pgo_debug_enabled() {
  case "${KANO_CPP_INFRA_PGO_DEBUG:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_pgo_verbose_enabled() {
  local raw="${KANO_CPP_INFRA_PGO_VERBOSE:-}"
  if [[ -z "$raw" ]]; then
    raw="${KANO_CPP_INFRA_PGO_DEBUG:-0}"
  fi
  case "$raw" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

pgo_debug_log() {
  is_pgo_debug_enabled || return 0
  echo "[pgo-gather][debug] $*" >&2
}

pgo_verbose_log() {
  is_pgo_verbose_enabled || return 0
  echo "[pgo-gather][verbose] $*" >&2
}

dump_cobertura_debug_summary() {
  local raw_dir="$1"
  local out_file="${2:-}"

  is_pgo_debug_enabled || return 0
  [[ -d "$raw_dir" ]] || return 0

  if [[ -z "$out_file" ]]; then
    if [[ -n "${KANO_CPP_INFRA_PGO_DEBUG_DIR:-}" ]]; then
      mkdir -p "$KANO_CPP_INFRA_PGO_DEBUG_DIR"
      out_file="$KANO_CPP_INFRA_PGO_DEBUG_DIR/cobertura-summary.txt"
    else
      out_file="$raw_dir/cobertura-summary.txt"
    fi
  fi

  "$PYTHON_BIN" - "$raw_dir" "$out_file" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

raw_dir = Path(sys.argv[1])
out_file = Path(sys.argv[2])

lines = []
lines.append(f"raw_dir={raw_dir}")
for xml_path in sorted(raw_dir.glob("*.cobertura.xml")):
    try:
        root = ET.parse(xml_path).getroot()
        lines_valid = int(root.attrib.get("lines-valid", "0") or "0")
        lines_covered = int(root.attrib.get("lines-covered", "0") or "0")
        line_rate = root.attrib.get("line-rate", "0")
        package_count = len(root.findall("./packages/package"))
        lines.append(
            f"{xml_path.name}\tlines-valid={lines_valid}\tlines-covered={lines_covered}\tline-rate={line_rate}\tpackages={package_count}"
        )
    except Exception as exc:
        lines.append(f"{xml_path.name}\tparse-error={exc}")

out_file.parent.mkdir(parents=True, exist_ok=True)
out_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

  pgo_debug_log "cobertura summary written: $out_file"
}

count_nonempty_cobertura_files() {
  local raw_dir="$1"
  "$PYTHON_BIN" - "$raw_dir" <<'PY'
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
    "$PYTHON_BIN" - "$1" <<'PY'
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
        --cover_children \
        --export_type "cobertura:$cov_win" \
        --quiet \
        -- "$bin_win" \
          --order lex --rng-seed 1337 --durations yes "[unit],[property]" \
          --reporter junit "--out=$junit_tmp" \
          >"$in_logs_dir/kano_git_tui_tests_salvage.log" 2>&1
    else
      MSYS2_ARG_CONV_EXCL='*' "$occ_bin" \
        --sources "$src_win" \
        --cover_children \
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
  local host_name host_arch preset
  host_name="$(uname -s 2>/dev/null || true)"
  host_arch="$(uname -m 2>/dev/null || true)"
  
  if [[ -n "${KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET:-}" ]]; then
    printf '%s\n' "$KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET"
    return 0
  fi

  if [[ "$gather_mode" == "coverage" ]]; then
    # Use coverage presets to gather data (unified with PGO collect for comprehensive testing)
    if [[ "$host_name" == MINGW* || "$host_name" == MSYS* || "$host_name" == CYGWIN* ]]; then
      printf '%s\n' "windows-ninja-msvc-coverage"
      return 0
    elif [[ "$host_name" == "Darwin" ]]; then
      if [[ "$host_arch" == "arm64" || "$host_arch" == "aarch64" ]]; then
        if preset="$(first_existing_preset macos-ninja-clang-arm64-coverage macos-ninja-clang-coverage macos-ninja-clang-arm64 macos-ninja-clang)"; then
          printf '%s\n' "$preset"
        else
          printf '%s\n' "macos-ninja-clang-arm64-coverage"
        fi
      else
        if preset="$(first_existing_preset macos-ninja-clang-x64-coverage macos-ninja-clang-coverage macos-ninja-clang-x64 macos-ninja-clang)"; then
          printf '%s\n' "$preset"
        else
          printf '%s\n' "macos-ninja-clang-coverage"
        fi
      fi
      return 0
    fi
    if preset="$(first_existing_preset linux-ninja-clang-coverage linux-ninja-gcc-coverage linux-ninja-clang linux-ninja-gcc)"; then
      printf '%s\n' "$preset"
    else
      printf '%s\n' "linux-ninja-clang-coverage"
    fi
    return 0
  fi

  # Default: PGO collect mode
  if [[ "$host_name" == MINGW* || "$host_name" == MSYS* || "$host_name" == CYGWIN* ]]; then
    printf '%s\n' "windows-ninja-msvc-pgo-collect"
    return 0
  fi

  if [[ "$host_name" == "Darwin" ]]; then
    if [[ "$host_arch" == "arm64" || "$host_arch" == "aarch64" ]]; then
      if preset="$(first_existing_preset macos-ninja-clang-arm64-pgo-collect macos-ninja-clang-pgo-collect macos-ninja-clang-arm64 macos-ninja-clang)"; then
        printf '%s\n' "$preset"
      else
        printf '%s\n' "macos-ninja-clang-arm64-pgo-collect"
      fi
    else
      if preset="$(first_existing_preset macos-ninja-clang-x64-pgo-collect macos-ninja-clang-pgo-collect macos-ninja-clang-x64 macos-ninja-clang)"; then
        printf '%s\n' "$preset"
      else
        printf '%s\n' "macos-ninja-clang-pgo-collect"
      fi
    fi
    return 0
  fi

  if preset="$(first_existing_preset linux-ninja-gcc-pgo-collect linux-ninja-gcc linux-ninja-clang-pgo-collect linux-ninja-clang)"; then
    printf '%s\n' "$preset"
  else
    printf '%s\n' "linux-ninja-gcc-pgo-collect"
  fi
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
  local _home="${HOME:-}"
  local _userprofile_posix=""
  if [[ -n "${USERPROFILE:-}" ]]; then
    _userprofile_posix="${USERPROFILE//\\//}"
  fi

  command -v codecoverage >/dev/null 2>&1 || \
  command -v CodeCoverage >/dev/null 2>&1 || \
  command -v CodeCoverage.exe >/dev/null 2>&1 || \
  [[ -x "$_home/.dotnet/tools/codecoverage" ]] || \
  [[ -x "$_home/.dotnet/tools/codecoverage.exe" ]] || \
  [[ -n "$_userprofile_posix" && -x "$_userprofile_posix/.dotnet/tools/codecoverage.exe" ]] || \
  [[ -x "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/Team Tools/Dynamic Code Coverage Tools/CodeCoverage.exe" ]] || \
  [[ -x "/c/Program Files/Microsoft Visual Studio/2022/Professional/Team Tools/Dynamic Code Coverage Tools/CodeCoverage.exe" ]] || \
  [[ -x "/c/Program Files/Microsoft Visual Studio/2022/Community/Team Tools/Dynamic Code Coverage Tools/CodeCoverage.exe" ]] || \
  [[ -x "/c/Program Files/Microsoft Visual Studio/2022/BuildTools/Team Tools/Dynamic Code Coverage Tools/CodeCoverage.exe" ]]
}

# Resolve the Microsoft.CodeCoverage.Console executable path
_resolve_microsoft_codecoverage() {
  local _home="${HOME:-}"
  local _userprofile_posix=""

  command -v codecoverage 2>/dev/null && return
  command -v CodeCoverage 2>/dev/null && return
  command -v CodeCoverage.exe 2>/dev/null && return

  [[ -x "$_home/.dotnet/tools/codecoverage" ]] && printf '%s\n' "$_home/.dotnet/tools/codecoverage" && return
  [[ -x "$_home/.dotnet/tools/codecoverage.exe" ]] && printf '%s\n' "$_home/.dotnet/tools/codecoverage.exe" && return

  if [[ -n "${USERPROFILE:-}" ]]; then
    _userprofile_posix="${USERPROFILE//\\//}"
    [[ -x "$_userprofile_posix/.dotnet/tools/codecoverage.exe" ]] && printf '%s\n' "$_userprofile_posix/.dotnet/tools/codecoverage.exe" && return
  fi

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

_resolve_llvm_tool() {
  local tool="$1"
  local env_var="$2"
  local fallback_env_var="$3"
  local explicit="${!env_var:-}"
  local fallback="${!fallback_env_var:-}"
  local candidate
  for candidate in \
    "$explicit" \
    "$fallback" \
    "$tool" \
    "$tool-21" \
    "$tool-20" \
    "$tool-19" \
    "$tool-18" \
    "$tool-17" \
    "$tool-16"; do
    [[ -n "$candidate" ]] || continue
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  if command -v xcrun >/dev/null 2>&1; then
    candidate="$(xcrun -f "$tool" 2>/dev/null || true)"
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  return 1
}

_resolve_llvm_profdata() {
  _resolve_llvm_tool llvm-profdata KANO_LLVM_PROFDATA LLVM_PROFDATA
}

_resolve_llvm_cov() {
  _resolve_llvm_tool llvm-cov KANO_LLVM_COV LLVM_COV
}

# Check if LLVM coverage tools are available (llvm-profdata + llvm-cov)
_has_llvm_coverage() {
  _resolve_llvm_profdata >/dev/null 2>&1 && _resolve_llvm_cov >/dev/null 2>&1
}

# Convert a POSIX path (Git-Bash style /c/...) to a Windows native path (C:\...)
_to_win_path() {
  local p="$1"

  # Prefer cygpath when available for canonical Windows paths.
  if command -v cygpath >/dev/null 2>&1; then
    local converted
    converted="$(cygpath -w "$p" 2>/dev/null || true)"
    if [[ -n "$converted" ]]; then
      printf '%s\n' "$converted"
      return
    fi
  fi

  # Already a Windows path
  if [[ "$p" =~ ^[A-Za-z]:[/\\\\] ]]; then
    printf '%s\n' "${p//\//\\}"
    return
  fi
  # Git-Bash /drive/... form
  if [[ "$p" =~ ^/([a-zA-Z])(/.*)?$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]:-}"
    rest="${rest//\//\\}"
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
  local gather_mode="${KANO_CPP_INFRA_PGO_GATHER_MODE:-pgo}"

  if [[ "$coverage_tool" == "microsoft" && -n "$coverage_out" ]] && _has_microsoft_codecoverage; then
    local codecov_bin
    codecov_bin="$(_resolve_microsoft_codecoverage)"
    local cobertura_out="${coverage_out%.cobertura.xml}.cobertura.xml"
    local exe="$1"
    local exe_win
    exe_win="$(_to_win_path "$exe")"
    shift
    local supports_instrument=0
    if "$codecov_bin" --help 2>/dev/null | grep -qi "instrument"; then
      supports_instrument=1
    fi

    local ps_script="& '${exe_win//\'/\'\'}'"
    local _arg _arg_esc
    for _arg in "$@"; do
      _arg_esc=${_arg//\'/\'\'}
      ps_script+=" '${_arg_esc}'"
    done
    local wrapped_command
    wrapped_command="powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"$ps_script\""

    local cobertura_out_win
    cobertura_out_win="$(cygpath -w "$cobertura_out" 2>/dev/null || printf '%s' "$cobertura_out")"
    local settings_path="${cobertura_out%.cobertura.xml}.settings.xml"
    local settings_win

    mkdir -p "$(dirname "$cobertura_out")"
    cat > "$settings_path" <<EOF
<Configuration>
  <CodeCoverage>
    <ModulePaths>
      <IncludeDirectories>
        <Directory>$(_to_win_path "$(dirname "$exe")")</Directory>
      </IncludeDirectories>
    </ModulePaths>
  </CodeCoverage>
</Configuration>
EOF
    settings_win="$(cygpath -w "$settings_path" 2>/dev/null || printf '%s' "$settings_path")"

    pgo_debug_log "provider=microsoft tool=$codecov_bin output=$cobertura_out"
    pgo_debug_log "provider=microsoft supports-instrument=$supports_instrument"

    if [[ "$supports_instrument" == "1" && "$gather_mode" == "coverage" ]]; then
      pgo_debug_log "provider=microsoft instrument=$exe_win"
      MSYS2_ARG_CONV_EXCL='*' "$codecov_bin" instrument "$exe_win"
    elif [[ "$gather_mode" == "coverage" ]]; then
      echo "[pgo-gather] warning: microsoft tool has no instrument command; using collect --settings compatibility path" >&2
    else
      echo "[pgo-gather] warning: microsoft coverage outside coverage mode is best-effort; prefer KANO_CPP_INFRA_PGO_GATHER_MODE=coverage" >&2
    fi

    pgo_debug_log "provider=microsoft command=$wrapped_command"
    MSYS2_ARG_CONV_EXCL='*' "$codecov_bin" collect \
      --settings "$settings_win" \
      --output-format cobertura \
      --output "$cobertura_out_win" \
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
    pgo_debug_log "provider=opencppcoverage tool=$occ_bin output=$coverage_out"
    pgo_debug_log "provider=opencppcoverage binary=$binary_win args=$*"
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
    write_coverage_status_html "$html_dir" "Coverage tooling unavailable" "llvm-profdata or llvm-cov was not found on this agent." "$profraw_dir"
    return 0
  fi
  local llvm_profdata
  local llvm_cov
  llvm_profdata="$(_resolve_llvm_profdata)"
  llvm_cov="$(_resolve_llvm_cov)"

  local -a profraw_files=()
  while IFS= read -r -d '' f; do
    profraw_files+=("$f")
  done < <(find "$profraw_dir" -name "*.profraw" -type f -print0 2>/dev/null || true)

  if [[ ${#profraw_files[@]} -eq 0 ]]; then
    echo "[pgo-gather] no .profraw files found; skipping LLVM coverage HTML" >&2
    write_coverage_status_html "$html_dir" "Coverage data unavailable" "No LLVM .profraw files were produced by the profile-gather run." "$profraw_dir"
    return 0
  fi

  local merged_profdata="$profraw_dir/merged.profdata"
  echo "[pgo-gather] merging ${#profraw_files[@]} .profraw file(s) ..." >&2
  "$llvm_profdata" merge -sparse "${profraw_files[@]}" -o "$merged_profdata" || {
    echo "[pgo-gather] warning: llvm-profdata merge failed; skipping coverage HTML" >&2
    write_coverage_status_html "$html_dir" "Coverage merge failed" "llvm-profdata could not merge the collected .profraw files." "$profraw_dir"
    return 0
  }

  # Build llvm-cov show args: first binary as positional, rest as --object
  local primary_bin="${binaries[0]:-}"
  if [[ -z "$primary_bin" ]]; then
    echo "[pgo-gather] warning: no binaries for llvm-cov; skipping HTML" >&2
    write_coverage_status_html "$html_dir" "Coverage binaries unavailable" "No test binaries were available for llvm-cov HTML rendering." "$profraw_dir"
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
  echo "[pgo-gather] generating LLVM coverage HTML with $llvm_cov ..." >&2
  "$llvm_cov" show "${show_args[@]}" >/dev/null 2>&1 || {
    echo "[pgo-gather] warning: llvm-cov show failed; trying without ignore regex" >&2
    "$llvm_cov" show "$primary_bin" -instr-profile="$merged_profdata" -format=html -output-dir="$html_dir" >/dev/null 2>&1 || {
      echo "[pgo-gather] warning: llvm-cov show failed entirely" >&2
      write_coverage_status_html "$html_dir" "Coverage render failed" "llvm-cov could not render the collected profile data." "$profraw_dir"
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
  if "$llvm_cov" export "${export_args[@]}" > "$llvm_json" 2>/dev/null; then
    "$PYTHON_BIN" "$SCRIPT_DIR/../lib/llvm_json_to_cobertura.py" "$llvm_json" "$CPP_ROOT" "$cobertura_out" 2>/dev/null || true
  fi
}

write_coverage_status_html() {
  local html_dir="$1"
  local title="$2"
  local detail="$3"
  local raw_dir="${4:-}"

  mkdir -p "$html_dir"
  "$PYTHON_BIN" - "$html_dir/index.html" "$title" "$detail" "$raw_dir" <<'PY'
import html
import sys
from pathlib import Path

out = Path(sys.argv[1])
title = sys.argv[2]
detail = sys.argv[3]
raw_dir = Path(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None
files = []
if raw_dir and raw_dir.exists():
    for pattern in ("*.cobertura.xml", "*.profraw", "*.json", "*.log", "*.txt"):
        files.extend(sorted(raw_dir.glob(pattern)))

def esc(value):
    return html.escape(str(value), quote=True)

items = "\n".join(f"<li><code>{esc(path.name)}</code></li>" for path in files[:80])
if not items:
    items = "<li>No raw coverage files were found.</li>"

out.write_text(f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{esc(title)}</title>
  <style>
    body {{ font-family: Segoe UI, Arial, sans-serif; margin: 2rem; line-height: 1.5; color: #24292f; }}
    h1 {{ margin: 0 0 0.75rem; font-size: 1.8rem; }}
    .panel {{ border: 1px solid #d0d7de; border-radius: 8px; padding: 1rem 1.25rem; background: #f6f8fa; max-width: 920px; }}
    code {{ background: #eef2f6; padding: 0.1rem 0.3rem; border-radius: 4px; }}
    ul {{ margin-bottom: 0; }}
  </style>
</head>
<body>
  <h1>{esc(title)}</h1>
  <div class="panel">
    <p>{esc(detail)}</p>
    <p>Raw directory: <code>{esc(raw_dir or "")}</code></p>
    <h2>Raw Inputs</h2>
    <ul>{items}</ul>
  </div>
</body>
</html>
""", encoding="utf-8")
PY
  echo "[pgo-gather] coverage status HTML: $html_dir/index.html" >&2
}

# Generate HTML coverage report from Cobertura XML files (Windows: microsoft or opencppcoverage).
generate_coverage_html() {
  local raw_dir="$1"
  local html_dir="$2"

  local -a xml_files=()
  while IFS= read -r -d '' f; do
    xml_files+=("$f")
  done < <(find "$raw_dir" -name "*.cobertura.xml" -type f -print0 2>/dev/null || true)

  if [[ ${#xml_files[@]} -eq 0 ]]; then
    echo "[pgo-gather] no .cobertura.xml files found; publishing coverage status HTML" >&2
    write_coverage_status_html "$html_dir" "Coverage data unavailable" "No Cobertura XML reports were produced by the profile-gather run." "$raw_dir"
    return 0
  fi

  # Keep only non-empty Cobertura files (lines-valid > 0).
  local -a nonempty_xml_files=()
  local xml
  for xml in "${xml_files[@]}"; do
    if "$PYTHON_BIN" - "$xml" <<'PY'
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
    dump_cobertura_debug_summary "$raw_dir"
    echo "[pgo-gather] all Cobertura XML reports are empty; publishing coverage status HTML" >&2
    write_coverage_status_html "$html_dir" "Coverage data empty" "Cobertura XML was produced, but all reports had zero valid lines." "$raw_dir"
    return 0
  fi

  local skill_root best_xml
  skill_root="$(resolve_test_skill_root 2>/dev/null || true)"
  if [[ -n "$skill_root" ]] && [[ -f "$skill_root/src/shell/reports/common/render_coverage_report.py" ]]; then
    best_xml="$("$PYTHON_BIN" - "${nonempty_xml_files[@]}" <<'PY'
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
      if "$PYTHON_BIN" "$skill_root/src/shell/reports/common/render_coverage_report.py" "$best_xml" "$html_dir" "$CPP_ROOT"; then
        echo "[pgo-gather] coverage HTML: $html_dir/index.html" >&2
        return 0
      fi
      echo "[pgo-gather] warning: skill coverage renderer failed; falling back to reportgenerator" >&2
    fi
  fi

  if ! _has_reportgenerator; then
    echo "[pgo-gather] reportgenerator not available; publishing coverage status HTML" >&2
    write_coverage_status_html "$html_dir" "Coverage renderer unavailable" "Non-empty Cobertura XML exists, but neither the skill coverage renderer nor reportgenerator could render it." "$raw_dir"
    return 0
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
  local in_progress="${7:-}"

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

  echo "[pgo-gather] running ${in_progress:+$in_progress }$in_label (${in_filter:-all-tests})" >&2
  pgo_verbose_log "${in_progress:+$in_progress }log: $log_path"
  if _run_with_coverage "$cov_filter" "$in_candidate" "${args[@]}" >"$log_path" 2>&1; then
    sync_llvm_profile_for_pgo_merge "$cov_filter"
    if [[ -f "$report_tmp" ]]; then
      mv -f "$report_tmp" "$report_path"
      echo "[pgo-gather] pass $in_label" >&2
      return 0
    fi
    echo "[pgo-gather] warning: $in_label finished without junit output; treating as failure" >&2
  fi
  if [[ -f "$report_tmp" ]]; then
    mv -f "$report_tmp" "$report_path"
    echo "[pgo-gather] warning: $in_label exited non-zero but produced junit; preserving report" >&2
    return 0
  fi

  local fallback_disabled=0
  if [[ "${KANO_CPP_INFRA_COVERAGE_DISABLE_FALLBACK:-1}" == "1" ]]; then
    fallback_disabled=1
    echo "[pgo-gather] fallback disabled: skipping full-binary/no-coverage retries for $in_label" >&2
  fi

  if [[ "$fallback_disabled" -eq 1 ]]; then
    rm -f "$report_tmp"
    cat > "$report_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="$in_label" errors="0" failures="1" skipped="0" tests="1" time="0">
    <testcase classname="$in_label" name="pgo-gather-run" time="0">
      <failure message="pgo-gather execution failed with fallback disabled; inspect $log_path"/>
    </testcase>
  </testsuite>
</testsuites>
EOF
    return 1
  fi

  echo "[pgo-gather] warning: $in_label failed for filter '${in_filter:-all-tests}', retry full binary" >&2
  rm -f "$report_tmp"
  if _run_with_coverage "$cov_fallback" "$in_candidate" --order lex --rng-seed 1337 "${reporter_args_tmp[@]}" >"$log_path" 2>&1; then
    sync_llvm_profile_for_pgo_merge "$cov_fallback"
    if [[ -f "$report_tmp" ]]; then
      mv -f "$report_tmp" "$report_path"
      echo "[pgo-gather] pass $in_label (fallback all-tests)" >&2
      return 0
    fi
    echo "[pgo-gather] warning: $in_label fallback finished without junit output; treating as failure" >&2
  fi
  if [[ -f "$report_tmp" ]]; then
    mv -f "$report_tmp" "$report_path"
    echo "[pgo-gather] warning: $in_label fallback exited non-zero but produced junit; preserving report" >&2
    return 0
  fi

  # If coverage wrapper crashes (common with some Windows binaries), preserve real
  # test counts by retrying without coverage instrumentation.
  if [[ -n "${KANO_CPP_INFRA_COVERAGE_TOOL:-}" ]]; then
    echo "[pgo-gather] warning: $in_label coverage execution failed; retrying without coverage" >&2
    rm -f "$report_tmp"

    if [[ -n "$in_filter" ]]; then
      if "$in_candidate" --order lex --rng-seed 1337 --durations yes "$in_filter" "${reporter_args_tmp[@]}" >>"$log_path" 2>&1; then
        if [[ -f "$report_tmp" ]]; then
          mv -f "$report_tmp" "$report_path"
          echo "[pgo-gather] pass $in_label (no-coverage filtered retry)" >&2
          return 0
        fi
      fi
      if [[ -f "$report_tmp" ]]; then
        mv -f "$report_tmp" "$report_path"
        echo "[pgo-gather] warning: $in_label no-coverage filtered retry exited non-zero but produced junit; preserving report" >&2
        return 0
      fi
    fi

    rm -f "$report_tmp"
    if "$in_candidate" --order lex --rng-seed 1337 "${reporter_args_tmp[@]}" >>"$log_path" 2>&1; then
      if [[ -f "$report_tmp" ]]; then
        mv -f "$report_tmp" "$report_path"
        echo "[pgo-gather] pass $in_label (no-coverage fallback all-tests)" >&2
        return 0
      fi
    fi
    if [[ -f "$report_tmp" ]]; then
      mv -f "$report_tmp" "$report_path"
      echo "[pgo-gather] warning: $in_label no-coverage fallback exited non-zero but produced junit; preserving report" >&2
      return 0
    fi
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

sync_llvm_profile_for_pgo_merge() {
  local profile_path="${1:-}"
  [[ "${KANO_CPP_INFRA_COVERAGE_TOOL:-}" == "llvm" ]] || return 0
  [[ -n "$profile_path" && -f "$profile_path" ]] || return 0
  [[ -n "${INF_PGO_COLLECT_DIR:-}" ]] || return 0

  mkdir -p "$INF_PGO_COLLECT_DIR"
  cp -f "$profile_path" "$INF_PGO_COLLECT_DIR/$(basename "$profile_path")"
}

_render_junit_html_reports_fallback() {
  local in_reports_dir="$1"
  local html_root="$2"

  mkdir -p "$html_root"

  "$PYTHON_BIN" - "$in_reports_dir" "$html_root" <<'PY'
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

  local reports_root
  reports_root="$(cd -- "$html_root/.." && pwd)"
  local tmp_result_dir="$reports_root/raw/.tmp-test-result"
  mkdir -p "$tmp_result_dir" "$html_root" "$reports_root/raw"

  "$PYTHON_BIN" - "$in_reports_dir" "$tmp_result_dir/ctest-report.xml" <<'PY'
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
        suite_total = int(suite.attrib.get("tests", "0") or "0")
        suite_failures = int(suite.attrib.get("failures", "0") or "0")
        suite_errors = int(suite.attrib.get("errors", "0") or "0")
        suite_skipped = int(suite.attrib.get("skipped", "0") or "0")
        testcases = list(suite.findall("testcase"))

        if not testcases:
            # Fallback: keep one synthetic entry if no testcase nodes exist.
            status = "failed" if suite_failures or suite_errors else ("notrun" if suite_skipped else "passed")

            test_el = ET.SubElement(testing, "Test", {"Status": status})
            ET.SubElement(test_el, "Name").text = suite_name
            ET.SubElement(test_el, "FullName").text = suite_name
            ET.SubElement(test_el, "CompletionStatus").text = status
            ET.SubElement(test_el, "ExecutionTime").text = suite.attrib.get("time", "0")

            results = ET.SubElement(test_el, "Results")
            nm_w = ET.SubElement(results, "NamedMeasurement", {"name": "Warnings"})
            ET.SubElement(nm_w, "Value").text = "0"
            nm_e = ET.SubElement(results, "NamedMeasurement", {"name": "Errors"})
            ET.SubElement(nm_e, "Value").text = str(suite_errors + suite_failures)
            continue

        emitted = 0
        emitted_failed = 0
        emitted_skipped = 0
        for tc in testcases:
            tc_name = tc.attrib.get("name", "unnamed")
            tc_time = tc.attrib.get("time", "0")
            full_name = f"{suite_name}::{tc_name}"

            has_failure = tc.find("failure") is not None
            has_error = tc.find("error") is not None
            has_skipped = tc.find("skipped") is not None
            status = "failed" if has_failure or has_error else ("notrun" if has_skipped else "passed")

            test_el = ET.SubElement(testing, "Test", {"Status": status})
            ET.SubElement(test_el, "Name").text = tc_name
            ET.SubElement(test_el, "FullName").text = full_name
            ET.SubElement(test_el, "CompletionStatus").text = status
            ET.SubElement(test_el, "ExecutionTime").text = tc_time

            results = ET.SubElement(test_el, "Results")
            nm_w = ET.SubElement(results, "NamedMeasurement", {"name": "Warnings"})
            ET.SubElement(nm_w, "Value").text = "0"
            nm_e = ET.SubElement(results, "NamedMeasurement", {"name": "Errors"})
            ET.SubElement(nm_e, "Value").text = "1" if (has_failure or has_error) else "0"

            emitted += 1
            if has_failure or has_error:
                emitted_failed += 1
            if has_skipped:
                emitted_skipped += 1

        # Catch2 JUnit often reports full totals in suite attributes while only
        # emitting testcase nodes for a subset. Fill the gap so renderer totals
        # reflect the actual suite test count.
        missing = max(0, suite_total - emitted)
        remaining_failed = max(0, (suite_failures + suite_errors) - emitted_failed)
        remaining_skipped = max(0, suite_skipped - emitted_skipped)
        for idx in range(missing):
            if idx < remaining_failed:
                status = "failed"
                err_value = "1"
            elif idx < remaining_failed + remaining_skipped:
                status = "notrun"
                err_value = "0"
            else:
                status = "passed"
                err_value = "0"

            tc_name = f"{suite_name}::synthetic-{idx + 1}"
            test_el = ET.SubElement(testing, "Test", {"Status": status})
            ET.SubElement(test_el, "Name").text = tc_name
            ET.SubElement(test_el, "FullName").text = tc_name
            ET.SubElement(test_el, "CompletionStatus").text = status
            ET.SubElement(test_el, "ExecutionTime").text = "0"

            results = ET.SubElement(test_el, "Results")
            nm_w = ET.SubElement(results, "NamedMeasurement", {"name": "Warnings"})
            ET.SubElement(nm_w, "Value").text = "0"
            nm_e = ET.SubElement(results, "NamedMeasurement", {"name": "Errors"})
            ET.SubElement(nm_e, "Value").text = err_value

out_xml.parent.mkdir(parents=True, exist_ok=True)
ET.ElementTree(site).write(out_xml, encoding="utf-8", xml_declaration=True)
PY

  local coverage_xml=""
  coverage_xml="$(find "$reports_root/coverage/raw" -maxdepth 2 -type f \( -name '*.cobertura.xml' -o -name 'cobertura.xml' -o -name 'coverage.xml' \) 2>/dev/null | head -n 1 || true)"

  if ! KANO_TEST_XML="$tmp_result_dir/ctest-report.xml" \
    KANO_COVERAGE_XML="$coverage_xml" \
    "$PYTHON_BIN" "$skill_root/src/shell/reports/common/kano-cpp-report-adapter" \
      --report-root "$reports_root" \
      --slug "pgo-gather" \
      --title "PGO Gather Feature Report" \
      --output "$reports_root/raw/kano-report-site-v1.json"; then
    echo "[pgo-gather] warning: skill adapter failed; using fallback html renderer" >&2
    _render_junit_html_reports_fallback "$in_reports_dir" "$html_root"
    return
  fi

  if ! "$PYTHON_BIN" "$skill_root/src/shell/reports/common/kano-report-site-renderer" \
    "$reports_root/raw/kano-report-site-v1.json" \
    "$html_root"; then
    echo "[pgo-gather] warning: skill site renderer failed; using fallback html renderer" >&2
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

  "$PYTHON_BIN" - "$reports_root" "$html_dir" "$coverage_html_dir" "$reports_dir" "$logs_dir" "${KANO_CPP_INFRA_COVERAGE_TOOL:-none}" "${KANO_CPP_INFRA_PGO_GATHER_QUICK:-0}" <<'PY'
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
  local host_name

  host_name="$(uname -s 2>/dev/null || true)"

  preset_name="$(resolve_collect_preset)"
  bin_root="$CPP_ROOT/out/bin/$preset_name/debug"
  reports_root="$CPP_ROOT/.kano/tmp/pgo/gather-reports"
  reports_dir="$reports_root/junit"
  logs_dir="$reports_root/logs"
  html_dir="$reports_root/html"
  local coverage_raw_dir="$reports_root/coverage/raw"
  local coverage_html_dir="$reports_root/coverage/html"
  local debug_dir="$reports_root/debug"

  if ! rm -rf "$reports_root" 2>/dev/null; then
    echo "[pgo-gather] warning: failed to remove $reports_root (likely file lock); cleaning files in-place" >&2
    find "$reports_root" -type f -delete 2>/dev/null || true
  fi
  mkdir -p "$reports_dir" "$logs_dir" "$html_dir" "$coverage_raw_dir"
  if is_pgo_debug_enabled; then
    mkdir -p "$debug_dir"
    export KANO_CPP_INFRA_PGO_DEBUG_DIR="$debug_dir"
    pgo_debug_log "debug enabled; artifacts dir: $debug_dir"
  else
    unset KANO_CPP_INFRA_PGO_DEBUG_DIR || true
  fi

  if is_windows_host; then
    exe_ext=".exe"
  fi

  if [[ "$gather_mode" == "pgo" ]]; then
    ensure_windows_pgo_runtime_path
  fi

  # Auto-select coverage tool based on platform (can be overridden by KANO_CPP_INFRA_COVERAGE_TOOL)
  local coverage_tool="${KANO_CPP_INFRA_COVERAGE_TOOL:-}"
  if [[ "$coverage_tool" == "none" ]]; then
    coverage_tool=""
  fi

  if [[ -z "$coverage_tool" ]]; then
    if is_windows_host; then
      if _has_opencppcoverage; then
        coverage_tool="opencppcoverage"
      elif _has_microsoft_codecoverage; then
        coverage_tool="microsoft"
      fi
    elif _has_llvm_coverage; then
      coverage_tool="llvm"
    fi
  fi
  export KANO_CPP_INFRA_COVERAGE_TOOL="${coverage_tool:-}"

  if [[ -n "$coverage_tool" ]]; then
    echo "[pgo-gather] coverage collection: $coverage_tool (output: $coverage_raw_dir)" >&2
    if is_pgo_debug_enabled; then
      if [[ "$coverage_tool" == "opencppcoverage" ]]; then
        {
          echo "tool=$(_resolve_opencppcoverage || true)"
          "$(_resolve_opencppcoverage || printf 'OpenCppCoverage')" --version 2>&1 || true
        } > "$debug_dir/tool-version-opencppcoverage.log" 2>&1
      elif [[ "$coverage_tool" == "microsoft" ]]; then
        {
          echo "tool=$(_resolve_microsoft_codecoverage || true)"
          "$(_resolve_microsoft_codecoverage || printf 'codecoverage')" --version 2>&1 || true
        } > "$debug_dir/tool-version-microsoft.log" 2>&1
      fi
    fi
  else
    echo "[pgo-gather] coverage collection: disabled (no supported tool found)" >&2
  fi

  echo "[pgo-gather] using gather mode: $gather_mode, preset: $preset_name" >&2
  # PGO gather is a training workload, not the authoritative test pass. Keep
  # CLI coverage on short, non-mutating command paths; the later test stage
  # runs the full functional suite and publishes the authoritative JUnit.
  # - commit-plan engine + properties
  # - export/archive paths
  # - TUI command-state/autocomplete paths
  local -a suite=(
    "kano_git_cli_tests|[cli]"
    "kano_git_commit_plan_tests|[unit],[property]"
    "kano_git_export_tests|[unit],[integration]"
    "kano_git_tui_tests|[unit],[property]"
  )

  # Quick mode keeps the full PGO workflow but reduces gather runtime by
  # running only a minimal representative test subset.
  if [[ "${KANO_CPP_INFRA_PGO_GATHER_QUICK:-0}" == "1" ]]; then
    echo "[pgo-gather] quick mode enabled: reduced gather suite" >&2
    case "${KANO_CPP_INFRA_PGO_GATHER_QUICK_SUITE:-}" in
      cli)
        suite=(
          "kano_git_cli_tests|[cli]"
        )
        ;;
      tui)
        suite=(
          "kano_git_tui_tests|[unit],[property]"
        )
        ;;
      *)
        if [[ "$host_name" == "Darwin" ]]; then
          suite=(
            "kano_git_tui_tests|[unit],[property]"
          )
        else
          suite=(
            "kano_git_tui_tests|[unit],[property]"
          )
        fi
        ;;
    esac
    if [[ -n "${KANO_CPP_INFRA_PGO_GATHER_QUICK_SUITE:-}" ]]; then
      echo "[pgo-gather] quick suite override: ${KANO_CPP_INFRA_PGO_GATHER_QUICK_SUITE}" >&2
    fi
  fi

  local -a collected_binaries=()
  local suite_total="${#suite[@]}"
  local suite_index=0

  echo "[pgo-gather] suite progress: 0/$suite_total queued" >&2

  for suite_entry in "${suite[@]}"; do
    IFS='|' read -r test_bin filter <<< "$suite_entry"
    label="${test_bin}"
    candidate="$bin_root/$test_bin$exe_ext"
    suite_index=$((suite_index + 1))
    local progress_tag="[$suite_index/$suite_total]"

    if [[ ! -f "$candidate" ]]; then
      echo "[pgo-gather] missing collect test binary: $candidate" >&2
      exit 1
    fi

    # Catch2 v3 uses --list-tests. Keep a cheap preflight list to confirm binary health.
    if ! "$candidate" --list-tests >"$logs_dir/${label}.list.log" 2>&1; then
      echo "[pgo-gather] warning: $label failed --list-tests preflight; continuing" >&2
    fi

    if is_pgo_verbose_enabled; then
      local selected_count="unknown"
      local selected_list=""
      if [[ -n "$filter" ]]; then
        selected_list="$("$candidate" --list-tests "$filter" 2>/dev/null || true)"
      else
        selected_list="$("$candidate" --list-tests 2>/dev/null || true)"
      fi
      if [[ -n "$selected_list" ]]; then
        local parsed_count
        parsed_count="$(printf '%s\n' "$selected_list" | awk '/test cases/{print $1; exit}')"
        if [[ -n "$parsed_count" && "$parsed_count" =~ ^[0-9]+$ ]]; then
          selected_count="$parsed_count"
        fi
      fi
      pgo_verbose_log "$progress_tag $label selected-tests=$selected_count filter='${filter:-all-tests}'"
    fi

    collected_binaries+=("$candidate")

    if run_collect_case "$candidate" "$label" "$filter" "$reports_dir" "$logs_dir" "$coverage_raw_dir" "$progress_tag"; then
      passed_count=$((passed_count + 1))
    else
      failed_count=$((failed_count + 1))
    fi

    echo "[pgo-gather] suite progress: $suite_index/$suite_total done (passed=$passed_count failed=$failed_count)" >&2
  done

  if [[ "${KANO_CPP_INFRA_COVERAGE_TOOL:-}" == "microsoft" ]] && is_windows_host; then
    local nonempty_count
    nonempty_count="$(count_nonempty_cobertura_files "$coverage_raw_dir")"
    if [[ "$nonempty_count" == "0" ]] && _has_opencppcoverage; then
      if [[ "${KANO_CPP_INFRA_COVERAGE_DISABLE_FALLBACK:-1}" == "1" ]]; then
        echo "[pgo-gather] fallback disabled: skipping OpenCppCoverage retry after empty Microsoft Cobertura" >&2
      else
      local previous_coverage_tool="${KANO_CPP_INFRA_COVERAGE_TOOL:-}"
      echo "[pgo-gather] Microsoft coverage produced only empty Cobertura reports; retrying kano_git_tui_tests with OpenCppCoverage" >&2
      export KANO_CPP_INFRA_COVERAGE_TOOL="opencppcoverage"
      if run_collect_case \
        "$bin_root/kano_git_tui_tests$exe_ext" \
        "kano_git_tui_tests" \
        "[unit],[property]" \
        "$reports_dir" \
        "$logs_dir" \
        "$coverage_raw_dir" \
        "[fallback]"; then
        echo "[pgo-gather] OpenCppCoverage fallback for kano_git_tui_tests completed" >&2
      else
        echo "[pgo-gather] warning: OpenCppCoverage fallback for kano_git_tui_tests failed" >&2
      fi

      nonempty_count="$(count_nonempty_cobertura_files "$coverage_raw_dir")"
      if [[ "$nonempty_count" == "0" ]]; then
        local occ_bin
        occ_bin="$(_resolve_opencppcoverage)"

        echo "[pgo-gather] OpenCppCoverage wrapper path still empty; running direct OpenCppCoverage fallback command" >&2
        (
          cd "$CPP_ROOT"
          local exe_rel="out/bin/$preset_name/debug/kano_git_tui_tests$exe_ext"
          local cov_rel=".kano/tmp/pgo/gather-reports/coverage/raw/kano_git_tui_tests_opencpp_fallback.cobertura.xml"
          local junit_rel=".kano/tmp/pgo/gather-reports/junit/kano_git_tui_tests_opencpp_fallback.xml"
          local src_win exe_win cov_win junit_win
          src_win="$(cygpath -w "code")"
          exe_win="$(cygpath -w "$exe_rel")"
          cov_win="$(cygpath -w "$cov_rel")"
          junit_win="$(cygpath -w "$junit_rel")"

          MSYS2_ARG_CONV_EXCL='*' "$occ_bin" \
            --sources "$src_win" \
            --cover_children \
            --export_type "cobertura:$cov_win" \
            --quiet \
            -- "$exe_win" \
              --order lex --rng-seed 1337 --durations yes "[unit],[property]" \
              --reporter junit "--out=$junit_win"
        ) >"$logs_dir/kano_git_tui_tests_opencpp_fallback.log" 2>&1 || true
      fi

      export KANO_CPP_INFRA_COVERAGE_TOOL="$previous_coverage_tool"
      fi
    fi
  fi

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

  dump_cobertura_debug_summary "$coverage_raw_dir"

  render_junit_html_reports "$reports_dir" "$html_dir"
  if [[ -n "${KANO_CPP_INFRA_COVERAGE_TOOL:-}" ]]; then
    if [[ "${KANO_CPP_INFRA_COVERAGE_TOOL:-}" == "llvm" ]]; then
      generate_llvm_coverage_html "$coverage_raw_dir" "$coverage_html_dir" "${collected_binaries[@]}"
    else
      generate_coverage_html "$coverage_raw_dir" "$coverage_html_dir"
    fi
  else
    echo "[pgo-gather] coverage HTML skipped (coverage disabled for this run)" >&2
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
