#!/usr/bin/env bash
# Focused watchdog re-entry contract: current Bash, exact argv, and mode guards.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
mkdir -p -- "$REPO_ROOT/build"
TEST_ROOT="$(mktemp -d "$REPO_ROOT/build/native-bash-contract.XXXXXXXXXX")"
if command -v cygpath >/dev/null 2>&1; then
  TEST_ROOT="$(cygpath -u "$TEST_ROOT")"
fi
cleanup() {
  [[ "$TEST_ROOT" == "$REPO_ROOT"/build/native-bash-contract.* ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p -- "$FAKE_BIN"
RECORDER="$FAKE_BIN/recorder"
printf '#!%s\n' "$BASH" > "$RECORDER"
cat >> "$RECORDER" <<'RECORDER_BODY'
set -euo pipefail
printf '%s\0' "$KANO_UNATTENDED" "$KANO_UNATTENDED_WATCHDOG_ACTIVE" "$@" > "$KANO_BASH_CONTRACT_LOG"
RECORDER_BODY
chmod +x "$RECORDER"
cp "$RECORDER" "$FAKE_BIN/python3"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$RECORDER" | cut -d ' ' -f 1 > "$RECORDER.unattended-v1"
else
  shasum -a 256 "$RECORDER" | cut -d ' ' -f 1 > "$RECORDER.unattended-v1"
fi

SCRIPT_PATH="$TEST_ROOT/script with spaces.sh"
ARGUMENTS=("two words" "" 'a"b' 'C:\path with spaces\' '$literal;*' 'UTF-8: 中文')
for kernel in "$(uname -s)" Linux; do
  expected_bash="$BASH"
  case "$kernel" in
    MINGW*|MSYS*|CYGWIN*) expected_bash="$(cygpath -aw "$BASH")" ;;
  esac
  for route in native bootstrap; do
    actual="$TEST_ROOT/$route.actual"
    expected="$TEST_ROOT/$route.expected"
    (
      source "$REPO_ROOT/scripts/lib/native_tool.sh"
      uname() { printf '%s\n' "$kernel"; }
      kano_cpp_infra_prepare_unattended_temp() { :; }
      export PATH="$FAKE_BIN:$PATH" KANO_BASH_CONTRACT_LOG="$actual"
      export KANO_UNATTENDED=1 KANO_UNATTENDED_WATCHDOG_ACTIVE=0
      export KANO_UNATTENDED_TIMEOUT_MS=1500 KANO_UNATTENDED_CLEANUP_TIMEOUT_MS=500
      if [[ "$route" == native ]]; then
        export KANO_CPP_INFRA_TOOL="$RECORDER"
      else
        export KANO_CPP_INFRA_TOOL="$TEST_ROOT/missing-tool"
      fi
      kano_cpp_infra_watchdog_enter "$SCRIPT_PATH" "${ARGUMENTS[@]}"
    )
    if [[ "$route" == native ]]; then
      printf '%s\0' 1 1 watchdog --timeout-ms 1500 --cleanup-timeout-ms 500 -- \
        "$expected_bash" "$SCRIPT_PATH" "${ARGUMENTS[@]}" > "$expected"
    else
      printf '%s\0' 1 1 "$REPO_ROOT/scripts/lib/watchdog-bootstrap.py" \
        --timeout-ms 1500 --cleanup-timeout-ms 500 -- \
        "$expected_bash" "$SCRIPT_PATH" "${ARGUMENTS[@]}" > "$expected"
    fi
    cmp "$expected" "$actual"
  done
done

(
  source "$REPO_ROOT/scripts/lib/native_tool.sh"
  BASH="$TEST_ROOT/missing-bash"
  KANO_UNATTENDED=0 kano_cpp_infra_watchdog_enter "$SCRIPT_PATH"
  KANO_UNATTENDED=1 KANO_UNATTENDED_WATCHDOG_ACTIVE=1 kano_cpp_infra_watchdog_enter "$SCRIPT_PATH"
  export KANO_UNATTENDED=1 KANO_UNATTENDED_WATCHDOG_ACTIVE=0
  if kano_cpp_infra_watchdog_enter "$SCRIPT_PATH" 2> "$TEST_ROOT/missing-bash.error"; then
    echo "Missing current Bash must fail closed." >&2
    exit 1
  else
    [[ "$?" -eq 127 ]]
  fi
  grep -q 'current Bash executable is unavailable' "$TEST_ROOT/missing-bash.error"
)

(
  source "$REPO_ROOT/scripts/lib/native_tool.sh"
  uname() { printf 'MINGW64\n'; }
  cygpath() { return 1; }
  export KANO_UNATTENDED=1 KANO_UNATTENDED_WATCHDOG_ACTIVE=0
  if kano_cpp_infra_watchdog_enter "$SCRIPT_PATH" 2> "$TEST_ROOT/cygpath.error"; then
    echo "Failed native Bash path conversion must fail closed." >&2
    exit 1
  else
    [[ "$?" -eq 127 ]]
  fi
  grep -q 'current Bash executable could not be resolved' "$TEST_ROOT/cygpath.error"
)
printf 'PASS: native and bootstrap Bash re-entry preserve executable, argv, and mode guards.\n'
