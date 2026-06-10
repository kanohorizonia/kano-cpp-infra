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
  local raw="${KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON:-}"

  if command -v jq >/dev/null 2>&1; then
    if [[ -n "$raw" ]]; then
      printf '%s' "$raw" |
        jq -c --arg mode "$mode" '. + {"KANO_CPP_INFRA_PGO_MODE": $mode} | if $mode == "use" and has("KOG_BUILD_TESTS") | not then . + {"KOG_BUILD_TESTS": "OFF"} else . end'
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
    *)
      return 127
      ;;
  esac
}

kano_cpp_infra_tool() {
  local tool
  local resolve_output
  if resolve_output="$(kano_cpp_infra_resolve_native_tool 2>&1)"; then
    tool="$resolve_output"
    "$tool" "$@"
    return $?
  fi

  case "${1:-}" in
    cache-args-to-cmake|cache-args-with-pgo-mode|cmake-preset-exists)
      kano_cpp_infra_tool_bootstrap_fallback "$@"
      return $?
      ;;
    *)
      printf '%s\n' "$resolve_output" >&2
      return 127
      ;;
  esac
}
