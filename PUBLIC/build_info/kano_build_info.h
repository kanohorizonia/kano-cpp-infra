#pragma once

/**
 * kano_build_info.h — public build_info facade for kano-cpp-infra
 *
 * Responsibility: app version, build metadata, VCS revision
 * Non-goals: not a package manager, not a build orchestrator
 *
 * Usage:
 *   #include <kano_build_info.h>
 *   KanoBuildInfo info = kano_build_info_discover();
 *   printf("version: %s\n", kano_build_info_get_version(info));
 */

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Opaque handle
 * --------------------------------------------------------------------------- */
typedef struct KanoBuildInfoImpl* KanoBuildInfo;

/* ---------------------------------------------------------------------------
 * Lifecycle
 * --------------------------------------------------------------------------- */
/**
 * Discover build metadata from the environment.
 * Returns a handle; call kano_build_info_free() to release.
 * The object is self-contained and does not depend on config.
 */
KanoBuildInfo kano_build_info_discover(void);

/**
 * Free a build info object.
 */
void kano_build_info_free(KanoBuildInfo info);

/* ---------------------------------------------------------------------------
 * Accessors
 * --------------------------------------------------------------------------- */
/**
 * Returns the version string (e.g. "1.2.3"). Owned by the object; do not free.
 */
const char* kano_build_info_get_version(KanoBuildInfo info);

/**
 * Returns the VCS revision string (e.g. git commit hash). NULL if not available.
 * Owned by the object; do not free.
 */
const char* kano_build_info_get_vcs_revision(KanoBuildInfo info);

/**
 * Returns the VCS branch name. NULL if not available.
 * Owned by the object; do not free.
 */
const char* kano_build_info_get_vcs_branch(KanoBuildInfo info);

/**
 * Returns the build type string (e.g. "Debug", "Release", "RelWithDebInfo").
 * Owned by the object; do not free.
 */
const char* kano_build_info_get_build_type(KanoBuildInfo info);

/**
 * Returns the compiler name and version (e.g. "MSVC 19.40"). Owned; do not free.
 */
const char* kano_build_info_get_compiler(KanoBuildInfo info);

/**
 * Returns the build timestamp (ISO 8601 format). Owned; do not free.
 */
const char* kano_build_info_get_timestamp(KanoBuildInfo info);

/**
 * Returns the Git status of the working tree ("clean" or "dirty").
 * Returns "unknown" if VCS is not Git.
 */
const char* kano_build_info_get_vcs_status(KanoBuildInfo info);

/* ---------------------------------------------------------------------------
 * Serialization
 * --------------------------------------------------------------------------- */
/**
 * Dump all fields as key=value pairs to stdout (for debugging/logging).
 */
void kano_build_info_dump(KanoBuildInfo info);

#ifdef __cplusplus
}
#endif
