/* diagnostics_impl.cpp — diagnostic code taxonomy and formatting */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

#include "kano_diagnostics.h"

/* ---------------------------------------------------------------------------
 * Thread-local last error (stub: not thread-safe without TLS)
 * --------------------------------------------------------------------------- */

static KanoDiagCode g_last_error = 0;

 KanoDiagCode kano_diag_encode(KanoDiagCategory cat, unsigned int number) {
    if (cat <= KANO_DIAG_CAT_NONE || cat >= KANO_DIAG_CAT_COUNT) cat = KANO_DIAG_CAT_INFRA;
    return ((KanoDiagCode)cat << 16) | (number & 0xFFFF);
}

 KanoDiagCategory kano_diag_category(KanoDiagCode code) {
    return (KanoDiagCategory)((code >> 16) & 0xFF);
}

 unsigned int kano_diag_number(KanoDiagCode code) {
    return code & 0xFFFF;
}

static const char* const cat_names[] = {
    "NONE", "CONFIG", "BUILD", "PLATFORM", "PROCESS", "INFRA"
};

const char* kano_diag_category_name(KanoDiagCategory cat) {
    if (cat <= KANO_DIAG_CAT_NONE || cat >= KANO_DIAG_CAT_COUNT)
        return "UNKNOWN";
    return cat_names[(int)cat];
}

char* kano_diag_format(KanoDiagCode code, const char* message) {
    if (!message) message = "(no message)";
    size_t len = strlen(KANO_DIAG_FACILITY) + 1
                + strlen(kano_diag_category_name(kano_diag_category(code))) + 1
                + 6 + 2 + strlen(message) + 1;
    char* out = (char*)malloc(len);
    if (!out) return NULL;
    sprintf(out, "[%s-%s-%u] %s",
            KANO_DIAG_FACILITY,
            kano_diag_category_name(kano_diag_category(code)),
            kano_diag_number(code),
            message);
    return out;
}

void kano_diag_print(KanoDiagCode code, const char* message, FILE* dest) {
    if (!dest) dest = stderr;
    char* formatted = kano_diag_format(code, message);
    if (formatted) {
        fprintf(dest, "%s\n", formatted);
        free(formatted);
    }
}

 KanoDiagCode kano_diag_last_error(void) {
    return g_last_error;
}

void kano_diag_set_last_error(KanoDiagCode code) {
    g_last_error = code;
}
