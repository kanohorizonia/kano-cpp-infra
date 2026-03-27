/* build_info_impl.cpp — build metadata discovery implementation
 *
 * Populates build info from KANO_INFRA_BUILD_* preprocessor definitions
 * injected by the consuming project's CMakeLists.txt.
 * Expected definitions:
 *   KANO_INFRA_BUILD_VERSION   (e.g. "1.2.3")
 *   KANO_INFRA_BUILD_REVISION  (e.g. "abc1234")
 *   KANO_INFRA_BUILD_BRANCH    (e.g. "main")
 *   KANO_INFRA_BUILD_TYPE      (e.g. "Release")
 *   KANO_INFRA_BUILD_COMPILER  (e.g. "Clang 16.0.0")
 *   KANO_INFRA_BUILD_TIMESTAMP (e.g. "2024-03-27T10:30:00Z")
 *   KANO_INFRA_BUILD_VCS_STATUS (e.g. "clean" or "dirty")
 */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "kano_build_info.h"

/* Stringify a macro value (even if it contains special characters) */
#define _KANO_INFRA_STRINGIFY_IMPL(x) #x
#define _KANO_INFRA_STRINGIFY(x) _KANO_INFRA_STRINGIFY_IMPL(x)

/* Default to "unknown" if the macro was never defined */
#ifndef KANO_INFRA_BUILD_VERSION
#define KANO_INFRA_BUILD_VERSION unknown
#endif
#ifndef KANO_INFRA_BUILD_REVISION
#define KANO_INFRA_BUILD_REVISION unknown
#endif
#ifndef KANO_INFRA_BUILD_BRANCH
#define KANO_INFRA_BUILD_BRANCH unknown
#endif
#ifndef KANO_INFRA_BUILD_TYPE
#define KANO_INFRA_BUILD_TYPE unknown
#endif
#ifndef KANO_INFRA_BUILD_COMPILER
#define KANO_INFRA_BUILD_COMPILER unknown
#endif
#ifndef KANO_INFRA_BUILD_TIMESTAMP
#define KANO_INFRA_BUILD_TIMESTAMP 1970-01-01T00:00:00Z
#endif
#ifndef KANO_INFRA_BUILD_VCS_STATUS
#define KANO_INFRA_BUILD_VCS_STATUS unknown
#endif

struct KanoBuildInfoImpl {
    char* version;
    char* vcs_revision;
    char* vcs_branch;
    char* build_type;
    char* compiler;
    char* timestamp;
    char* vcs_status;
};

static char* kano_info_strdup(const char* s) {
    if (!s) return NULL;
    size_t len = strlen(s);
    char* p = (char*)malloc(len + 1);
    if (!p) return NULL;
    memcpy(p, s, len + 1);
    return p;
}

KanoBuildInfo kano_build_info_discover(void) {
    KanoBuildInfo info = (KanoBuildInfo)calloc(1, sizeof(struct KanoBuildInfoImpl));
    if (!info) return NULL;

    info->version     = kano_info_strdup(_KANO_INFRA_STRINGIFY(KANO_INFRA_BUILD_VERSION));
    info->vcs_revision = kano_info_strdup(_KANO_INFRA_STRINGIFY(KANO_INFRA_BUILD_REVISION));
    info->vcs_branch  = kano_info_strdup(_KANO_INFRA_STRINGIFY(KANO_INFRA_BUILD_BRANCH));
    info->build_type  = kano_info_strdup(_KANO_INFRA_STRINGIFY(KANO_INFRA_BUILD_TYPE));
    info->compiler    = kano_info_strdup(_KANO_INFRA_STRINGIFY(KANO_INFRA_BUILD_COMPILER));
    info->timestamp   = kano_info_strdup(_KANO_INFRA_STRINGIFY(KANO_INFRA_BUILD_TIMESTAMP));
    info->vcs_status  = kano_info_strdup(_KANO_INFRA_STRINGIFY(KANO_INFRA_BUILD_VCS_STATUS));

    return info;
}

void kano_build_info_free(KanoBuildInfo info) {
    if (!info) return;
    free(info->version);
    free(info->vcs_revision);
    free(info->vcs_branch);
    free(info->build_type);
    free(info->compiler);
    free(info->timestamp);
    free(info->vcs_status);
    free(info);
}

const char* kano_build_info_get_version(KanoBuildInfo info)         { return info ? info->version : NULL; }
const char* kano_build_info_get_vcs_revision(KanoBuildInfo info)  { return info ? info->vcs_revision : NULL; }
const char* kano_build_info_get_vcs_branch(KanoBuildInfo info)     { return info ? info->vcs_branch : NULL; }
const char* kano_build_info_get_build_type(KanoBuildInfo info)     { return info ? info->build_type : NULL; }
const char* kano_build_info_get_compiler(KanoBuildInfo info)       { return info ? info->compiler : NULL; }
const char* kano_build_info_get_timestamp(KanoBuildInfo info)      { return info ? info->timestamp : NULL; }
const char* kano_build_info_get_vcs_status(KanoBuildInfo info)    { return info ? info->vcs_status : NULL; }

void kano_build_info_dump(KanoBuildInfo info) {
    if (!info) return;
    printf("version=%s vcs_revision=%s vcs_branch=%s build_type=%s "
           "compiler=%s timestamp=%s vcs_status=%s\n",
           info->version     ? info->version     : "(null)",
           info->vcs_revision ? info->vcs_revision : "(null)",
           info->vcs_branch  ? info->vcs_branch  : "(null)",
           info->build_type  ? info->build_type  : "(null)",
           info->compiler    ? info->compiler    : "(null)",
           info->timestamp   ? info->timestamp   : "(null)",
           info->vcs_status  ? info->vcs_status  : "(null)");
}
