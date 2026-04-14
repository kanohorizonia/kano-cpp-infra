#!/usr/bin/env bash
# stages/prerequisite-macos.sh
#
# macOS prerequisite bootstrap for kog self build.
#
# Responsibility split:
#   pixi (pixi.toml)  — cmake, ninja, git, ripgrep (conda-forge packages)
#   this script       — ensures pixi is installed, runs pixi install,
#                       then handles things pixi cannot provide:
#                         • Xcode Command Line Tools (clang compiler)
#                         • No platform/mac/prerequisite.sh exists yet;
#                           this script covers the full macOS bootstrap.
#
# Called automatically by the kog launcher when `kog self build` fails on
# the first attempt (fallback: install prerequisites, then retry build).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 1. Ensure pixi is installed
# ---------------------------------------------------------------------------
ensure_pixi() {
  if command -v pixi >/dev/null 2>&1; then
    echo "[prereq][macos] pixi already available: $(pixi --version 2>/dev/null || true)"
    return 0
  fi

  echo "[prereq][macos] pixi not found — installing via curl..."

  if ! command -v curl >/dev/null 2>&1; then
    echo "[prereq][macos] ERROR: curl not found; cannot install pixi automatically." >&2
    echo "[prereq][macos] Install pixi manually: https://pixi.sh/latest/#linux-and-macos" >&2
    return 1
  fi

  curl -fsSL https://pixi.sh/install.sh | bash

  # Refresh PATH
  if [[ -f "${HOME}/.pixi/bin/pixi" ]]; then
    export PATH="${HOME}/.pixi/bin:${PATH}"
  fi

  if ! command -v pixi >/dev/null 2>&1; then
    echo "[prereq][macos] WARNING: pixi installed but not yet on PATH." >&2
    echo "[prereq][macos] Open a new terminal and re-run 'kog self build'." >&2
    return 1
  fi

  echo "[prereq][macos] pixi installed: $(pixi --version 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# 2. Run pixi install to materialise the conda-forge environment
#    (cmake, ninja, git, ripgrep — declared in pixi.toml)
# ---------------------------------------------------------------------------
run_pixi_install() {
  local project_root="${KANO_GIT_MASTER_ROOT:-$(cd -- "$SCRIPT_DIR/../../../../.." && pwd)}"

  if [[ ! -f "$project_root/pixi.toml" ]]; then
    echo "[prereq][macos] WARNING: pixi.toml not found at $project_root — skipping pixi install" >&2
    return 0
  fi

  echo "[prereq][macos] running pixi install in $project_root ..."
  pixi install --manifest-path "$project_root/pixi.toml"
  echo "[prereq][macos] pixi install complete"
}

# ---------------------------------------------------------------------------
# 3. Ensure Xcode Command Line Tools (provides clang, ar, libtool, etc.)
#    pixi cannot install the Xcode CLT — it must come from Apple.
# ---------------------------------------------------------------------------
ensure_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    echo "[prereq][macos] Xcode CLT already installed: $(xcode-select -p)"
    return 0
  fi

  echo "[prereq][macos] Xcode Command Line Tools not found — triggering install..."
  echo "[prereq][macos] A dialog may appear asking you to install the tools."
  echo "[prereq][macos] Accept it, wait for completion, then re-run 'kog self build'."

  # This triggers the GUI install dialog on interactive sessions.
  # On headless CI, use: sudo xcode-select --install  or pre-install via CI image.
  xcode-select --install 2>/dev/null || true

  # Give the user a clear message since the install is async
  echo "[prereq][macos] After Xcode CLT installation completes, re-run 'kog self build'." >&2
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "[prereq][macos] starting macOS prerequisite bootstrap"

ensure_pixi
run_pixi_install
ensure_xcode_clt

echo "[prereq][macos] macOS prerequisite bootstrap complete"
