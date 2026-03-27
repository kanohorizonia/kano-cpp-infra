#pragma once

/**
 * kano_self.h — public self-build facade for kano-cpp-infra
 *
 * Responsibility: self-build/rebuild metadata, bootstrap sequencing,
 *                 internal dependency graph
 * Non-goals: not a package installer, not a general-purpose task runner
 *
 * Usage:
 *   #include <kano_self.h>
 *   KanoSelfCtx ctx = kano_self_create_from_cwd();
 *   KanoSelfStepSeq seq = kano_self_get_build_sequence(ctx);
 */

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Opaque handles
 * --------------------------------------------------------------------------- */
typedef struct KanoSelfCtxImpl* KanoSelfCtx;
typedef struct KanoSelfStepSeqImpl* KanoSelfStepSeq;
typedef struct KanoSelfStepImpl* KanoSelfStep;

/* ---------------------------------------------------------------------------
 * Bootstrap context
 * --------------------------------------------------------------------------- */
/**
 * Create a self-build context from the current working directory.
 * The context scans for build metadata (CMakeLists.txt, CMakePresets.json, etc.)
 * Returns NULL if the directory is not a kano-cpp-infra working tree.
 */
KanoSelfCtx kano_self_create_from_cwd(void);

/**
 * Create a self-build context from an explicit directory path.
 * Returns NULL on error.
 */
KanoSelfCtx kano_self_create(const char* directory);

/**
 * Free a self-build context.
 */
void kano_self_free(KanoSelfCtx ctx);

/* ---------------------------------------------------------------------------
 * Build graph query
 * --------------------------------------------------------------------------- */
/**
 * Returns the directory this context was created from. Owned; do not free.
 */
const char* kano_self_get_root(KanoSelfCtx ctx);

/**
 * Returns true if this is a clean tree (no build artifacts).
 */
bool kano_self_is_clean(KanoSelfCtx ctx);

/**
 * Get the ordered sequence of bootstrap/build steps.
 * The sequence is owned by the context; do not free separately.
 */
KanoSelfStepSeq kano_self_get_build_sequence(KanoSelfCtx ctx);

/**
 * Get step count in the sequence.
 */
size_t kano_self_seq_count(KanoSelfStepSeq seq);

/**
 * Get step at index (0-based). Returns NULL if out of range.
 */
KanoSelfStep kano_self_seq_at(KanoSelfStepSeq seq, size_t index);

/* ---------------------------------------------------------------------------
 * Step properties
 * --------------------------------------------------------------------------- */
/**
 * Step type enumeration.
 */
typedef enum KanoSelfStepType {
    KANO_SELF_STEP_CONFIGURE,  /* cmake configure */
    KANO_SELF_STEP_BUILD,       /* cmake --build */
    KANO_SELF_STEP_INSTALL,     /* cmake --install */
    KANO_SELF_STEP_TEST,        /* ctest */
    KANO_SELF_STEP_BOOTSTRAP,   /* prerequisite bootstrap (e.g. vcvars) */
} KanoSelfStepType;

/**
 * Step type as a string. Owned; do not free.
 */
const char* kano_self_step_type_name(KanoSelfStep step);

/**
 * Returns the CMake target name (or NULL if N/A). Owned; do not free.
 */
const char* kano_self_step_target(KanoSelfStep step);

/**
 * Returns the step description. Owned; do not free.
 */
const char* kano_self_step_description(KanoSelfStep step);

/**
 * Execute a single step. Returns false if step fails.
 * If dry_run is true, prints what would be executed without running.
 */
bool kano_self_step_execute(KanoSelfStep step, bool dry_run);

#ifdef __cplusplus
}
#endif
