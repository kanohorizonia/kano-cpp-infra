#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)}"
export KANO_CPP_ROOT="$CPP_ROOT"

. "$CPP_ROOT/shared/infra/scripts/lib/matrix.sh"

# Debug build: use the debug preset script for the current platform
case "$(kano_cpp_infra_matrix_host_os)" in
  win64)
    exec bash "$CPP_ROOT/shared/infra/scripts/platform/win64/ninja-msvc-debug.sh" "$@"
    ;;
  mac)
    exec bash "$CPP_ROOT/shared/infra/scripts/platform/mac/native-build.sh" --config Debug "$@"
    ;;
  *)
    exec bash "$CPP_ROOT/shared/infra/scripts/platform/linux/native-build.sh" --config Debug "$@"
    ;;
esac
