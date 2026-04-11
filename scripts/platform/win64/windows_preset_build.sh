#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KANO_WINDOWS_PS_HELPER="$SCRIPT_DIR/windows_preset_helper.ps1"
KANO_COMMON_BUILD_METADATA_SH="$SCRIPT_DIR/../../lib/build_metadata.sh"

if [[ -f "$KANO_COMMON_BUILD_METADATA_SH" ]]; then
  # shellcheck disable=SC1090
  source "$KANO_COMMON_BUILD_METADATA_SH"
fi

kano_windows_build_prefix() {
  printf '%s' "${KABSD_BUILD_PREFIX:-${KANO_BUILD_PREFIX:-KANO}}"
}

kano_windows_cmake_var_prefix() {
  printf '%s' "${KABSD_CMAKE_VAR_PREFIX:-${KANO_CMAKE_VAR_PREFIX:-KB}}"
}

kano_windows_cpp_root() {
  if declare -F kano_cpp_root >/dev/null 2>&1; then
    kano_cpp_root
    return 0
  fi
  if [[ -n "${KANO_CPP_ROOT:-${INF_CPP_ROOT:-${KOB_CPP_ROOT:-${KABSD_CPP_ROOT:-}}}}" ]]; then
    printf '%s' "${KANO_CPP_ROOT:-${INF_CPP_ROOT:-${KOB_CPP_ROOT:-${KABSD_CPP_ROOT:-}}}}"
    return 0
  fi
  pwd
}

kano_windows_apply_self_build_config() {
  if declare -F kano_cpp_apply_self_build_config >/dev/null 2>&1; then
    kano_cpp_apply_self_build_config "$(kano_windows_build_prefix)"
  fi
}

kano_windows_collect_build_metadata() {
  export KABSD_BUILD_PREFIX="$(kano_windows_build_prefix)"
  export KABSD_CMAKE_VAR_PREFIX="$(kano_windows_cmake_var_prefix)"
  if declare -F kano_cpp_collect_build_metadata >/dev/null 2>&1; then
    kano_cpp_collect_build_metadata "$(kano_windows_build_prefix)"
  fi
}

kano_windows_powershell_bin() {
  local candidate
  for candidate in powershell powershell.exe pwsh pwsh.exe; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

kano_windows_run_ps_helper() {
  local powershell_bin=""
  powershell_bin="$(kano_windows_powershell_bin)" || return 127
  "$powershell_bin" -NoProfile -ExecutionPolicy Bypass -File "$KANO_WINDOWS_PS_HELPER" "$@"
}

kano_windows_file_exists() {
  local in_path="$1"
  kano_windows_run_ps_helper -Action test-path -Path "$in_path" >/dev/null 2>&1
}

kano_windows_detect_vcvarsall() {
  local found=""
  found="$(kano_windows_run_ps_helper -Action detect-vcvarsall 2>/dev/null | tr -d '\r')"
  if [[ -n "$found" ]] && kano_windows_file_exists "$found"; then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

kano_windows_run_preset() {
  local in_configure_preset="$1"
  local in_build_preset="$2"
  local in_vcvars_arch="$3"

  if [[ ! -f "$KANO_WINDOWS_PS_HELPER" ]]; then
    echo "windows preset helper script not found: $KANO_WINDOWS_PS_HELPER" >&2
    exit 1
  fi

  local requested_vcvars="${KANO_VCVARSALL:-${KOB_VCVARSALL:-}}"
  local resolved_vcvars=""
  if [[ -n "$requested_vcvars" ]]; then
    resolved_vcvars="$requested_vcvars"
  else
    resolved_vcvars="$(kano_windows_detect_vcvarsall || true)"
  fi

  if ! kano_windows_file_exists "$resolved_vcvars"; then
    echo "vcvarsall.bat not found." >&2
    echo "Set KANO_VCVARSALL explicitly." >&2
    exit 1
  fi

  kano_windows_apply_self_build_config
  kano_windows_collect_build_metadata

  kano_windows_run_ps_helper \
    -Action run-preset \
    -Root "$(kano_windows_cpp_root)" \
    -Vcvars "$resolved_vcvars" \
    -Arch "$in_vcvars_arch" \
    -ConfigurePreset "$in_configure_preset" \
    -BuildPreset "$in_build_preset"
}

kano_windows_configure_preset() {
  local in_configure_preset="$1"
  local in_vcvars_arch="$2"

  if [[ ! -f "$KANO_WINDOWS_PS_HELPER" ]]; then
    echo "windows preset helper script not found: $KANO_WINDOWS_PS_HELPER" >&2
    exit 1
  fi

  local requested_vcvars="${KANO_VCVARSALL:-${KOB_VCVARSALL:-}}"
  local resolved_vcvars=""
  if [[ -n "$requested_vcvars" ]]; then
    resolved_vcvars="$requested_vcvars"
  else
    resolved_vcvars="$(kano_windows_detect_vcvarsall || true)"
  fi

  if ! kano_windows_file_exists "$resolved_vcvars"; then
    echo "vcvarsall.bat not found." >&2
    echo "Set KANO_VCVARSALL explicitly." >&2
    exit 1
  fi

  kano_windows_apply_self_build_config
  kano_windows_collect_build_metadata

  kano_windows_run_ps_helper \
    -Action configure-preset \
    -Root "$(kano_windows_cpp_root)" \
    -Vcvars "$resolved_vcvars" \
    -Arch "$in_vcvars_arch" \
    -ConfigurePreset "$in_configure_preset"
}

# backlog compatibility aliases
kabsd_run_windows_preset() { kano_windows_run_preset "$@"; }
kabsd_configure_windows_preset() { kano_windows_configure_preset "$@"; }
