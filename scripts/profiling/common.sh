#!/usr/bin/env bash

set -euo pipefail

INF_PROFILE_COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Allow wrapper scripts to override these via env vars; fall back to direct infra layout.
INF_PROFILE_SCRIPT_ROOT="${INF_PROFILE_SCRIPT_ROOT:-$INF_PROFILE_COMMON_DIR}"
INF_PROFILE_CPP_ROOT="${INF_PROFILE_CPP_ROOT:-${INF_CPP_ROOT:-$(cd -- "$INF_PROFILE_COMMON_DIR/../../../.." && pwd)}}"
INF_PROFILE_REPO_ROOT="${INF_PROFILE_REPO_ROOT:-$(cd -- "$INF_PROFILE_CPP_ROOT/../.." && pwd)}"
INF_PROFILE_TMP_ROOT="${INF_PROFILE_TMP_ROOT:-$INF_PROFILE_REPO_ROOT/.kano/tmp/profiling}"
INF_PROFILE_REPORT_ROOT="${INF_PROFILE_REPORT_ROOT:-$INF_PROFILE_REPO_ROOT/docs/profiling}"
INF_BASELINE_SCRIPT="${INF_BASELINE_SCRIPT:-$INF_PROFILE_CPP_ROOT/shared/infra/scripts/common/measure_iteration_baseline.sh}"
INF_PGO_REBUILD_SCRIPT="${INF_PGO_REBUILD_SCRIPT:-$INF_PROFILE_CPP_ROOT/shared/infra/scripts/workflows/pgo-rebuild.sh}"

inf_profile_host_os() {
  local os_name
  os_name="$(uname -s 2>/dev/null || true)"
  case "$os_name" in
    MINGW*|MSYS*|CYGWIN*) printf '%s\n' windows ;;
    Darwin) printf '%s\n' macos ;;
    *) printf '%s\n' linux ;;
  esac
}

inf_profile_arch() {
  local arch
  arch="$(uname -m 2>/dev/null || true)"
  case "$arch" in
    aarch64|arm64) printf '%s\n' arm64 ;;
    *) printf '%s\n' x64 ;;
  esac
}

inf_profile_resolve_matrix() {
  local matrix_name="${1:-default}"
  printf '%s\n' "$INF_PROFILE_COMMON_DIR/matrices/${matrix_name}.json"
}

inf_profile_require_matrix() {
  local matrix_path
  matrix_path="$(inf_profile_resolve_matrix "$1")"
  [[ -f "$matrix_path" ]] || {
    echo "profiling matrix not found: $matrix_path" >&2
    return 1
  }
  printf '%s\n' "$matrix_path"
}
