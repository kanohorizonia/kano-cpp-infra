#!/usr/bin/env bash
# =============================================================================
# macOS Native Build — kano-cpp-infra
# =============================================================================
# Simple macOS native build entrypoint for consumers WITHOUT macOS-specific
# overrides (e.g. LLVM prefix, CMAKE_OSX_ARCHITECTURES, remote macBuilder).
#
# Usage:
#   KOG_CPP_ROOT=<src/cpp-root> bash <infra>/scripts/mac/native-build.sh \
#       <configure-preset> <build-preset>
#
# Consumers with custom LLVM/SDK logic (like git-master) should keep their
# own macOS scripts that source local unix_preset_build.sh (which delegates to
# kano_cpp_run_unix_preset) instead of using this entrypoint.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KOG_CPP_ROOT="${KOG_CPP_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Source infra's generic unix preset runner (provides kano_cpp_run_unix_preset)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/unix_preset_build.sh"

export KOG_BUILD_USE_LLVM=1
kano_cpp_run_unix_preset "${1:-macos-ninja-clang}" "${2:-macos-ninja-clang-debug}" KOG
