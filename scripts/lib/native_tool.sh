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

kano_cpp_infra_tool() {
  local tool
  tool="$(kano_cpp_infra_resolve_native_tool)"
  "$tool" "$@"
}
