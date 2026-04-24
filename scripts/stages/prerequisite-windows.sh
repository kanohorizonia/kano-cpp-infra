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
run_global_tool_install
run_pixi_install
run_platform_prereqs

echo "[prereq][windows] Windows prerequisite bootstrap complete"
