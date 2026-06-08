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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/report_skill_adapter.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/python_resolver.sh"

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

coverage_resolve_llvm_tool() {
    local tool="$1"
    local env_var="$2"
    local fallback_env_var="$3"
    local explicit="${!env_var:-}"
    local fallback="${!fallback_env_var:-}"
    local candidate
    for candidate in \
        "$explicit" \
        "$fallback" \
        "$tool" \
        "$tool-21" \
        "$tool-20" \
        "$tool-19" \
        "$tool-18" \
        "$tool-17" \
        "$tool-16"; do
        [[ -n "$candidate" ]] || continue
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    if command -v xcrun >/dev/null 2>&1; then
        candidate="$(xcrun -f "$tool" 2>/dev/null || true)"
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    return 1
}

coverage_resolve_llvm_profdata() {
    coverage_resolve_llvm_tool llvm-profdata KANO_LLVM_PROFDATA LLVM_PROFDATA
}

coverage_resolve_llvm_cov() {
    coverage_resolve_llvm_tool llvm-cov KANO_LLVM_COV LLVM_COV
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

coverage_cpp_root() {
    printf '%s\n' "${INF_CPP_ROOT:-${KANO_CPP_INFRA_CPP_ROOT:-${KANO_CPP_ROOT:-$INF_CPP_ROOT_DEFAULT}}}"
}

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

coverage_resolve_python_bin() {
    kano_resolve_python_bin
}

coverage_to_windows_path() {
    local value="${1:-}"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$value"
        return 0
    fi
    printf '%s\n' "$value"
}

coverage_resolve_opencppcoverage() {
    if command -v OpenCppCoverage >/dev/null 2>&1; then
        command -v OpenCppCoverage
        return 0
    fi
    if command -v OpenCppCoverage.exe >/dev/null 2>&1; then
        command -v OpenCppCoverage.exe
        return 0
    fi
    if [[ -x "/c/Program Files/OpenCppCoverage/OpenCppCoverage.exe" ]]; then
        printf '%s\n' "/c/Program Files/OpenCppCoverage/OpenCppCoverage.exe"
        return 0
    fi
    if [[ -x "/c/Program Files/OpenCppCoverage/OpenCppCoverage" ]]; then
        printf '%s\n' "/c/Program Files/OpenCppCoverage/OpenCppCoverage"
        return 0
    fi
    return 1
}

coverage_is_windows_preset() {
    local preset="${1:-}"
    _is_windows && [[ "$preset" == windows-* ]]
}

coverage_cobertura_lines_valid() {
    local xml_file="$1"
    local python_bin
    python_bin="$(coverage_resolve_python_bin)" || return 1
    kano_python "$python_bin" - "$xml_file" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
    print(int(root.attrib.get("lines-valid", "0") or "0"))
except Exception:
    print(0)
PY
}

coverage_normalize_cobertura_for_jenkins() {
    local source_xml="$1"
    local target_xml="${2:-$1}"
    local python_bin

    [[ -f "$source_xml" ]] || return 0
    python_bin="$(coverage_resolve_python_bin)" || return 1
    mkdir -p "$(dirname "$target_xml")"
    kano_python "$python_bin" - "$source_xml" "$target_xml" <<'PY'
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import PurePosixPath

source_xml, target_xml = sys.argv[1], sys.argv[2]
tree = ET.parse(source_xml)
root = tree.getroot()

sources = root.find("sources")
if sources is None:
    sources = ET.SubElement(root, "sources")
for child in list(sources):
    sources.remove(child)
ET.SubElement(sources, "source").text = "."

def normalize_filename(value: str) -> str:
    path = value.replace("\\", "/")
    lowered = path.lower()
    markers = ("/src/cpp/", "src/cpp/", "/work/src/cpp/")
    for marker in markers:
        index = lowered.find(marker)
        if index >= 0:
            path = "src/cpp/" + path[index + len(marker):].lstrip("/")
            break
    if path.startswith("code/"):
        path = f"src/cpp/{path}"
    if path.startswith("./"):
        path = path[2:]
    return str(PurePosixPath(path))

for class_node in root.findall(".//class"):
    filename = class_node.attrib.get("filename", "")
    if filename:
        class_node.set("filename", normalize_filename(filename))

tree.write(target_xml, encoding="utf-8", xml_declaration=True)
PY
}

coverage_render_fallback_cobertura_html() {
    local cobertura_xml="$1"
    local output_dir="$2"
    local cpp_root="$3"
    local python_bin

    python_bin="$(coverage_resolve_python_bin)" || return 1
    mkdir -p "$output_dir"
    kano_python "$python_bin" - "$cobertura_xml" "$output_dir" "$cpp_root" <<'PY'
import html
import pathlib
import sys
import xml.etree.ElementTree as ET

xml_path = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
cpp_root = pathlib.Path(sys.argv[3])

try:
    root = ET.parse(xml_path).getroot()
except Exception as exc:
    (out_dir / "index.html").write_text(
        "<!doctype html><html><head><meta charset='utf-8'><title>Coverage Report</title></head>"
        f"<body><h1>Coverage Report</h1><p>Failed to parse Cobertura XML: {html.escape(str(exc))}</p></body></html>",
        encoding="utf-8",
    )
    raise SystemExit(0)

lines_valid = int(root.attrib.get("lines-valid", "0") or "0")
lines_covered = int(root.attrib.get("lines-covered", "0") or "0")
branches_valid = int(root.attrib.get("branches-valid", "0") or "0")
branches_covered = int(root.attrib.get("branches-covered", "0") or "0")

def pct(done: int, total: int) -> str:
    return "n/a" if total <= 0 else f"{(done / total) * 100:.1f}%"

rows = []
for package in root.findall(".//package"):
    for cls in package.findall(".//class"):
        filename = cls.attrib.get("filename", "")
        class_lines = cls.findall(".//line")
        total = len(class_lines)
        covered = sum(1 for line in class_lines if int(line.attrib.get("hits", "0") or "0") > 0)
        rows.append((covered, total, filename))

rows.sort(key=lambda item: (item[1] == 0, item[0] / item[1] if item[1] else 0, item[2]))
row_html = "\n".join(
    "<tr>"
    f"<td>{html.escape(filename)}</td>"
    f"<td>{covered}</td>"
    f"<td>{total}</td>"
    f"<td>{html.escape(pct(covered, total))}</td>"
    "</tr>"
    for covered, total, filename in rows[:200]
)

if not row_html:
    row_html = "<tr><td colspan='4'>No class-level coverage entries were found.</td></tr>"

(out_dir / "index.html").write_text(f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Coverage Report</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem; color: #24292f; }}
    .summary {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 0.75rem; max-width: 960px; }}
    .metric {{ border: 1px solid #d0d7de; border-radius: 8px; padding: 0.8rem 1rem; background: #f6f8fa; }}
    .value {{ font-size: 1.5rem; font-weight: 650; }}
    table {{ border-collapse: collapse; width: 100%; margin-top: 1.5rem; }}
    th, td {{ border: 1px solid #d0d7de; padding: 0.45rem 0.6rem; text-align: left; }}
    th {{ background: #f6f8fa; }}
    code {{ background: #f6f8fa; padding: 0.1rem 0.3rem; border-radius: 4px; }}
  </style>
</head>
<body>
  <h1>Coverage Report</h1>
  <div class="summary">
    <div class="metric"><div>Line Coverage</div><div class="value">{html.escape(pct(lines_covered, lines_valid))}</div><div>{lines_covered} / {lines_valid}</div></div>
    <div class="metric"><div>Branch Coverage</div><div class="value">{html.escape(pct(branches_covered, branches_valid))}</div><div>{branches_covered} / {branches_valid}</div></div>
    <div class="metric"><div>Classes</div><div class="value">{len(rows)}</div><div>from Cobertura XML</div></div>
  </div>
  <p>Cobertura XML: <code>{html.escape(str(xml_path))}</code></p>
  <p>Source root: <code>{html.escape(str(cpp_root))}</code></p>
  <h2>Lowest Coverage Files</h2>
  <table>
    <thead><tr><th>File</th><th>Covered</th><th>Total</th><th>Coverage</th></tr></thead>
    <tbody>
{row_html}
    </tbody>
  </table>
</body>
</html>
""", encoding="utf-8")
PY
}

coverage_run_windows_opencppcoverage() {
    local preset="$1"
    local test_binary="$2"
    local cpp_root binary_path occ_bin source_root cobertura_xml
    local source_win binary_win cobertura_win log_file lines_valid

    cpp_root="${INF_CPP_ROOT:-$(pwd)/src/cpp}"
    binary_path="$(coverage_resolve_binary_path "$preset" "$test_binary" || true)"
    if [[ ! -f "$binary_path" ]]; then
        echo "[coverage_run_tests] ERROR: Binary not found: $binary_path" >&2
        return 1
    fi
    occ_bin="$(coverage_resolve_opencppcoverage)" || {
        echo "[coverage_run_tests] ERROR: OpenCppCoverage not found." >&2
        return 1
    }

    source_root="${KANO_COVERAGE_SOURCE_ROOT:-$cpp_root/code}"
    cobertura_xml="$INF_COVERAGE_ROOT/cobertura.xml"
    log_file="$INF_COVERAGE_ROOT/opencppcoverage.log"

    mkdir -p "$INF_COVERAGE_ROOT"
    rm -f "$cobertura_xml" "$log_file"

    source_win="$(coverage_to_windows_path "$source_root")"
    binary_win="$(coverage_to_windows_path "$binary_path")"
    cobertura_win="$(coverage_to_windows_path "$cobertura_xml")"

    echo "[coverage_run_tests] Windows OpenCppCoverage binary: $binary_path"
    echo "[coverage_run_tests] Windows OpenCppCoverage source root: $source_root"
    echo "[coverage_run_tests] Windows OpenCppCoverage XML: $cobertura_xml"

    MSYS2_ARG_CONV_EXCL='*' "$occ_bin" \
        --sources "$source_win" \
        --cover_children \
        --export_type "cobertura:$cobertura_win" \
        --quiet \
        -- "$binary_win" \
            --order lex --rng-seed 1337 --durations yes \
        >"$log_file" 2>&1

    coverage_normalize_cobertura_for_jenkins "$cobertura_xml" "$cobertura_xml"
    lines_valid="$(coverage_cobertura_lines_valid "$cobertura_xml")"
    if [[ "$lines_valid" -le 0 ]]; then
        echo "[coverage_run_tests] WARNING: OpenCppCoverage produced empty Cobertura XML. See $log_file" >&2
        coverage_write_status "UNAVAILABLE" "EMPTY_COBERTURA" "$cobertura_xml"
        return 0
    fi

    coverage_write_status "VALID" "COBERTURA_READY" "$cobertura_xml"
    echo "[coverage_run_tests] OpenCppCoverage Cobertura ready: $cobertura_xml (lines-valid=$lines_valid)"
}

coverage_render_cobertura_html() {
    local cobertura_xml="$1"
    local cpp_root="${INF_CPP_ROOT:-$(pwd)/src/cpp}"
    local lines_valid python_bin skill_root renderer

    if [[ ! -f "$cobertura_xml" ]]; then
        echo "[coverage_report] WARNING: Cobertura XML not found: $cobertura_xml" >&2
        coverage_write_status "UNAVAILABLE" "MISSING_COBERTURA" "$cobertura_xml"
        return 0
    fi

    lines_valid="$(coverage_cobertura_lines_valid "$cobertura_xml")"
    if [[ "$lines_valid" -le 0 ]]; then
        echo "[coverage_report] WARNING: Cobertura XML has no valid lines: $cobertura_xml" >&2
        coverage_write_status "UNAVAILABLE" "EMPTY_COBERTURA" "$cobertura_xml"
        return 0
    fi

    python_bin="$(coverage_resolve_python_bin)" || {
        echo "[coverage_report] ERROR: python is required to render Cobertura HTML." >&2
        coverage_write_status "TOOL_FAILED" "PYTHON_NOT_FOUND" "python"
        return 1
    }
    skill_root="$(report_skill_find_root "$(cd -- "$cpp_root/../.." >/dev/null 2>&1 && pwd)" 2>/dev/null || true)"
    renderer="$skill_root/src/shell/reports/common/render_coverage_report.py"

    mkdir -p "$INF_COVERAGE_HTML_DIR"
    if [[ -z "$skill_root" || ! -f "$renderer" ]]; then
        echo "[coverage_report] WARNING: kano-cpp-test-skill coverage renderer not found; writing fallback coverage HTML." >&2
        coverage_render_fallback_cobertura_html "$cobertura_xml" "$INF_COVERAGE_HTML_DIR" "$cpp_root"
        coverage_write_status "VALID" "HTML_READY_FALLBACK" "$INF_COVERAGE_HTML_DIR/index.html"
        echo "[coverage_report] Fallback Cobertura HTML report: $INF_COVERAGE_HTML_DIR/index.html"
        return 0
    fi

    kano_python "$python_bin" "$renderer" "$cobertura_xml" "$INF_COVERAGE_HTML_DIR" "$cpp_root"
    coverage_write_status "VALID" "HTML_READY" "$INF_COVERAGE_HTML_DIR/index.html"
    echo "[coverage_report] Cobertura HTML report: $INF_COVERAGE_HTML_DIR/index.html"
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
        if [[ "$target_platform" == "windows" && "$host_os" == "win64" ]]; then
            local windows_build_preset=""
            local windows_helper=""
            local cpp_root=""

            cpp_root="$(coverage_cpp_root)"
            windows_build_preset="${KANO_CPP_INFRA_COVERAGE_BUILD_PRESET:-$(kano_cpp_infra_matrix_default_coverage_build_preset)}"
            windows_helper="$SCRIPT_DIR/windows_preset_build.sh"
            if [[ ! -f "$windows_helper" ]]; then
                echo "[coverage_build] ERROR: Windows preset helper not found: $windows_helper" >&2
                return 1
            fi

            export INF_CPP_ROOT="$cpp_root"
            export KANO_CPP_INFRA_CPP_ROOT="$cpp_root"
            export KANO_CPP_ROOT="$cpp_root"
            # shellcheck disable=SC1090
            source "$windows_helper"
            kano_windows_run_preset "$preset" "$windows_build_preset" "${KANO_CPP_INFRA_VCVARS_ARCH:-x64}"
        else
            (
                local cpp_root=""
                cpp_root="$(coverage_cpp_root)"
                if [[ -n "$cpp_root" ]]; then
                    cd "$cpp_root"
                fi
                cmake --preset "$preset"
                cmake --build --preset "${preset}"
            )
        fi
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

    if coverage_is_windows_preset "$preset"; then
        coverage_run_windows_opencppcoverage "$preset" "$test_binary"
        return
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

    if coverage_is_windows_preset "$(coverage_default_configure_preset || true)"; then
        if [[ -f "$INF_COVERAGE_ROOT/cobertura.xml" ]]; then
            echo "[coverage_merge] Windows Cobertura coverage is already normalized: $INF_COVERAGE_ROOT/cobertura.xml"
            return 0
        fi
    fi

    if [[ "$compiler_id" == "Clang" ]]; then
        local llvm_profdata
        if ! llvm_profdata="$(coverage_resolve_llvm_profdata)"; then
            echo "[coverage_merge] ERROR: llvm-profdata not found. Install LLVM/Clang tools." >&2
            return 1
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

    if coverage_is_windows_preset "$preset"; then
        coverage_render_cobertura_html "$INF_COVERAGE_ROOT/cobertura.xml"
        return
    fi

    if [[ ! -f "$INF_COVERAGE_PROFDATA" ]]; then
        echo "[coverage_report] WARNING: Merged profile not found: $INF_COVERAGE_PROFDATA" >&2
        echo "[coverage_report] Run coverage_merge first." >&2
        coverage_write_status "UNAVAILABLE" "MISSING_MERGED_PROFILE" "$INF_COVERAGE_PROFDATA"
        return 0
    fi

    if [[ "$compiler_id" == "Clang" ]]; then
        local llvm_cov
        if ! llvm_cov="$(coverage_resolve_llvm_cov)"; then
            echo "[coverage_report] ERROR: llvm-cov not found." >&2
            coverage_write_status "TOOL_FAILED" "LLVM_COV_NOT_FOUND" "llvm-cov"
            return 1
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
