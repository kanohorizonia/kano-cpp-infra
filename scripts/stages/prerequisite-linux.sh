#!/usr/bin/env bash
# stages/prerequisite-linux.sh
#
# Linux prerequisite bootstrap for kog self build.
#
# Responsibility split:
#   pixi (shared infra pixi.toml)  — cmake, ninja, git, ripgrep (conda-forge packages)
#   this script       — ensures pixi is installed, runs pixi install,
#                       then delegates to platform/linux/prerequisite.sh
#                       for things pixi cannot provide:
#                         • gcc-15 / g++-15 (compiler toolchain via apt)
#                         • clang / pkg-config
#
# Called automatically by the kog launcher when `kog self build` fails on
# the first attempt (fallback: install prerequisites, then retry build).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_SCRIPT="$SCRIPT_DIR/../platform/linux/prerequisite.sh"

# ---------------------------------------------------------------------------
# 1. Ensure pixi is installed
# ---------------------------------------------------------------------------
ensure_pixi() {
  if command -v pixi >/dev/null 2>&1; then
    echo "[prereq][linux] pixi already available: $(pixi --version 2>/dev/null || true)"
    return 0
  fi

  echo "[prereq][linux] pixi not found — installing via curl..."

  if ! command -v curl >/dev/null 2>&1; then
    echo "[prereq][linux] ERROR: curl not found; cannot install pixi automatically." >&2
    echo "[prereq][linux] Install pixi manually: https://pixi.sh/latest/#linux-and-macos" >&2
    return 1
  fi

  curl -fsSL https://pixi.sh/install.sh | bash

  # Refresh PATH
  if [[ -f "${HOME}/.pixi/bin/pixi" ]]; then
    export PATH="${HOME}/.pixi/bin:${PATH}"
  fi

  if ! command -v pixi >/dev/null 2>&1; then
    echo "[prereq][linux] WARNING: pixi installed but not yet on PATH." >&2
    echo "[prereq][linux] Open a new terminal and re-run 'kog self build'." >&2
    return 1
  fi

  echo "[prereq][linux] pixi installed: $(pixi --version 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# 2. Run pixi install to materialise the canonical shared-infra environment
#    (cmake, ninja, git, ripgrep — declared in src/cpp/shared/infra/pixi.toml)
# ---------------------------------------------------------------------------
run_pixi_install() {
  local manifest_path="${KANO_PIXI_MANIFEST_PATH:-$(cd -- "$SCRIPT_DIR/../.." && pwd)/pixi.toml}"

  if [[ ! -f "$manifest_path" ]]; then
    echo "[prereq][linux] WARNING: shared infra pixi.toml not found at $manifest_path — skipping pixi install" >&2
    return 0
  fi

  echo "[prereq][linux] running pixi install for $manifest_path ..."
  pixi install --manifest-path "$manifest_path"
  echo "[prereq][linux] pixi install complete"
}

# ---------------------------------------------------------------------------
# 2b. Install shared global tools (pixi global install).
#    These are shared across ALL projects on this machine.
#    Installed once; reused by all workspaces via pixi_bootstrap.sh.
# ---------------------------------------------------------------------------
run_global_tool_install() {
  if [[ ! -f "$SCRIPT_DIR/../lib/pixi_bootstrap.sh" ]]; then
    echo "[prereq][linux] WARNING: pixi_bootstrap.sh not found — skipping global tool install" >&2
    return 0
  fi
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/../lib/pixi_bootstrap.sh"
  kano_pixi_bootstrap_install_global_tools
}

# ---------------------------------------------------------------------------
# 3. Delegate to platform/linux/prerequisite.sh for compiler toolchain
#    (gcc-15, clang, pkg-config via apt; skips cmake/ninja/git if pixi active)
# ---------------------------------------------------------------------------
run_platform_prereqs() {
  if [[ ! -f "$PLATFORM_SCRIPT" ]]; then
    echo "[prereq][linux] WARNING: platform script not found: $PLATFORM_SCRIPT" >&2
    echo "[prereq][linux] Skipping compiler toolchain prerequisite step." >&2
    return 0
  fi

  echo "[prereq][linux] running platform prerequisite script..."
  bash "$PLATFORM_SCRIPT"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "[prereq][linux] starting Linux prerequisite bootstrap"

ensure_pixi
run_global_tool_install
run_pixi_install
run_platform_prereqs

echo "[prereq][linux] Linux prerequisite bootstrap complete"
