#!/usr/bin/env bash

set -euo pipefail

KOG_MATRIX_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KOG_MATRIX_CPP_ROOT="$(cd -- "$KOG_MATRIX_SCRIPT_DIR/../../../../.." && pwd)"
KOG_MATRIX_BASE="$KOG_MATRIX_SCRIPT_DIR/../.."

kog_matrix_host_os() {
  local os_name
  os_name="$(uname -s 2>/dev/null || true)"
  case "$os_name" in
    MINGW*|MSYS*|CYGWIN*) printf '%s\n' win64 ;;
    Darwin) printf '%s\n' mac ;;
    *) printf '%s\n' linux ;;
  esac
}

kog_matrix_arch() {
  local arch
  arch="$(uname -m 2>/dev/null || true)"
  case "$arch" in
    aarch64|arm64) printf '%s\n' arm64 ;;
    *) printf '%s\n' x64 ;;
  esac
}

kog_matrix_default_release_script() {
  local os_name arch
  os_name="$(kog_matrix_host_os)"
  arch="$(kog_matrix_arch)"
  case "$os_name" in
    win64)
      printf '%s\n' "$KOG_MATRIX_BASE/platform/win64/ninja-msvc-release.sh"
      ;;
    mac)
      printf '%s\n' "$KOG_MATRIX_BASE/platform/mac/native-build.sh"
      ;;
    *)
      printf '%s\n' "$KOG_MATRIX_BASE/platform/linux/native-build.sh"
      ;;
  esac
}

kog_matrix_default_test_report_script() {
  local os_name arch
  os_name="$(kog_matrix_host_os)"
  arch="$(kog_matrix_arch)"
  case "$os_name" in
    win64) printf '%s\n' "$KOG_MATRIX_BASE/platform/win64/windows_preset_build.sh" ;;
    mac) printf '%s\n' "$KOG_MATRIX_BASE/platform/mac/native-build.sh" ;;
    *) printf '%s\n' "$KOG_MATRIX_BASE/platform/linux/native-build.sh" ;;
  esac
}

kog_matrix_default_coverage_build_script() {
  local os_name arch
  os_name="$(kog_matrix_host_os)"
  arch="$(kog_matrix_arch)"
  case "$os_name" in
    win64) printf '%s\n' "$KOG_MATRIX_BASE/platform/win64/ninja-msvc-coverage-build.sh" ;;
    mac) printf '%s\n' "$KOG_MATRIX_BASE/platform/mac/native-build.sh" ;;
    *) printf '%s\n' "$KOG_MATRIX_BASE/platform/linux/native-build.sh" ;;
  esac
}

kog_matrix_default_coverage_gather_script() {
  local os_name arch
  os_name="$(kog_matrix_host_os)"
  arch="$(kog_matrix_arch)"
  case "$os_name" in
    win64) printf '%s\n' "$KOG_MATRIX_BASE/platform/win64/ninja-msvc-coverage-build.sh" ;;
    mac) printf '%s\n' "$KOG_MATRIX_BASE/platform/mac/native-build.sh" ;;
    *) printf '%s\n' "$KOG_MATRIX_BASE/platform/linux/native-build.sh" ;;
  esac
}

kog_matrix_default_coverage_report_script() {
  local backend os_name arch
  backend="${1:-default}"
  os_name="$(kog_matrix_host_os)"
  arch="$(kog_matrix_arch)"
  case "$os_name" in
    win64)
      printf '%s\n' "$KOG_MATRIX_BASE/platform/win64/windows_preset_build.sh"
      ;;
    mac) printf '%s\n' "$KOG_MATRIX_BASE/platform/mac/native-build.sh" ;;
    *) printf '%s\n' "$KOG_MATRIX_BASE/platform/linux/native-build.sh" ;;
  esac
}
