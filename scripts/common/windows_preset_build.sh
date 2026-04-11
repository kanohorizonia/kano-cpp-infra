#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${INF_CPP_ROOT:-}" ]]; then
  echo "INF_CPP_ROOT is not set." >&2
  exit 1
fi

if [[ -n "${INF_EXPERT_SKILL_ROOT:-}" ]] && [[ -f "$INF_EXPERT_SKILL_ROOT/src/shell/build/windows/windows_preset_build.sh" ]]; then
  # shellcheck source=../../../../../.agents/skills/kano/kano-cpp-expert-skill/src/shell/build/windows/windows_preset_build.sh
  source "$INF_EXPERT_SKILL_ROOT/src/shell/build/windows/windows_preset_build.sh"
  return 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build_metadata.sh"

INF_WINDOWS_PS_HELPER="$SCRIPT_DIR/windows_preset_helper.ps1"

inf_powershell_bin() {
  local candidate
  for candidate in powershell powershell.exe pwsh pwsh.exe; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

inf_run_windows_ps_helper() {
  local PowerShellBin=""
  PowerShellBin="$(inf_powershell_bin)" || return 127
  "$PowerShellBin" -NoProfile -ExecutionPolicy Bypass -File "$INF_WINDOWS_PS_HELPER" "$@"
}

inf_windows_file_exists() {
  local InPath="$1"
  inf_run_windows_ps_helper -Action test-path -Path "$InPath" >/dev/null 2>&1
}

inf_detect_vcvarsall() {
  local Found=""
  if inf_powershell_bin >/dev/null 2>&1; then
    Found="$(inf_run_windows_ps_helper -Action detect-vcvarsall 2>/dev/null | tr -d '\r')"
  fi

  if [[ -n "$Found" ]] && inf_windows_file_exists "$Found"; then
    printf '%s\n' "$Found"
    return 0
  fi

  return 1
}

inf_resolve_windows_source_root() {
  local InRootWin="$1"
  local InConfigurePreset="$2"
  local DecisionAndRoot=""
  local Decision=""
  local EffectiveRoot=""

  DecisionAndRoot="$(
    inf_run_windows_ps_helper -Action resolve-source-root -Root "$InRootWin" -Preset "$InConfigurePreset" \
      | tr -d '\r'
  )"

  Decision="${DecisionAndRoot%%|*}"
  EffectiveRoot="${DecisionAndRoot#*|}"
  if [[ -z "$EffectiveRoot" ]]; then
    EffectiveRoot="$InRootWin"
  fi

  case "$Decision" in
    use-cache-home)
      echo "[launcher][cmake-cache][info] detected path-alias cache; reuse source root: $EffectiveRoot" >&2
      ;;
    clean-cache)
      echo "[launcher][cmake-cache][warn] removed incompatible cache dir for preset: $InConfigurePreset" >&2
      ;;
  esac

  printf '%s\n' "$EffectiveRoot"
}

inf_prepare_windows_subst_root() {
  local InRootWin="$1"
  local InConfigurePreset="$2"
  local InSubstPurpose="$3"
  local InPreferredSubstDrive="$4"
  local InSubstMode="${INF_SUBST_MODE:-auto}"

  # InSubstPurpose is kept for launch logs/context compatibility.
  : "$InSubstPurpose"
  inf_run_windows_ps_helper -Action prepare-subst-root -Root "$InRootWin" -Preset "$InConfigurePreset" -PreferredDrive "$InPreferredSubstDrive" -Mode "$InSubstMode" \
    | tr -d '\r'
}

inf_cleanup_windows_subst_drive() {
  local InMappedDrive="$1"
  local InCleanupFlag="$2"
  local InSubstPurpose="$3"

  if [[ "$InCleanupFlag" != "1" ]]; then
    return 0
  fi
  if [[ -z "$InMappedDrive" ]]; then
    return 0
  fi

  inf_run_windows_ps_helper -Action cleanup-subst -Drive "$InMappedDrive" >/dev/null 2>&1 || true
  echo "[launcher][subst][info] unmapped $InMappedDrive (purpose: $InSubstPurpose)" >&2
}

inf_run_windows_preset() {
  local InConfigurePreset="$1"
  local InBuildPreset="$2"
  local InVcvarsArch="$3"
  local InSubstPurpose="${INF_SUBST_PURPOSE:-kano-git cpp build}"
  local InPreferredSubstDrive="${INF_SUBST_DRIVE:-}"

  if ! command -v cmd.exe >/dev/null 2>&1; then
    echo "cmd.exe is required." >&2
    exit 1
  fi

  if ! inf_powershell_bin >/dev/null 2>&1; then
    echo "powershell is required." >&2
    exit 1
  fi

  if [[ ! -f "$INF_WINDOWS_PS_HELPER" ]]; then
    echo "windows preset helper script not found: $INF_WINDOWS_PS_HELPER" >&2
    exit 1
  fi

  local RequestedVcvars="${INF_VCVARSALL:-}"
  local ResolvedVcvars=""
  if [[ -n "$RequestedVcvars" ]]; then
    ResolvedVcvars="$RequestedVcvars"
  else
    ResolvedVcvars="$(inf_detect_vcvarsall || true)"
  fi

  if ! inf_windows_file_exists "$ResolvedVcvars"; then
    echo "vcvarsall.bat not found." >&2
    echo "Set INF_VCVARSALL explicitly, e.g.:" >&2
    echo "  INF_VCVARSALL='C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvarsall.bat'" >&2
    exit 1
  fi

  local RootWin

  inf_apply_self_build_config
  inf_collect_build_metadata

  if command -v cygpath >/dev/null 2>&1; then
    RootWin="$(cygpath -w "$INF_CPP_ROOT")"
  else
    RootWin="$(cd "$INF_CPP_ROOT" && pwd -W)"
  fi

  local BuildRootWin
  local EffectiveRootWin
  local SubstDrive
  local SubstCleanupFlag
  local SubstLine

  BuildRootWin="$RootWin"
  SubstDrive=""
  SubstCleanupFlag="0"
  SubstLine="$(inf_prepare_windows_subst_root "$BuildRootWin" "$InConfigurePreset" "$InSubstPurpose" "$InPreferredSubstDrive")"
  if [[ -n "$SubstLine" ]]; then
    BuildRootWin="${SubstLine%%$'\t'*}"
    local _rest="${SubstLine#*$'\t'}"
    SubstDrive="${_rest%%$'\t'*}"
    SubstCleanupFlag="${SubstLine##*$'\t'}"
  fi
  if [[ -n "$SubstDrive" && "$BuildRootWin" != "$RootWin" ]]; then
    echo "[launcher][subst][info] mapped $SubstDrive -> $RootWin (purpose: $InSubstPurpose)" >&2
  fi

  EffectiveRootWin="$(inf_resolve_windows_source_root "$BuildRootWin" "$InConfigurePreset")"
  if [[ -n "$EffectiveRootWin" ]]; then
    BuildRootWin="$EffectiveRootWin"
  fi

  local ExitCode=0
  inf_run_windows_ps_helper \
    -Action run-preset \
    -Root "$BuildRootWin" \
    -Vcvars "$ResolvedVcvars" \
    -Arch "$InVcvarsArch" \
    -ConfigurePreset "$InConfigurePreset" \
    -BuildPreset "$InBuildPreset" || ExitCode=$?

  inf_cleanup_windows_subst_drive "$SubstDrive" "$SubstCleanupFlag" "$InSubstPurpose"
  return "$ExitCode"
}

inf_configure_windows_preset() {
  local InConfigurePreset="$1"
  local InVcvarsArch="$2"
  local InSubstPurpose="${INF_SUBST_PURPOSE:-kano-git cpp configure}"
  local InPreferredSubstDrive="${INF_SUBST_DRIVE:-}"

  if ! command -v cmd.exe >/dev/null 2>&1; then
    echo "cmd.exe is required." >&2
    exit 1
  fi

  if ! inf_powershell_bin >/dev/null 2>&1; then
    echo "powershell is required." >&2
    exit 1
  fi

  if [[ ! -f "$INF_WINDOWS_PS_HELPER" ]]; then
    echo "windows preset helper script not found: $INF_WINDOWS_PS_HELPER" >&2
    exit 1
  fi

  local RequestedVcvars="${INF_VCVARSALL:-}"
  local ResolvedVcvars=""
  if [[ -n "$RequestedVcvars" ]]; then
    ResolvedVcvars="$RequestedVcvars"
  else
    ResolvedVcvars="$(inf_detect_vcvarsall || true)"
  fi

  if ! inf_windows_file_exists "$ResolvedVcvars"; then
    echo "vcvarsall.bat not found." >&2
    echo "Set INF_VCVARSALL explicitly, e.g.:" >&2
    echo "  INF_VCVARSALL='C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvarsall.bat'" >&2
    exit 1
  fi

  local RootWin
  inf_apply_self_build_config
  inf_collect_build_metadata

  if command -v cygpath >/dev/null 2>&1; then
    RootWin="$(cygpath -w "$INF_CPP_ROOT")"
  else
    RootWin="$(cd "$INF_CPP_ROOT" && pwd -W)"
  fi

  local BuildRootWin="$RootWin"
  local EffectiveRootWin=""
  local SubstDrive=""
  local SubstCleanupFlag="0"
  local SubstLine=""

  SubstLine="$(inf_prepare_windows_subst_root "$BuildRootWin" "$InConfigurePreset" "$InSubstPurpose" "$InPreferredSubstDrive")"
  if [[ -n "$SubstLine" ]]; then
    BuildRootWin="${SubstLine%%$'\t'*}"
    local _rest="${SubstLine#*$'\t'}"
    SubstDrive="${_rest%%$'\t'*}"
    SubstCleanupFlag="${SubstLine##*$'\t'}"
  fi
  if [[ -n "$SubstDrive" && "$BuildRootWin" != "$RootWin" ]]; then
    echo "[launcher][subst][info] mapped $SubstDrive -> $RootWin (purpose: $InSubstPurpose)" >&2
  fi

  EffectiveRootWin="$(inf_resolve_windows_source_root "$BuildRootWin" "$InConfigurePreset")"
  if [[ -n "$EffectiveRootWin" ]]; then
    BuildRootWin="$EffectiveRootWin"
  fi

  local SolutionPath=""
  local ExitCode=0
  SolutionPath="$({ inf_run_windows_ps_helper \
    -Action configure-preset \
    -Root "$BuildRootWin" \
    -Vcvars "$ResolvedVcvars" \
    -Arch "$InVcvarsArch" \
    -ConfigurePreset "$InConfigurePreset"; } 2>&1)" || ExitCode=$?

  inf_cleanup_windows_subst_drive "$SubstDrive" "$SubstCleanupFlag" "$InSubstPurpose"
  if [[ "$ExitCode" -ne 0 ]]; then
    printf '%s\n' "$SolutionPath" >&2
    return "$ExitCode"
  fi

  SolutionPath="$(printf '%s\n' "$SolutionPath" | tr -d '\r' | tail -n 1)"
  printf '%s\n' "$SolutionPath"
}
