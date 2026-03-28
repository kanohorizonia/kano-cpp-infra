#!/usr/bin/env bash
set -euo pipefail

_kano_cpp_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

_kano_cpp_default_unknown() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s' "unknown"
    return
  fi
  printf '%s' "$value"
}

_kano_cpp_home_dir() {
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

_kano_cpp_export_prefixed() {
  local prefix="$1"
  local suffix="$2"
  local value="$3"
  local name="${prefix}_${suffix}"
  printf -v "$name" '%s' "$value"
  export "$name"
}

kano_cpp_root() {
  local candidate
  for candidate in     "${KANO_CPP_ROOT:-}"     "${KOG_CPP_ROOT:-}"     "${KOB_CPP_ROOT:-}"     "${KABSD_CPP_ROOT:-}"; do
    if [[ -n "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  pwd
}

kano_cpp_workspace_root() {
  local cpp_root
  cpp_root="$(kano_cpp_root)"
  (cd "$cpp_root/../.." && pwd)
}

_kano_cpp_extract_toml_section_value() {
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
        if (line ~ /^'"'"'.*'"'"'$/) {
          sub(/^'"'"'/, "", line)
          sub(/'"'"'$/, "", line)
        }
        print line
      }
    }
  ' "$file_path" | tail -n 1
}

kano_cpp_resolve_self_config_value() {
  local key_name="$1"
  local workspace_root
  local home_dir=""
  local value=""
  local file_path=""
  workspace_root="$(kano_cpp_workspace_root)"
  home_dir="$(_kano_cpp_home_dir || true)"

  for file_path in     "$workspace_root/.kano/kano_cpp_config.toml"     "$workspace_root/.kano/kog_config.toml"     "$workspace_root/assets/kob_config.toml"     "$workspace_root/.kano/kob_config.toml"     "$home_dir/.kano/kano_cpp_config.toml"     "$home_dir/.kano/kog_config.toml"     "$home_dir/.kano/kob_config.toml"; do
    if [[ -f "$file_path" ]]; then
      local candidate=""
      candidate="$(_kano_cpp_extract_toml_section_value "$file_path" "self" "$key_name")"
      if [[ -n "$candidate" ]]; then
        value="$candidate"
      fi
    fi
  done

  printf '%s' "$value"
}

kano_cpp_apply_self_build_config() {
  local prefix="${1:-KANO}"
  local launcher_var="${prefix}_COMPILER_LAUNCHER"
  local current_launcher="${!launcher_var:-}"
  if [[ -z "$current_launcher" ]]; then
    local configured_launcher=""
    configured_launcher="$(kano_cpp_resolve_self_config_value "compiler_launcher")"
    if [[ -n "$configured_launcher" ]]; then
      printf -v "$launcher_var" '%s' "$configured_launcher"
      export "$launcher_var"
    fi
  fi
}

kano_cpp_collect_build_metadata() {
  local prefix="${1:-KANO}"
  local root="${KANO_BUILD_METADATA_ROOT:-}"
  local version_file="${KANO_BUILD_VERSION_FILE:-}"
  local version="unknown"
  local branch="unknown"
  local hash_short="unknown"
  local hash_full="unknown"
  local dirty="unknown"
  local host_name
  local platform

  if [[ -z "$root" ]]; then
    root="$(kano_cpp_workspace_root)"
  fi
  if [[ -z "$version_file" ]]; then
    version_file="$root/VERSION"
  fi

  if [[ -f "$version_file" ]]; then
    version="$(_kano_cpp_trim "$(<"$version_file")")"
  fi

  host_name="${KANO_BUILD_HOST_NAME:-${HOSTNAME:-$(hostname 2>/dev/null || printf 'unknown')}}"
  platform="${KANO_BUILD_PLATFORM:-$(uname -s 2>/dev/null || printf 'unknown')-$(uname -m 2>/dev/null || printf 'unknown')}"

  if command -v git >/dev/null 2>&1 && (cd "$root" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    branch="$( (cd "$root" && git symbolic-ref --short HEAD 2>/dev/null) || true )"
    hash_short="$( (cd "$root" && git rev-parse --short HEAD 2>/dev/null) || true )"
    hash_full="$( (cd "$root" && git rev-parse HEAD 2>/dev/null) || true )"
    if [[ -n "$( (cd "$root" && git status --porcelain 2>/dev/null) || true )" ]]; then
      dirty="true"
    else
      dirty="false"
    fi
  fi

  _kano_cpp_export_prefixed "$prefix" "BUILD_VERSION" "$(_kano_cpp_default_unknown "$version")"
  _kano_cpp_export_prefixed "$prefix" "BUILD_BRANCH" "$(_kano_cpp_default_unknown "$(_kano_cpp_trim "$branch")")"
  _kano_cpp_export_prefixed "$prefix" "BUILD_REVISION_HASH_SHORT" "$(_kano_cpp_default_unknown "$(_kano_cpp_trim "$hash_short")")"
  _kano_cpp_export_prefixed "$prefix" "BUILD_REVISION_HASH" "$(_kano_cpp_default_unknown "$(_kano_cpp_trim "$hash_full")")"
  _kano_cpp_export_prefixed "$prefix" "BUILD_DIRTY" "$(_kano_cpp_default_unknown "$(_kano_cpp_trim "$dirty")")"
  _kano_cpp_export_prefixed "$prefix" "BUILD_HOST_NAME" "$(_kano_cpp_default_unknown "$(_kano_cpp_trim "$host_name")")"
  _kano_cpp_export_prefixed "$prefix" "BUILD_PLATFORM" "$(_kano_cpp_default_unknown "$(_kano_cpp_trim "$platform")")"
}
