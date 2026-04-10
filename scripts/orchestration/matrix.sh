#!/usr/bin/env bash

set -euo pipefail

KOG_MATRIX_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KOG_MATRIX_CPP_ROOT="$(cd -- "$KOG_MATRIX_SCRIPT_DIR/../.." && pwd)"
KOG_MATRIX_BASE="$KOG_MATRIX_CPP_ROOT/scripts"

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
      if [[ "$arch" == "arm64" ]]; then
        printf '%s\n' "$KOG_MATRIX_BASE/win64/ninja-msvc-arm64-release.sh"
      else
        printf '%s\n' "$KOG_MATRIX_BASE/win64/ninja-msvc-release.sh"
      fi
      ;;
    mac)
      if [[ "$arch" == "arm64" ]]; then
        printf '%s\n' "$KOG_MATRIX_BASE/mac/ninja-clang-arm64-release.sh"
      else
        printf '%s\n' "$KOG_MATRIX_BASE/mac/ninja-clang-x64-release.sh"
      fi
      ;;
    *)
      printf '%s\n' "$KOG_MATRIX_BASE/linux/ninja-gcc-release.sh"
      ;;
  esac
}

kog_matrix_default_test_report_script() {
  local os_name arch
  os_name="$(kog_matrix_host_os)"
  arch="$(kog_matrix_arch)"
  case "$os_name" in
    win64) printf '%s\n' "$KOG_MATRIX_BASE/win64/test-report.sh" ;;
    mac)
      if [[ "$arch" == "arm64" ]]; then
        printf '%s\n' "$KOG_MATRIX_BASE/mac/test-report-arm64.sh"
      else
        printf '%s\n' "$KOG_MATRIX_BASE/mac/test-report.sh"
      fi
      ;;
    *) printf '%s\n' "$KOG_MATRIX_BASE/linux/test-report.sh" ;;
  esac
}

kog_matrix_default_coverage_build_script() {
  local os_name arch
  os_name="$(kog_matrix_host_os)"
  arch="$(kog_matrix_arch)"
  case "$os_name" in
    win64) printf '%s\n' "$KOG_MATRIX_BASE/win64/ninja-msvc-coverage-build.sh" ;;
    mac)
      if [[ "$arch" == "arm64" ]]; then
        printf '%s\n' "$KOG_MATRIX_BASE/mac/ninja-clang-arm64-coverage-build.sh"
      else
        printf '%s\n' "$KOG_MATRIX_BASE/mac/ninja-clang-coverage-build.sh"
      fi
      ;;
    *) printf '%s\n' "$KOG_MATRIX_BASE/linux/ninja-clang-coverage-build.sh" ;;
  esac
}

kog_matrix_default_coverage_gather_script() {
  local os_name arch
  os_name="$(kog_matrix_host_os)"
  arch="$(kog_matrix_arch)"
  case "$os_name" in
    win64) printf '%s\n' "$KOG_MATRIX_BASE/win64/ninja-msvc-coverage-run.sh" ;;
    mac)
      if [[ "$arch" == "arm64" ]]; then
        printf '%s\n' "$KOG_MATRIX_BASE/mac/ninja-clang-arm64-coverage-run.sh"
      else
        printf '%s\n' "$KOG_MATRIX_BASE/mac/ninja-clang-coverage-run.sh"
      fi
      ;;
    *) printf '%s\n' "$KOG_MATRIX_BASE/linux/ninja-clang-coverage-run.sh" ;;
  esac
}

kog_matrix_default_coverage_report_script() {
  local backend os_name arch
  backend="${1:-default}"
  os_name="$(kog_matrix_host_os)"
  arch="$(kog_matrix_arch)"
  case "$os_name" in
    win64)
      if [[ "$backend" == "opencppcoverage" ]]; then
        printf '%s\n' "$KOG_MATRIX_BASE/win64/coverage-report-opencppcoverage.sh"
      else
        printf '%s\n' "$KOG_MATRIX_BASE/win64/coverage-report-microsoft.sh"
      fi
      ;;
    mac)
      if [[ "$arch" == "arm64" ]]; then
        printf '%s\n' "$KOG_MATRIX_BASE/mac/coverage-report-llvm-arm64.sh"
      else
        printf '%s\n' "$KOG_MATRIX_BASE/mac/coverage-report-llvm.sh"
      fi
      ;;
    *) printf '%s\n' "$KOG_MATRIX_BASE/linux/coverage-report-llvm.sh" ;;
  esac
}
