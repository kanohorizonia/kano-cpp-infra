#!/usr/bin/env bash
set -euo pipefail

report_skill_find_root() {
  local repo_root="${1:-}"
  local parent_root candidate

  if [[ -z "$repo_root" ]]; then
    repo_root="$(git -C "${KANO_CPP_INFRA_REPO_ROOT:-$PWD}" rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
  parent_root="$(cd -- "$repo_root/.." >/dev/null 2>&1 && pwd)"

  for candidate in \
    "${KANO_CPP_TEST_SKILL_ROOT:-}" \
    "${KANO_CPP_INFRA_TEST_SKILL_ROOT:-}" \
    "$repo_root/_tools/kano-cpp-test-skill" \
    "$parent_root/kano-cpp-test-skill"
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

  repo_root="$(git -C "${KANO_CPP_INFRA_REPO_ROOT:-$PWD}" rev-parse --show-toplevel 2>/dev/null || pwd)"

  export KANO_CPP_INFRA_REPO_ROOT="$repo_root"
  export KANO_CPP_INFRA_CPP_ROOT="${KANO_CPP_INFRA_CPP_ROOT:-$repo_root/src/cpp}"
  export KANO_WORKSPACE_ROOT="$KANO_CPP_INFRA_REPO_ROOT"
  export KANO_CPP_INFRA_REPORT_ROOT="${KANO_CPP_INFRA_REPORT_ROOT:-$repo_root/.kano/tmp/reports}"

  if ! skill_root="$(report_skill_find_root "$repo_root")"; then
    echo "[ERROR] kano-cpp-test-skill not found." >&2
    echo "[ERROR] Set KANO_CPP_TEST_SKILL_ROOT or KANO_CPP_INFRA_TEST_SKILL_ROOT," >&2
    echo "[ERROR] or checkout the skill into _tools/kano-cpp-test-skill." >&2
    return 1
  fi

  export KANO_CPP_TEST_SKILL_ROOT="$skill_root"
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

  bash "$KANO_CPP_TEST_SKILL_ROOT/src/shell/reports/common/package-reports.sh" "$@"
}
