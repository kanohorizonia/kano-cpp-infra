#!/usr/bin/env bash
set -euo pipefail

is_windows_host() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

dotnet_tools_bin() {
  if is_windows_host; then
    printf '%s\n' "$USERPROFILE/.dotnet/tools"
  else
    printf '%s\n' "$HOME/.dotnet/tools"
  fi
}

ensure_dotnet_tools_on_path() {
  local tools_bin
  tools_bin="$(dotnet_tools_bin)"
  if [[ -d "$tools_bin" ]]; then
    export PATH="$tools_bin:$PATH"
  fi
}

install_or_update_dotnet_tool() {
  local pkg="$1"
  local cmd_name="$2"

  if has_cmd "$cmd_name"; then
    return 0
  fi

  if ! has_cmd dotnet; then
    echo "[ensure-coverage-tools] missing dotnet; cannot install $pkg" >&2
    return 1
  fi

  dotnet tool update --global "$pkg" >/dev/null 2>&1 || \
    dotnet tool install --global "$pkg" >/dev/null 2>&1
  ensure_dotnet_tools_on_path
  has_cmd "$cmd_name"
}

main() {
  ensure_dotnet_tools_on_path

  local failed=0

  if is_windows_host; then
    if install_or_update_dotnet_tool "microsoft.codecoverage.console" "codecoverage"; then
      echo "[ensure-coverage-tools] microsoft.codecoverage.console: ok"
    else
      echo "[ensure-coverage-tools] microsoft.codecoverage.console: failed" >&2
      failed=1
    fi

    if install_or_update_dotnet_tool "dotnet-reportgenerator-globaltool" "reportgenerator"; then
      echo "[ensure-coverage-tools] reportgenerator: ok"
    else
      echo "[ensure-coverage-tools] reportgenerator: failed" >&2
      failed=1
    fi

    if has_cmd OpenCppCoverage || has_cmd OpenCppCoverage.exe || [[ -x "/c/Program Files/OpenCppCoverage/OpenCppCoverage.exe" ]]; then
      echo "[ensure-coverage-tools] OpenCppCoverage: ok"
    else
      echo "[ensure-coverage-tools] OpenCppCoverage: missing (optional fallback)" >&2
    fi
  else
    if has_cmd llvm-profdata && has_cmd llvm-cov; then
      echo "[ensure-coverage-tools] llvm-profdata/llvm-cov: ok"
    else
      echo "[ensure-coverage-tools] llvm coverage tools missing" >&2
      failed=1
    fi

    if install_or_update_dotnet_tool "dotnet-reportgenerator-globaltool" "reportgenerator"; then
      echo "[ensure-coverage-tools] reportgenerator: ok"
    else
      echo "[ensure-coverage-tools] reportgenerator: failed" >&2
      failed=1
    fi
  fi

  if [[ "$failed" -ne 0 ]]; then
    return 1
  fi

  echo "[ensure-coverage-tools] all required tools are available"
}

main "$@"
