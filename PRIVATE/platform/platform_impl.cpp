/* platform_impl.cpp — OS detection and path helpers */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "kano_platform.h"

/* ---------------------------------------------------------------------------
 * Minimal stub implementations. Full implementations would use
 * platform-specific APIs: GetAdaptersAddresses on Windows,
 * uname/sysctl on POSIX.
 * --------------------------------------------------------------------------- */

struct KanoPlatformOSName { KanoPlatformOS os; const char* name; };
static const struct KanoPlatformOSName os_names[] = {
    { KANO_PLATFORM_OS_WINDOWS, "windows" },
    { KANO_PLATFORM_OS_LINUX,   "linux"   },
    { KANO_PLATFORM_OS_MACOS,   "macos"   },
    { KANO_PLATFORM_OS_UNKNOWN, "unknown" },
};

static const struct { KanoPlatformArch arch; const char* name; } arch_names[] = {
    { KANO_PLATFORM_ARCH_X64,   "x64"   },
    { KANO_PLATFORM_ARCH_ARM64,"arm64" },
    { KANO_PLATFORM_ARCH_X86,  "x86"   },
    { KANO_PLATFORM_ARCH_UNKNOWN, "unknown" },
};

 KanoPlatformOS kano_platform_detect_os(void) {
#if defined(_WIN32)
    return KANO_PLATFORM_OS_WINDOWS;
#elif defined(__linux__)
    return KANO_PLATFORM_OS_LINUX;
#elif defined(__APPLE__)
    return KANO_PLATFORM_OS_MACOS;
#else
    return KANO_PLATFORM_OS_UNKNOWN;
#endif
}

const char* kano_platform_os_name(KanoPlatformOS os) {
    for (int i = 0; i < (int)(sizeof(os_names)/sizeof(os_names[0])); i++)
        if (os_names[i].os == os) return os_names[i].name;
    return "unknown";
}

 KanoPlatformArch kano_platform_detect_arch(void) {
#if defined(_M_X64) || defined(__x86_64__)
    return KANO_PLATFORM_ARCH_X64;
#elif defined(_M_ARM64) || defined(__aarch64__)
    return KANO_PLATFORM_ARCH_ARM64;
#elif defined(_M_IX86) || defined(__i386__)
    return KANO_PLATFORM_ARCH_X86;
#else
    return KANO_PLATFORM_ARCH_UNKNOWN;
#endif
}

const char* kano_platform_arch_name(KanoPlatformArch arch) {
    for (int i = 0; i < (int)(sizeof(arch_names)/sizeof(arch_names[0])); i++)
        if (arch_names[i].arch == arch) return arch_names[i].name;
    return "unknown";
}

bool kano_platform_is_windows(void) { return kano_platform_detect_os() == KANO_PLATFORM_OS_WINDOWS; }
bool kano_platform_is_linux(void)   { return kano_platform_detect_os() == KANO_PLATFORM_OS_LINUX; }
bool kano_platform_is_macos(void)   { return kano_platform_detect_os() == KANO_PLATFORM_OS_MACOS; }

char* kano_platform_normalize_path(const char* path) {
    if (!path) return NULL;
    char* out = (char*)malloc(4096);
    if (!out) return NULL;
    /* Minimal: just copy. Real impl would resolve . and .. */
    strncpy(out, path, 4095);
    out[4095] = '\0';
    return out;
}

char* kano_platform_join_path(const char* base, const char* append) {
    if (!base || !append) return NULL;
    size_t len = strlen(base) + 1 + strlen(append) + 1;
    char* out = (char*)malloc(len);
    if (!out) return NULL;
    sprintf(out, "%s/%s", base, append);
    return out;
}

bool kano_platform_is_absolute(const char* path) {
    if (!path) return false;
#if defined(_WIN32)
    return (path[0] >= 'A' && path[0] <= 'Z') && path[1] == ':';
#else
    return path[0] == '/';
#endif
}

char* kano_platform_native_separators(const char* path) {
    if (!path) return NULL;
    char* out = (char*)malloc(strlen(path) + 1);
    if (!out) return NULL;
    char* dst = out;
    for (const char* src = path; *src; src++, dst++) {
        *dst = (*src == '/') ? '\\' : *src;
    }
    *dst = '\0';
    return out;
}

const char* kano_platform_get_env(const char* key) {
    if (!key) return NULL;
    return getenv(key);
}

bool kano_platform_get_env_int(const char* key, int* out_value) {
    const char* v = kano_platform_get_env(key);
    if (!v) return false;
    *out_value = atoi(v);
    return true;
}

bool kano_platform_has_env(const char* key) {
    return kano_platform_get_env(key) != NULL;
}

bool kano_platform_set_env(const char* key, const char* value) {
    if (!key) return false;
#if defined(_WIN32)
    return 0 == _putenv_s(key, value ? value : "");
#else
    if (value) return 0 == setenv(key, value, 1);
    unsetenv(key);
    return true;
#endif
}

bool kano_platform_unset_env(const char* key) {
    if (!key) return false;
#if defined(_WIN32)
    return 0 == _putenv_s(key, "");
#else
    return 0 == unsetenv(key);
#endif
}
