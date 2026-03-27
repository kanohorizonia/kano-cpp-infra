#pragma once

/**
 * kano_platform.h — public platform facade for kano-cpp-infra
 *
 * Responsibility: OS detection, path normalization, env helpers
 * Non-goals: not a filesystem abstraction, not a shell emulator
 *
 * Usage:
 *   #include <kano_platform.h>
 *   KanoPlatformOS os = kano_platform_detect_os();
 *   char* path = kano_platform_normalize_path(home, "src/../src/file.txt");
 */

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * OS enumeration
 * --------------------------------------------------------------------------- */
typedef enum KanoPlatformOS {
    KANO_PLATFORM_OS_UNKNOWN = 0,
    KANO_PLATFORM_OS_WINDOWS,
    KANO_PLATFORM_OS_LINUX,
    KANO_PLATFORM_OS_MACOS,
} KanoPlatformOS;

/* ---------------------------------------------------------------------------
 * Architecture enumeration
 * --------------------------------------------------------------------------- */
typedef enum KanoPlatformArch {
    KANO_PLATFORM_ARCH_UNKNOWN = 0,
    KANO_PLATFORM_ARCH_X64,
    KANO_PLATFORM_ARCH_ARM64,
    KANO_PLATFORM_ARCH_X86,
} KanoPlatformArch;

/* ---------------------------------------------------------------------------
 * OS detection
 * --------------------------------------------------------------------------- */
/**
 * Detect the current operating system.
 */
KanoPlatformOS kano_platform_detect_os(void);

/**
 * Human-readable OS name (e.g. "windows", "linux", "macos"). Owned; do not free.
 */
const char* kano_platform_os_name(KanoPlatformOS os);

/**
 * Detect the current CPU architecture.
 */
KanoPlatformArch kano_platform_detect_arch(void);

/**
 * Human-readable arch name (e.g. "x64", "arm64"). Owned; do not free.
 */
const char* kano_platform_arch_name(KanoPlatformArch arch);

/**
 * Returns true if running on Windows.
 */
bool kano_platform_is_windows(void);

/**
 * Returns true if running on Linux.
 */
bool kano_platform_is_linux(void);

/**
 * Returns true if running on macOS.
 */
bool kano_platform_is_macos(void);

/* ---------------------------------------------------------------------------
 * Path normalization
 * ---------------------------------------------------------------------------);
/**
 * Normalize a path: resolve . and .. components, collapse redundant separators.
 * Returns an allocated string; call free() to release.
 * The result uses native path separators for the current OS.
 */
char* kano_platform_normalize_path(const char* path);

/**
 * Join two path segments. Handles trailing/leading separators correctly.
 * Returns an allocated string; call free() to release.
 */
char* kano_platform_join_path(const char* base, const char* append);

/**
 * Returns true if the path is absolute.
 */
bool kano_platform_is_absolute(const char* path);

/**
 * Convert a forward-slash path to native separators (no-op on Unix).
 * Returns an allocated string; call free() to release.
 */
char* kano_platform_native_separators(const char* path);

/* ---------------------------------------------------------------------------
 * Environment
 * --------------------------------------------------------------------------- */
/**
 * Get an environment variable. Returns NULL if not set.
 * The returned pointer is from getenv(); do not free.
 */
const char* kano_platform_get_env(const char* key);

/**
 * Get an environment variable as an integer. Returns false if missing or invalid.
 */
bool kano_platform_get_env_int(const char* key, int* out_value);

/**
 * Returns true if the environment variable is set and non-empty.
 */
bool kano_platform_has_env(const char* key);

/**
 * Set an environment variable. Returns false on failure.
 */
bool kano_platform_set_env(const char* key, const char* value);

/**
 * Unset an environment variable. Returns false on failure.
 */
bool kano_platform_unset_env(const char* key);

#ifdef __cplusplus
}
#endif
