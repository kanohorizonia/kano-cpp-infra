#!/usr/bin/env bash
set -euo pipefail

KANO_CPP_LINUX_CI_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KANO_CPP_LINUX_CI_SCRIPTS_DIR="$(cd -- "$KANO_CPP_LINUX_CI_LIB_DIR/.." && pwd)"
KANO_CPP_LINUX_CI_INFRA_DIR="$(cd -- "$KANO_CPP_LINUX_CI_SCRIPTS_DIR/.." && pwd)"
KANO_CPP_LINUX_CI_CPP_ROOT="$(cd -- "$KANO_CPP_LINUX_CI_INFRA_DIR/../.." && pwd)"
KANO_CPP_LINUX_CI_REPO_ROOT="$(cd -- "$KANO_CPP_LINUX_CI_CPP_ROOT/../.." && pwd)"
KANO_CPP_LINUX_CI_SUITE_MAP="$KANO_CPP_LINUX_CI_INFRA_DIR/config/suite-map.kano-git-master.json"

export KANO_CPP_INFRA_REPO_ROOT="${KANO_CPP_INFRA_REPO_ROOT:-$KANO_CPP_LINUX_CI_REPO_ROOT}"
export KANO_CPP_INFRA_CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$KANO_CPP_LINUX_CI_CPP_ROOT}"
export KANO_CPP_ROOT="${KANO_CPP_ROOT:-$KANO_CPP_LINUX_CI_CPP_ROOT}"

# shellcheck disable=SC1091
source "$KANO_CPP_LINUX_CI_LIB_DIR/docker_host.sh"

kano_cpp_linux_ci_host_os() {
  uname -s 2>/dev/null || echo "unknown"
}

kano_cpp_linux_ci_is_linux_host() {
  [[ "$(kano_cpp_linux_ci_host_os)" == "Linux" ]]
}

kano_cpp_linux_ci_release_configure_preset() {
  printf '%s\n' "${KANO_CPP_LINUX_RELEASE_CONFIGURE_PRESET:-linux-ninja-gcc}"
}

kano_cpp_linux_ci_release_build_preset() {
  printf '%s\n' "${KANO_CPP_LINUX_RELEASE_BUILD_PRESET:-linux-ninja-gcc-release}"
}

kano_cpp_linux_ci_fetchcontent_deps_root() {
  local release_configure_preset=""
  release_configure_preset="$(kano_cpp_linux_ci_release_configure_preset)"
  printf '%s\n' "${KANO_CPP_LINUX_FETCHCONTENT_DEPS_ROOT:-$KANO_CPP_LINUX_CI_CPP_ROOT/out/obj/$release_configure_preset/_deps}"
}

kano_cpp_linux_ci_collect_fetchcontent_source_args() {
  local -n out_ref="$1"
  local deps_root=""
  local entry=""
  local key=""
  local source_dir=""

  deps_root="$(kano_cpp_linux_ci_fetchcontent_deps_root)"
  [[ -d "$deps_root" ]] || return 0

  for entry in \
    "NLOHMANN_JSON:nlohmann_json-src" \
    "CLI11:cli11-src" \
    "FTXUI:ftxui-src" \
    "TOMLPLUSPLUS:tomlplusplus-src" \
    "CATCH2:catch2-src" \
    "RAPIDCHECK:rapidcheck-src"
  do
    key="${entry%%:*}"
    source_dir="$deps_root/${entry#*:}"
    if [[ -d "$source_dir" ]]; then
      echo "[linux-ci] reusing FetchContent source $key from $source_dir"
      out_ref+=("-DFETCHCONTENT_SOURCE_DIR_${key}=$source_dir")
    fi
  done
}

kano_cpp_linux_ci_coverage_configure_preset() {
  printf '%s\n' "${KANO_CPP_LINUX_COVERAGE_CONFIGURE_PRESET:-linux-ninja-clang-coverage}"
}

kano_cpp_linux_ci_coverage_build_preset() {
  printf '%s\n' "${KANO_CPP_LINUX_COVERAGE_BUILD_PRESET:-linux-ninja-clang-coverage-debug}"
}

kano_cpp_linux_ci_default_docker_image() {
  printf '%s\n' "${KANO_CPP_LINUX_DOCKER_IMAGE:-ubuntu:25.10}"
}

kano_cpp_linux_ci_container_revision() {
  printf '%s\n' "${KANO_CPP_LINUX_CI_CONTAINER_REV:-1}"
}

kano_cpp_linux_ci_require_docker() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  echo "docker is required to run Linux CI tasks on non-Linux hosts." >&2
  return 1
}

kano_cpp_linux_ci_forward_env_args() {
  local -n out_ref="$1"
  local name

  for name in \
    KANO_REPORT_ROOT \
    KANO_TEST_REPORTS_ROOT \
    KANO_COVERAGE_REPORTS_ROOT \
    KANO_REPORT_SLUG \
    KANO_TEST_LANE \
    KANO_TEST_XML \
    KANO_COVERAGE_XML \
    KANO_COVERAGE_HTML_DIR \
    KANO_COVERAGE_SUMMARY \
    KANO_BDD_METADATA_DIR \
    KANO_CPP_INFRA_PGO_GATHER_QUICK \
    KANO_CPP_INFRA_PGO_GATHER_QUICK_SUITE \
    KANO_CPP_INFRA_PGO_DEBUG \
    KANO_CPP_INFRA_COVERAGE_TOOL \
    KANO_CPP_INFRA_PGO_COLLECT_CONFIGURE_PRESET \
    KANO_CPP_INFRA_PGO_COLLECT_BUILD_PRESET \
    KANO_CPP_INFRA_PGO_COLLECT_BUILD_TARGETS \
    KANO_CPP_INFRA_PGO_USE_CONFIGURE_PRESET \
    KANO_CPP_INFRA_PGO_USE_BUILD_PRESET \
    KANO_CPP_INFRA_PGO_TEST_PRESET
  do
    if [[ -n "${!name+x}" ]]; then
      out_ref+=(-e "$name=${!name}")
    fi
  done
}

kano_cpp_linux_ci_hash_text() {
  local input="${1:-}"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | awk '{print substr($1, 1, 12)}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
    return 0
  fi
  python3 - "$input" <<'PY'
from __future__ import annotations

import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:12])
PY
}

kano_cpp_linux_ci_container_key_root() {
  local canonical_root=""

  if canonical_root="$(kano_cpp_docker_host_path_for_cli "$KANO_CPP_LINUX_CI_REPO_ROOT" 2>/dev/null)"; then
    :
  else
    canonical_root="$(cd -- "$KANO_CPP_LINUX_CI_REPO_ROOT" >/dev/null 2>&1 && pwd -P)"
  fi

  canonical_root="${canonical_root//\\//}"
  canonical_root="${canonical_root%/}"
  if kano_cpp_docker_is_windows_shell; then
    canonical_root="$(printf '%s' "$canonical_root" | tr '[:upper:]' '[:lower:]')"
  fi

  printf '%s\n' "$canonical_root"
}

kano_cpp_linux_ci_container_name() {
  local image="${1:?image is required}"
  local key=""

  key="$(kano_cpp_linux_ci_hash_text "$(kano_cpp_linux_ci_container_key_root)|${image}|$(kano_cpp_linux_ci_container_revision)")"
  printf '%s\n' "kano-cpp-linux-ci-${key}"
}

kano_cpp_linux_ci_container_exists() {
  local container_name="${1:?container name is required}"
  kano_cpp_docker_run inspect "$container_name" >/dev/null 2>&1
}

kano_cpp_linux_ci_container_running() {
  local container_name="${1:?container name is required}"
  [[ "$(kano_cpp_docker_run inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)" == "true" ]]
}

kano_cpp_linux_ci_ensure_container() {
  local container_name="${1:?container name is required}"
  local image="${2:?image is required}"
  local mount_arg="${3:?mount argument is required}"

  if kano_cpp_linux_ci_container_exists "$container_name"; then
    return 0
  fi

  echo "[linux-ci-docker] creating reusable container: $container_name"
  kano_cpp_docker_run create \
    --name "$container_name" \
    --security-opt seccomp=unconfined \
    -v "$mount_arg" \
    -w /work \
    "$image" \
    sleep infinity >/dev/null
}

kano_cpp_linux_ci_start_container() {
  local container_name="${1:?container name is required}"
  if kano_cpp_linux_ci_container_running "$container_name"; then
    return 0
  fi
  echo "[linux-ci-docker] starting reusable container: $container_name"
  kano_cpp_docker_run start "$container_name" >/dev/null
}

kano_cpp_linux_ci_stop_container() {
  local container_name="${1:?container name is required}"
  if ! kano_cpp_linux_ci_container_running "$container_name"; then
    return 0
  fi
  kano_cpp_docker_run stop -t 1 "$container_name" >/dev/null
}

kano_cpp_linux_ci_exec_via_docker() {
  local repo_relative_script="${1:?repo-relative script path is required}"
  shift

  local mount_arg=""
  local image=""
  local container_name=""
  local -a env_args=()

  kano_cpp_linux_ci_require_docker || return 1
  mount_arg="$(kano_cpp_docker_volume_arg "$KANO_CPP_LINUX_CI_REPO_ROOT" /work)" || return 1
  image="$(kano_cpp_linux_ci_default_docker_image)"
  container_name="$(kano_cpp_linux_ci_container_name "$image")"
  kano_cpp_linux_ci_forward_env_args env_args

  kano_cpp_linux_ci_ensure_container "$container_name" "$image" "$mount_arg" || return 1
  kano_cpp_linux_ci_start_container "$container_name" || return 1
  trap 'kano_cpp_linux_ci_stop_container "$container_name" >/dev/null 2>&1 || true' RETURN

  kano_cpp_docker_run exec \
    "${env_args[@]}" \
    -e KANO_CPP_LINUX_CI_IN_DOCKER=1 \
    -w /work \
    "$container_name" \
    bash -lc '
set -euo pipefail
need_install=0
for tool in bash cmake ninja git python3; do
  command -v "$tool" >/dev/null 2>&1 || need_install=1
done
if (( need_install )); then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    cmake \
    ninja-build \
    gcc-15 \
    g++-15 \
    clang \
    lld \
    llvm \
    python3 \
    git
fi
exec bash "$1" "${@:2}"
' _ "/work/$repo_relative_script" "$@"
}

kano_cpp_linux_ci_python() {
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    command -v python
    return 0
  fi
  echo "python3 or python is required." >&2
  return 1
}

kano_cpp_linux_ci_resolve_path() {
  local raw_path="${1:-}"
  local normalized=""

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
  printf '%s/%s\n' "${KANO_CPP_LINUX_CI_REPO_ROOT%/}" "$normalized"
}

kano_cpp_linux_ci_init_report_contract() {
  : "${KANO_REPORT_SLUG:=linux-ci}"

  export KANO_REPORT_ROOT="$(kano_cpp_linux_ci_resolve_path "${KANO_REPORT_ROOT:-out/jenkins}")"
  export KANO_TEST_REPORTS_ROOT="$(kano_cpp_linux_ci_resolve_path "${KANO_TEST_REPORTS_ROOT:-$KANO_REPORT_ROOT/test-reports}")"
  export KANO_COVERAGE_REPORTS_ROOT="$(kano_cpp_linux_ci_resolve_path "${KANO_COVERAGE_REPORTS_ROOT:-$KANO_REPORT_ROOT/coverage-reports}")"
  export KANO_TEST_REPORT_DIR="$(kano_cpp_linux_ci_resolve_path "${KANO_TEST_REPORT_DIR:-$KANO_TEST_REPORTS_ROOT/$KANO_REPORT_SLUG}")"
  export KANO_COVERAGE_REPORT_DIR="$(kano_cpp_linux_ci_resolve_path "${KANO_COVERAGE_REPORT_DIR:-$KANO_COVERAGE_REPORTS_ROOT/$KANO_REPORT_SLUG}")"
  export KANO_TEST_XML="$(kano_cpp_linux_ci_resolve_path "${KANO_TEST_XML:-$KANO_TEST_REPORT_DIR/tests.xml}")"
  export KANO_COVERAGE_XML="$(kano_cpp_linux_ci_resolve_path "${KANO_COVERAGE_XML:-$KANO_COVERAGE_REPORT_DIR/cobertura.xml}")"
  export KANO_COVERAGE_HTML_DIR="$(kano_cpp_linux_ci_resolve_path "${KANO_COVERAGE_HTML_DIR:-$KANO_COVERAGE_REPORT_DIR/report-html}")"
  export KANO_COVERAGE_SUMMARY="$(kano_cpp_linux_ci_resolve_path "${KANO_COVERAGE_SUMMARY:-$KANO_COVERAGE_REPORT_DIR/summary.txt}")"
  export KANO_BDD_METADATA_DIR="$(kano_cpp_linux_ci_resolve_path "${KANO_BDD_METADATA_DIR:-$KANO_REPORT_ROOT/raw/bdd-metadata}")"
}

kano_cpp_linux_ci_copy_suite_map() {
  [[ -f "$KANO_CPP_LINUX_CI_SUITE_MAP" ]] || return 0
  mkdir -p "$KANO_REPORT_ROOT/raw"
  cp -f "$KANO_CPP_LINUX_CI_SUITE_MAP" "$KANO_REPORT_ROOT/raw/suite-map.kano-git-master.json"
}

kano_cpp_linux_ci_prepare_test_report_dirs() {
  kano_cpp_linux_ci_init_report_contract
  rm -rf -- "$KANO_TEST_REPORT_DIR" "$KANO_BDD_METADATA_DIR"
  mkdir -p "$KANO_TEST_REPORT_DIR" "$KANO_BDD_METADATA_DIR" "$KANO_REPORT_ROOT/raw"
  kano_cpp_linux_ci_copy_suite_map
}

kano_cpp_linux_ci_prepare_coverage_report_dirs() {
  kano_cpp_linux_ci_init_report_contract
  rm -rf -- "$KANO_TEST_REPORT_DIR" "$KANO_COVERAGE_REPORT_DIR" "$KANO_BDD_METADATA_DIR"
  mkdir -p "$KANO_TEST_REPORT_DIR" "$KANO_COVERAGE_REPORT_DIR" "$KANO_BDD_METADATA_DIR" "$KANO_REPORT_ROOT/raw"
  kano_cpp_linux_ci_copy_suite_map
}

kano_cpp_linux_ci_resolve_bin_dir() {
  local cpp_dir="${1:?cpp_dir is required}"
  local preset_name="${2:?preset_name is required}"
  local canonical=""

  if [[ -d "$cpp_dir/out/bin/$preset_name" ]]; then
    printf '%s\n' "$cpp_dir/out/bin/$preset_name"
    return 0
  fi

  canonical="$(printf '%s' "$preset_name" | sed -E 's/-(debug|release|relwithdebinfo|minsizerel)$//')"
  if [[ -d "$cpp_dir/out/bin/$canonical" ]]; then
    printf '%s\n' "$cpp_dir/out/bin/$canonical"
    return 0
  fi

  return 1
}

kano_cpp_linux_ci_run_release_build() {
  local configure_preset build_preset
  configure_preset="$(kano_cpp_linux_ci_release_configure_preset)"
  build_preset="$(kano_cpp_linux_ci_release_build_preset)"

  (
    cd "$KANO_CPP_LINUX_CI_CPP_ROOT"
    cmake --preset "$configure_preset"
    cmake --build --preset "$build_preset"
  )
}

kano_cpp_linux_ci_run_coverage_build() {
  local configure_preset build_preset
  local -a fetchcontent_source_args=()
  configure_preset="$(kano_cpp_linux_ci_coverage_configure_preset)"
  build_preset="$(kano_cpp_linux_ci_coverage_build_preset)"
  kano_cpp_linux_ci_collect_fetchcontent_source_args fetchcontent_source_args

  (
    cd "$KANO_CPP_LINUX_CI_CPP_ROOT"
    cmake --preset "$configure_preset" "${fetchcontent_source_args[@]}"
    cmake --build --preset "$build_preset"
  )
}

kano_cpp_linux_ci_run_test_lane() {
  local preset_name="${1:?preset is required}"
  local lane_name="${2:?lane is required}"
  local xml_output="${3:-}"

  (
    cd "$KANO_CPP_LINUX_CI_CPP_ROOT"
    if [[ -n "$xml_output" ]]; then
      KANO_SKIP_TEST_BUILD=1 KANO_TEST_XML="$xml_output" \
        bash "$KANO_CPP_LINUX_CI_CPP_ROOT/code/tests/run_tests.sh" "$preset_name" "$lane_name"
    else
      KANO_SKIP_TEST_BUILD=1 \
        bash "$KANO_CPP_LINUX_CI_CPP_ROOT/code/tests/run_tests.sh" "$preset_name" "$lane_name"
    fi
  )
}

kano_cpp_linux_ci_generate_bdd_metadata() {
  local junit_xml="${1:?junit xml is required}"
  local metadata_dir="${2:?metadata dir is required}"
  local suite_name="${3:-kano_git_cli_tests}"
  local python_cmd=""

  [[ -f "$junit_xml" ]] || return 0

  python_cmd="$(kano_cpp_linux_ci_python)" || return 1
  mkdir -p "$metadata_dir"
  "$python_cmd" "$KANO_CPP_LINUX_CI_INFRA_DIR/scripts/tools/generate-bdd-metadata-from-junit.py" \
    "$junit_xml" \
    "$metadata_dir" \
    "$suite_name"
}

kano_cpp_linux_ci_merge_junit_dir() {
  local input_dir="${1:?input dir is required}"
  local output_xml="${2:?output xml is required}"
  local python_cmd=""

  python_cmd="$(kano_cpp_linux_ci_python)" || return 1
  mkdir -p "$(dirname "$output_xml")"
  "$python_cmd" - "$input_dir" "$output_xml" <<'PY'
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

in_dir = Path(sys.argv[1])
out_path = Path(sys.argv[2])
root = ET.Element("testsuites")
for xml_path in sorted(in_dir.glob("*.xml")):
    try:
        doc = ET.parse(xml_path).getroot()
    except ET.ParseError:
        continue
    if doc.tag == "testsuite":
        root.append(doc)
    elif doc.tag == "testsuites":
        for suite in doc.findall("testsuite"):
            root.append(suite)

out_path.parent.mkdir(parents=True, exist_ok=True)
ET.ElementTree(root).write(out_path, encoding="utf-8", xml_declaration=True)
PY
}

kano_cpp_linux_ci_write_gather_summary_junit() {
  local reports_root="${1:?reports root is required}"
  local input_dir="${2:?input dir is required}"
  local output_xml="${3:?output xml is required}"
  local python_cmd=""

  python_cmd="$(kano_cpp_linux_ci_python)" || return 1
  mkdir -p "$(dirname "$output_xml")"
  "$python_cmd" - "$reports_root" "$input_dir" "$output_xml" <<'PY'
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

reports_root = Path(sys.argv[1])
input_dir = Path(sys.argv[2])
out_path = Path(sys.argv[3])

raw_suites = 0
raw_tests = 0
raw_failures = 0
raw_errors = 0
raw_skipped = 0
raw_files = 0

for xml_path in sorted(input_dir.glob("*.xml")):
    try:
        doc = ET.parse(xml_path).getroot()
    except ET.ParseError:
        continue
    raw_files += 1
    suites = []
    if doc.tag == "testsuite":
        suites = [doc]
    elif doc.tag == "testsuites":
        suites = list(doc.findall("testsuite"))
    for suite in suites:
        raw_suites += 1
        raw_tests += int(suite.attrib.get("tests", "0") or "0")
        raw_failures += int(suite.attrib.get("failures", "0") or "0")
        raw_errors += int(suite.attrib.get("errors", "0") or "0")
        raw_skipped += int(suite.attrib.get("skipped", "0") or "0")

root = ET.Element("testsuites")
suite = ET.SubElement(
    root,
    "testsuite",
    {
        "name": "linux_coverage_gather",
        "tests": "1",
        "failures": "0",
        "errors": "0",
        "skipped": "0",
        "time": "0",
    },
)
ET.SubElement(
    suite,
    "testcase",
    {
        "classname": "linux_coverage_gather",
        "name": "coverage-gather-succeeded",
        "time": "0",
    },
)
ET.SubElement(suite, "system-out").text = (
    "pgo-gather completed successfully. "
    f"rawFiles={raw_files} rawSuites={raw_suites} rawTests={raw_tests} "
    f"rawFailures={raw_failures} rawErrors={raw_errors} rawSkipped={raw_skipped} "
    f"rawReports={reports_root / 'junit'}"
)

out_path.parent.mkdir(parents=True, exist_ok=True)
ET.ElementTree(root).write(out_path, encoding="utf-8", xml_declaration=True)
PY
}

kano_cpp_linux_ci_pick_coverage_xml() {
  local raw_dir="${1:?raw dir is required}"
  local fallback=""

  if [[ -f "$raw_dir/coverage.cobertura.xml" ]]; then
    printf '%s\n' "$raw_dir/coverage.cobertura.xml"
    return 0
  fi

  fallback="$(find "$raw_dir" -maxdepth 1 -type f \( -name '*.cobertura.xml' -o -name 'cobertura.xml' -o -name 'coverage.xml' \) | sort | head -n 1 || true)"
  if [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  return 1
}

kano_cpp_linux_ci_copy_tree() {
  local source_dir="${1:?source dir is required}"
  local target_dir="${2:?target dir is required}"

  rm -rf -- "$target_dir"
  mkdir -p "$(dirname "$target_dir")"
  cp -a "$source_dir" "$target_dir"
}

kano_cpp_linux_ci_write_coverage_summary() {
  local raw_dir="${1:?raw dir is required}"
  local summary_file="${2:?summary file is required}"
  local profdata=""
  local bin_root=""
  local primary=""
  local candidate=""
  local -a args=()

  profdata="$raw_dir/merged.profdata"
  [[ -f "$profdata" ]] || return 0
  command -v llvm-cov >/dev/null 2>&1 || return 0

  bin_root="$KANO_CPP_LINUX_CI_CPP_ROOT/out/bin/$(kano_cpp_linux_ci_coverage_configure_preset)/debug"
  for candidate in \
    "$bin_root/kano_git_cli_tests" \
    "$bin_root/kano_git_tui_tests" \
    "$bin_root/kano_git_commit_plan_tests" \
    "$bin_root/kano_git_export_tests"
  do
    if [[ -f "$candidate" ]]; then
      primary="$candidate"
      break
    fi
  done

  [[ -n "$primary" ]] || return 0

  args=("$primary" "-instr-profile=$profdata")
  for candidate in \
    "$bin_root/kano_git_commit_plan_tests" \
    "$bin_root/kano_git_export_tests" \
    "$bin_root/kano_git_tui_tests"
  do
    if [[ -f "$candidate" && "$candidate" != "$primary" ]]; then
      args+=("--object=$candidate")
    fi
  done

  mkdir -p "$(dirname "$summary_file")"
  llvm-cov report "${args[@]}" > "$summary_file" || true
}

kano_cpp_linux_ci_run_coverage_gather() {
  (
    cd "$KANO_CPP_LINUX_CI_CPP_ROOT"
    KANO_CPP_INFRA_COVERAGE_TOOL="${KANO_CPP_INFRA_COVERAGE_TOOL:-llvm}" \
      KANO_CPP_INFRA_PGO_GATHER_MODE=coverage \
      bash "$KANO_CPP_LINUX_CI_INFRA_DIR/scripts/stages/pgo-gather.sh"
  )
}

kano_cpp_linux_ci_canonicalize_gather_reports() {
  local reports_root="${1:?reports root is required}"
  local junit_dir="$reports_root/junit"
  local raw_coverage_dir="$reports_root/coverage/raw"
  local html_dir="$reports_root/coverage/html"
  local raw_junit_dir="$KANO_REPORT_ROOT/raw/pgo-gather-junit"
  local coverage_xml=""

  kano_cpp_linux_ci_prepare_coverage_report_dirs
  if [[ -d "$junit_dir" ]]; then
    rm -rf -- "$raw_junit_dir"
    mkdir -p "$raw_junit_dir"
    cp -a "$junit_dir/." "$raw_junit_dir/"
  fi
  kano_cpp_linux_ci_write_gather_summary_junit "$reports_root" "$junit_dir" "$KANO_TEST_XML"
  kano_cpp_linux_ci_generate_bdd_metadata "$KANO_TEST_XML" "$KANO_BDD_METADATA_DIR" "linux_coverage_gather"

  coverage_xml="$(kano_cpp_linux_ci_pick_coverage_xml "$raw_coverage_dir" || true)"
  if [[ -n "$coverage_xml" ]]; then
    mkdir -p "$(dirname "$KANO_COVERAGE_XML")"
    cp -f "$coverage_xml" "$KANO_COVERAGE_XML"
  fi
  if [[ -d "$html_dir" ]]; then
    kano_cpp_linux_ci_copy_tree "$html_dir" "$KANO_COVERAGE_HTML_DIR"
  fi
  kano_cpp_linux_ci_write_coverage_summary "$raw_coverage_dir" "$KANO_COVERAGE_SUMMARY"
}

kano_cpp_linux_ci_require_release_binary() {
  local bin_dir=""
  local binary_path=""

  bin_dir="$(kano_cpp_linux_ci_resolve_bin_dir "$KANO_CPP_LINUX_CI_CPP_ROOT" "$(kano_cpp_linux_ci_release_build_preset)")" || {
    echo "Unable to resolve Linux release binary directory." >&2
    return 1
  }
  binary_path="$bin_dir/release/kano-git"
  if [[ ! -f "$binary_path" ]]; then
    echo "Missing Linux release binary: $binary_path" >&2
    return 1
  fi
  chmod u+x "$binary_path" >/dev/null 2>&1 || true
  printf '%s\n' "$binary_path"
}

kano_cpp_linux_ci_export_has_output_arg() {
  local arg=""
  for arg in "$@"; do
    if [[ "$arg" == "--output" || "$arg" == --output=* ]]; then
      return 0
    fi
  done
  return 1
}

kano_cpp_linux_ci_export_output_dir() {
  printf '%s\n' "$KANO_CPP_LINUX_CI_REPO_ROOT/.kano/tmp/git/export"
}

kano_cpp_linux_ci_sync_export_output() {
  local staged_output_dir="${1:?staged output dir is required}"
  local target_output_dir="${2:?target output dir is required}"

  mkdir -p "$target_output_dir"
  if [[ -d "$staged_output_dir" ]]; then
    cp -a "$staged_output_dir/." "$target_output_dir/"
  fi
}

kano_cpp_linux_ci_rewrite_export_manifests() {
  local staged_output_dir="${1:?staged output dir is required}"
  local target_output_dir="${2:?target output dir is required}"
  local repo_tmp_dir="${KANO_CPP_LINUX_CI_REPO_ROOT}/.kano/tmp"

  python3 - "$staged_output_dir" "$target_output_dir" "$repo_tmp_dir" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

staged_output = Path(sys.argv[1])
target_output = Path(sys.argv[2])
repo_tmp = Path(sys.argv[3])

if not repo_tmp.exists():
    raise SystemExit(0)

manifest_names = {p.name for p in staged_output.glob("*.export-manifest.json")}
if not manifest_names:
    raise SystemExit(0)

for manifest_name in manifest_names:
    candidates = [
        target_output / manifest_name,
        repo_tmp / manifest_name,
    ]
    for manifest_path in candidates:
        if not manifest_path.is_file():
            continue
        try:
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        archive_file = data.get("archiveFile")
        if not isinstance(archive_file, str):
            continue
        archive_name = Path(archive_file).name
        rewritten_archive = (target_output / archive_name).as_posix()
        data["archiveFile"] = rewritten_archive
        if isinstance(data.get("path"), str):
            data["path"] = rewritten_archive
        archives = data.get("archives")
        if isinstance(archives, list):
            for archive_entry in archives:
                if not isinstance(archive_entry, dict):
                    continue
                entry_source = archive_entry.get("archiveFile") or archive_entry.get("path")
                if not isinstance(entry_source, str):
                    continue
                entry_name = Path(entry_source).name
                rewritten_entry = (target_output / entry_name).as_posix()
                archive_entry["archiveFile"] = rewritten_entry
                archive_entry["path"] = rewritten_entry
        manifest_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

kano_cpp_linux_ci_run_export() {
  local binary_path=""
  local -a args=("$@")
  local stage_output_dir=""
  local target_output_dir=""
  local exit_code=0

  binary_path="$(kano_cpp_linux_ci_require_release_binary)" || return 1
  if [[ ${#args[@]} -eq 0 ]]; then
    args=(export --single --validate-release-archive)
  fi

  # Docker-hosted Linux exports validate badly from large Windows bind mounts.
  # Stage the archive in container-local tmp storage, then sync artifacts back.
  if [[ "${KANO_CPP_LINUX_CI_IN_DOCKER:-0}" == "1" ]] && ! kano_cpp_linux_ci_export_has_output_arg "${args[@]}"; then
    target_output_dir="$(kano_cpp_linux_ci_export_output_dir)"
    stage_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/kano-cpp-linux-export.XXXXXX")" || return 1
    args+=(--output "$stage_output_dir")
    echo "[linux-ci-docker] staging export in container tmp dir: $stage_output_dir"
  fi

  set +e
  (
    cd "$KANO_CPP_LINUX_CI_REPO_ROOT"
    KANO_GIT_MASTER_ROOT="$KANO_CPP_LINUX_CI_REPO_ROOT" "$binary_path" "${args[@]}"
  )
  exit_code=$?
  set -e

  if [[ -n "$stage_output_dir" ]]; then
    echo "[linux-ci-docker] syncing staged export artifacts -> $target_output_dir"
    if ! kano_cpp_linux_ci_sync_export_output "$stage_output_dir" "$target_output_dir"; then
      echo "Failed to sync staged export artifacts back to workspace." >&2
      [[ $exit_code -eq 0 ]] && exit_code=1
    else
      kano_cpp_linux_ci_rewrite_export_manifests "$stage_output_dir" "$target_output_dir" || {
        echo "Failed to rewrite staged export manifests for workspace paths." >&2
        [[ $exit_code -eq 0 ]] && exit_code=1
      }
    fi
    rm -rf "$stage_output_dir"
  fi

  return "$exit_code"
}

kano_cpp_linux_ci_run_validate() {
  local binary_path=""
  local -a args=("$@")

  binary_path="$(kano_cpp_linux_ci_require_release_binary)" || return 1
  if [[ ${#args[@]} -eq 0 ]]; then
    args=(repo-hygiene check --archive-safe)
  fi

  (
    cd "$KANO_CPP_LINUX_CI_REPO_ROOT"
    KANO_GIT_MASTER_ROOT="$KANO_CPP_LINUX_CI_REPO_ROOT" "$binary_path" "${args[@]}"
  )
}
