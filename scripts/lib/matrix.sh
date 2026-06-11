#!/usr/bin/env bash

set -euo pipefail

KANO_CPP_INFRA_MATRIX_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KANO_CPP_INFRA_MATRIX_CPP_ROOT="$(cd -- "$KANO_CPP_INFRA_MATRIX_SCRIPT_DIR/../../../.." && pwd)"
KANO_CPP_INFRA_MATRIX_BASE="$KANO_CPP_INFRA_MATRIX_SCRIPT_DIR/.."
KANO_CPP_INFRA_MATRIX_CMAKE_PRESETS="$KANO_CPP_INFRA_MATRIX_CPP_ROOT/CMakePresets.json"

kano_cpp_infra_matrix_is_wsl() {
  [[ "$(uname -s 2>/dev/null || true)" == Linux* ]] && \
  grep -qi microsoft /proc/version 2>/dev/null
}

kano_cpp_infra_matrix_host_os() {
  local os_name
  os_name="$(uname -s 2>/dev/null || true)"
  # WSL reports Linux but is not a supported Windows build path — treat as linux host
  case "$os_name" in
    MINGW*|MSYS*|CYGWIN*) printf '%s\n' win64 ;;
    Darwin) printf '%s\n' mac ;;
    *) printf '%s\n' linux ;;
  esac
}

kano_cpp_infra_matrix_arch() {
  local arch
  arch="$(uname -m 2>/dev/null || true)"
  case "$arch" in
    aarch64|arm64) printf '%s\n' arm64 ;;
    *) printf '%s\n' x64 ;;
  esac
}

kano_cpp_infra_matrix_preset_exists() {
  local preset="${1:-}"
  [[ -n "$preset" ]] || return 1
  [[ -f "$KANO_CPP_INFRA_MATRIX_CMAKE_PRESETS" ]] || return 1
  grep -Fq "\"name\": \"${preset}\"" "$KANO_CPP_INFRA_MATRIX_CMAKE_PRESETS"
}

kano_cpp_infra_matrix_first_existing_preset() {
  local candidate
  for candidate in "$@"; do
    if [[ -n "$candidate" ]] && kano_cpp_infra_matrix_preset_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

kano_cpp_infra_matrix_default_coverage_configure_preset() {
  local os_name arch
  os_name="$(kano_cpp_infra_matrix_host_os)"
  arch="$(kano_cpp_infra_matrix_arch)"
  case "$os_name" in
    win64)
      kano_cpp_infra_matrix_first_existing_preset windows-ninja-clang-coverage windows-ninja-msvc-coverage windows-ninja-msvc
      ;;
    mac)
      if [[ "$arch" == "arm64" ]]; then
        kano_cpp_infra_matrix_first_existing_preset \
          macos-ninja-clang-arm64-coverage \
          macos-ninja-clang-coverage \
          macos-ninja-clang-arm64 \
          macos-ninja-clang
      else
        kano_cpp_infra_matrix_first_existing_preset \
          macos-ninja-clang-x64-coverage \
          macos-ninja-clang-coverage \
          macos-ninja-clang-x64 \
          macos-ninja-clang
      fi
      ;;
    *)
      kano_cpp_infra_matrix_first_existing_preset \
        linux-ninja-clang-coverage \
        linux-ninja-gcc-coverage \
        linux-ninja-clang \
        linux-ninja-gcc
      ;;
  esac
}

kano_cpp_infra_matrix_default_coverage_build_preset() {
  local os_name arch
  os_name="$(kano_cpp_infra_matrix_host_os)"
  arch="$(kano_cpp_infra_matrix_arch)"
  case "$os_name" in
    win64)
      kano_cpp_infra_matrix_first_existing_preset \
        windows-ninja-clang-coverage-debug \
        windows-ninja-msvc-coverage-debug \
        windows-ninja-msvc-debug
      ;;
    mac)
      if [[ "$arch" == "arm64" ]]; then
        kano_cpp_infra_matrix_first_existing_preset \
          macos-ninja-clang-arm64-coverage-debug \
          macos-ninja-clang-coverage-debug \
          macos-ninja-clang-arm64-debug \
          macos-ninja-clang-debug
      else
        kano_cpp_infra_matrix_first_existing_preset \
          macos-ninja-clang-x64-coverage-debug \
          macos-ninja-clang-coverage-debug \
          macos-ninja-clang-x64-debug \
          macos-ninja-clang-debug
      fi
      ;;
    *)
      kano_cpp_infra_matrix_first_existing_preset \
        linux-ninja-clang-coverage-debug \
        linux-ninja-gcc-coverage-debug \
        linux-ninja-clang-debug \
        linux-ninja-gcc-debug
      ;;
  esac
}

kano_cpp_infra_matrix_default_release_configure_preset() {
  local os_name arch
  os_name="$(kano_cpp_infra_matrix_host_os)"
  arch="$(kano_cpp_infra_matrix_arch)"
  case "$os_name" in
    win64)
      kano_cpp_infra_matrix_first_existing_preset windows-ninja-msvc windows-ninja-msvc-arm64
      ;;
    mac)
      if [[ "$arch" == "arm64" ]]; then
        kano_cpp_infra_matrix_first_existing_preset macos-ninja-clang-arm64 macos-ninja-clang
      else
        kano_cpp_infra_matrix_first_existing_preset macos-ninja-clang-x64 macos-ninja-clang
      fi
      ;;
    *)
      kano_cpp_infra_matrix_first_existing_preset linux-ninja-gcc linux-ninja-clang
      ;;
  esac
}

kano_cpp_infra_matrix_default_release_build_preset() {
  local os_name arch
  os_name="$(kano_cpp_infra_matrix_host_os)"
  arch="$(kano_cpp_infra_matrix_arch)"
  case "$os_name" in
    win64)
      kano_cpp_infra_matrix_first_existing_preset windows-ninja-msvc-release windows-ninja-msvc-arm64-release
      ;;
    mac)
      if [[ "$arch" == "arm64" ]]; then
        kano_cpp_infra_matrix_first_existing_preset macos-ninja-clang-arm64-release macos-ninja-clang-release
      else
        kano_cpp_infra_matrix_first_existing_preset macos-ninja-clang-x64-release macos-ninja-clang-release
      fi
      ;;
    *)
      kano_cpp_infra_matrix_first_existing_preset linux-ninja-gcc-release linux-ninja-clang-release
      ;;
  esac
}

kano_cpp_infra_matrix_default_release_script() {
  local os_name arch
  os_name="$(kano_cpp_infra_matrix_host_os)"
  arch="$(kano_cpp_infra_matrix_arch)"
  case "$os_name" in
    win64)
      printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/platform/win64/ninja-msvc-release.sh"
      ;;
    mac)
      printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/platform/mac/native-build.sh"
      ;;
    *)
      printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/platform/linux/native-build.sh"
      ;;
  esac
}

kano_cpp_infra_matrix_default_test_report_script() {
  local os_name arch
  os_name="$(kano_cpp_infra_matrix_host_os)"
  arch="$(kano_cpp_infra_matrix_arch)"
  case "$os_name" in
    win64) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/lib/test_report.sh" ;;
    mac) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/lib/test_report.sh" ;;
    *) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/lib/test_report.sh" ;;
  esac
}

kano_cpp_infra_matrix_default_coverage_build_script() {
  local os_name arch
  os_name="$(kano_cpp_infra_matrix_host_os)"
  arch="$(kano_cpp_infra_matrix_arch)"
  case "$os_name" in
    win64) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/platform/win64/ninja-msvc-coverage-build.sh" ;;
    mac) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/platform/mac/native-build.sh" ;;
    *) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/platform/linux/native-build.sh" ;;
  esac
}

kano_cpp_infra_matrix_default_coverage_gather_script() {
  local os_name arch
  os_name="$(kano_cpp_infra_matrix_host_os)"
  arch="$(kano_cpp_infra_matrix_arch)"
  case "$os_name" in
    win64) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/lib/coverage_report.sh" ;;
    mac) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/lib/coverage_report.sh" ;;
    *) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/lib/coverage_report.sh" ;;
  esac
}

kano_cpp_infra_matrix_default_coverage_report_script() {
  local backend os_name arch
  backend="${1:-default}"
  os_name="$(kano_cpp_infra_matrix_host_os)"
  arch="$(kano_cpp_infra_matrix_arch)"
  case "$os_name" in
    win64)
      printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/lib/coverage_report.sh"
      ;;
    mac) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/lib/coverage_report.sh" ;;
    *) printf '%s\n' "$KANO_CPP_INFRA_MATRIX_BASE/lib/coverage_report.sh" ;;
  esac
}
