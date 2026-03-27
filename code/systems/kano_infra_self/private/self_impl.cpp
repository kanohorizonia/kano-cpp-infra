/* self_impl.cpp — self-build/rebuild metadata implementation */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "kano_self.h"

/* ---------------------------------------------------------------------------
 * Minimal stub. Full implementation would parse CMakeLists.txt,
 * CMakePresets.json, and build.ninja files to build the step graph.
 * --------------------------------------------------------------------------- */

struct KanoSelfCtxImpl {
    char* root;
    bool is_clean;
};

struct KanoSelfStepSeqImpl {
    KanoSelfStep* steps;
    size_t count;
};

struct KanoSelfStepImpl {
    KanoSelfStepType type;
    char* target;
    char* description;
};

 KanoSelfCtx kano_self_create_from_cwd(void) {
    /* TODO: use getcwd() */
    return kano_self_create(".");
}

 KanoSelfCtx kano_self_create(const char* directory) {
    if (!directory) return NULL;
    KanoSelfCtx ctx = (KanoSelfCtx)calloc(1, sizeof(struct KanoSelfCtxImpl));
    if (!ctx) return NULL;
    ctx->root = (char*)malloc(strlen(directory) + 1);
    strcpy(ctx->root, directory);
    ctx->is_clean = true; /* TODO: check for build/ directory */
    return ctx;
}

void kano_self_free(KanoSelfCtx ctx) {
    if (!ctx) return;
    free(ctx->root);
    free(ctx);
}

const char* kano_self_get_root(KanoSelfCtx ctx) {
    return ctx ? ctx->root : NULL;
}

bool kano_self_is_clean(KanoSelfCtx ctx) {
    return ctx ? ctx->is_clean : true;
}

 KanoSelfStepSeq kano_self_get_build_sequence(KanoSelfCtx ctx) {
    (void)ctx;
    /* TODO: return real sequence from CMakePresets.json / build.ninja */
    return NULL; /* stub */
}

 size_t kano_self_seq_count(KanoSelfStepSeq seq) {
    return seq ? seq->count : 0;
}

 KanoSelfStep kano_self_seq_at(KanoSelfStepSeq seq, size_t index) {
    if (!seq || index >= seq->count) return NULL;
    return seq->steps[index];
}

const char* kano_self_step_type_name(KanoSelfStep step) {
    if (!step) return "unknown";
    static const char* const names[] = {
        "CONFIGURE", "BUILD", "INSTALL", "TEST", "BOOTSTRAP"
    };
    if ((int)step->type < 0 || step->type > KANO_SELF_STEP_BOOTSTRAP)
        return "unknown";
    return names[(int)step->type];
}

const char* kano_self_step_target(KanoSelfStep step) { return step ? step->target : NULL; }
const char* kano_self_step_description(KanoSelfStep step) { return step ? step->description : NULL; }

bool kano_self_step_execute(KanoSelfStep step, bool dry_run) {
    if (!step) return false;
    if (dry_run) {
        printf("[dry-run] step: %s\n", kano_self_step_description(step));
        return true;
    }
    /* TODO: execute actual cmake/ctest command */
    return true;
}
