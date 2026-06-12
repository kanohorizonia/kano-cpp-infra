#!/usr/bin/env bash
set -euo pipefail

KANO_CPP_INFRA_NATIVE_TOOL_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KANO_CPP_INFRA_NATIVE_TOOL_CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-${KANO_CPP_ROOT:-$(cd -- "$KANO_CPP_INFRA_NATIVE_TOOL_LIB_DIR/../../../.." && pwd)}}"

kano_cpp_infra_resolve_native_tool() {
  local exe_suffix=""
  local candidate=""

  if [[ -n "${KANO_CPP_INFRA_TOOL:-}" ]]; then
    if [[ -x "$KANO_CPP_INFRA_TOOL" || -f "$KANO_CPP_INFRA_TOOL" ]]; then
      printf '%s\n' "$KANO_CPP_INFRA_TOOL"
      return 0
    fi
    echo "KANO_CPP_INFRA_TOOL is set but not found: $KANO_CPP_INFRA_TOOL" >&2
    return 1
  fi

  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) exe_suffix=".exe" ;;
  esac

  for candidate in \
    "$KANO_CPP_INFRA_NATIVE_TOOL_CPP_ROOT/out/bin/"*/release/kano-cpp-infra-tool"$exe_suffix" \
    "$KANO_CPP_INFRA_NATIVE_TOOL_CPP_ROOT/out/bin/"*/debug/kano-cpp-infra-tool"$exe_suffix" \
    "$KANO_CPP_INFRA_NATIVE_TOOL_CPP_ROOT/out/bin/"*/kano-cpp-infra-tool"$exe_suffix"
  do
    if [[ -x "$candidate" || -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Native kano-cpp-infra-tool was not found. Build it with pixi run build-dev." >&2
  return 1
}

kano_cpp_infra_tool_bootstrap_cache_args_to_cmake() {
  local raw="${1:-${INF_CMAKE_CACHE_ARGS_JSON:-}}"
  [[ -n "$raw" ]] || return 0

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$raw" |
      jq -r 'to_entries[] | "-D\(.key)=\((.value | if type == "boolean" then (if . then "ON" else "OFF" end) else tostring end))"'
    return 0
  fi

  raw="${raw#\{}"
  raw="${raw%\}}"
  local pair key value
  while IFS= read -r pair; do
    pair="${pair#"${pair%%[![:space:]]*}"}"
    pair="${pair%"${pair##*[![:space:]]}"}"
    [[ -n "$pair" ]] || continue
    key="${pair%%:*}"
    value="${pair#*:}"
    key="${key//\"/}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value%\"}"
    value="${value#\"}"
    case "$value" in
      true) value="ON" ;;
      false) value="OFF" ;;
    esac
    [[ -n "$key" ]] || continue
    printf -- '-D%s=%s\n' "$key" "$value"
  done < <(printf '%s\n' "$raw" | tr ',' '\n')
}

kano_cpp_infra_tool_bootstrap_cache_args_with_pgo_mode() {
  local mode="${1:?pgo mode is required}"
  local raw="${KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON:-${INF_CMAKE_CACHE_ARGS_JSON:-}}"

  if command -v jq >/dev/null 2>&1; then
    if [[ -n "$raw" ]]; then
      printf '%s' "$raw" |
        jq -c --arg mode "$mode" '. + {"KANO_CPP_INFRA_PGO_MODE": $mode} | if $mode == "use" and (has("KOG_BUILD_TESTS") | not) then . + {"KOG_BUILD_TESTS": "OFF"} else . end'
    else
      jq -cn --arg mode "$mode" '{"KANO_CPP_INFRA_PGO_MODE": $mode} | if $mode == "use" then . + {"KOG_BUILD_TESTS": "OFF"} else . end'
    fi
    return 0
  fi

  local extra="\"KANO_CPP_INFRA_PGO_MODE\":\"$mode\""
  if [[ "$mode" == "use" && "$raw" != *'"KOG_BUILD_TESTS"'* ]]; then
    extra="$extra,\"KOG_BUILD_TESTS\":\"OFF\""
  fi
  if [[ -z "$raw" || "$raw" == "{}" ]]; then
    printf '{%s}\n' "$extra"
  else
    raw="${raw%\}}"
    printf '%s,%s}\n' "$raw" "$extra"
  fi
}

kano_cpp_infra_tool_bootstrap_cmake_preset_exists() {
  local presets_json="${1:?CMakePresets.json is required}"
  local preset_name="${2:?preset name is required}"
  [[ -f "$presets_json" ]] || return 1

  if command -v jq >/dev/null 2>&1; then
    jq -e --arg name "$preset_name" '
      ([.configurePresets[]?.name, .buildPresets[]?.name] | index($name)) != null
    ' "$presets_json" >/dev/null
    return $?
  fi

  grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"${preset_name//\//\\/}\"" "$presets_json"
}

kano_cpp_infra_tool_json_string() {
  local text="${1:-}"
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  text="${text//$'\r'/\\r}"
  text="${text//$'\n'/\\n}"
  text="${text//$'\t'/\\t}"
  printf '"%s"' "$text"
}

kano_cpp_infra_tool_csv_json_array() {
  local raw="${1:-}"
  local first=1
  local item
  printf '['
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] || continue
    if [[ "$first" -eq 0 ]]; then
      printf ','
    fi
    first=0
    kano_cpp_infra_tool_json_string "$item"
  done
  printf ']'
}

kano_cpp_infra_tool_bootstrap_profile_run_manifest() {
  local compiler=""
  local coverage_provider=""
  local pgo_provider=""
  local mode=""
  local out=""
  local training_command=""
  local coverage_command=""
  local pgo_data_paths=""
  local coverage_report_paths=""
  local microsoft_server_mode=0

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --microsoft-server-mode)
        microsoft_server_mode=1
        shift
        ;;
      --compiler|--coverage-provider|--pgo-provider|--profile-run-mode|--out|--training-command|--coverage-command|--pgo-data-paths|--coverage-report-paths)
        local key="$1"
        shift
        if [[ "$#" -eq 0 ]]; then
          echo "profile-run-manifest missing value for $key" >&2
          return 2
        fi
        case "$key" in
          --compiler) compiler="$1" ;;
          --coverage-provider) coverage_provider="$1" ;;
          --pgo-provider) pgo_provider="$1" ;;
          --profile-run-mode) mode="$1" ;;
          --out) out="$1" ;;
          --training-command) training_command="$1" ;;
          --coverage-command) coverage_command="$1" ;;
          --pgo-data-paths) pgo_data_paths="$1" ;;
          --coverage-report-paths) coverage_report_paths="$1" ;;
        esac
        shift
        ;;
      *)
        echo "unknown profile-run-manifest argument: $1" >&2
        return 2
        ;;
    esac
  done

  if [[ -z "$out" ]]; then
    echo "profile-run-manifest requires --out" >&2
    return 2
  fi

  compiler="$(printf '%s' "${compiler:-${KANO_CXX_COMPILER:-msvc}}" | tr '[:upper:]' '[:lower:]')"
  coverage_provider="$(printf '%s' "${coverage_provider:-${KANO_CXX_COVERAGE_PROVIDER:-none}}" | tr '[:upper:]' '[:lower:]')"
  pgo_provider="$(printf '%s' "${pgo_provider:-${KANO_CXX_PGO_PROVIDER:-none}}" | tr '[:upper:]' '[:lower:]')"
  mode="$(printf '%s' "${mode:-${KANO_CXX_PROFILE_RUN_MODE:-pgo-rebuild}}" | tr '[:upper:]' '[:lower:]')"

  local unified_execution=false
  local unified_profile_data=false
  local split_lanes=true
  local coverage_subject="normal-test-binary"
  local collector_scope="none"
  local notes_json=""

  case "$mode" in
    pgo-gather-with-coverage)
      split_lanes=false
      if [[ "$compiler" == "msvc" && "$coverage_provider" == "opencppcoverage" && "$pgo_provider" == "msvc-pgo" ]]; then
        unified_execution=true
        coverage_subject="pgo-instrumented-training-binary"
        collector_scope="process-wrapper"
        notes_json="$(kano_cpp_infra_tool_json_string "MSVC training run wrapped by OpenCppCoverage; coverage output remains separate from .pgd/.pgc data.")"
      elif [[ "$compiler" == "msvc" && "$coverage_provider" == "microsoft-codecoverage" && "$pgo_provider" == "msvc-pgo" ]]; then
        echo "MSVC unified PGO+coverage execution is only supported with OpenCppCoverage. Microsoft.CodeCoverage.Console coverage output is not MSVC PGO training data." >&2
        return 2
      elif [[ "$compiler" == "clang" && "$coverage_provider" == "llvm-cov" && "$pgo_provider" == "llvm-profdata" ]]; then
        unified_execution=true
        unified_profile_data=true
        coverage_subject="llvm-instrumented-binary"
        collector_scope="process-wrapper"
        notes_json="$(kano_cpp_infra_tool_json_string "LLVM source-based instrumentation provides shared profile data for coverage and PGO.")"
      else
        echo "Unsupported unified profile combination: compiler=$compiler, coverageProvider=$coverage_provider, pgoProvider=$pgo_provider" >&2
        return 2
      fi
      ;;
    coverage-all)
      if [[ "$coverage_provider" == "microsoft-codecoverage" ]]; then
        coverage_subject="instrumented-coverage-binary"
        if [[ "$microsoft_server_mode" -eq 1 ]]; then
          collector_scope="local-session-server"
          notes_json="$(kano_cpp_infra_tool_json_string "Microsoft.CodeCoverage.Console server-mode is local/session detached collection, not remote telemetry.")"
        else
          collector_scope="process-wrapper"
        fi
      elif [[ "$coverage_provider" == "llvm-cov" ]]; then
        coverage_subject="llvm-instrumented-binary"
        collector_scope="process-wrapper"
      elif [[ "$coverage_provider" == "opencppcoverage" ]]; then
        coverage_subject="normal-test-binary"
        collector_scope="process-wrapper"
      fi
      ;;
    pgo-gather|pgo-rebuild)
      notes_json="$(kano_cpp_infra_tool_json_string "PGO lane only; coverage reports are not treated as training data.")"
      ;;
    *)
      echo "Unsupported profile run mode: $mode" >&2
      return 2
      ;;
  esac

  if [[ "$coverage_provider" == "microsoft-codecoverage" && "$microsoft_server_mode" -eq 1 && "$mode" != "coverage-all" ]]; then
    local extra_note
    extra_note="$(kano_cpp_infra_tool_json_string "microsoftServerMode requested outside coverage-all; collectorScope remains mode-derived.")"
    notes_json="${notes_json:+$notes_json,}$extra_note"
  fi

  mkdir -p "$(dirname "$out")"
  {
    printf '{\n'
    printf '  "schemaVersion": "1.0",\n'
    printf '  "profileRunMode": '; kano_cpp_infra_tool_json_string "$mode"; printf ',\n'
    printf '  "compiler": '; kano_cpp_infra_tool_json_string "$compiler"; printf ',\n'
    printf '  "coverageProvider": '; kano_cpp_infra_tool_json_string "$coverage_provider"; printf ',\n'
    printf '  "pgoProvider": '; kano_cpp_infra_tool_json_string "$pgo_provider"; printf ',\n'
    printf '  "unifiedExecution": %s,\n' "$unified_execution"
    printf '  "unifiedProfileData": %s,\n' "$unified_profile_data"
    printf '  "splitLanes": %s,\n' "$split_lanes"
    printf '  "coverageSubject": '; kano_cpp_infra_tool_json_string "$coverage_subject"; printf ',\n'
    printf '  "collectorScope": '; kano_cpp_infra_tool_json_string "$collector_scope"; printf ',\n'
    printf '  "remoteTelemetry": false,\n'
    printf '  "realUserProfile": false,\n'
    printf '  "pgoDataPaths": '; kano_cpp_infra_tool_csv_json_array "$pgo_data_paths"; printf ',\n'
    printf '  "coverageReportPaths": '; kano_cpp_infra_tool_csv_json_array "$coverage_report_paths"; printf ',\n'
    printf '  "trainingCommand": '; kano_cpp_infra_tool_json_string "$training_command"; printf ',\n'
    printf '  "coverageCommand": '; kano_cpp_infra_tool_json_string "$coverage_command"; printf ',\n'
    printf '  "notes": [%s]\n' "$notes_json"
    printf '}\n'
  } > "$out"
}

kano_cpp_infra_tool_bootstrap_fallback() {
  local command_name="${1:-}"
  shift || true

  case "$command_name" in
    cache-args-to-cmake)
      kano_cpp_infra_tool_bootstrap_cache_args_to_cmake "$@"
      ;;
    cache-args-with-pgo-mode)
      kano_cpp_infra_tool_bootstrap_cache_args_with_pgo_mode "$@"
      ;;
    cmake-preset-exists)
      kano_cpp_infra_tool_bootstrap_cmake_preset_exists "$@"
      ;;
    profile-run-manifest)
      kano_cpp_infra_tool_bootstrap_profile_run_manifest "$@"
      ;;
    *)
      return 127
      ;;
  esac
}

kano_cpp_infra_tool() {
  case "${1:-}" in
    cache-args-with-pgo-mode)
      kano_cpp_infra_tool_bootstrap_fallback "$@"
      return $?
      ;;
  esac

  local tool
  local resolve_output
  if resolve_output="$(kano_cpp_infra_resolve_native_tool 2>&1)"; then
    tool="$resolve_output"
    "$tool" "$@"
    return $?
  fi

  case "${1:-}" in
    cache-args-to-cmake|cache-args-with-pgo-mode|cmake-preset-exists|profile-run-manifest)
      kano_cpp_infra_tool_bootstrap_fallback "$@"
      return $?
      ;;
    *)
      printf '%s\n' "$resolve_output" >&2
      return 127
      ;;
  esac
}
