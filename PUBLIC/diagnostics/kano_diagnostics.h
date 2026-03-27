#pragma once

/**
 * kano_diagnostics.h — public diagnostics facade for kano-cpp-infra
 *
 * Responsibility: structured error reporting, error code taxonomy,
 *                 diagnostic output formatting
 * Non-goals: not a log aggregation system, not a crash reporter
 *
 * Usage:
 *   #include <kano_diagnostics.h>
 *   KanoDiagCode code = kano_diag_encode(KANO_DIAG_CAT_BUILD, 1);
 *   kano_diag_print(code, "cmake failed", stderr);
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Diagnostic categories
 * --------------------------------------------------------------------------- */
typedef enum KanoDiagCategory {
    KANO_DIAG_CAT_NONE     = 0,
    KANO_DIAG_CAT_CONFIG   = 1,   /* config loading / merge errors       */
    KANO_DIAG_CAT_BUILD    = 2,   /* build failures                     */
    KANO_DIAG_CAT_PLATFORM = 3,   /* OS / arch detection failures       */
    KANO_DIAG_CAT_PROCESS  = 4,   /* subprocess errors                  */
    KANO_DIAG_CAT_INFRA    = 5,   /* infra module internal errors       */
    KANO_DIAG_CAT_COUNT,
} KanoDiagCategory;

/* ---------------------------------------------------------------------------
 * Error code taxonomy
 *
 * Format: KDIAG-<category>-<number>
 * Example: KDIAG-BUILD-1  ("build step failed")
 * Example: KDIAG-CONFIG-3 ("key not found")
 * --------------------------------------------------------------------------- */
#define KANO_DIAG_FACILITY "KDIAG"

typedef unsigned int KanoDiagCode;

/**
 * Encode a diagnostic code from category and number.
 * Number must be > 0.
 */
KanoDiagCode kano_diag_encode(KanoDiagCategory cat, unsigned int number);

/**
 * Decode category from a diagnostic code.
 */
KanoDiagCategory kano_diag_category(KanoDiagCode code);

/**
 * Decode number from a diagnostic code.
 */
unsigned int kano_diag_number(KanoDiagCode code);

/**
 * Human-readable string for a category. Owned; do not free.
 */
const char* kano_diag_category_name(KanoDiagCategory cat);

/* ---------------------------------------------------------------------------
 * Formatting
 * --------------------------------------------------------------------------- */
/**
 * Format a diagnostic message.
 * The output is allocated; call free() to release.
 * Format: [<facility>-<category>-<number>] <message>
 */
char* kano_diag_format(KanoDiagCode code, const char* message);

/**
 * Print a formatted diagnostic to a FILE*.
 * If details is non-NULL, also prints details on a second line.
 */
void kano_diag_print(KanoDiagCode code, const char* message, FILE* dest);

/**
 * The last error code set by any kano-cpp-infra function (thread-local).
 */
KanoDiagCode kano_diag_last_error(void);

/**
 * Set the last error code.
 */
void kano_diag_set_last_error(KanoDiagCode code);

#ifdef __cplusplus
}
#endif
