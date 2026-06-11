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
#   KANO_CPP_INFRA_PGO_GATHER_WITH_COVERAGE
#       Set to 1/true to auto-select a coverage tool while running the PGO gather
#       preset. By default PGO gather runs tests directly and leaves coverage to
#       the dedicated coverage stage.
#
#   KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET
#       Override the auto-detected preset name.
#
#   KANO_CPP_INFRA_PGO_GATHER_CLI_FILTER
#       Override the CLI training test filter. The default is a stable
#       infrastructure smoke; full functional coverage belongs in the later test
#       stage, not the PGO profile-gather stage.
#
#   KANO_CPP_INFRA_PGO_GATHER_COMMIT_PLAN_FILTER
#   KANO_CPP_INFRA_PGO_GATHER_EXPORT_FILTER
#   KANO_CPP_INFRA_PGO_GATHER_TUI_FILTER
#       Override the remaining training filters. Defaults are intentionally
#       short representative smoke tests; exhaustive unit/property/integration
#       coverage belongs in the later automation test stage.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)}"
REPORT_SKILL_ADAPTER_SH="$SCRIPT_DIR/../lib/report_skill_adapter.sh"
. "$SCRIPT_DIR/../lib/native_tool.sh"

if [[ -f "$REPORT_SKILL_ADAPTER_SH" ]]; then
  # shellcheck disable=SC1090
  source "$REPORT_SKILL_ADAPTER_SH"
fi

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

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_windows_host() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

is_macos_host() {
  [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]
}

is_arm64_host() {
  case "$(uname -m 2>/dev/null || true)" in
    arm64|aarch64) return 0 ;;
    *) return 1 ;;
  esac
}

cmake_preset_exists() {
  local preset_name="$1"
  kano_cpp_infra_tool cmake-preset-exists "$CPP_ROOT/CMakePresets.json" "$preset_name"
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

  kano_cpp_infra_tool dump-cobertura-summary "$raw_dir" "$out_file"

  pgo_debug_log "cobertura summary written: $out_file"
}

count_nonempty_cobertura_files() {
  local raw_dir="$1"
  kano_cpp_infra_tool count-nonempty-cobertura "$raw_dir"
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
    kano_cpp_infra_tool cobertura-lines-valid "$1"
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
  
  if [[ -n "${KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET:-}" ]]; then
    printf '%s\n' "$KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET"
    return 0
  fi

  if [[ "$gather_mode" == "coverage" ]]; then
    # Use coverage presets to gather data (unified with PGO collect for comprehensive testing)
    if is_windows_host; then
      first_existing_preset windows-ninja-msvc-coverage windows-ninja-msvc windows-ninja-clang-coverage windows-ninja-clang
      return $?
    elif is_macos_host; then
      if is_arm64_host; then
        first_existing_preset macos-ninja-clang-arm64-coverage macos-ninja-clang-arm64 macos-ninja-clang-coverage macos-ninja-clang
      else
        first_existing_preset macos-ninja-clang-x64-coverage macos-ninja-clang-x64 macos-ninja-clang-coverage macos-ninja-clang
      fi
      return $?
    fi
    first_existing_preset linux-ninja-clang-coverage linux-ninja-gcc-coverage linux-ninja-clang linux-ninja-gcc
    return $?
  fi

  # Default: PGO collect mode
  if is_windows_host; then
    first_existing_preset windows-ninja-msvc-pgo-collect windows-ninja-msvc windows-ninja-clang-pgo-collect windows-ninja-clang
    return $?
  fi

  if is_macos_host; then
    if is_arm64_host; then
      first_existing_preset macos-ninja-clang-arm64-pgo-collect macos-ninja-clang-arm64 macos-ninja-clang-pgo-collect macos-ninja-clang
    else
      first_existing_preset macos-ninja-clang-x64-pgo-collect macos-ninja-clang-x64 macos-ninja-clang-pgo-collect macos-ninja-clang
    fi
    return $?
  fi

  first_existing_preset linux-ninja-gcc-pgo-collect linux-ninja-gcc linux-ninja-clang-pgo-collect linux-ninja-clang
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

# Check if LLVM coverage tools are available (llvm-profdata + llvm-cov)
_has_llvm_coverage() {
  command -v llvm-profdata >/dev/null 2>&1 && command -v llvm-cov >/dev/null 2>&1
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
    kano_cpp_infra_tool llvm-json-to-cobertura "$llvm_json" "$CPP_ROOT" "$cobertura_out" 2>/dev/null || true
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
    if kano_cpp_infra_tool cobertura-has-lines "$xml"
    then
      nonempty_xml_files+=("$xml")
    fi
  done

  if [[ ${#nonempty_xml_files[@]} -eq 0 ]]; then
    dump_cobertura_debug_summary "$raw_dir"
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

_render_junit_html_reports_fallback() {
  local in_reports_dir="$1"
  local html_root="$2"

  mkdir -p "$html_root"
  kano_cpp_infra_tool junit-html-fallback "$in_reports_dir" "$html_root"
}

render_junit_html_reports() {
  local in_reports_dir="$1"
  local html_root="$2"

  _render_junit_html_reports_fallback "$in_reports_dir" "$html_root"
}

render_reports_homepage() {
  local reports_root="$1"
  local html_dir="$2"
  local coverage_html_dir="$3"
  local reports_dir="$4"
  local logs_dir="$5"

  mkdir -p "$reports_root"

  kano_cpp_infra_tool reports-homepage "$reports_root" "$html_dir" "$coverage_html_dir" "$reports_dir" "$logs_dir" "${KANO_CPP_INFRA_COVERAGE_TOOL:-none}" "${KANO_CPP_INFRA_PGO_GATHER_QUICK:-0}"
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

  # Auto-select coverage tool only for explicit coverage lanes. PGO gather should
  # run tests directly by default so coverage wrapper instability cannot corrupt
  # profile gathering or JUnit output.
  local coverage_tool="${KANO_CPP_INFRA_COVERAGE_TOOL:-}"
  local coverage_tool_explicit=0
  if [[ -n "${KANO_CPP_INFRA_COVERAGE_TOOL+x}" ]]; then
    coverage_tool_explicit=1
  fi
  if [[ "$coverage_tool" == "none" ]]; then
    coverage_tool=""
  fi

  local auto_select_coverage=0
  if [[ "$gather_mode" == "coverage" ]] || is_truthy "${KANO_CPP_INFRA_PGO_GATHER_WITH_COVERAGE:-0}"; then
    auto_select_coverage=1
  fi

  if [[ -z "$coverage_tool" && "$coverage_tool_explicit" -eq 0 && "$auto_select_coverage" -eq 1 ]]; then
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
  local cli_training_filter="${KANO_CPP_INFRA_PGO_GATHER_CLI_FILTER:-[functional][infrastructure]}"
  local commit_plan_training_filter="${KANO_CPP_INFRA_PGO_GATHER_COMMIT_PLAN_FILTER:-[Unit][SerializePlanJson]}"
  local export_training_filter="${KANO_CPP_INFRA_PGO_GATHER_EXPORT_FILTER:-[tdd][unit][feature:kog-export-upload][config]}"
  local tui_training_filter="${KANO_CPP_INFRA_PGO_GATHER_TUI_FILTER:-[unit]}"

  # - CLI smoke path
  # - commit-plan engine + properties
  # - export/archive paths
  # - TUI command-state/autocomplete paths
  local -a suite=(
    "kano_git_cli_tests|$cli_training_filter"
    "kano_git_commit_plan_tests|$commit_plan_training_filter"
    "kano_git_export_tests|$export_training_filter"
    "kano_git_tui_tests|$tui_training_filter"
  )

  # Quick mode keeps the full PGO workflow but reduces gather runtime by
  # running only a minimal representative test subset.
  if [[ "${KANO_CPP_INFRA_PGO_GATHER_QUICK:-0}" == "1" ]]; then
    echo "[pgo-gather] quick mode enabled: reduced gather suite" >&2
    suite=(
      "kano_git_tui_tests|$tui_training_filter"
    )
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
