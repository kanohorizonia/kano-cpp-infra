#!/usr/bin/env bash
# =============================================================================
# Coverage Report Workflow Script
# =============================================================================
# Provides functions for:
#   coverage_build   - Build with coverage instrumentation
#   coverage_merge  - Merge .profraw files into merged.profdata
#   coverage_report - Generate HTML/text coverage report
#   coverage_all    - Run full workflow: build + test + merge + report
#
# Platform support:
#   macOS:  native with llvm-cov from Xcode
#   Linux:  native (CI) or Docker (local)
#   Windows: native (CI) with MSVC tooling
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INF_CPP_ROOT_DEFAULT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/docker_host.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/matrix.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Coverage directories
# ─────────────────────────────────────────────────────────────────────────────
coverage_resolve_root_path() {
    local raw_path="${1:-}"
    local normalized=""
    local base_root="${INF_CPP_ROOT:-${KANO_CPP_INFRA_CPP_ROOT:-${KANO_CPP_ROOT:-$INF_CPP_ROOT_DEFAULT}}}"

    if [[ -z "$raw_path" ]]; then
        return 0
    fi

    normalized="${raw_path//\\//}"
    if command -v cygpath >/dev/null 2>&1 && [[ "$normalized" =~ ^[A-Za-z]:/ ]]; then
        cygpath -u "$normalized"
        return 0
    fi
    if [[ "$normalized" == /* ]]; then
        printf '%s\n' "$normalized"
        return 0
    fi
    normalized="${normalized#./}"
    printf '%s/%s\n' "${base_root%/}" "$normalized"
}

INF_COVERAGE_ROOT="${INF_COVERAGE_ROOT:-${INF_BUILD_ROOT:-$INF_CPP_ROOT_DEFAULT/out}/coverage}"
INF_COVERAGE_ROOT="$(coverage_resolve_root_path "$INF_COVERAGE_ROOT")"
INF_COVERAGE_PROFRAW_DIR="$INF_COVERAGE_ROOT/profraw"
INF_COVERAGE_PROFDATA="$INF_COVERAGE_ROOT/merged.profdata"
INF_COVERAGE_HTML_DIR="$INF_COVERAGE_ROOT/html"

# ─────────────────────────────────────────────────────────────────────────────
# Utility: Detect platform and compiler
# ─────────────────────────────────────────────────────────────────────────────
detect_coverage_env() {
    local platform
    local compiler_id
    local llvm_cov_path

    platform="$(uname -s 2>/dev/null || echo "unknown")"
    compiler_id="unknown"
    llvm_cov_path=""

    # Detect compiler
    if [[ -n "${CXX:-}" ]]; then
        if [[ "$CXX" == *"clang"* ]]; then
            compiler_id="Clang"
        elif [[ "$CXX" == *"gcc"* || "$CXX" == "g++"* ]]; then
            compiler_id="GNU"
        elif [[ "$CXX" == *"msvc"* || "$CXX" == "cl"* ]]; then
            compiler_id="MSVC"
        fi
    elif command -v clang++ >/dev/null 2>&1; then
        compiler_id="Clang"
    elif command -v g++ >/dev/null 2>&1; then
        compiler_id="GNU"
    elif command -v cl >/dev/null 2>&1; then
        compiler_id="MSVC"
    fi

    # Find llvm-cov
    if [[ "$compiler_id" == "Clang" ]]; then
        if [[ "$platform" == "Darwin" ]]; then
            # macOS: Xcode LLVM
            if [[ -x "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-cov" ]]; then
                llvm_cov_path="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
            elif command -v llvm-cov >/dev/null 2>&1; then
                llvm_cov_path="$(dirname "$(command -v llvm-cov)")"
            fi
        else
            # Linux/Unix: check common paths
            for path in /usr/lib/llvm-18/bin /usr/lib/llvm-17/bin /usr/lib/llvm-16/bin /usr/bin; do
                if [[ -x "$path/llvm-cov" ]]; then
                    llvm_cov_path="$path"
                    break
                fi
            done
            if [[ -z "$llvm_cov_path" ]] && command -v llvm-cov >/dev/null 2>&1; then
                llvm_cov_path="$(dirname "$(command -v llvm-cov)")"
            fi
        fi
    fi

    echo "$platform:$compiler_id:$llvm_cov_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Utility: Detect host OS (different from target platform for cross-compile)
# ─────────────────────────────────────────────────────────────────────────────
detect_host_os() {
    uname -s 2>/dev/null || echo "unknown"
}

_is_darwin() { [[ "$(detect_host_os)" == "Darwin" ]]; }
_is_linux()  { [[ "$(detect_host_os)" == "Linux" ]]; }
_is_windows(){ [[ "$(detect_host_os)" == MINGW* || "$(detect_host_os)" == CYGWIN* || "$(detect_host_os)" == MSYS* ]]; }

coverage_default_configure_preset() {
    kano_cpp_infra_matrix_default_coverage_configure_preset
}

coverage_default_test_binary() {
    local platform="${1:-$(detect_host_os)}"
    case "$platform" in
        Darwin|Linux)
            printf '%s\n' "kano_git_tui_tests"
            ;;
        MINGW*|CYGWIN*|MSYS*|*nt*)
            printf '%s\n' "kano_git_tui_tests.exe"
            ;;
    esac
}

coverage_binary_candidate_dirs() {
    local preset="${1:-}"
    local cpp_root="${INF_CPP_ROOT:-${KANO_CPP_INFRA_CPP_ROOT:-$INF_CPP_ROOT_DEFAULT}}"

    case "$preset" in
        linux-*)
            if [[ -d "$INF_COVERAGE_ROOT/linux-out/bin/${preset}" ]]; then
                printf '%s\n' \
                    "$INF_COVERAGE_ROOT/linux-out/bin/${preset}/debug" \
                    "$INF_COVERAGE_ROOT/linux-out/bin/${preset}/release" \
                    "$INF_COVERAGE_ROOT/linux-out/bin/${preset}"
            fi
            printf '%s\n' \
                "$cpp_root/out/bin/${preset}/debug" \
                "$cpp_root/out/bin/${preset}/release" \
                "$cpp_root/out/bin/${preset}"
            ;;
        macos-*|windows-*)
            printf '%s\n' \
                "$cpp_root/out/bin/${preset}/debug" \
                "$cpp_root/out/bin/${preset}/release" \
                "$cpp_root/out/bin/${preset}"
            ;;
        *)
            return 1
            ;;
    esac
}

coverage_resolve_binary_path() {
    local preset="${1:-}"
    local test_binary="${2:-}"
    local candidate_dir=""
    local fallback_path=""

    while IFS= read -r candidate_dir; do
        [[ -n "$candidate_dir" ]] || continue
        if [[ -z "$fallback_path" ]]; then
            fallback_path="$candidate_dir/$test_binary"
        fi
        if [[ -f "$candidate_dir/$test_binary" ]]; then
            printf '%s\n' "$candidate_dir/$test_binary"
            return 0
        fi
    done < <(coverage_binary_candidate_dirs "$preset")

    [[ -n "$fallback_path" ]] || return 1
    printf '%s\n' "$fallback_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Utility: Ensure directories
# ─────────────────────────────────────────────────────────────────────────────
coverage_ensure_dirs() {
    mkdir -p "$INF_COVERAGE_PROFRAW_DIR"
    mkdir -p "$INF_COVERAGE_HTML_DIR"
}

coverage_json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    printf '%s' "$value"
}

coverage_write_status() {
    local status="$1"
    local reason="$2"
    local detail="${3:-}"
    local json_status json_reason json_detail

    json_status="$(coverage_json_escape "$status")"
    json_reason="$(coverage_json_escape "$reason")"
    json_detail="$(coverage_json_escape "$detail")"

    mkdir -p "$INF_COVERAGE_ROOT"
    cat > "$INF_COVERAGE_ROOT/coverage-status.json" <<EOF
{
  "coverageHealth": "$json_status",
  "reason": "$json_reason",
  "detail": "$json_detail"
}
EOF
    cat > "$INF_COVERAGE_ROOT/coverage-status.md" <<EOF
# Coverage Status

- Status: $status
- Reason: $reason
- Detail: $detail
EOF
    echo "[coverage_report] Coverage status: $status ($reason)"
    echo "[coverage_report] Status artifact: $INF_COVERAGE_ROOT/coverage-status.json"
}

# ─────────────────────────────────────────────────────────────────────────────
# coverage_build - Build with coverage instrumentation
# ─────────────────────────────────────────────────────────────────────────────
# Usage: coverage_build [preset]
# Example: coverage_build macos-ninja-clang-coverage
#          coverage_build linux-ninja-clang-coverage
#          coverage_build windows-ninja-msvc-coverage
# ─────────────────────────────────────────────────────────────────────────────
coverage_build() {
    local preset="${1:-}"
    local env_info
    local platform
    local compiler_id
    local llvm_cov_path

    env_info="$(detect_coverage_env)"
    IFS=':' read -r platform compiler_id llvm_cov_path <<< "$env_info"

    echo "[coverage_build] Starting coverage build..."
    echo "[coverage_build] Host platform: $(detect_host_os)"
    echo "[coverage_build] Target platform: $platform, Compiler: $compiler_id"

    coverage_ensure_dirs

    # Auto-select preset if not provided
    if [[ -z "$preset" ]]; then
        preset="$(coverage_default_configure_preset || true)"
        echo "[coverage_build] Auto-selected preset: $preset"
    fi

    if [[ -z "$preset" ]]; then
        echo "[coverage_build] ERROR: Could not auto-detect preset. Please specify explicitly." >&2
        return 1
    fi

    local host_os
    host_os="$(detect_host_os)"

    # Determine target platform from preset
    local target_platform=""
    if [[ "$preset" == macos-* ]]; then
        target_platform="macos"
    elif [[ "$preset" == linux-* ]]; then
        target_platform="linux"
    elif [[ "$preset" == windows-* ]]; then
        target_platform="windows"
    fi

    echo "[coverage_build] Target platform: $target_platform"

    # Cross-platform build logic
    if [[ "$host_os" == "$target_platform" || "$target_platform" == "windows" ]]; then
        # Native build
        echo "[coverage_build] Native build (host=$host_os, target=$target_platform)"
        (
            if [[ -n "${INF_CPP_ROOT:-}" ]]; then
                cd "$INF_CPP_ROOT"
            fi
            cmake --preset "$preset"
            cmake --build --preset "${preset}"
        )
    elif [[ "$target_platform" == "macos" ]]; then
        # macOS build from non-macOS host → use repo-local adapter when available.
        echo "[coverage_build] Remote macOS build via remote host adapter"
        local repo_local_adapter="${SCRIPT_DIR}/../../../../scripts/macos/remote-build.sh"
        if [[ -f "$repo_local_adapter" ]]; then
            # shellcheck disable=SC1091
source "$repo_local_adapter"
            kog_remote_build_macos "$preset" "Debug"
        else
            source "$SCRIPT_DIR/macos_remote_build.sh"
            inf_remote_build_macos "$preset" "Debug"
        fi
    elif [[ "$target_platform" == "linux" ]]; then
        # Linux build from non-Linux host → use Docker
        if command -v docker >/dev/null 2>&1; then
            echo "[coverage_build] Linux build via Docker"
            coverage_build_linux_via_docker "$preset"
        else
            echo "[coverage_build] ERROR: Docker required for Linux builds on non-Linux host" >&2
            echo "[coverage_build] Or use: coverage_build $preset on a Linux machine" >&2
            return 1
        fi
    else
        echo "[coverage_build] ERROR: Cannot build $target_platform on $host_os without remote build configured" >&2
        return 1
    fi

    echo "[coverage_build] Build complete."
    echo "[coverage_build] Now run: coverage_run_tests [preset] [test-binary]"
}

# ─────────────────────────────────────────────────────────────────────────────
# coverage_build_linux_via_docker
# Uses docker cp pattern: build inside container, copy results out
# ─────────────────────────────────────────────────────────────────────────────
coverage_build_linux_via_docker() {
    local preset="${1:-linux-ninja-clang-coverage}"
    local cpp_root="${INF_CPP_ROOT:-$(pwd)/src/cpp}"
    local repo_root=""
    local container_name="kano-git-coverage-$$"
    local docker_image="ubuntu:24.04"
    local input_mount=""
    local linux_out_host=""
    local linux_deps_host=""
    local q_preset=""
    local container_script=""

    echo "[coverage_build_linux_docker] Starting Docker container..."

    repo_root="$(cd "$cpp_root/../.." >/dev/null 2>&1 && pwd -P)"
    input_mount="$(kano_cpp_docker_volume_arg "$repo_root" /input ro)" || return 1

    # Start container in background, mount the repo read-only so the build can run
    # in an internal writable workspace and stay shell-agnostic across hosts.
    kano_cpp_docker_run run -d \
        --name "$container_name" \
        --security-opt seccomp=unconfined \
        -v "$input_mount" \
        -w /workspace \
        "$docker_image" sleep infinity \
        2>&1 || {
        echo "[coverage_build_linux_docker] ERROR: Failed to start container" >&2
        return 1
    }

    printf -v q_preset '%q' "$preset"
    printf -v container_script '%s\n' \
        "set -euo pipefail" \
        "rm -rf /workspace/src/cpp" \
        "mkdir -p /workspace/src" \
        "cp -a /input/src/cpp /workspace/src/cpp" \
        "cd /workspace/src/cpp" \
        "apt-get update" \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y cmake ninja-build clang llvm llvm-tools python3 git" \
        "cmake --preset ${q_preset}" \
        "cmake --build --preset ${q_preset}"

    # Install tools and build inside container
    kano_cpp_docker_run exec "$container_name" bash -lc "$container_script" 2>&1 || {
        echo "[coverage_build_linux_docker] ERROR: Docker build failed" >&2
        kano_cpp_docker_run rm -f "$container_name" >/dev/null 2>&1 || true
        return 1
    }

    # Copy build output back to host
    mkdir -p "$INF_COVERAGE_ROOT"
    rm -rf "$INF_COVERAGE_ROOT/linux-out" "$INF_COVERAGE_ROOT/linux-deps"
    linux_out_host="$(kano_cpp_docker_host_path_for_cli "$INF_COVERAGE_ROOT")/linux-out"
    kano_cpp_docker_run cp "$container_name:/workspace/src/cpp/out" "$linux_out_host" 2>&1
    if kano_cpp_docker_run exec "$container_name" test -d /workspace/src/cpp/_deps >/dev/null 2>&1; then
        linux_deps_host="$(kano_cpp_docker_host_path_for_cli "$INF_COVERAGE_ROOT")/linux-deps"
        kano_cpp_docker_run cp "$container_name:/workspace/src/cpp/_deps" "$linux_deps_host" 2>&1 || true
    fi

    # Cleanup
    kano_cpp_docker_run rm -f "$container_name" >/dev/null 2>&1 || true

    echo "[coverage_build_linux_docker] Done."
    echo "[coverage_build_linux_docker] Build output copied to: $INF_COVERAGE_ROOT/linux-out"
}

# ─────────────────────────────────────────────────────────────────────────────
# coverage_run_tests - Run tests with coverage instrumentation
# ─────────────────────────────────────────────────────────────────────────────
# Usage: coverage_run_tests [preset] [test-binary]
# Example: coverage_run_tests macos-ninja-clang-coverage kano_git_tui_tests
# ─────────────────────────────────────────────────────────────────────────────
coverage_run_tests() {
    local preset="${1:-}"
    local test_binary="${2:-}"
    local env_info
    local platform
    local compiler_id
    local llvm_cov_path

    env_info="$(detect_coverage_env)"
    IFS=':' read -r platform compiler_id llvm_cov_path <<< "$env_info"

    echo "[coverage_run_tests] Running tests with coverage..."

    # Auto-detect from preset
    if [[ -z "$preset" ]]; then
        preset="$(coverage_default_configure_preset || true)"
    fi

    # Auto-detect test binary
    if [[ -z "$test_binary" ]]; then
        test_binary="$(coverage_default_test_binary "$platform")"
    fi

    local cpp_root="${INF_CPP_ROOT:-$(pwd)/src/cpp}"
    local binary_path=""
    binary_path="$(coverage_resolve_binary_path "$preset" "$test_binary" || true)"

    if [[ ! -f "$binary_path" ]]; then
        echo "[coverage_run_tests] ERROR: Binary not found: $binary_path" >&2
        return 1
    fi

    echo "[coverage_run_tests] Binary: $binary_path"
    echo "[coverage_run_tests] Profile output: $INF_COVERAGE_PROFRAW_DIR"

    # Clean old profraw files
    rm -f "$INF_COVERAGE_PROFRAW_DIR"/*.profraw 2>/dev/null || true

    # Set LLVM_PROFILE_FILE and run
    export LLVM_PROFILE_FILE="$INF_COVERAGE_PROFRAW_DIR/%m.profraw"

    (
        cd "$cpp_root"
        "$binary_path"
    )

    echo "[coverage_run_tests] Tests complete. Profile data in: $INF_COVERAGE_PROFRAW_DIR"
    echo "[coverage_run_tests] Found: $(find "$INF_COVERAGE_PROFRAW_DIR" -name "*.profraw" 2>/dev/null | wc -l) .profraw files"
}

# ─────────────────────────────────────────────────────────────────────────────
# coverage_merge - Merge .profraw files into merged.profdata
# ─────────────────────────────────────────────────────────────────────────────
# Usage: coverage_merge [output-file]
# Example: coverage_merge
#          coverage_merge custom.profdata
# ─────────────────────────────────────────────────────────────────────────────
coverage_merge() {
    local output_file="${1:-$INF_COVERAGE_PROFDATA}"
    local env_info
    local platform
    local compiler_id
    local llvm_cov_path

    env_info="$(detect_coverage_env)"
    IFS=':' read -r platform compiler_id llvm_cov_path <<< "$env_info"

    echo "[coverage_merge] Merging coverage profiles..."
    echo "[coverage_merge] Platform: $platform, Compiler: $compiler_id"
    echo "[coverage_merge] LLVM-cov path: ${llvm_cov_path:-not found}"

    coverage_ensure_dirs

    if [[ "$compiler_id" == "Clang" ]]; then
        if [[ -z "$llvm_cov_path" ]] && ! command -v llvm-profdata >/dev/null 2>&1; then
            echo "[coverage_merge] ERROR: llvm-profdata not found. Install LLVM/Clang tools." >&2
            return 1
        fi

        local llvm_profdata="${llvm_cov_path:+$llvm_cov_path/}llvm-profdata"
        if [[ ! -x "$llvm_profdata" ]] && ! command -v llvm-profdata >/dev/null 2>&1; then
            echo "[coverage_merge] ERROR: llvm-profdata not executable: $llvm_profdata" >&2
            return 1
        fi
        if [[ ! -x "$llvm_profdata" ]]; then
            llvm_profdata="$(command -v llvm-profdata)"
        fi

        local -a profraw_files=()
        while IFS= read -r -d '' file; do
            profraw_files+=("$file")
        done < <(find "$INF_COVERAGE_PROFRAW_DIR" -name "*.profraw" -type f -print0 2>/dev/null || true)

        if [[ ${#profraw_files[@]} -eq 0 ]]; then
            echo "[coverage_merge] WARNING: No .profraw files found in $INF_COVERAGE_PROFRAW_DIR" >&2
            echo "[coverage_merge] Did you run coverage_run_tests first?" >&2
            return 1
        fi

        echo "[coverage_merge] Found ${#profraw_files[@]} .profraw files"

        mkdir -p "$(dirname "$output_file")"
        "$llvm_profdata" merge -o "$output_file" "${profraw_files[@]}" 2>&1 || {
            echo "[coverage_merge] ERROR: llvm-profdata merge failed" >&2
            return 1
        }

        echo "[coverage_merge] Merged profile written to: $output_file"

    elif [[ "$compiler_id" == "GNU" ]]; then
        echo "[coverage_merge] GCC coverage: .gcda files are in build directory"
        echo "[coverage_merge] Use gcov tool to generate coverage reports"

    elif [[ "$compiler_id" == "MSVC" ]]; then
        echo "[coverage_merge] MSVC coverage: /PROFILE data in build directory"
        echo "[coverage_merge] Use Microsoft.CodeCoverage.Console or Visual Studio for reports"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# coverage_report - Generate HTML/text coverage report
# ─────────────────────────────────────────────────────────────────────────────
# Usage: coverage_report [preset] [test-binary]
# Example: coverage_report
#          coverage_report macos-ninja-clang-coverage kano_git_tui_tests
# ─────────────────────────────────────────────────────────────────────────────
coverage_report() {
    local preset="${1:-}"
    local test_binary="${2:-}"
    local env_info
    local platform
    local compiler_id
    local llvm_cov_path

    env_info="$(detect_coverage_env)"
    IFS=':' read -r platform compiler_id llvm_cov_path <<< "$env_info"

    echo "[coverage_report] Generating coverage report..."
    echo "[coverage_report] Platform: $platform, Compiler: $compiler_id"

    coverage_ensure_dirs

    # Auto-detect preset
    if [[ -z "$preset" ]]; then
        preset="$(coverage_default_configure_preset || true)"
    fi

    # Auto-detect test binary
    if [[ -z "$test_binary" ]]; then
        test_binary="$(coverage_default_test_binary "$platform")"
    fi

    local binary_path=""
    binary_path="$(coverage_resolve_binary_path "$preset" "$test_binary" || true)"

    if [[ ! -f "$binary_path" ]]; then
        echo "[coverage_report] WARNING: Binary not found: $binary_path" >&2
        coverage_write_status "UNAVAILABLE" "NO_INSTRUMENTED_BINARIES" "$binary_path"
        return 0
    fi

    if [[ ! -f "$INF_COVERAGE_PROFDATA" ]]; then
        echo "[coverage_report] WARNING: Merged profile not found: $INF_COVERAGE_PROFDATA" >&2
        echo "[coverage_report] Run coverage_merge first." >&2
        coverage_write_status "UNAVAILABLE" "MISSING_MERGED_PROFILE" "$INF_COVERAGE_PROFDATA"
        return 0
    fi

    if [[ "$compiler_id" == "Clang" ]]; then
        if [[ -z "$llvm_cov_path" ]] && ! command -v llvm-cov >/dev/null 2>&1; then
            echo "[coverage_report] ERROR: llvm-cov not found." >&2
            coverage_write_status "TOOL_FAILED" "LLVM_COV_NOT_FOUND" "llvm-cov"
            return 1
        fi

        local llvm_cov="${llvm_cov_path:+$llvm_cov_path/}llvm-cov"
        if [[ ! -x "$llvm_cov" ]] && ! command -v llvm-cov >/dev/null 2>&1; then
            echo "[coverage_report] ERROR: llvm-cov not executable: $llvm_cov" >&2
            coverage_write_status "TOOL_FAILED" "LLVM_COV_NOT_EXECUTABLE" "$llvm_cov"
            return 1
        fi
        if [[ ! -x "$llvm_cov" ]]; then
            llvm_cov="$(command -v llvm-cov)"
        fi

        # HTML report
        mkdir -p "$INF_COVERAGE_HTML_DIR"
        echo "[coverage_report] Generating HTML report..."
        "$llvm_cov" show \
            "$binary_path" \
            -instr-profile="$INF_COVERAGE_PROFDATA" \
            --format=html \
            --output-dir="$INF_COVERAGE_HTML_DIR" \
            --ignore-filename-regex="_deps|catch2|ftxui|thirdparty|build|\.vcpkg" 2>&1 || {
            echo "[coverage_report] WARNING: Some files not found (normal for deps)"
        }

        # Text summary
        echo ""
        echo "[coverage_report] Text summary:"
        "$llvm_cov" report \
            "$binary_path" \
            -instr-profile="$INF_COVERAGE_PROFDATA" \
            --ignore-filename-regex="_deps|catch2|ftxui|thirdparty|build|\.vcpkg" 2>&1 || true

        echo ""
        echo "[coverage_report] HTML report: $INF_COVERAGE_HTML_DIR/index.html"

    elif [[ "$compiler_id" == "GNU" ]]; then
        echo "[coverage_report] Use gcov to generate coverage reports from .gcda files"
        echo "[coverage_report] gcda files in: $INF_COVERAGE_PROFRAW_DIR"

    elif [[ "$compiler_id" == "MSVC" ]]; then
        echo "[coverage_report] MSVC coverage data in build directory"
        echo "[coverage_report] Use Microsoft.CodeCoverage.Console: coverage analyze /in:input.coverage /out:output.coverage"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# coverage_all - Run full coverage workflow
# ─────────────────────────────────────────────────────────────────────────────
# Usage: coverage_all [preset]
# Example: coverage_all macos-ninja-clang-coverage
#          coverage_all linux-ninja-clang-coverage
# ─────────────────────────────────────────────────────────────────────────────
coverage_all() {
    local preset="${1:-}"

    echo "========================================"
    echo "  Coverage Workflow"
    echo "========================================"

    coverage_build "$preset"
    coverage_run_tests "$preset"
    coverage_merge
    coverage_report "$preset"

    echo ""
    echo "========================================"
    echo "  Coverage Complete"
    echo "========================================"
    echo "Reports:"
    echo "  HTML: $INF_COVERAGE_HTML_DIR/index.html"
    echo "  Summary: Run 'coverage_report' for text output"
}

# ─────────────────────────────────────────────────────────────────────────────
# coverage_info - Show current coverage environment
# ─────────────────────────────────────────────────────────────────────────────
coverage_info() {
    local env_info
    env_info="$(detect_coverage_env)"

    echo "=== Coverage Environment ==="
    echo "Host OS:        $(detect_host_os)"
    echo "Target Platform: ${env_info%%:*}"
    echo "Compiler:       ${env_info#*:}"
    echo "llvm-cov path: ${env_info##*:}"
    echo ""
    echo "Directories:"
    echo "  Coverage Root: $INF_COVERAGE_ROOT"
    echo "  Profraw Dir:  $INF_COVERAGE_PROFRAW_DIR"
    echo "  Merged Data:  $INF_COVERAGE_PROFDATA"
    echo "  HTML Output:  $INF_COVERAGE_HTML_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main entrypoint
# ─────────────────────────────────────────────────────────────────────────────
_coverage_main() {
    local command="${1:-}"

    case "$command" in
        build)
            shift
            coverage_build "$@"
            ;;
        test|run-tests)
            shift
            coverage_run_tests "$@"
            ;;
        merge)
            shift
            coverage_merge "$@"
            ;;
        report)
            shift
            coverage_report "$@"
            ;;
        all)
            shift
            coverage_all "$@"
            ;;
        info)
            coverage_info
            ;;
        help|--help|-h)
            echo "Usage: $0 <command> [options]"
            echo ""
            echo "Commands:"
            echo "  build [preset]       Build with coverage instrumentation"
            echo "  test [preset] [bin]  Run tests to generate .profraw files"
            echo "  merge [file]        Merge .profraw into merged.profdata"
            echo "  report [preset] [bin] Generate HTML/text coverage report"
            echo "  all [preset]         Run full workflow: build + test + merge + report"
            echo "  info                 Show coverage environment"
            echo ""
            echo "Examples:"
            echo "  $0 all macos-ninja-clang-coverage"
            echo "  $0 all linux-ninja-clang-coverage"
            echo "  $0 build linux-ninja-clang-coverage"
            echo "  $0 test"
            echo "  $0 merge"
            echo "  $0 report"
            echo ""
            echo "Environment Variables:"
            echo "  INF_COVERAGE_ROOT    Base directory (default: build/coverage)"
            echo "  INF_BUILD_ROOT      Build root directory"
            echo "  INF_CPP_ROOT        C++ source root"
            ;;
        "")
            echo "Error: No command specified" >&2
            echo "Run '$0 help' for usage." >&2
            return 1
            ;;
        *)
            echo "Error: Unknown command: $command" >&2
            echo "Run '$0 help' for usage." >&2
            return 1
            ;;
    esac
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _coverage_main "$@"
fi
