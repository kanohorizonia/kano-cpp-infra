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

static bool kano_process_append_buffer(char** target, size_t* target_size, const char* data, size_t data_size) {
    char* next;

    if (data_size == 0) return true;
    next = (char*)realloc(*target, *target_size + data_size + 1);
    if (!next) return false;
    memcpy(next + *target_size, data, data_size);
    *target_size += data_size;
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
};

static DWORD WINAPI kano_process_reader_thread(LPVOID param) {
    struct KanoReaderContext* ctx = (struct KanoReaderContext*)param;
    char buffer[8192];
    DWORD bytes_read = 0;

    while (ReadFile(ctx->handle, buffer, (DWORD)sizeof(buffer), &bytes_read, NULL) && bytes_read > 0) {
        if (!kano_process_append_buffer(ctx->target, ctx->target_size, buffer, (size_t)bytes_read)) {
            return 1;
        }
        if (ctx->proc->output_callback) {
            ctx->proc->output_callback(ctx->stream, buffer, (size_t)bytes_read, ctx->proc->user_data);
        }
    }
    return 0;
}

static void kano_process_cancel_capture_readers(KanoProcess proc, HANDLE* readers) {
    if (readers[0]) CancelSynchronousIo(readers[0]);
    if (readers[1]) CancelSynchronousIo(readers[1]);
    if (proc->stdout_read) {
        CloseHandle(proc->stdout_read);
        proc->stdout_read = NULL;
    }
    if (proc->stderr_read) {
        CloseHandle(proc->stderr_read);
        proc->stderr_read = NULL;
    }
}

static void kano_process_join_reader(HANDLE reader) {
    if (!reader) return;
    if (WaitForSingleObject(reader, 5000) == WAIT_TIMEOUT) {
        TerminateThread(reader, 1);
        WaitForSingleObject(reader, INFINITE);
    }
    CloseHandle(reader);
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

static bool kano_process_make_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return false;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static bool kano_process_append_buffer(char** target, size_t* target_size, const char* data, size_t data_size) {
    char* next;
    if (data_size == 0) return true;
    next = (char*)realloc(*target, *target_size + data_size + 1);
    if (!next) return false;
    memcpy(next + *target_size, data, data_size);
    *target_size += data_size;
    next[*target_size] = '\0';
    *target = next;
    return true;
}

static bool kano_process_read_fd(int fd,
                                 KanoProcessStream stream,
                                 KanoProcess proc,
                                 char** target,
                                 size_t* target_size) {
    char buffer[4096];
    ssize_t n;

    while (1) {
        n = read(fd, buffer, sizeof(buffer));
        if (n > 0) {
            if (!kano_process_append_buffer(target, target_size, buffer, (size_t)n)) {
                return false;
            }
            if (proc->output_callback) {
                proc->output_callback(stream, buffer, (size_t)n, proc->user_data);
            }
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
}

static bool kano_process_wait_capture(KanoProcess proc, int timeout_ms, KanoProcessResult* out_result) {
    char* stdout_buf = NULL;
    char* stderr_buf = NULL;
    size_t stdout_size = 0;
    size_t stderr_size = 0;
    int stdout_open = (proc->stdout_fd >= 0);
    int stderr_open = (proc->stderr_fd >= 0);
    int process_done = 0;
    int status = 0;
    long long start_ms = kano_process_now_ms();

    while (!process_done || stdout_open || stderr_open) {
        struct pollfd fds[2];
        nfds_t nfds = 0;
        int poll_timeout = 100;
        int poll_rc;
        pid_t waited;

        if (timeout_ms > 0) {
            long long elapsed = kano_process_now_ms() - start_ms;
            long long remaining = (long long)timeout_ms - elapsed;
            if (remaining <= 0 && !process_done) {
                kill(proc->pid, SIGKILL);
                out_result->timed_out = true;
                out_result->exit_code = 124;
                timeout_ms = 0;
            } else if (remaining > 0 && remaining < poll_timeout) {
                poll_timeout = (int)remaining;
            }
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

        if (nfds > 0) {
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
                        if (!kano_process_read_fd(proc->stdout_fd, KANO_PROCESS_STREAM_STDOUT, proc, &stdout_buf, &stdout_size)) {
                            close(proc->stdout_fd);
                            proc->stdout_fd = -1;
                            stdout_open = 0;
                        }
                    }
                    index += 1;
                }
                if (stderr_open) {
                    if (fds[index].revents & (POLLIN | POLLHUP)) {
                        if (!kano_process_read_fd(proc->stderr_fd, KANO_PROCESS_STREAM_STDERR, proc, &stderr_buf, &stderr_size)) {
                            close(proc->stderr_fd);
                            proc->stderr_fd = -1;
                            stderr_open = 0;
                        }
                    }
                }
            }
        }

        if (!process_done) {
            waited = waitpid(proc->pid, &status, WNOHANG);
            if (waited == proc->pid) {
                process_done = 1;
                if (!out_result->timed_out) {
                    out_result->exit_code = kano_process_status_to_exit_code(status);
                }
            }
        }
    }

    out_result->stdout_data = stdout_buf;
    out_result->stderr_data = stderr_buf;
    if (!out_result->timed_out) {
        out_result->exit_code = kano_process_status_to_exit_code(status);
    }
    return true;
}

static bool kano_process_wait_passthrough(KanoProcess proc, int timeout_ms, KanoProcessResult* out_result) {
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
            kill(proc->pid, SIGKILL);
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

        free(argv);
        proc->pid = pid;
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

bool kano_process_wait(KanoProcess proc, int timeout_ms, KanoProcessResult* out_result) {
    if (!proc || !out_result || !proc->spawned) return false;
    memset(out_result, 0, sizeof(*out_result));
#ifdef _WIN32
    DWORD wait_result;
    if (proc->mode == KANO_PROCESS_MODE_CAPTURE) {
        HANDLE readers[2];
        struct KanoReaderContext stdout_ctx;
        struct KanoReaderContext stderr_ctx;
        char* stdout_buf = NULL;
        char* stderr_buf = NULL;
        size_t stdout_size = 0;
        size_t stderr_size = 0;

        stdout_ctx.proc = proc;
        stdout_ctx.handle = proc->stdout_read;
        stdout_ctx.stream = KANO_PROCESS_STREAM_STDOUT;
        stdout_ctx.target = &stdout_buf;
        stdout_ctx.target_size = &stdout_size;
        stderr_ctx.proc = proc;
        stderr_ctx.handle = proc->stderr_read;
        stderr_ctx.stream = KANO_PROCESS_STREAM_STDERR;
        stderr_ctx.target = &stderr_buf;
        stderr_ctx.target_size = &stderr_size;

        readers[0] = CreateThread(NULL, 0, kano_process_reader_thread, &stdout_ctx, 0, NULL);
        readers[1] = CreateThread(NULL, 0, kano_process_reader_thread, &stderr_ctx, 0, NULL);

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
            kano_process_cancel_capture_readers(proc, readers);
        }

        kano_process_join_reader(readers[0]);
        kano_process_join_reader(readers[1]);

        out_result->stdout_data = stdout_buf;
        out_result->stderr_data = stderr_buf;
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
        return kano_process_wait_capture(proc, timeout_ms, out_result);
    }
    return kano_process_wait_passthrough(proc, timeout_ms, out_result);
#endif
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

bool kano_process_run(const char* executable, KanoProcessResult* out_result, ...) {
    KanoProcessOptions options;

    memset(&options, 0, sizeof(options));
    options.executable = executable;
    options.mode = KANO_PROCESS_MODE_CAPTURE;
    return kano_process_run_ex(&options, out_result);
}

bool kano_process_run_ex(const KanoProcessOptions* options, KanoProcessResult* out_result) {
    KanoProcess proc;
    bool ok;

    proc = kano_process_spawn_ex(options);
    if (!proc) return false;
    ok = kano_process_wait(proc, options ? options->timeout_ms : 0, out_result);
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
    return kill(proc->pid, SIGTERM) == 0;
#endif
}
