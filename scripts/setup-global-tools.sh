#!/usr/bin/env bash
# setup-global-tools.sh — Entry point for global Pixi toolchain installation
#
# Usage:
#   bash src/cpp/shared/infra/scripts/setup-global-tools.sh
#
# This script delegates to the platform-specific installation logic
# based on the current OS.
#
# What it installs:
#   - pixi (if not present)
#   - Global tools from src/cpp/shared/infra/pixi-global-tool.toml (via pixi global install)
#
# Idempotent: safe to run multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect platform
detect_platform() {
    local os_type="${OSTYPE:-}"
    case "${os_type}" in
        darwin*)
            echo "darwin"
            ;;
        linux-*)
            echo "linux"
            ;;
        msys*|cygwin*|mingw*)
            echo "win64"
            ;;
        *)
            # Fallback: check uname
            local kernel
            kernel="$(uname -s 2>/dev/null || echo "unknown")"
            case "${kernel}" in
                Darwin)    echo "darwin" ;;
                Linux)     echo "linux" ;;
                MINGW*|MSYS*|CYGWIN*) echo "win64" ;;
                *)         echo "unknown" ;;
            esac
            ;;
    esac
}

PLATFORM="$(detect_platform)"
echo "[setup-global-tools] Detected platform: ${PLATFORM}"

# Source pixi_bootstrap.sh which contains the install logic
BOOTSTRAP_LIB="${SCRIPT_DIR}/lib/pixi_bootstrap.sh"
if [[ ! -f "${BOOTSTRAP_LIB}" ]]; then
    echo "[setup-global-tools] ERROR: pixi_bootstrap.sh not found at ${BOOTSTRAP_LIB}" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${BOOTSTRAP_LIB}"

# Detect if pixi is available
check_pixi() {
    if command -v pixi &>/dev/null; then
        return 0
    fi
    return 1
}

# Install pixi if not present
install_pixi_if_needed() {
    if check_pixi; then
        echo "[setup-global-tools] pixi already installed: $(pixi --version)"
        return 0
    fi

    echo "[setup-global-tools] pixi not found — installing..."

    local pixi_install_script
    pixi_install_script="$(mktemp)"

    case "${PLATFORM}" in
        win64)
            if command -v curl &>/dev/null; then
                curl -fsSL https://pixi.sh/install.ps1 -o "${pixi_install_script}" 2>/dev/null || \
                curl -fsSL https://pixi.sh/install.sh -o "${pixi_install_script}" 2>/dev/null
            elif command -v wget &>/dev/null; then
                wget -qO- https://pixi.sh/install.sh -O "${pixi_install_script}" 2>/dev/null
            fi
            bash "${pixi_install_script}"
            ;;
        linux|darwin)
            if command -v curl &>/dev/null; then
                curl -fsSL https://pixi.sh/install.sh -o "${pixi_install_script}"
            elif command -v wget &>/dev/null; then
                wget -qO- https://pixi.sh/install.sh -O "${pixi_install_script}" 2>/dev/null
            fi
            bash "${pixi_install_script}"
            ;;
        *)
            echo "[setup-global-tools] ERROR: Unknown platform: ${PLATFORM}" >&2
            return 1
            ;;
    esac

    local install_status=$?
    rm -f "${pixi_install_script}"

    if [[ ${install_status} -ne 0 ]]; then
        echo "[setup-global-tools] ERROR: pixi installation failed" >&2
        return ${install_status}
    fi

    echo "[setup-global-tools] pixi installed successfully"
    return 0
}

# Main
echo "[setup-global-tools] Starting global toolchain installation..."

# Install pixi first
if ! install_pixi_if_needed; then
    echo "[setup-global-tools] ERROR: Failed to install pixi" >&2
    exit 1
fi

# Verify pixi is available
if ! check_pixi; then
    # Try to source pixi activation script if available
    pixi_activation="${HOME}/.pixi/bin/pixi-activation.sh"
    if [[ -f "${pixi_activation}" ]]; then
        echo "[setup-global-tools] Sourcing pixi activation script..."
        # shellcheck source=/dev/null
        source "${pixi_activation}"
    fi
fi

if ! check_pixi; then
    echo "[setup-global-tools] ERROR: pixi not found after installation. Please restart your shell." >&2
    exit 1
fi

echo "[setup-global-tools] pixi version: $(pixi --version)"

# Install global tools
echo "[setup-global-tools] Installing global tools..."
kano_pixi_bootstrap_install_global_tools

echo "[setup-global-tools] Global toolchain installation complete!"
