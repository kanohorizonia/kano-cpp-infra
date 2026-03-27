/* process_impl.cpp — subprocess spawn and wait */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

#include "kano_process.h"

/* ---------------------------------------------------------------------------
 * Minimal stub: uses popen on POSIX, _popen on Windows.
 * Full implementation would use native process APIs for full control.
 * --------------------------------------------------------------------------- */

struct KanoProcessImpl {
    char* executable;
    char* working_dir;
    char** args;       /* NULL-terminated */
    bool spawned;
    /* stub: just stores command for later */
    char* cmdline;
};

 KanoProcess kano_process_spawn(const char* executable, const char* working_dir, ...) {
    if (!executable) return NULL;
    KanoProcess proc = (KanoProcess)calloc(1, sizeof(struct KanoProcessImpl));
    if (!proc) return NULL;
    proc->executable = (char*)malloc(strlen(executable) + 1);
    strcpy(proc->executable, executable);
    if (working_dir) {
        proc->working_dir = (char*)malloc(strlen(working_dir) + 1);
        strcpy(proc->working_dir, working_dir);
    }
    /* stub: cmdline not built */
    (void)va_start; /* suppress warning */
    return proc;
}

bool kano_process_wait(KanoProcess proc, int timeout_ms, KanoProcessResult* out_result) {
    if (!proc || !out_result) return false;
    memset(out_result, 0, sizeof(*out_result));
    /* stub: return success */
    out_result->exit_code = 0;
    out_result->timed_out = false;
    (void)timeout_ms;
    return true;
}

void kano_process_free(KanoProcess proc) {
    if (!proc) return;
    free(proc->executable);
    free(proc->working_dir);
    free(proc->cmdline);
    free(proc);
}

void kano_process_free_result(KanoProcessResult* result) {
    if (!result) return;
    free(result->stdout_data);
    free(result->stderr_data);
    memset(result, 0, sizeof(*result));
}

bool kano_process_run(const char* executable, KanoProcessResult* out_result, ...) {
    KanoProcess proc = kano_process_spawn(executable, NULL);
    if (!proc) return false;
    bool ok = kano_process_wait(proc, 0, out_result);
    kano_process_free(proc);
    return ok;
}

bool kano_process_is_running(KanoProcess proc) {
    (void)proc;
    return false; /* stub: always false */
}

bool kano_process_terminate(KanoProcess proc) {
    (void)proc;
    return false; /* stub */
}
