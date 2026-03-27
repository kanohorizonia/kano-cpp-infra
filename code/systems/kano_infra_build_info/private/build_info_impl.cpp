/* build_info_impl.cpp — build metadata discovery implementation */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "kano_build_info.h"

/* ---------------------------------------------------------------------------
 * Minimal stub: returns static strings. Full implementation would query
 * git, cmake, and compiler to populate real metadata.
 * --------------------------------------------------------------------------- */

struct KanoBuildInfoImpl {
    char* version;
    char* vcs_revision;
    char* vcs_branch;
    char* build_type;
    char* compiler;
    char* timestamp;
    char* vcs_status;
};

KanoBuildInfo kano_build_info_discover(void) {
    KanoBuildInfo info = (KanoBuildInfo)calloc(1, sizeof(struct KanoBuildInfoImpl));
    if (!info) return NULL;
    /* TODO: dynamically discover from git/cmake/compiler */
    info->version     = (char*)"0.0.0";
    info->vcs_revision = NULL;
    info->vcs_branch  = NULL;
    info->build_type  = (char*)"Debug";
    info->compiler    = (char*)"unknown";
    info->timestamp   = (char*)"1970-01-01T00:00:00Z";
    info->vcs_status  = (char*)"unknown";
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

const char* kano_build_info_get_version(KanoBuildInfo info)    { return info ? info->version : NULL; }
const char* kano_build_info_get_vcs_revision(KanoBuildInfo i)   { (void)i; return NULL; }
const char* kano_build_info_get_vcs_branch(KanoBuildInfo i)    { (void)i; return NULL; }
const char* kano_build_info_get_build_type(KanoBuildInfo info) { return info ? info->build_type : NULL; }
const char* kano_build_info_get_compiler(KanoBuildInfo info)   { return info ? info->compiler : NULL; }
const char* kano_build_info_get_timestamp(KanoBuildInfo info)  { return info ? info->timestamp : NULL; }
const char* kano_build_info_get_vcs_status(KanoBuildInfo info)  { return info ? info->vcs_status : NULL; }

void kano_build_info_dump(KanoBuildInfo info) {
    if (!info) return;
    printf("version=%s build_type=%s compiler=%s timestamp=%s vcs_status=%s\n",
           info->version, info->build_type, info->compiler,
           info->timestamp, info->vcs_status);
}
