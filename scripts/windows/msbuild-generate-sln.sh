#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/windows_preset_build.sh"

echo "Configuring Visual Studio solution with automatic vcvarsall bootstrap..."
kano_windows_configure_preset "windows-msbuild" "x64"
echo "Generated solution under: $(kano_windows_cpp_root)/out/obj/windows-msbuild"
