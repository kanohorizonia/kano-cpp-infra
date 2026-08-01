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

/*
 * Additive binary-safe result contract.  KanoProcessResult deliberately stays
 * byte-for-byte source and ABI compatible with 1.0 consumers.  A zero limit
 * means unlimited retention.  Capture always continues draining both pipes
 * after a limit is reached so a noisy child cannot deadlock.
 */
typedef struct KanoProcessCaptureLimitsV2 {
    size_t stdout_max_bytes;
    size_t stderr_max_bytes;
} KanoProcessCaptureLimitsV2;

typedef struct KanoProcessResultV2 {
    int exit_code;
    char* stdout_data;   /* allocated byte buffer; may contain embedded NUL */
    size_t stdout_size;  /* retained byte count, excluding sentinel NUL */
    bool stdout_truncated;
    char* stderr_data;   /* allocated byte buffer; may contain embedded NUL */
    size_t stderr_size;  /* retained byte count, excluding sentinel NUL */
    bool stderr_truncated;
    bool timed_out;
} KanoProcessResultV2;

typedef enum KanoProcessMode {
    KANO_PROCESS_MODE_PASS_THROUGH = 0,
    KANO_PROCESS_MODE_CAPTURE = 1,
} KanoProcessMode;

typedef enum KanoProcessStream {
    KANO_PROCESS_STREAM_STDOUT = 0,
    KANO_PROCESS_STREAM_STDERR = 1,
} KanoProcessStream;

/*
 * Callbacks execute synchronously with capture delivery and must return
 * promptly. Time spent inside caller code is outside the process timeout
 * guarantee.
 */
typedef void (*KanoProcessOutputCallback)(
    KanoProcessStream stream,
    const char* chunk,
    size_t chunk_size,
    void* user_data
);

typedef struct KanoProcessOptions {
    const char* executable;
    const char* working_dir;
    const char* const* argv;
    size_t argv_count;
    KanoProcessMode mode;
    int timeout_ms;
    KanoProcessOutputCallback output_callback;
    void* user_data;
} KanoProcessOptions;

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
 * Begin spawning a process using an explicit options struct.
 * This is the parity-oriented API for consumers that need argv arrays,
 * working-dir control, capture mode, timeout input, and output callbacks.
 */
KanoProcess kano_process_spawn_ex(const KanoProcessOptions* options);

/**
 * Wait for a spawned process to complete. Copies stdout/stderr into the
 * legacy NUL-terminated result buffers.
 * If timeout_ms > 0, kills the owned process tree when the process or an
 * inherited capture writer exceeds the timeout. Capture cleanup uses one
 * fixed, bounded grace after that deadline.
 * Returns false on error (e.g. process already finished, invalid handle).
 * The result is allocated; call kano_process_free_result() to release.
 */
bool kano_process_wait(KanoProcess proc, int timeout_ms, KanoProcessResult* out_result);

/** Versioned, binary-safe wait with independent bounded stream retention. */
bool kano_process_wait_v2(KanoProcess proc, int timeout_ms,
                          const KanoProcessCaptureLimitsV2* limits,
                          KanoProcessResultV2* out_result);

/**
 * Free a process handle (only needed if you discard before wait).
 */
void kano_process_free(KanoProcess proc);

/**
 * Free a result struct and its captured stdout/stderr strings.
 */
void kano_process_free_result(KanoProcessResult* result);

/** Free a V2 result and reset all fields. */
void kano_process_free_result_v2(KanoProcessResultV2* result);

/* ---------------------------------------------------------------------------
 * Convenience single-shot API
 * --------------------------------------------------------------------------- */
/**
 * Run a process and wait for it to complete (synchronous, no timeout).
 * Returns false on spawn error; exit_code is in result.exit_code on success.
 * stdout/stderr are allocated and must be freed by the caller.
 */
bool kano_process_run(const char* executable, KanoProcessResult* out_result, ...);

/**
 * Run a process synchronously using an explicit options struct.
 * This preserves the old API while providing a path toward richer adapters.
 */
bool kano_process_run_ex(const KanoProcessOptions* options, KanoProcessResult* out_result);

/** Versioned single-shot API with binary-safe bounded capture. */
bool kano_process_run_ex_v2(const KanoProcessOptions* options,
                            const KanoProcessCaptureLimitsV2* limits,
                            KanoProcessResultV2* out_result);

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
