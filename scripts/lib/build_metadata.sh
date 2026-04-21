#!/usr/bin/env bash
set -euo pipefail

# ANSI Colors
_KOG_CLR_RESET='\033[0m'
_KOG_CLR_BOLD_GREEN='\033[1;32m'
_KOG_CLR_BOLD_YELLOW='\033[1;33m'
_KOG_CLR_BOLD_CYAN='\033[1;36m'

_kano_cpp_infra_color_enabled() {
  if [[ -n "${NO_COLOR:-}" || -n "${KOG_NO_COLOR:-}" ]]; then
    return 1
  fi
  if [[ -t 2 ]]; then
    return 0
  fi
  return 1
}

_kano_cpp_infra_log_prefix() {
  local prefix="$1"
  local color="$2"
  if _kano_cpp_infra_color_enabled; then
    printf "${color}${prefix}${_KOG_CLR_RESET}"
  else
    printf "${prefix}"
  fi
}

_kano_cpp_infra_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

_kano_cpp_infra_default_unknown() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s' "unknown"
    return
  fi
  printf '%s' "$value"
}

_kano_cpp_infra_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

_kano_cpp_infra_home_dir() {
  if [[ -n "${HOME:-}" ]]; then
    printf '%s' "$HOME"
    return 0
  fi
  if [[ -n "${USERPROFILE:-}" ]]; then
    printf '%s' "$USERPROFILE"
    return 0
  fi
  return 1
}

_kano_cpp_infra_default_cache_dir_for_launcher() {
  local launcher_name="$1"
  local home_dir=""
  home_dir="$(_kano_cpp_infra_home_dir || true)"
  if [[ -z "$home_dir" ]]; then
    return 1
  fi

  case "$launcher_name" in
    sccache)
      printf '%s' "$home_dir/.kano/cache/sccache"
      return 0
      ;;
    ccache)
      printf '%s' "$home_dir/.kano/cache/ccache"
      return 0
      ;;
    fastbuild)
      printf '%s' "$home_dir/.kano/cache/fastbuild"
      return 0
      ;;
  esac
  return 1
}

kano_cpp_infra_apply_fastbuild_env() {
  local home_dir=""
  home_dir="$(_kano_cpp_infra_home_dir || true)"

  local fastbuild_root="${KANO_CPP_INFRA_FASTBUILD_ROOT:-}"
  if [[ -z "$fastbuild_root" && -d "D:/Application/FASTBuild" ]]; then
    fastbuild_root="D:/Application/FASTBuild"
  fi
  if [[ -n "$fastbuild_root" ]]; then
    export KANO_CPP_INFRA_FASTBUILD_ROOT="$fastbuild_root"
    if [[ -x "$fastbuild_root/FBuild.exe" ]]; then
      export KANO_CPP_INFRA_FASTBUILD_EXECUTABLE="$fastbuild_root/FBuild.exe"
    fi
  fi

  export KANO_CPP_INFRA_COMPILER_LAUNCHER="none"
  unset KANO_CPP_INFRA_COMPILER_LAUNCHER_RESOLVED || true

  local cache_dir="${FASTBUILD_CACHE_PATH:-}"
  if [[ -z "$cache_dir" ]]; then
    cache_dir="$(_kano_cpp_infra_default_cache_dir_for_launcher fastbuild || true)"
  fi
  if [[ -n "$cache_dir" ]]; then
    export FASTBUILD_CACHE_PATH="$cache_dir"
    mkdir -p "$cache_dir" >/dev/null 2>&1 || true
  fi

  if [[ -z "${FASTBUILD_BROKERAGE_PATH:-}" ]]; then
    export FASTBUILD_BROKERAGE_PATH='\\nas\workspace\cache\fastbuild\brokerage'
  fi

  if [[ -z "${FASTBUILD_CACHE_MODE:-}" ]]; then
    export FASTBUILD_CACHE_MODE="rw"
  fi

  if [[ -z "${FASTBUILD_TEMP_PATH:-}" && -n "$home_dir" ]]; then
    export FASTBUILD_TEMP_PATH="$home_dir/.kano/cache/fastbuild/tmp"
    mkdir -p "$FASTBUILD_TEMP_PATH" >/dev/null 2>&1 || true
  fi

  echo "$(_kano_cpp_infra_log_prefix "[launcher]" "$_KOG_CLR_BOLD_GREEN")[fastbuild][info] exe=${KANO_CPP_INFRA_FASTBUILD_EXECUTABLE:-unknown} cache_dir=${FASTBUILD_CACHE_PATH:-unknown} brokerage=${FASTBUILD_BROKERAGE_PATH:-unknown} cache_mode=${FASTBUILD_CACHE_MODE:-unknown}" >&2
}

_kano_cpp_infra_select_compiler_launcher() {
  local configured="$1"
  local normalized=""
  normalized="$(_kano_cpp_infra_lower "$(_kano_cpp_infra_trim "$configured")")"

  case "$normalized" in
    ""|none)
      return 1
      ;;
    auto)
      if [[ "$(uname -s 2>/dev/null || true)" == MINGW* || "$(uname -s 2>/dev/null || true)" == MSYS* || "$(uname -s 2>/dev/null || true)" == CYGWIN* ]]; then
        for candidate in ccache ccache.exe sccache sccache.exe; do
          if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
          fi
        done
      else
        for candidate in ccache ccache.exe sccache sccache.exe; do
          if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
          fi
        done
      fi
      return 1
      ;;
    sccache)
      for candidate in sccache sccache.exe; do
        if command -v "$candidate" >/dev/null 2>&1; then
          printf '%s' "$candidate"
          return 0
        fi
      done
      return 1
      ;;
    ccache)
      for candidate in ccache ccache.exe; do
        if command -v "$candidate" >/dev/null 2>&1; then
          printf '%s' "$candidate"
          return 0
        fi
      done
      return 1
      ;;
    *)
      if command -v "$configured" >/dev/null 2>&1; then
        printf '%s' "$configured"
        return 0
      fi
      return 1
      ;;
  esac
}

kano_cpp_infra_workspace_root() {
  local cpp_root="${KANO_CPP_INFRA_CPP_ROOT:-$(pwd)}"
  (cd "$cpp_root/../.." && pwd)
}

_kano_cpp_infra_extract_toml_section_value() {
  local file_path="$1"
  local section_name="$2"
  local key_name="$3"
  awk -v section="$section_name" -v key="$key_name" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*\[/ {
      current = $0
      sub(/^[[:space:]]*\[/, "", current)
      sub(/\][[:space:]]*$/, "", current)
      current = trim(current)
      in_section = (current == section)
      next
    }
    in_section {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
        sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
        line = trim(line)
        if (line ~ /^".*"$/) {
          sub(/^"/, "", line)
          sub(/"$/, "", line)
        }
        print line
      }
    }
  ' "$file_path" | tail -n 1
}

kano_cpp_infra_resolve_self_config_value() {
  local key_name="$1"
  local workspace_root
  local home_dir="${HOME:-}"
  local value=""
  local file_path=""
  workspace_root="$(kano_cpp_infra_workspace_root)"

  for file_path in \
    "$workspace_root/.kano/kano_cpp_infra_config.toml" \
    "$home_dir/.kano/kano_cpp_infra_config.toml"; do
    if [[ -f "$file_path" ]]; then
      local candidate=""
      candidate="$(_kano_cpp_infra_extract_toml_section_value "$file_path" "self" "$key_name")"
      if [[ -n "$candidate" ]]; then
        value="$candidate"
      fi
    fi
  done

  printf '%s' "$value"
}

kano_cpp_apply_self_build_config() {
  unset KANO_CPP_INFRA_COMPILER_LAUNCHER_RESOLVED || true
  if [[ -z "${KOG_COMPILER_LAUNCHER:-}" ]]; then
    local configured_launcher=""
    configured_launcher="$(kano_cpp_infra_resolve_self_config_value "compiler_launcher")"
    if [[ -n "$configured_launcher" ]]; then
      export KOG_COMPILER_LAUNCHER="$configured_launcher"
    else
      export KOG_COMPILER_LAUNCHER="auto"
    fi
  fi

  local resolved_launcher=""
  if resolved_launcher="$(_kano_cpp_infra_select_compiler_launcher "${KOG_COMPILER_LAUNCHER:-}")"; then
    local launcher_name
    launcher_name="$(_kano_cpp_infra_lower "$(basename "$resolved_launcher" .exe)")"
    export KANO_CPP_INFRA_COMPILER_LAUNCHER_RESOLVED="$resolved_launcher"

    local cache_dir=""
    cache_dir="$(_kano_cpp_infra_default_cache_dir_for_launcher "$launcher_name" || true)"
    if [[ "$launcher_name" == "sccache" ]]; then
      if [[ -z "${SCCACHE_DIR:-}" && -n "$cache_dir" ]]; then
        export SCCACHE_DIR="$cache_dir"
      fi
      mkdir -p "${SCCACHE_DIR:-$cache_dir}" >/dev/null 2>&1 || true
      echo "$(_kano_cpp_infra_log_prefix "[launcher]" "$_KOG_CLR_BOLD_GREEN")[compiler-cache][info] launcher=$resolved_launcher cache_dir=${SCCACHE_DIR:-unknown}" >&2
    elif [[ "$launcher_name" == "ccache" ]]; then
      if [[ -z "${CCACHE_DIR:-}" && -n "$cache_dir" ]]; then
        export CCACHE_DIR="$cache_dir"
      fi
      mkdir -p "${CCACHE_DIR:-$cache_dir}" >/dev/null 2>&1 || true
      echo "$(_kano_cpp_infra_log_prefix "[launcher]" "$_KOG_CLR_BOLD_GREEN")[compiler-cache][info] launcher=$resolved_launcher cache_dir=${CCACHE_DIR:-unknown}" >&2
    else
      echo "$(_kano_cpp_infra_log_prefix "[launcher]" "$_KOG_CLR_BOLD_GREEN")[compiler-cache][info] launcher=$resolved_launcher" >&2
    fi
  else
    if [[ -n "${KOG_COMPILER_LAUNCHER:-}" && "$(_kano_cpp_infra_lower "${KOG_COMPILER_LAUNCHER}")" != "none" ]]; then
      echo "$(_kano_cpp_infra_log_prefix "[launcher]" "$_KOG_CLR_BOLD_GREEN")[compiler-cache]($(_kano_cpp_infra_log_prefix "warn" "$_KOG_CLR_BOLD_YELLOW")) requested launcher unavailable: ${KOG_COMPILER_LAUNCHER}" >&2
    fi
  fi
}

kano_cpp_collect_build_metadata() {
  local root="${KANO_CPP_INFRA_CPP_ROOT:-$(pwd)}"
  local vcs="unknown"
  local branch="unknown"
  local revision="unknown"
  local hash_short="unknown"
  local hash_full="unknown"
  local dirty="unknown"
  local timestamp_utc
  local host_name
  local ci
  local context
  local pipeline_id
  local platform="${KANO_CPP_INFRA_BUILD_PLATFORM:-$(uname -s 2>/dev/null || printf 'unknown')-$(uname -m 2>/dev/null || printf 'unknown')}"

  timestamp_utc=""
  host_name="${KANO_CPP_INFRA_BUILD_HOST_NAME:-${HOSTNAME:-$(hostname 2>/dev/null || printf 'unknown')}}"
  if [[ -n "${CI:-}" ]]; then
    ci="true"
    context="ci"
  else
    ci="false"
    context="local-manual"
  fi
  pipeline_id="${KANO_CPP_INFRA_BUILD_PIPELINE_ID:-${GITHUB_RUN_ID:-${CI_PIPELINE_ID:-${BUILD_BUILDID:-${BUILD_NUMBER:-$context}}}}}"

  if command -v git >/dev/null 2>&1 && (cd "$root" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    vcs="git"
    branch="$( (cd "$root" && git symbolic-ref --short HEAD 2>/dev/null) || true )"
    revision="$( (cd "$root" && git rev-list --count --first-parent HEAD 2>/dev/null) || true )"
    hash_short="$( (cd "$root" && git rev-parse --short HEAD 2>/dev/null) || true )"
    hash_full="$( (cd "$root" && git rev-parse HEAD 2>/dev/null) || true )"
    if [[ -z "$timestamp_utc" ]]; then
      timestamp_utc="$( (cd "$root" && git show -s --format=%cI HEAD 2>/dev/null) || true )"
    fi
    if [[ -n "$( (cd "$root" && git status --porcelain 2>/dev/null) || true )" ]]; then
      dirty="true"
    else
      dirty="false"
    fi
  elif command -v svn >/dev/null 2>&1 && (cd "$root" && svn info >/dev/null 2>&1); then
    vcs="svn"
    branch="$( (cd "$root" && svn info --show-item relative-url 2>/dev/null) || true )"
    branch="${branch#^/}"
    revision="$( (cd "$root" && svn info --show-item revision 2>/dev/null) || true )"
    if [[ -z "$timestamp_utc" ]]; then
      timestamp_utc="$( (cd "$root" && svn info --show-item last-changed-date 2>/dev/null) || true )"
    fi
    if [[ -n "$( (cd "$root" && svn status -q 2>/dev/null) || true )" ]]; then
      dirty="true"
    else
      dirty="false"
    fi
  elif command -v p4 >/dev/null 2>&1; then
    vcs="p4"
    branch="$(p4 switch 2>/dev/null || true)"
    revision="$(p4 changes -m1 ...#have 2>/dev/null | grep -Eo 'Change *[0-9:]+' | grep -Eo '[0-9]{1,9}' | sed -n '1p' || true)"
    dirty="unknown"
  fi

  export KANO_CPP_INFRA_BUILD_VCS="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$vcs")")"
  export KANO_CPP_INFRA_BUILD_BRANCH="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$branch")")"
  export KANO_CPP_INFRA_BUILD_REVISION="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$revision")")"
  export KANO_CPP_INFRA_BUILD_REVISION_HASH_SHORT="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$hash_short")")"
  export KANO_CPP_INFRA_BUILD_REVISION_HASH="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$hash_full")")"
  export KANO_CPP_INFRA_BUILD_DIRTY="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$dirty")")"
  export KANO_CPP_INFRA_BUILD_HOST_NAME="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$host_name")")"
  export KANO_CPP_INFRA_BUILD_CI="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$ci")")"
  export KANO_CPP_INFRA_BUILD_CONTEXT="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$context")")"
  export KANO_CPP_INFRA_BUILD_PIPELINE_ID="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$pipeline_id")")"
  export KANO_CPP_INFRA_BUILD_PLATFORM="$(_kano_cpp_infra_default_unknown "$(_kano_cpp_infra_trim "$platform")")"
}
