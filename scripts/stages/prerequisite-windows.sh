#!/usr/bin/env bash
# stages/prerequisite-windows.sh
#
# Windows prerequisite bootstrap for kog self build.
#
# Responsibility split:
#   pixi (shared infra pixi.toml)  — cmake, ninja, git, ripgrep (conda-forge packages)
#   this script       — ensures pixi is installed, runs pixi install,
#                       then delegates to platform/win64/prerequisite.ps1
#                       for things pixi cannot provide:
#                         • Microsoft Visual Studio Build Tools (MSVC)
#                         • winget-managed packages when not in a pixi env
#
# Called automatically by the kog launcher when `kog self build` fails on
# the first attempt (fallback: install prerequisites, then retry build).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_SCRIPT="$SCRIPT_DIR/../platform/win64/prerequisite.ps1"

# WSL is not a supported Windows build environment — it must be treated as a
# Linux host and use the Linux prerequisite path instead.
if [[ "$(uname -s 2>/dev/null || true)" == Linux* ]] && grep -qi microsoft /proc/version 2>/dev/null; then
  echo "[prereq][windows] ERROR: WSL detected. This script is for native Windows (Git Bash / MSYS2) only." >&2
  echo "[prereq][windows] On WSL, use the Linux prerequisite path: stages/prerequisite-linux.sh" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Ensure pixi is installed
# ---------------------------------------------------------------------------
ensure_pixi() {
  if command -v pixi >/dev/null 2>&1; then
    echo "[prereq][windows] pixi already available: $(pixi --version 2>/dev/null || true)"
    return 0
  fi

  echo "[prereq][windows] pixi not found — installing via PowerShell..."

  local powershell_bin=""
  for candidate in powershell powershell.exe pwsh pwsh.exe; do
    if command -v "$candidate" >/dev/null 2>&1; then
      powershell_bin="$candidate"
      break
    fi
  done

  if [[ -z "$powershell_bin" ]]; then
    echo "[prereq][windows] ERROR: PowerShell not found; cannot install pixi automatically." >&2
    echo "[prereq][windows] Install pixi manually: https://pixi.sh/latest/#windows" >&2
    return 1
  fi

  "$powershell_bin" -NoProfile -ExecutionPolicy Bypass -Command \
    "iwr -useb https://pixi.sh/install.ps1 | iex"

  # Refresh PATH so the newly installed pixi is visible in this shell session
  if [[ -f "${USERPROFILE}/.pixi/bin/pixi" ]]; then
    export PATH="${USERPROFILE}/.pixi/bin:${PATH}"
  elif [[ -f "${HOME}/.pixi/bin/pixi" ]]; then
    export PATH="${HOME}/.pixi/bin:${PATH}"
  fi

  if ! command -v pixi >/dev/null 2>&1; then
    echo "[prereq][windows] WARNING: pixi installed but not yet on PATH." >&2
    echo "[prereq][windows] Open a new terminal and re-run 'kog self build'." >&2
    return 1
  fi

  echo "[prereq][windows] pixi installed: $(pixi --version 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# 2. Run pixi install to materialise the canonical shared-infra environment
#    (cmake, ninja, git, ripgrep — declared in src/cpp/shared/infra/pixi.toml)
# ---------------------------------------------------------------------------
run_pixi_install() {
  local manifest_path="${KANO_PIXI_MANIFEST_PATH:-$(cd -- "$SCRIPT_DIR/../.." && pwd)/pixi.toml}"

  if [[ ! -f "$manifest_path" ]]; then
    echo "[prereq][windows] WARNING: shared infra pixi.toml not found at $manifest_path — skipping pixi install" >&2
    return 0
  fi

  echo "[prereq][windows] running pixi install for $manifest_path ..."
  pixi install --manifest-path "$manifest_path"
  echo "[prereq][windows] pixi install complete"
}

# ---------------------------------------------------------------------------
# 2b. Install shared global tools (pixi global install).
#    These are shared across ALL projects on this machine.
#    Installed once; reused by all workspaces via pixi_bootstrap.sh.
# ---------------------------------------------------------------------------
run_global_tool_install() {
  if [[ ! -f "$SCRIPT_DIR/../lib/pixi_bootstrap.sh" ]]; then
    echo "[prereq][windows] WARNING: pixi_bootstrap.sh not found — skipping global tool install" >&2
    return 0
  fi
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/../lib/pixi_bootstrap.sh"
  kano_pixi_bootstrap_install_global_tools
}

expose_pixi_global_bin() {
  local pixi_bin=""

  if [[ -n "${USERPROFILE:-}" ]]; then
    if command -v cygpath >/dev/null 2>&1; then
      pixi_bin="$(cygpath -u "${USERPROFILE}")/.pixi/bin"
    else
      pixi_bin="$(printf '%s' "${USERPROFILE}" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/\L\1|')/.pixi/bin"
    fi
  fi

  if [[ -z "$pixi_bin" || ! -d "$pixi_bin" ]]; then
    pixi_bin="${HOME}/.pixi/bin"
  fi

  if [[ -d "$pixi_bin" && ":$PATH:" != *":$pixi_bin:"* ]]; then
    export PATH="$pixi_bin:$PATH"
    echo "[prereq][windows] added pixi global bin to PATH: $pixi_bin"
  fi
}

# ---------------------------------------------------------------------------
# 3. Delegate to platform/win64/prerequisite.ps1 for MSVC and winget packages
#    (skips cmake/ninja/git automatically when already provided by pixi)
# ---------------------------------------------------------------------------
run_platform_prereqs() {
  if [[ ! -f "$PLATFORM_SCRIPT" ]]; then
    echo "[prereq][windows] WARNING: platform script not found: $PLATFORM_SCRIPT" >&2
    echo "[prereq][windows] Skipping MSVC/winget prerequisite step." >&2
    return 0
  fi

  echo "[prereq][windows] running platform prerequisite script..."
  bash "$PLATFORM_SCRIPT"
}

verify_vcvarsall_ready() {
  if [[ -n "${KANO_VCVARSALL:-}" && -f "${KANO_VCVARSALL}" ]]; then
    echo "[prereq][windows] vcvarsall ready via KANO_VCVARSALL: ${KANO_VCVARSALL}"
    return 0
  fi

  local candidate=""
  local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"

  if [[ -x "$vswhere" ]]; then
    candidate="$($vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'VC\\Auxiliary\\Build\\vcvarsall.bat' 2>/dev/null | head -n 1 || true)"
    candidate="${candidate//$'\r'/}"
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      export KANO_VCVARSALL="$candidate"
      echo "[prereq][windows] vcvarsall discovered: $candidate"
      return 0
    fi
  fi

  shopt -s nullglob
  for candidate in \
    /c/Program\ Files/Microsoft\ Visual\ Studio/*/*/VC/Auxiliary/Build/vcvarsall.bat \
    /c/Program\ Files\ \(x86\)/Microsoft\ Visual\ Studio/*/*/VC/Auxiliary/Build/vcvarsall.bat; do
    if [[ -f "$candidate" ]]; then
      shopt -u nullglob
      export KANO_VCVARSALL="$candidate"
      echo "[prereq][windows] vcvarsall discovered via fallback: $candidate"
      return 0
    fi
  done
  shopt -u nullglob

  echo "[prereq][windows] ERROR: vcvarsall.bat not found after prerequisite bootstrap." >&2
  echo "[prereq][windows] If Visual Studio installer is busy (exit 1618), wait for it to finish and rerun 'kog self build'." >&2
  echo "[prereq][windows] Or set KANO_VCVARSALL manually to your vcvarsall.bat path." >&2
  return 1
}

resolve_windows_sdk_bin_dir() {
  local root candidate latest=""

  for root in \
    "/c/Program Files (x86)/Windows Kits/10/bin" \
    "/c/Program Files/Windows Kits/10/bin"; do
    [[ -d "$root" ]] || continue

    shopt -s nullglob
    for candidate in "$root"/*/x64; do
      [[ -d "$candidate" ]] || continue
      if [[ -z "$latest" || "$candidate" > "$latest" ]]; then
        latest="$candidate"
      fi
    done
    shopt -u nullglob
  done

  if [[ -n "$latest" ]]; then
    printf '%s\n' "$latest"
    return 0
  fi

  return 1
}

verify_windows_sdk_tools_ready() {
  local sdk_bin=""
  if ! sdk_bin="$(resolve_windows_sdk_bin_dir)"; then
    echo "[prereq][windows] ERROR: Windows SDK tools not found (missing Windows Kits bin/x64)." >&2
    echo "[prereq][windows] Re-run 'kog self install-prereq' after Visual Studio installer finishes." >&2
    return 1
  fi

  if [[ ! -f "$sdk_bin/rc.exe" || ! -f "$sdk_bin/mt.exe" ]]; then
    echo "[prereq][windows] ERROR: Windows SDK incomplete at $sdk_bin (rc.exe/mt.exe missing)." >&2
    echo "[prereq][windows] Re-run 'kog self install-prereq' to install SDK components." >&2
    return 1
  fi

  echo "[prereq][windows] Windows SDK tools ready: $sdk_bin"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "[prereq][windows] starting Windows prerequisite bootstrap"

ensure_pixi
run_global_tool_install
expose_pixi_global_bin
run_pixi_install
run_platform_prereqs
verify_vcvarsall_ready
verify_windows_sdk_tools_ready

echo "[prereq][windows] Windows prerequisite bootstrap complete"
