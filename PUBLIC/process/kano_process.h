#pragma once

/**
 * kano_process.h — public process facade for kano-cpp-infra
 *
 * Responsibility: subprocess spawn, stdout/stderr capture, exit code
 * Non-goals: not a job scheduler, not a log aggregator
 *
 * Usage:
 *   #include <kano_process.h>
 *   KanoProcessResult r = kano_process_run("cmake", args, NULL);
 *   if (r.exit_code != 0) { ... }
 */

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Opaque handle
 * --------------------------------------------------------------------------- */
typedef struct KanoProcessImpl* KanoProcess;

/* ---------------------------------------------------------------------------
 * Result structure (caller-owned after kano_process_wait)
 * --------------------------------------------------------------------------- */
typedef struct KanoProcessResult {
    int exit_code;
    char* stdout_data;   /* allocated; caller frees with kano_process_free_result */
    char* stderr_data;   /* allocated; caller frees with kano_process_free_result */
    bool timed_out;
} KanoProcessResult;

/* ---------------------------------------------------------------------------
 * Lifecycle
 * --------------------------------------------------------------------------- */
/**
 * Begin spawning a process. Returns a handle for use with kano_process_wait.
 * Arguments are passed as: arg0, arg1, ..., NULL (last must be NULL).
 * If working_dir is not NULL, the process runs in that directory.
 */
KanoProcess kano_process_spawn(const char* executable, const char* working_dir, ...);

/**
 * Wait for a spawned process to complete. Copies stdout/stderr into result.
 * If timeout_ms > 0, kills the process if it exceeds the timeout.
 * Returns false on error (e.g. process already finished, invalid handle).
 * The result is allocated; call kano_process_free_result() to release.
 */
bool kano_process_wait(KanoProcess proc, int timeout_ms, KanoProcessResult* out_result);

/**
 * Free a process handle (only needed if you discard before wait).
 */
void kano_process_free(KanoProcess proc);

/**
 * Free a result struct and its captured stdout/stderr strings.
 */
void kano_process_free_result(KanoProcessResult* result);

/* ---------------------------------------------------------------------------
 * Convenience single-shot API
 * --------------------------------------------------------------------------- */
/**
 * Run a process and wait for it to complete (synchronous, no timeout).
 * Returns false on spawn error; exit_code is in result.exit_code on success.
 * stdout/stderr are allocated and must be freed by the caller.
 */
bool kano_process_run(const char* executable, KanoProcessResult* out_result, ...);

/* ---------------------------------------------------------------------------
 * Query (only valid after spawn, before free)
 * --------------------------------------------------------------------------- */
/**
 * Returns true if the process is still running.
 */
bool kano_process_is_running(KanoProcess proc);

/**
 * Send SIGTERM to the process (SIGKILL on Windows). Not guaranteed to work.
 */
bool kano_process_terminate(KanoProcess proc);

#ifdef __cplusplus
}
#endif
