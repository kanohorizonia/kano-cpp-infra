#!/usr/bin/env bash
# =============================================================================
# Linux Native Build via Docker — kano-cpp-infra
# =============================================================================
# Cross-host Linux build: detects host OS and routes appropriately.
#   - Linux host → native preset build
#   - Windows/macOS host + Docker → Docker-based build
#
# Usage (infra entrypoint):
#   KANO_CPP_ROOT=<src/cpp-root> bash <infra>/scripts/linux/native-build.sh \
#       <configure-preset> <build-preset> [prefix]
#
# Consumer pixi.toml typically calls this with hardcoded presets:
#   bash <infra>/scripts/linux/native-build.sh linux-ninja-clang linux-ninja-clang-debug
# =============================================================================
set -euo pipefail

KANO_INFRA_LINUX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${KANO_CPP_ROOT:-${INF_CPP_ROOT:-${KOB_CPP_ROOT:-}}}" ]]; then
    export KANO_CPP_ROOT="$(cd "$KANO_INFRA_LINUX_SCRIPT_DIR/../.." && pwd)"
fi

# Source infra's generic unix preset runner
# shellcheck disable=SC1091
source "${KANO_INFRA_LINUX_SCRIPT_DIR}/../../lib/unix_preset_build.sh"

# Source infra's Docker Linux build helper (for cross-host builds)
# shellcheck disable=SC1091
source "${KANO_INFRA_LINUX_SCRIPT_DIR}/docker-build.sh"

detect_host_and_build() {
    local in_configure_preset="${1:-}"
    local in_build_preset="${2:-}"
    local build_prefix="${3:-KANO}"
    local host_os
    host_os="$(uname -s 2>/dev/null || true)"

    case "$host_os" in
        Linux)
            echo "[INFO] Linux host detected → native build"
            kano_cpp_run_unix_preset "$in_configure_preset" "$in_build_preset" "$build_prefix"
            ;;
        Darwin|MINGW*|MSYS*|CYGWIN*)
            if command -v docker >/dev/null 2>&1; then
                echo "[INFO] Non-Linux host + Docker detected → Docker build"
                kano_cpp_run_linux_preset_via_docker "$in_configure_preset" "$in_build_preset"
            else
                echo "[ERROR] Docker required for Linux builds on non-Linux host" >&2
                exit 1
            fi
            ;;
        *)
            echo "[ERROR] Unknown host OS: $host_os" >&2
            exit 1
            ;;
    esac
}

detect_host_and_build "${1:-linux-ninja-clang}" "${2:-linux-ninja-clang-debug}" "${3:-KANO}"
