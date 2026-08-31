#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap pixi environment if not already active
# Skip if global tools (cmake, ninja) are already available in PATH
if ! command -v cmake >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  source "$SCRIPT_DIR/pixi_bootstrap.sh"
  kano_pixi_bootstrap_activate
fi

KANO_WINDOWS_PS_HELPER="$SCRIPT_DIR/windows_preset_helper.ps1"
KANO_COMMON_BUILD_METADATA_SH="$SCRIPT_DIR/build_metadata.sh"

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

KANO_WINDOWS_PS_HELPER_MODE="${KANO_WINDOWS_PS_HELPER_MODE:-}"

kano_windows_run_ps_helper_scriptblock() {
  local powershell_bin="$1"
  shift
  local helper_path_for_ps="$KANO_WINDOWS_PS_HELPER"
  if command -v cygpath >/dev/null 2>&1; then
    helper_path_for_ps="$(cygpath -w "$KANO_WINDOWS_PS_HELPER" 2>/dev/null || printf '%s' "$KANO_WINDOWS_PS_HELPER")"
  fi
  local helper_escaped="${helper_path_for_ps//\'/\'\'}"
  local arg arg_escaped
  local forwarded_args=""
  local pending_path_flag=""
  for arg in "$@"; do
    if [[ "$arg" == -* ]]; then
      forwarded_args+=" $arg"
      case "$arg" in
        -Path|-Root|-BuildDir|-CoverageBuildDir|-Vcvars)
          pending_path_flag="$arg"
          ;;
        *)
          pending_path_flag=""
          ;;
      esac
    else
      if [[ -n "$pending_path_flag" ]] && command -v cygpath >/dev/null 2>&1; then
        arg="$(cygpath -w "$arg" 2>/dev/null || printf '%s' "$arg")"
      fi
      arg_escaped="${arg//\'/\'\'}"
      forwarded_args+=" '$arg_escaped'"
      pending_path_flag=""
    fi
  done

  "$powershell_bin" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "\$script = Get-Content -Raw -LiteralPath '$helper_escaped'; \$sb = [ScriptBlock]::Create(\$script); & \$sb$forwarded_args"
}

kano_windows_select_ps_helper_mode() {
  local powershell_bin="$1"
  if [[ -n "$KANO_WINDOWS_PS_HELPER_MODE" ]]; then
    return 0
  fi

  if "$powershell_bin" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$KANO_WINDOWS_PS_HELPER" -Action probe >/dev/null 2>&1; then
    KANO_WINDOWS_PS_HELPER_MODE="file"
  else
    KANO_WINDOWS_PS_HELPER_MODE="scriptblock"
  fi
}

kano_windows_run_ps_helper() {
  local powershell_bin=""
  powershell_bin="$(kano_windows_powershell_bin)" || return 127
  kano_windows_select_ps_helper_mode "$powershell_bin"

  if [[ "$KANO_WINDOWS_PS_HELPER_MODE" == "file" ]]; then
    "$powershell_bin" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$KANO_WINDOWS_PS_HELPER" "$@"
    return $?
  fi

  kano_windows_run_ps_helper_scriptblock "$powershell_bin" "$@"
}

kano_windows_file_exists() {
  local in_path="$1"
  # Convert backslashes to forward slashes for Git Bash compatibility
  local converted_path="${in_path//\\//}"
  # Try both original and converted paths
  if [[ -f "$in_path" || -d "$in_path" ]]; then
    return 0
  fi
  if [[ -f "$converted_path" || -d "$converted_path" ]]; then
    return 0
  fi
  return 1
}

kano_windows_detect_vcvarsall() {
  local found=""
  found="$(kano_windows_run_ps_helper -Action detect-vcvarsall 2>/dev/null | tr -d '\r')"
  if [[ -n "$found" ]] && kano_windows_file_exists "$found"; then
    printf '%s\n' "$found"
    return 0
  fi

  # Fallback: directly scan common Visual Studio install roots.
  local candidate
  shopt -s nullglob
  for candidate in \
    /c/Program\ Files/Microsoft\ Visual\ Studio/*/*/VC/Auxiliary/Build/vcvarsall.bat \
    /c/Program\ Files\ \(x86\)/Microsoft\ Visual\ Studio/*/*/VC/Auxiliary/Build/vcvarsall.bat; do
    if kano_windows_file_exists "$candidate"; then
      printf '%s\n' "$candidate"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob

  return 1
}

kano_windows_native_root() {
  local root="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$root"
    return
  fi
  (cd "$root" && pwd -W)
}

kano_windows_prepare_subst_root() {
  local root="$1"
  local configure_preset="$2"
  local preferred_drive="$3"
  local mode="${KANO_WINDOWS_SUBST_MODE:-${INF_SUBST_MODE:-auto}}"
  kano_windows_run_ps_helper \
    -Action prepare-subst-root \
    -Root "$root" \
    -ConfigurePreset "$configure_preset" \
    -PreferredDrive "$preferred_drive" \
    -Mode "$mode" |
    tr -d '\r'
}

kano_windows_cleanup_subst_drive() {
  local drive="$1"
  local cleanup_required="$2"
  local purpose="$3"
  if [[ "$cleanup_required" != "1" || -z "$drive" ]]; then
    return 0
  fi

  kano_windows_run_ps_helper -Action cleanup-subst -Drive "$drive" >/dev/null 2>&1 || true
  echo "[launcher][subst][info] unmapped $drive (purpose: $purpose)" >&2
}

kano_windows_run_preset() {
  local in_configure_preset="$1"
  local in_build_preset="$2"
  local in_vcvars_arch="$3"
  local subst_purpose="${KANO_WINDOWS_SUBST_PURPOSE:-${INF_SUBST_PURPOSE:-kano cpp build}}"
  local build_target="${KANO_WINDOWS_BUILD_TARGET:-${INF_BUILD_TARGET:-}}"
  local preferred_subst_drive="${KANO_WINDOWS_SUBST_DRIVE:-${INF_SUBST_DRIVE:-}}"

  if [[ ! -f "$KANO_WINDOWS_PS_HELPER" ]]; then
    echo "windows preset helper script not found: $KANO_WINDOWS_PS_HELPER" >&2
    exit 1
  fi

  local powershell_bin=""
  powershell_bin="$(kano_windows_powershell_bin)" || return 127
  kano_windows_select_ps_helper_mode "$powershell_bin"

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
  export KANO_CPP_INFRA_CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(kano_windows_cpp_root)}"
  export KANO_CPP_INFRA_BUILD_CONFIGURE_PRESET="$in_configure_preset"
  export KANO_CPP_INFRA_BUILD_BUILD_PRESET="$in_build_preset"
  export KANO_CPP_INFRA_LLVM_PREFIX=""
  kano_cpp_print_self_build_toolchain

  local native_root=""
  native_root="$(kano_windows_native_root "$(kano_windows_cpp_root)")"
  local build_root="$native_root"
  local subst_drive=""
  local subst_cleanup_required="0"
  local subst_result=""
  subst_result="$(kano_windows_prepare_subst_root "$native_root" "$in_configure_preset" "$preferred_subst_drive")"
  if [[ -n "$subst_result" ]]; then
    build_root="${subst_result%%$'\t'*}"
    local subst_tail="${subst_result#*$'\t'}"
    subst_drive="${subst_tail%%$'\t'*}"
    subst_cleanup_required="${subst_result##*$'\t'}"
  fi
  if [[ -n "$subst_drive" && "$build_root" != "$native_root" ]]; then
    echo "[launcher][subst][info] mapped $subst_drive -> $native_root (purpose: $subst_purpose)" >&2
  fi

  local exit_code=0
  kano_windows_run_ps_helper \
    -Action run-preset \
    -Root "$build_root" \
    -CanonicalRoot "$native_root" \
    -Vcvars "$resolved_vcvars" \
    -Arch "$in_vcvars_arch" \
    -ConfigurePreset "$in_configure_preset" \
    -BuildPreset "$in_build_preset" \
    -BuildTarget "$build_target" || exit_code=$?

  kano_windows_cleanup_subst_drive "$subst_drive" "$subst_cleanup_required" "$subst_purpose"
  return "$exit_code"
}

kano_windows_configure_preset() {
  local in_configure_preset="$1"
  local in_vcvars_arch="$2"
  local subst_purpose="${KANO_WINDOWS_SUBST_PURPOSE:-${INF_SUBST_PURPOSE:-kano cpp configure}}"
  local preferred_subst_drive="${KANO_WINDOWS_SUBST_DRIVE:-${INF_SUBST_DRIVE:-}}"

  if [[ ! -f "$KANO_WINDOWS_PS_HELPER" ]]; then
    echo "windows preset helper script not found: $KANO_WINDOWS_PS_HELPER" >&2
    exit 1
  fi

  local powershell_bin=""
  powershell_bin="$(kano_windows_powershell_bin)" || return 127
  kano_windows_select_ps_helper_mode "$powershell_bin"

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

  local native_root=""
  native_root="$(kano_windows_native_root "$(kano_windows_cpp_root)")"
  local build_root="$native_root"
  local subst_drive=""
  local subst_cleanup_required="0"
  local subst_result=""
  subst_result="$(kano_windows_prepare_subst_root "$native_root" "$in_configure_preset" "$preferred_subst_drive")"
  if [[ -n "$subst_result" ]]; then
    build_root="${subst_result%%$'\t'*}"
    local subst_tail="${subst_result#*$'\t'}"
    subst_drive="${subst_tail%%$'\t'*}"
    subst_cleanup_required="${subst_result##*$'\t'}"
  fi
  if [[ -n "$subst_drive" && "$build_root" != "$native_root" ]]; then
    echo "[launcher][subst][info] mapped $subst_drive -> $native_root (purpose: $subst_purpose)" >&2
  fi

  local exit_code=0
  kano_windows_run_ps_helper \
    -Action configure-preset \
    -Root "$build_root" \
    -CanonicalRoot "$native_root" \
    -Vcvars "$resolved_vcvars" \
    -Arch "$in_vcvars_arch" \
    -ConfigurePreset "$in_configure_preset" || exit_code=$?

  kano_windows_cleanup_subst_drive "$subst_drive" "$subst_cleanup_required" "$subst_purpose"
  return "$exit_code"
}

# backlog compatibility aliases
kabsd_run_windows_preset() { kano_windows_run_preset "$@"; }
kabsd_configure_windows_preset() { kano_windows_configure_preset "$@"; }
