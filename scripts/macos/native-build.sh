#!/usr/bin/env bash
# =============================================================================
# macOS Native/Remote Build — kano-cpp-infra
# =============================================================================
# Cross-host macOS build: detects host OS and routes appropriately.
#   - macOS host → native preset build (with LLVM support)
#   - Windows/Linux host → remote build via macBuilder
#
# Usage (infra entrypoint):
#   KOG_CPP_ROOT=<src/cpp-root> bash <infra>/scripts/macos/native-build.sh \
#       <configure-preset> <build-preset>
#
# Consumer pixi.toml typically calls this with hardcoded presets.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KOG_CPP_ROOT="${KOG_CPP_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Source infra's generic unix preset runner
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/unix_preset_build.sh"

detect_host_and_build() {
    local in_configure_preset="${1:-}"
    local in_build_preset="${2:-}"
    local host_os
    host_os="$(uname -s 2>/dev/null || true)"

    case "$host_os" in
        Darwin)
            echo "[INFO] macOS host detected → native build"
            # Enable LLVM mode for macOS
            export KOG_BUILD_USE_LLVM=1
            kano_cpp_run_unix_preset "$in_configure_preset" "$in_build_preset" KOG
            ;;
        *)
            echo "[INFO] Non-macOS host detected → remote build via macBuilder"
            # Remote macOS build (requires kano-remote-host or KOB_MACBUILDER_HOST)
            kano_cpp_remote_build_macos "$in_configure_preset" "$in_build_preset"
            ;;
    esac
}

detect_host_and_build "${1:-macos-ninja-clang}" "${2:-macos-ninja-clang-debug}"
