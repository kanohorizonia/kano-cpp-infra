#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${KOB_CPP_ROOT:-${KABSD_CPP_ROOT:-}}" ]]; then
  echo "KOB_CPP_ROOT is not set." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KABSD_WINDOWS_PS_HELPER="$SCRIPT_DIR/windows_preset_helper.ps1"

kabsd_powershell_bin() {
  local candidate
  for candidate in powershell powershell.exe pwsh pwsh.exe; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

kabsd_run_windows_build() {
  local build_dir="$1"
  local config="$2"
  local generator="${3:-Ninja}"
  local arch="${4:-x64}"
  local powershell_bin=""

  powershell_bin="$(kabsd_powershell_bin)" || {
    echo "PowerShell is required." >&2
    return 127
  }

  kob_apply_self_build_config
  kob_collect_build_metadata

  "$powershell_bin" -NoProfile -ExecutionPolicy Bypass -File "$KABSD_WINDOWS_PS_HELPER" \
    -Action run-build \
    -Root "$(kob_cpp_root)" \
    -BuildDir "$build_dir" \
    -Config "$config" \
    -Generator "$generator" \
    -Arch "$arch"
}

kabsd_run_windows_ps_helper() {
  local powershell_bin=""
  powershell_bin="$(kabsd_powershell_bin)" || return 127
  "$powershell_bin" -NoProfile -ExecutionPolicy Bypass -File "$KABSD_WINDOWS_PS_HELPER" "$@"
}

kabsd_windows_file_exists() {
  local in_path="$1"
  kabsd_run_windows_ps_helper -Action test-path -Path "$in_path" >/dev/null 2>&1
}

kabsd_detect_vcvarsall() {
  local found=""
  found="$(kabsd_run_windows_ps_helper -Action detect-vcvarsall 2>/dev/null | tr -d '\r')"
  if [[ -n "$found" ]] && kabsd_windows_file_exists "$found"; then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

kabsd_run_windows_preset() {
  local in_configure_preset="$1"
  local in_build_preset="$2"
  local in_vcvars_arch="$3"

  if [[ ! -f "$KABSD_WINDOWS_PS_HELPER" ]]; then
    echo "windows preset helper script not found: $KABSD_WINDOWS_PS_HELPER" >&2
    exit 1
  fi

  local requested_vcvars="${KOB_VCVARSALL:-}"
  local resolved_vcvars=""
  if [[ -n "$requested_vcvars" ]]; then
    resolved_vcvars="$requested_vcvars"
  else
    resolved_vcvars="$(kabsd_detect_vcvarsall || true)"
  fi

  if ! kabsd_windows_file_exists "$resolved_vcvars"; then
    echo "vcvarsall.bat not found." >&2
    echo "Set KOB_VCVARSALL explicitly, e.g.:" >&2
    echo "  KOB_VCVARSALL='C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvarsall.bat'" >&2
    exit 1
  fi

  kob_apply_self_build_config
  kob_collect_build_metadata

  kabsd_run_windows_ps_helper \
    -Action run-preset \
    -Root "$(kob_cpp_root)" \
    -Vcvars "$resolved_vcvars" \
    -Arch "$in_vcvars_arch" \
    -ConfigurePreset "$in_configure_preset" \
    -BuildPreset "$in_build_preset"
}

kabsd_configure_windows_preset() {
  local in_configure_preset="$1"
  local in_vcvars_arch="$2"

  if [[ ! -f "$KABSD_WINDOWS_PS_HELPER" ]]; then
    echo "windows preset helper script not found: $KABSD_WINDOWS_PS_HELPER" >&2
    exit 1
  fi

  local requested_vcvars="${KOB_VCVARSALL:-}"
  local resolved_vcvars=""
  if [[ -n "$requested_vcvars" ]]; then
    resolved_vcvars="$requested_vcvars"
  else
    resolved_vcvars="$(kabsd_detect_vcvarsall || true)"
  fi

  if ! kabsd_windows_file_exists "$resolved_vcvars"; then
    echo "vcvarsall.bat not found." >&2
    echo "Set KOB_VCVARSALL explicitly, e.g.:" >&2
    echo "  KOB_VCVARSALL='C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvarsall.bat'" >&2
    exit 1
  fi

  kob_apply_self_build_config
  kob_collect_build_metadata

  kabsd_run_windows_ps_helper \
    -Action configure-preset \
    -Root "$(kob_cpp_root)" \
    -Vcvars "$resolved_vcvars" \
    -Arch "$in_vcvars_arch" \
    -ConfigurePreset "$in_configure_preset"
}
