#!/usr/bin/env bash
# stages/prerequisite-windows.sh
#
# Windows prerequisite bootstrap for kog self build.
#
# Responsibility split:
#   pixi (pixi.toml)  — cmake, ninja, git, ripgrep (conda-forge packages)
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
# 2. Run pixi install to materialise the conda-forge environment
#    (cmake, ninja, git, ripgrep — declared in pixi.toml)
# ---------------------------------------------------------------------------
run_pixi_install() {
  local project_root="${KANO_GIT_MASTER_ROOT:-$(cd -- "$SCRIPT_DIR/../../../../.." && pwd)}"

  if [[ ! -f "$project_root/pixi.toml" ]]; then
    echo "[prereq][windows] WARNING: pixi.toml not found at $project_root — skipping pixi install" >&2
    return 0
  fi

  echo "[prereq][windows] running pixi install in $project_root ..."
  pixi install --manifest-path "$project_root/pixi.toml"
  echo "[prereq][windows] pixi install complete"
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "[prereq][windows] starting Windows prerequisite bootstrap"

ensure_pixi
run_pixi_install
run_platform_prereqs

echo "[prereq][windows] Windows prerequisite bootstrap complete"
