#!/usr/bin/env bash
set -euo pipefail

report_skill_default_repo_root() {
  local search_root git_root adapter_dir infra_mount_root consuming_root

  search_root="${KANO_CPP_INFRA_REPO_ROOT:-$PWD}"
  git_root="$(git -C "$search_root" rev-parse --show-toplevel 2>/dev/null || pwd)"

  adapter_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  infra_mount_root="$(cd -- "$adapter_dir/../.." >/dev/null 2>&1 && pwd)"
  if consuming_root="$(cd -- "$infra_mount_root/../../../.." >/dev/null 2>&1 && pwd)"; then
    if [[ "$infra_mount_root" == "$consuming_root/src/cpp/shared/infra" ]]; then
      printf '%s\n' "$consuming_root"
      return 0
    fi
  fi

  printf '%s\n' "$git_root"
}

report_skill_find_root() {
  local repo_root="${1:-}"
  local parent_root candidate
  local fallback_skill_root=""
  local home_root=""

  if [[ -z "$repo_root" ]]; then
    repo_root="$(report_skill_default_repo_root)"
  fi
  parent_root="$(cd -- "$repo_root/.." >/dev/null 2>&1 && pwd)"
  home_root="${KANO_HOME:-${HOME:-}}"
  if [[ -n "$home_root" ]]; then
    fallback_skill_root="$home_root/.agents/skills/kano/kano-cpp-test-skill"
  fi

  for candidate in \
    "${KANO_CPP_TEST_SKILL_ROOT:-}" \
    "${KANO_CPP_INFRA_TEST_SKILL_ROOT:-}" \
    "$repo_root/_tools/kano-cpp-test-skill" \
    "$parent_root/kano-cpp-test-skill" \
    "$fallback_skill_root"
  do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate/src/shell/reports/common/report-env.sh" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

report_skill_load() {
  local skill_root
  local repo_root

  repo_root="$(report_skill_default_repo_root)"

  export KANO_CPP_INFRA_REPO_ROOT="$repo_root"
  export KANO_CPP_INFRA_CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$repo_root/src/cpp}"
  export KANO_WORKSPACE_ROOT="$KANO_CPP_INFRA_REPO_ROOT"
  export KANO_CPP_INFRA_REPORT_ROOT="$(report_skill_resolve_repo_path "${KANO_CPP_INFRA_REPORT_ROOT:-.kano/tmp/reports}" "$repo_root")"
  export KANO_REPORT_ROOT="$(report_skill_resolve_repo_path "${KANO_REPORT_ROOT:-$KANO_CPP_INFRA_REPORT_ROOT}" "$repo_root")"

  if ! skill_root="$(report_skill_find_root "$repo_root")"; then
    echo "[ERROR] kano-cpp-test-skill not found." >&2
    echo "[ERROR] Set KANO_CPP_TEST_SKILL_ROOT or KANO_CPP_INFRA_TEST_SKILL_ROOT," >&2
    echo "[ERROR] or checkout the skill into _tools/kano-cpp-test-skill." >&2
    return 1
  fi

  export KANO_CPP_TEST_SKILL_ROOT="$skill_root"
}

report_skill_resolve_repo_path() {
  local raw_path="${1:-}"
  local repo_root="${2:-${KANO_CPP_INFRA_REPO_ROOT:-$PWD}}"
  local normalized
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
  printf '%s/%s\n' "${repo_root%/}" "$normalized"
}

report_skill_copy_file_if_present() {
  local source_path="${1:-}"
  local target_path="${2:-}"
  [[ -n "$source_path" && -n "$target_path" && -f "$source_path" ]] || return 0
  mkdir -p "$(dirname "$target_path")"
  cp -f "$source_path" "$target_path"
}

report_skill_copy_tree_if_present() {
  local source_dir="${1:-}"
  local target_dir="${2:-}"
  [[ -n "$source_dir" && -n "$target_dir" && -d "$source_dir" ]] || return 0
  rm -rf -- "$target_dir"
  mkdir -p "$target_dir"
  cp -a "$source_dir"/. "$target_dir"/
}

report_skill_same_path() {
  local left="${1:-}"
  local right="${2:-}"
  [[ -n "$left" && -n "$right" ]] || return 1
  [[ "$(cd -- "$left" 2>/dev/null && pwd -P)" == "$(cd -- "$right" 2>/dev/null && pwd -P)" ]]
}

report_skill_prepare_coverage_input() {
  local source_dir="${INF_COVERAGE_ROOT:-}"
  local target_dir="${KANO_COVERAGE_REPORT_DIR:-}"
  local report_slug="${KANO_REPORT_SLUG:-coverage}"
  local report_target_dir=""

  if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
    source_dir="$KANO_CPP_INFRA_CPP_ROOT/out/coverage"
  fi
  source_dir="$(report_skill_resolve_repo_path "$source_dir" "$KANO_CPP_INFRA_REPO_ROOT")"
  [[ -d "$source_dir" ]] || return 0

  if [[ -z "$target_dir" ]]; then
    target_dir="${KANO_COVERAGE_REPORTS_ROOT:-$KANO_REPORT_ROOT/coverage-reports}/$report_slug"
  fi
  target_dir="$(report_skill_resolve_repo_path "$target_dir" "$KANO_CPP_INFRA_REPO_ROOT")"
  if [[ -n "${KANO_REPORT_ROOT:-}" ]]; then
    report_target_dir="$(report_skill_resolve_repo_path "$KANO_REPORT_ROOT/coverage-reports/$report_slug" "$KANO_CPP_INFRA_REPO_ROOT")"
  fi

  mkdir -p "$target_dir"
  report_skill_copy_file_if_present "$source_dir/cobertura.xml" "$target_dir/cobertura.xml"
  report_skill_copy_file_if_present "$source_dir/coverage.xml" "$target_dir/coverage.xml"
  report_skill_copy_file_if_present "$source_dir/summary.txt" "$target_dir/summary.txt"
  report_skill_copy_file_if_present "$source_dir/coverage-status.json" "$target_dir/coverage-status.json"
  report_skill_copy_file_if_present "$source_dir/coverage-status.md" "$target_dir/coverage-status.md"
  report_skill_copy_file_if_present "$source_dir/opencppcoverage.log" "$target_dir/opencppcoverage.log"

  if [[ -d "$source_dir/html" ]]; then
    report_skill_copy_tree_if_present "$source_dir/html" "$target_dir/html"
    report_skill_copy_tree_if_present "$source_dir/html" "$target_dir/report-html"
  fi
  if [[ -d "$source_dir/report-html" ]]; then
    report_skill_copy_tree_if_present "$source_dir/report-html" "$target_dir/report-html"
  fi
  if [[ -d "$source_dir/native-html" ]]; then
    report_skill_copy_tree_if_present "$source_dir/native-html" "$target_dir/native-html"
  fi
  if [[ -d "$source_dir/html-cobertura" ]]; then
    report_skill_copy_tree_if_present "$source_dir/html-cobertura" "$target_dir/html-cobertura"
  fi

  if [[ -n "$report_target_dir" ]]; then
    mkdir -p "$report_target_dir"
    if ! report_skill_same_path "$target_dir" "$report_target_dir"; then
      report_skill_copy_tree_if_present "$target_dir" "$report_target_dir"
    fi
    target_dir="$report_target_dir"
  fi

  export KANO_COVERAGE_REPORT_DIR="$target_dir"
  export KANO_COVERAGE_XML="${KANO_COVERAGE_XML:-$target_dir/cobertura.xml}"
  export KANO_COVERAGE_SUMMARY="${KANO_COVERAGE_SUMMARY:-$target_dir/summary.txt}"
  export KANO_COVERAGE_PROVIDER_HTML_DIR="${KANO_COVERAGE_PROVIDER_HTML_DIR:-$target_dir/native-html}"
  export KANO_COVERAGE_COBERTURA_HTML_DIR="${KANO_COVERAGE_COBERTURA_HTML_DIR:-$target_dir/html-cobertura}"
  if [[ -f "$target_dir/report-html/index.html" ]]; then
    export KANO_COVERAGE_HTML_DIR="${KANO_COVERAGE_HTML_DIR:-$target_dir/report-html}"
  elif [[ -f "$target_dir/html/index.html" ]]; then
    export KANO_COVERAGE_HTML_DIR="${KANO_COVERAGE_HTML_DIR:-$target_dir/html}"
  else
    export KANO_COVERAGE_HTML_DIR="${KANO_COVERAGE_HTML_DIR:-$target_dir/report-html}"
  fi
}

report_skill_package() {
  if [[ -z "${KANO_CPP_TEST_SKILL_ROOT:-}" ]]; then
    echo "[ERROR] report_skill_load must be called before report_skill_package" >&2
    return 1
  fi
  : "${KANO_REPORT_SLUG:=package-all}"
  export KANO_REPORT_SLUG

  : "${KANO_TEST_LANE:=gather}"
  export KANO_TEST_LANE
  : "${KANO_REPORT_COMMAND:=pixi run gather-reports}"
  export KANO_REPORT_COMMAND

  local suite_map_src="$KANO_CPP_INFRA_CPP_ROOT/shared/infra/config/suite-map.kano-git-master.json"
  if [[ -f "$suite_map_src" && -n "${KANO_REPORT_ROOT:-}" ]]; then
    mkdir -p "$KANO_REPORT_ROOT/raw"
    cp -f "$suite_map_src" "$KANO_REPORT_ROOT/raw/suite-map.kano-git-master.json"
    export KANO_TEST_SUITE_MAP_REL="raw/suite-map.kano-git-master.json"
  fi

  report_skill_prepare_coverage_input

  bash "$KANO_CPP_TEST_SKILL_ROOT/src/shell/reports/common/package-reports.sh" "$@"
}
