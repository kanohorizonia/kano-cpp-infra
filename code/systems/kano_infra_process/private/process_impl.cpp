/* process_impl.cpp - subprocess spawn and wait */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include <stdarg.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#endif

#include "kano_process.h"

struct KanoProcessImpl {
    char* executable;
    char* working_dir;
    char** args;
    size_t arg_count;
    KanoProcessMode mode;
    int timeout_ms;
    KanoProcessOutputCallback output_callback;
    void* user_data;
    bool spawned;
    char* cmdline;
#ifdef _WIN32
    PROCESS_INFORMATION process_info;
    HANDLE stdout_read;
    HANDLE stderr_read;
    HANDLE job;
#else
    pid_t pid;
    pid_t process_group;
    int stdout_fd;
    int stderr_fd;
#endif
};

void kano_process_free(KanoProcess proc);

static char* kano_process_dup_string(const char* value) {
    char* out;
    size_t len;

    if (!value) return NULL;
    len = strlen(value);
    out = (char*)malloc(len + 1);
    if (!out) return NULL;
    memcpy(out, value, len + 1);
    return out;
}

#ifdef _WIN32
static bool kano_process_is_cmd_executable(const char* executable) {
    const char* base = executable;
    const char* cursor;

    if (!executable) return false;
    for (cursor = executable; *cursor; ++cursor) {
        if (*cursor == '\\' || *cursor == '/') {
            base = cursor + 1;
        }
    }

    return _stricmp(base, "cmd") == 0 || _stricmp(base, "cmd.exe") == 0;
}
#endif

static bool kano_process_copy_args(KanoProcess proc, const char* const* argv, size_t argv_count) {
    size_t i;

    proc->args = (char**)calloc(argv_count + 1, sizeof(char*));
    if (!proc->args) return false;
    proc->arg_count = argv_count;

    for (i = 0; i < argv_count; ++i) {
        proc->args[i] = kano_process_dup_string(argv[i]);
        if (!proc->args[i]) {
            return false;
        }
    }
    proc->args[argv_count] = NULL;
    return true;
}

static void kano_process_free_args(KanoProcess proc) {
    size_t i;

    if (!proc || !proc->args) return;
    for (i = 0; i < proc->arg_count; ++i) {
        free(proc->args[i]);
    }
    free(proc->args);
    proc->args = NULL;
    proc->arg_count = 0;
}

static KanoProcess kano_process_alloc(const KanoProcessOptions* options) {
    KanoProcess proc;

    if (!options || !options->executable) return NULL;

    proc = (KanoProcess)calloc(1, sizeof(struct KanoProcessImpl));
    if (!proc) return NULL;

    proc->executable = kano_process_dup_string(options->executable);
    if (!proc->executable) {
        kano_process_free(proc);
        return NULL;
    }

    if (options->working_dir) {
        proc->working_dir = kano_process_dup_string(options->working_dir);
        if (!proc->working_dir) {
            kano_process_free(proc);
            return NULL;
        }
    }

    proc->mode = options->mode;
    proc->timeout_ms = options->timeout_ms;
    proc->output_callback = options->output_callback;
    proc->user_data = options->user_data;
#ifdef _WIN32
    memset(&proc->process_info, 0, sizeof(proc->process_info));
    proc->stdout_read = NULL;
    proc->stderr_read = NULL;
    proc->job = NULL;
#else
    proc->process_group = 0;
    proc->stdout_fd = -1;
    proc->stderr_fd = -1;
#endif

    if (options->argv && options->argv_count > 0) {
        if (!kano_process_copy_args(proc, options->argv, options->argv_count)) {
            kano_process_free(proc);
            return NULL;
        }
    }

    return proc;
}

#ifdef _WIN32

static char* kano_process_build_command_line(KanoProcess proc) {
    size_t i;
    size_t total = 0;
    char* cmd;
    char* out;

    // Executable: no quotes (Windows CreateProcessA parses first token as executable name)
    total += strlen(proc->executable);
    // Args: quoted (skip argv[0] since it's the same as executable)
    for (i = 1; i < proc->arg_count; ++i) {
        total += 3 + strlen(proc->args[i]);  // space + quote + arg + quote
    }

    cmd = (char*)malloc(total + 1);
    if (!cmd) return NULL;

    out = cmd;
    // Executable first (no quotes)
    memcpy(out, proc->executable, strlen(proc->executable));
    out += strlen(proc->executable);

    // Then quoted args (skip argv[0])
    for (i = 1; i < proc->arg_count; ++i) {
        *out++ = ' ';
#ifdef _WIN32
        if (kano_process_is_cmd_executable(proc->executable) && proc->args[i][0] == '/') {
            memcpy(out, proc->args[i], strlen(proc->args[i]));
            out += strlen(proc->args[i]);
            continue;
        }
#endif
        *out++ = '"';
        memcpy(out, proc->args[i], strlen(proc->args[i]));
        out += strlen(proc->args[i]);
        *out++ = '"';
    }
    *out = '\0';
    return cmd;
}

static bool kano_process_append_buffer(char** target, size_t* target_size, const char* data, size_t data_size,
                                       size_t max_size, bool* truncated) {
    char* next;
    size_t retained = data_size;
    if (max_size > 0 && *target_size + retained > max_size) {
        retained = *target_size >= max_size ? 0 : max_size - *target_size;
        *truncated = true;
    }
    if (retained == 0) return true;
    next = (char*)realloc(*target, *target_size + retained + 1);
    if (!next) return false;
    memcpy(next + *target_size, data, retained);
    *target_size += retained;
    next[*target_size] = '\0';
    *target = next;
    return true;
}

struct KanoReaderContext {
    KanoProcess proc;
    HANDLE handle;
    KanoProcessStream stream;
    char** target;
    size_t* target_size;
    size_t max_size;
    bool* truncated;
    volatile LONG cancel_requested;
};

static bool kano_process_reader_cancel_requested(struct KanoReaderContext* ctx) {
    return InterlockedCompareExchange(&ctx->cancel_requested, 0, 0) != 0;
}

static DWORD WINAPI kano_process_reader_thread(LPVOID param) {
    struct KanoReaderContext* ctx = (struct KanoReaderContext*)param;
    char buffer[8192];
    DWORD bytes_read = 0;

    while (!kano_process_reader_cancel_requested(ctx) &&
           ReadFile(ctx->handle, buffer, (DWORD)sizeof(buffer), &bytes_read, NULL) &&
           bytes_read > 0) {
        if (kano_process_reader_cancel_requested(ctx)) break;
        if (!kano_process_append_buffer(ctx->target, ctx->target_size, buffer, (size_t)bytes_read,
                                        ctx->max_size, ctx->truncated)) {
            return 1;
        }
        if (ctx->proc->output_callback && !kano_process_reader_cancel_requested(ctx)) {
            ctx->proc->output_callback(ctx->stream, buffer, (size_t)bytes_read, ctx->proc->user_data);
        }
    }
    return 0;
}

static void kano_process_request_capture_cancel(struct KanoReaderContext* contexts, HANDLE* readers) {
    InterlockedExchange(&contexts[0].cancel_requested, 1);
    InterlockedExchange(&contexts[1].cancel_requested, 1);
    if (readers[0]) CancelSynchronousIo(readers[0]);
    if (readers[1]) CancelSynchronousIo(readers[1]);
}

static void kano_process_close_capture_handles(KanoProcess proc) {
    if (proc->stdout_read) {
        CloseHandle(proc->stdout_read);
        proc->stdout_read = NULL;
    }
    if (proc->stderr_read) {
        CloseHandle(proc->stderr_read);
        proc->stderr_read = NULL;
    }
}

static DWORD kano_process_wait_capture_readers(HANDLE* readers, DWORD timeout_ms) {
    HANDLE active[2];
    DWORD count = 0;
    if (readers[0]) active[count++] = readers[0];
    if (readers[1]) active[count++] = readers[1];
    if (count == 0) return WAIT_OBJECT_0;
    return WaitForMultipleObjects(count, active, TRUE, timeout_ms);
}

static void kano_process_close_reader_handles(HANDLE* readers) {
    if (readers[0]) {
        CloseHandle(readers[0]);
        readers[0] = NULL;
    }
    if (readers[1]) {
        CloseHandle(readers[1]);
        readers[1] = NULL;
    }
}

#else

static long long kano_process_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((long long)ts.tv_sec * 1000LL) + (ts.tv_nsec / 1000000LL);
}

static char** kano_process_build_exec_argv(KanoProcess proc) {
    size_t i;
    char** argv = (char**)calloc(proc->arg_count + 2, sizeof(char*));
    if (!argv) return NULL;
    argv[0] = proc->executable;
    for (i = 0; i < proc->arg_count; ++i) {
        argv[i + 1] = proc->args[i];
    }
    argv[proc->arg_count + 1] = NULL;
    return argv;
}

static int kano_process_status_to_exit_code(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

static bool kano_process_signal_owned_tree(KanoProcess proc, int signal_number) {
    if (!proc || !proc->spawned) return false;

    if (proc->process_group > 0) {
        if (kill(-proc->process_group, signal_number) == 0) return true;
        return errno == ESRCH;
    }

    if (kill(proc->pid, signal_number) == 0) return true;
    return errno == ESRCH;
}

static bool kano_process_signal_unreaped_tree(KanoProcess proc, int signal_number) {
    bool signaled = false;
    if (!proc || !proc->spawned) return false;

    if (proc->process_group > 0) {
        if (kill(-proc->process_group, signal_number) == 0 || errno == ESRCH) {
            signaled = true;
        }
    }

    /* The unreaped PID cannot have been recycled, even if the child called setsid(). */
    if (proc->pid > 0) {
        if (kill(proc->pid, signal_number) == 0 || errno == ESRCH) {
            signaled = true;
        }
    }
    return signaled;
}

static bool kano_process_make_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return false;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static bool kano_process_append_buffer(char** target, size_t* target_size, const char* data, size_t data_size,
                                       size_t max_size, bool* truncated) {
    char* next;
    size_t retained = data_size;
    if (max_size > 0 && *target_size + retained > max_size) {
        retained = *target_size >= max_size ? 0 : max_size - *target_size;
        *truncated = true;
    }
    if (retained == 0) return true;
    next = (char*)realloc(*target, *target_size + retained + 1);
    if (!next) return false;
    memcpy(next + *target_size, data, retained);
    *target_size += retained;
    next[*target_size] = '\0';
    *target = next;
    return true;
}

static bool kano_process_read_fd(int fd,
                                 KanoProcessStream stream,
                                 KanoProcess proc,
                                 char** target,
                                 size_t* target_size, size_t max_size, bool* truncated) {
    char buffer[4096];
    size_t remaining_budget = 65536;
    ssize_t n;

    while (remaining_budget > 0) {
        n = read(fd, buffer, sizeof(buffer));
        if (n > 0) {
            if (!kano_process_append_buffer(target, target_size, buffer, (size_t)n, max_size, truncated)) {
                return false;
            }
            if (proc->output_callback) {
                proc->output_callback(stream, buffer, (size_t)n, proc->user_data);
            }
            remaining_budget -= (size_t)n;
            continue;
        }
        if (n == 0) {
            return false;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return true;
        }
        return false;
    }
    return true;
}

static bool kano_process_wait_capture(KanoProcess proc, int timeout_ms,
                                      const KanoProcessCaptureLimitsV2* limits,
                                      KanoProcessResultV2* out_result) {
    const long long cleanup_grace_ms = 1000;
    char* stdout_buf = NULL;
    char* stderr_buf = NULL;
    size_t stdout_size = 0;
    size_t stderr_size = 0;
    int stdout_open = (proc->stdout_fd >= 0);
    int stderr_open = (proc->stderr_fd >= 0);
    int process_done = 0;
    int status = 0;
    long long start_ms = kano_process_now_ms();
    long long primary_deadline_ms = timeout_ms > 0 ? start_ms + (long long)timeout_ms : 0;
    long long cleanup_deadline_ms = 0;

    while (!process_done || stdout_open || stderr_open) {
        struct pollfd fds[2];
        nfds_t nfds = 0;
        int poll_timeout = 100;
        int poll_rc;
        pid_t waited;

        if (out_result->timed_out) {
            long long remaining = cleanup_deadline_ms - kano_process_now_ms();
            poll_timeout = remaining > 0 && remaining < poll_timeout ? (int)remaining :
                           remaining <= 0 ? 0 : poll_timeout;
        } else if (primary_deadline_ms > 0) {
            long long remaining = primary_deadline_ms - kano_process_now_ms();
            poll_timeout = remaining > 0 && remaining < poll_timeout ? (int)remaining :
                           remaining <= 0 ? 0 : poll_timeout;
        }

        if (stdout_open) {
            fds[nfds].fd = proc->stdout_fd;
            fds[nfds].events = POLLIN | POLLHUP;
            fds[nfds].revents = 0;
            nfds += 1;
        }
        if (stderr_open) {
            fds[nfds].fd = proc->stderr_fd;
            fds[nfds].events = POLLIN | POLLHUP;
            fds[nfds].revents = 0;
            nfds += 1;
        }

        poll_rc = poll(fds, nfds, poll_timeout);
        if (poll_rc < 0 && errno != EINTR) {
            free(stdout_buf);
            free(stderr_buf);
            return false;
        }
        if (poll_rc > 0) {
            nfds_t index = 0;
            if (stdout_open) {
                if (fds[index].revents & (POLLIN | POLLHUP)) {
                    if (!kano_process_read_fd(proc->stdout_fd, KANO_PROCESS_STREAM_STDOUT, proc, &stdout_buf, &stdout_size,
                                              limits ? limits->stdout_max_bytes : 0, &out_result->stdout_truncated)) {
                        close(proc->stdout_fd);
                        proc->stdout_fd = -1;
                        stdout_open = 0;
                    }
                }
                if (stdout_open && (fds[index].revents & (POLLERR | POLLNVAL))) {
                    close(proc->stdout_fd);
                    proc->stdout_fd = -1;
                    stdout_open = 0;
                }
                index += 1;
            }
            if (stderr_open) {
                if (fds[index].revents & (POLLIN | POLLHUP)) {
                    if (!kano_process_read_fd(proc->stderr_fd, KANO_PROCESS_STREAM_STDERR, proc, &stderr_buf, &stderr_size,
                                              limits ? limits->stderr_max_bytes : 0, &out_result->stderr_truncated)) {
                        close(proc->stderr_fd);
                        proc->stderr_fd = -1;
                        stderr_open = 0;
                    }
                }
                if (stderr_open && (fds[index].revents & (POLLERR | POLLNVAL))) {
                    close(proc->stderr_fd);
                    proc->stderr_fd = -1;
                    stderr_open = 0;
                }
            }
        }

        /*
         * Before timeout, keep an exited leader unreaped while a capture FD is
         * still open. The zombie reserves its PID/PGID until the deadline, so
         * a later group signal cannot target a recycled unrelated process.
         */
        if (!process_done && (out_result->timed_out || (!stdout_open && !stderr_open))) {
            waited = waitpid(proc->pid, &status, WNOHANG);
            if (waited == proc->pid) {
                process_done = 1;
                if (!out_result->timed_out) {
                    out_result->exit_code = kano_process_status_to_exit_code(status);
                }
            } else if (waited < 0 && errno == ECHILD) {
                process_done = 1;
            } else if (waited < 0 && errno != EINTR) {
                free(stdout_buf);
                free(stderr_buf);
                return false;
            }
        }

        if (process_done && !stdout_open && !stderr_open) break;

        if (!out_result->timed_out && primary_deadline_ms > 0 &&
            kano_process_now_ms() >= primary_deadline_ms) {
            kano_process_signal_unreaped_tree(proc, SIGKILL);
            out_result->timed_out = true;
            out_result->exit_code = 124;
            cleanup_deadline_ms = primary_deadline_ms + cleanup_grace_ms;
            continue;
        }

        if (out_result->timed_out && kano_process_now_ms() >= cleanup_deadline_ms) {
            /* One last non-blocking drain, then stop waiting for inherited writers. */
            if (stdout_open) {
                kano_process_read_fd(proc->stdout_fd, KANO_PROCESS_STREAM_STDOUT, proc,
                                     &stdout_buf, &stdout_size,
                                     limits ? limits->stdout_max_bytes : 0,
                                     &out_result->stdout_truncated);
                close(proc->stdout_fd);
                proc->stdout_fd = -1;
                stdout_open = 0;
            }
            if (stderr_open) {
                kano_process_read_fd(proc->stderr_fd, KANO_PROCESS_STREAM_STDERR, proc,
                                     &stderr_buf, &stderr_size,
                                     limits ? limits->stderr_max_bytes : 0,
                                     &out_result->stderr_truncated);
                close(proc->stderr_fd);
                proc->stderr_fd = -1;
                stderr_open = 0;
            }
            if (!process_done) {
                waited = waitpid(proc->pid, &status, WNOHANG);
                if (waited == proc->pid || (waited < 0 && errno == ECHILD)) {
                    process_done = 1;
                }
            }
            break;
        }
    }

    out_result->stdout_data = stdout_buf;
    out_result->stdout_size = stdout_size;
    out_result->stderr_data = stderr_buf;
    out_result->stderr_size = stderr_size;
    if (!out_result->timed_out) {
        out_result->exit_code = kano_process_status_to_exit_code(status);
    }
    return true;
}

static bool kano_process_wait_passthrough(KanoProcess proc, int timeout_ms, KanoProcessResultV2* out_result) {
    int status = 0;
    long long start_ms = kano_process_now_ms();

    while (1) {
        pid_t waited = waitpid(proc->pid, &status, WNOHANG);
        if (waited == proc->pid) {
            out_result->exit_code = kano_process_status_to_exit_code(status);
            return true;
        }
        if (waited < 0) {
            return false;
        }
        if (timeout_ms > 0 && (kano_process_now_ms() - start_ms) >= timeout_ms) {
            kano_process_signal_unreaped_tree(proc, SIGKILL);
            waitpid(proc->pid, &status, 0);
            out_result->timed_out = true;
            out_result->exit_code = 124;
            return true;
        }
        usleep(10000);
    }
}

#endif

KanoProcess kano_process_spawn(const char* executable, const char* working_dir, ...) {
    KanoProcessOptions options;

    memset(&options, 0, sizeof(options));
    options.executable = executable;
    options.working_dir = working_dir;
    options.mode = KANO_PROCESS_MODE_CAPTURE;
    return kano_process_spawn_ex(&options);
}

KanoProcess kano_process_spawn_ex(const KanoProcessOptions* options) {
    KanoProcess proc = kano_process_alloc(options);
    if (!proc) return NULL;

#ifdef _WIN32
    {
        SECURITY_ATTRIBUTES sa;
        HANDLE stdout_write = NULL;
        HANDLE stderr_write = NULL;
        STARTUPINFOA si;
        BOOL ok;

        proc->cmdline = kano_process_build_command_line(proc);
        if (!proc->cmdline) {
            kano_process_free(proc);
            return NULL;
        }

        memset(&sa, 0, sizeof(sa));
        sa.nLength = sizeof(sa);
        sa.bInheritHandle = TRUE;

        if (proc->mode == KANO_PROCESS_MODE_CAPTURE) {
            if (!CreatePipe(&proc->stdout_read, &stdout_write, &sa, 0) ||
                !CreatePipe(&proc->stderr_read, &stderr_write, &sa, 0)) {
                if (proc->stdout_read) CloseHandle(proc->stdout_read);
                if (stdout_write) CloseHandle(stdout_write);
                if (proc->stderr_read) CloseHandle(proc->stderr_read);
                if (stderr_write) CloseHandle(stderr_write);
                kano_process_free(proc);
                return NULL;
            }
            SetHandleInformation(proc->stdout_read, HANDLE_FLAG_INHERIT, 0);
            SetHandleInformation(proc->stderr_read, HANDLE_FLAG_INHERIT, 0);
        }

        memset(&si, 0, sizeof(si));
        si.cb = sizeof(si);
        if (proc->mode == KANO_PROCESS_MODE_CAPTURE) {
            si.dwFlags |= STARTF_USESTDHANDLES;
            si.hStdOutput = stdout_write;
            si.hStdError = stderr_write;
            si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        }

        ok = CreateProcessA(
            NULL,
            proc->cmdline,
            NULL,
            NULL,
            proc->mode == KANO_PROCESS_MODE_CAPTURE ? TRUE : FALSE,
            CREATE_SUSPENDED,
            NULL,
            proc->working_dir,
            &si,
            &proc->process_info
        );
        if (!ok) {
            if (proc->stdout_read) CloseHandle(proc->stdout_read);
            if (stdout_write) CloseHandle(stdout_write);
            if (proc->stderr_read) CloseHandle(proc->stderr_read);
            if (stderr_write) CloseHandle(stderr_write);
            kano_process_free(proc);
            return NULL;
        }

        proc->job = CreateJobObjectA(NULL, NULL);
        if (proc->job != NULL) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit_info;
            memset(&limit_info, 0, sizeof(limit_info));
            limit_info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(proc->job, JobObjectExtendedLimitInformation, &limit_info, sizeof(limit_info));
            if (!AssignProcessToJobObject(proc->job, proc->process_info.hProcess)) {
                CloseHandle(proc->job);
                proc->job = NULL;
            }
        }

        ResumeThread(proc->process_info.hThread);
        proc->spawned = true;

        if (stdout_write) CloseHandle(stdout_write);
        if (stderr_write) CloseHandle(stderr_write);
        return proc;
    }
#else
    {
        char** argv = kano_process_build_exec_argv(proc);
        int stdout_pipe[2] = {-1, -1};
        int stderr_pipe[2] = {-1, -1};
        pid_t pid;

        if (!argv) {
            kano_process_free(proc);
            return NULL;
        }

        if (proc->mode == KANO_PROCESS_MODE_CAPTURE) {
            if (pipe(stdout_pipe) != 0 || pipe(stderr_pipe) != 0) {
                if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
                if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
                if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
                if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
                free(argv);
                kano_process_free(proc);
                return NULL;
            }
        }

        pid = fork();
        if (pid < 0) {
            if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
            if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
            if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
            if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
            free(argv);
            kano_process_free(proc);
            return NULL;
        }

        if (pid == 0) {
            if (setpgid(0, 0) != 0) {
                _exit(127);
            }
            if (proc->working_dir && chdir(proc->working_dir) != 0) {
                _exit(127);
            }
            if (proc->mode == KANO_PROCESS_MODE_CAPTURE) {
                close(stdout_pipe[0]);
                close(stderr_pipe[0]);
                dup2(stdout_pipe[1], STDOUT_FILENO);
                dup2(stderr_pipe[1], STDERR_FILENO);
                close(stdout_pipe[1]);
                close(stderr_pipe[1]);
            }
            execvp(proc->executable, argv);
            _exit(127);
        }

        /*
         * The child also establishes the group before exec. The parent-side
         * call closes the window where an immediate terminate could otherwise
         * run before the child does so. EACCES means the child already exec'd
         * after establishing its group; ESRCH means it already exited.
         */
        while (setpgid(pid, pid) != 0 && errno == EINTR) {
        }

        free(argv);
        proc->pid = pid;
        proc->process_group = pid;
        proc->spawned = true;

        if (proc->mode == KANO_PROCESS_MODE_CAPTURE) {
            close(stdout_pipe[1]);
            close(stderr_pipe[1]);
            proc->stdout_fd = stdout_pipe[0];
            proc->stderr_fd = stderr_pipe[0];
            kano_process_make_nonblocking(proc->stdout_fd);
            kano_process_make_nonblocking(proc->stderr_fd);
        }

        return proc;
    }
#endif
}

bool kano_process_wait_v2(KanoProcess proc, int timeout_ms,
                          const KanoProcessCaptureLimitsV2* limits,
                          KanoProcessResultV2* out_result) {
    if (!out_result) return false;
    memset(out_result, 0, sizeof(*out_result));
    if (!proc || !proc->spawned) return false;
#ifdef _WIN32
    DWORD wait_result;
    if (proc->mode == KANO_PROCESS_MODE_CAPTURE) {
        const ULONGLONG cleanup_grace_ms = 1000;
        HANDLE readers[2] = {NULL, NULL};
        struct KanoReaderContext contexts[2];
        char* stdout_buf = NULL;
        char* stderr_buf = NULL;
        size_t stdout_size = 0;
        size_t stderr_size = 0;
        bool process_done = false;
        bool reader_done[2] = {false, false};
        bool wait_failed = false;
        ULONGLONG primary_deadline = timeout_ms > 0 ? GetTickCount64() + (ULONGLONG)timeout_ms : 0;

        memset(contexts, 0, sizeof(contexts));
        contexts[0].proc = proc;
        contexts[0].handle = proc->stdout_read;
        contexts[0].stream = KANO_PROCESS_STREAM_STDOUT;
        contexts[0].target = &stdout_buf;
        contexts[0].target_size = &stdout_size;
        contexts[0].max_size = limits ? limits->stdout_max_bytes : 0;
        contexts[0].truncated = &out_result->stdout_truncated;
        contexts[1].proc = proc;
        contexts[1].handle = proc->stderr_read;
        contexts[1].stream = KANO_PROCESS_STREAM_STDERR;
        contexts[1].target = &stderr_buf;
        contexts[1].target_size = &stderr_size;
        contexts[1].max_size = limits ? limits->stderr_max_bytes : 0;
        contexts[1].truncated = &out_result->stderr_truncated;

        readers[0] = CreateThread(NULL, 0, kano_process_reader_thread, &contexts[0], 0, NULL);
        readers[1] = CreateThread(NULL, 0, kano_process_reader_thread, &contexts[1], 0, NULL);
        if (!readers[0] || !readers[1]) {
            if (proc->job) {
                TerminateJobObject(proc->job, 1);
            } else {
                TerminateProcess(proc->process_info.hProcess, 1);
            }
            kano_process_request_capture_cancel(contexts, readers);
            kano_process_wait_capture_readers(readers, INFINITE);
            kano_process_close_reader_handles(readers);
            kano_process_close_capture_handles(proc);
            free(stdout_buf);
            free(stderr_buf);
            return false;
        }

        while (!process_done || !reader_done[0] || !reader_done[1]) {
            HANDLE active[3];
            DWORD active_count = 0;
            DWORD wait_ms = INFINITE;

            if (!process_done && WaitForSingleObject(proc->process_info.hProcess, 0) == WAIT_OBJECT_0) {
                process_done = true;
            }
            if (!reader_done[0] && WaitForSingleObject(readers[0], 0) == WAIT_OBJECT_0) {
                reader_done[0] = true;
            }
            if (!reader_done[1] && WaitForSingleObject(readers[1], 0) == WAIT_OBJECT_0) {
                reader_done[1] = true;
            }
            if (process_done && reader_done[0] && reader_done[1]) break;

            if (primary_deadline > 0) {
                ULONGLONG now = GetTickCount64();
                ULONGLONG remaining;
                if (now >= primary_deadline) {
                    out_result->timed_out = true;
                    break;
                }
                remaining = primary_deadline - now;
                wait_ms = remaining > (ULONGLONG)MAXDWORD ? MAXDWORD : (DWORD)remaining;
            }

            if (!process_done) active[active_count++] = proc->process_info.hProcess;
            if (!reader_done[0]) active[active_count++] = readers[0];
            if (!reader_done[1]) active[active_count++] = readers[1];
            wait_result = WaitForMultipleObjects(active_count, active, FALSE, wait_ms);
            if (wait_result == WAIT_TIMEOUT) {
                out_result->timed_out = true;
                break;
            }
            if (wait_result == WAIT_FAILED) {
                wait_failed = true;
                break;
            }
        }

        if (out_result->timed_out || wait_failed) {
            DWORD reader_wait;
            ULONGLONG cleanup_deadline = out_result->timed_out && primary_deadline > 0
                ? primary_deadline + cleanup_grace_ms
                : GetTickCount64() + cleanup_grace_ms;
            ULONGLONG cleanup_now;
            DWORD cleanup_wait_ms;

            if (out_result->timed_out) {
                out_result->exit_code = 124;
            }
            if (proc->job) {
                TerminateJobObject(proc->job, out_result->timed_out ? 124 : 1);
            } else if (!process_done) {
                TerminateProcess(proc->process_info.hProcess, out_result->timed_out ? 124 : 1);
            }
            kano_process_request_capture_cancel(contexts, readers);

            cleanup_now = GetTickCount64();
            cleanup_wait_ms = cleanup_deadline > cleanup_now
                ? (DWORD)(cleanup_deadline - cleanup_now)
                : 0;
            reader_wait = kano_process_wait_capture_readers(readers, cleanup_wait_ms);
            if (reader_wait != WAIT_OBJECT_0) {
                /*
                 * Cancellation plus closing the owned Job normally releases
                 * both reads within the shared grace. A user callback that is
                 * itself blocked remains outside the process timeout contract;
                 * wait for it rather than corrupting the host with TerminateThread.
                 */
                kano_process_request_capture_cancel(contexts, readers);
                kano_process_wait_capture_readers(readers, INFINITE);
            }
        }

        kano_process_close_reader_handles(readers);
        kano_process_close_capture_handles(proc);

        if (wait_failed) {
            free(stdout_buf);
            free(stderr_buf);
            memset(out_result, 0, sizeof(*out_result));
            return false;
        }

        out_result->stdout_data = stdout_buf;
        out_result->stdout_size = stdout_size;
        out_result->stderr_data = stderr_buf;
        out_result->stderr_size = stderr_size;
    } else {
        wait_result = WaitForSingleObject(proc->process_info.hProcess, timeout_ms > 0 ? (DWORD)timeout_ms : INFINITE);
        if (wait_result == WAIT_TIMEOUT) {
            out_result->timed_out = true;
            out_result->exit_code = 124;
            if (proc->job) {
                TerminateJobObject(proc->job, 124);
            } else {
                TerminateProcess(proc->process_info.hProcess, 124);
            }
            WaitForSingleObject(proc->process_info.hProcess, 5000);
        }
    }

    if (!out_result->timed_out) {
        DWORD exit_code = 0;
        GetExitCodeProcess(proc->process_info.hProcess, &exit_code);
        out_result->exit_code = (int)exit_code;
    }
    return true;
#else
    if (proc->mode == KANO_PROCESS_MODE_CAPTURE) {
        return kano_process_wait_capture(proc, timeout_ms, limits, out_result);
    }
    return kano_process_wait_passthrough(proc, timeout_ms, out_result);
#endif
}

bool kano_process_wait(KanoProcess proc, int timeout_ms, KanoProcessResult* out_result) {
    KanoProcessResultV2 v2;
    bool ok;
    if (!out_result) return false;
    memset(out_result, 0, sizeof(*out_result));
    memset(&v2, 0, sizeof(v2));
    ok = kano_process_wait_v2(proc, timeout_ms, NULL, &v2);
    if (!ok) return false;
    out_result->exit_code = v2.exit_code;
    out_result->stdout_data = v2.stdout_data;
    out_result->stderr_data = v2.stderr_data;
    out_result->timed_out = v2.timed_out;
    return true;
}

void kano_process_free(KanoProcess proc) {
    if (!proc) return;
#ifdef _WIN32
    if (proc->stdout_read) CloseHandle(proc->stdout_read);
    if (proc->stderr_read) CloseHandle(proc->stderr_read);
    if (proc->process_info.hProcess) CloseHandle(proc->process_info.hProcess);
    if (proc->process_info.hThread) CloseHandle(proc->process_info.hThread);
    if (proc->job) CloseHandle(proc->job);
#else
    if (proc->stdout_fd >= 0) close(proc->stdout_fd);
    if (proc->stderr_fd >= 0) close(proc->stderr_fd);
#endif
    free(proc->executable);
    free(proc->working_dir);
    kano_process_free_args(proc);
    free(proc->cmdline);
    free(proc);
}

void kano_process_free_result(KanoProcessResult* result) {
    if (!result) return;
    free(result->stdout_data);
    free(result->stderr_data);
    memset(result, 0, sizeof(*result));
}

void kano_process_free_result_v2(KanoProcessResultV2* result) {
    if (!result) return;
    free(result->stdout_data);
    free(result->stderr_data);
    memset(result, 0, sizeof(*result));
}

bool kano_process_run(const char* executable, KanoProcessResult* out_result, ...) {
    KanoProcessOptions options;

    memset(&options, 0, sizeof(options));
    options.executable = executable;
    options.mode = KANO_PROCESS_MODE_CAPTURE;
    return kano_process_run_ex(&options, out_result);
}

bool kano_process_run_ex(const KanoProcessOptions* options, KanoProcessResult* out_result) {
    KanoProcessResultV2 v2;
    bool ok;
    if (!out_result) return false;
    memset(out_result, 0, sizeof(*out_result));
    memset(&v2, 0, sizeof(v2));
    ok = kano_process_run_ex_v2(options, NULL, &v2);
    if (!ok) return false;
    out_result->exit_code = v2.exit_code;
    out_result->stdout_data = v2.stdout_data;
    out_result->stderr_data = v2.stderr_data;
    out_result->timed_out = v2.timed_out;
    return true;
}

bool kano_process_run_ex_v2(const KanoProcessOptions* options,
                            const KanoProcessCaptureLimitsV2* limits,
                            KanoProcessResultV2* out_result) {
    KanoProcess proc;
    bool ok;

    if (!out_result) return false;
    memset(out_result, 0, sizeof(*out_result));
    proc = kano_process_spawn_ex(options);
    if (!proc) return false;
    ok = kano_process_wait_v2(proc, options ? options->timeout_ms : 0, limits, out_result);
    kano_process_free(proc);
    return ok;
}

bool kano_process_is_running(KanoProcess proc) {
#ifdef _WIN32
    DWORD exit_code;
    if (!proc || !proc->spawned || !proc->process_info.hProcess) return false;
    if (!GetExitCodeProcess(proc->process_info.hProcess, &exit_code)) return false;
    return exit_code == STILL_ACTIVE;
#else
    int status;
    pid_t waited;
    if (!proc || !proc->spawned) return false;
    waited = waitpid(proc->pid, &status, WNOHANG);
    if (waited == 0) return true;
    return false;
#endif
}

bool kano_process_terminate(KanoProcess proc) {
#ifdef _WIN32
    if (!proc || !proc->spawned || !proc->process_info.hProcess) return false;
    if (proc->job) return TerminateJobObject(proc->job, 1) != 0;
    return TerminateProcess(proc->process_info.hProcess, 1) != 0;
#else
    if (!proc || !proc->spawned) return false;
    return kano_process_signal_owned_tree(proc, SIGTERM);
#endif
}
