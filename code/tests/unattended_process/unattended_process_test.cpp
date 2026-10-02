#include <kano_process.h>
#include <kano_unattended.hpp>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <set>
#include <string>
#ifdef _WIN32
#include <windows.h>
#else
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#ifndef KANO_UNATTENDED_CHILD_PATH
#error KANO_UNATTENDED_CHILD_PATH must name the compiled child fixture
#endif

static int Failures = 0;
static void Check(bool condition, const char* message) {
    if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); ++Failures; }
}

static KanoUnattendedProcessResult Run(const char* mode, int timeout_ms = 2000) {
    const char* args[] = {mode};
    KanoUnattendedProcessOptions options{};
    options.executable = KANO_UNATTENDED_CHILD_PATH;
    options.argv = args;
    options.argv_count = 1;
    options.mode = KANO_PROCESS_MODE_CAPTURE;
    options.timeout_ms = timeout_ms;
    options.cleanup_timeout_ms = 700;
    options.capture_limits = {1024, 512};
    KanoUnattendedProcessResult result{};
    const auto started = std::chrono::steady_clock::now();
    const bool ok = kano_process_run_unattended(&options, &result);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    std::printf("case=%s status=%d exit=%d timeout=%d cleanup=%d error=%lu elapsed=%lld bytes=%zu/%zu\n",
                mode, (int)result.status, result.process.exit_code, result.process.timed_out,
                result.cleanup_complete, result.system_error, result.elapsed_ms,
                result.process.stdout_size, result.process.stderr_size);
    Check(ok == (result.status == KANO_UNATTENDED_PROCESS_COMPLETED), "return matches status");
    Check(elapsed < timeout_ms + options.cleanup_timeout_ms + 1000, "bounded execution elapsed");
    Check(result.elapsed_ms >= 0 && result.elapsed_ms <= elapsed + 50, "monotonic diagnostics");
    Check(result.process.stdout_size <= 1024 && result.process.stderr_size <= 512, "bounded capture");
#ifdef _WIN32
    Check(result.containment == KANO_PROCESS_CONTAINMENT_WINDOWS_JOB, "Windows Job established");
#else
    Check(result.containment == KANO_PROCESS_CONTAINMENT_POSIX_GROUP, "POSIX group established");
#endif
    return result;
}

static bool IsAlive(long pid) {
#ifdef _WIN32
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);
    if (!process) return false;
    const bool alive = WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
    CloseHandle(process);
    return alive;
#else
    return kill((pid_t)pid, 0) == 0 || errno == EPERM;
#endif
}

static size_t CheckCapturedProcessesStopped(const KanoUnattendedProcessResult& result) {
    const std::string output = result.process.stdout_data
        ? std::string(result.process.stdout_data, result.process.stdout_size) : "";
    size_t cursor = 0;
    int count = 0;
    std::set<long> unique_pids;
    while ((cursor = output.find("PID:", cursor)) != std::string::npos) {
        const long pid = std::strtol(output.c_str() + cursor + 4, NULL, 10);
        if (pid > 0) {
#ifdef _WIN32
            if (IsAlive(pid)) std::fprintf(stderr, "alive owned PID:%ld captured=%s\n", pid, output.c_str());
            Check(!IsAlive(pid), "owned process stopped");
#else
            /* A zombie may remain until the platform's orphan reaper runs. */
            Check(!IsAlive(pid) || !result.cleanup_complete, "group cleanup diagnostics match liveness");
#endif
            ++count;
            unique_pids.insert(pid);
        }
        cursor += 4;
    }
    Check(count > 0, "fixture published owned process IDs");
    return unique_pids.size();
}

int main() {
    kano::infra::ConfigureUnattendedExecution();
    KanoUnattendedProcessResult result{};
    KanoUnattendedProcessOptions invalid{};
    Check(!kano_process_run_unattended(&invalid, &result), "empty options rejected");
    Check(result.status == KANO_UNATTENDED_PROCESS_INVALID_OPTIONS && result.cleanup_complete,
          "invalid options create no process");
    invalid.executable = KANO_UNATTENDED_CHILD_PATH;
    invalid.timeout_ms = 200;
    invalid.cleanup_timeout_ms = 200;
    invalid.mode = KANO_PROCESS_MODE_CAPTURE;
    Check(!kano_process_run_unattended(&invalid, &result), "unbounded capture rejected");
    invalid.capture_limits = {1024, 512};
    invalid.timeout_ms = 0;
    Check(!kano_process_run_unattended(&invalid, &result), "zero timeout rejected");
    invalid.timeout_ms = 200;
    invalid.cleanup_timeout_ms = 0;
    Check(!kano_process_run_unattended(&invalid, &result), "zero cleanup budget rejected");
    const char* invalid_arg = "unused";
    invalid.cleanup_timeout_ms = 200;
    invalid.argv = &invalid_arg;
    invalid.argv_count = (size_t)-1;
    Check(!kano_process_run_unattended(&invalid, &result), "overflowing argument count rejected");
    kano_process_free_unattended_result(&result);

#ifdef _WIN32
    const char* cmd_args[] = {"/d", "/c", "echo unattended-cmd"};
    KanoUnattendedProcessOptions cmd{};
    cmd.executable = "cmd.exe";
    cmd.argv = cmd_args;
    cmd.argv_count = 3;
    cmd.mode = KANO_PROCESS_MODE_CAPTURE;
    cmd.timeout_ms = 1000;
    cmd.cleanup_timeout_ms = 700;
    cmd.capture_limits = {1024, 512};
    Check(kano_process_run_unattended(&cmd, &result) && result.process.exit_code == 0 &&
          result.cleanup_complete && result.process.stdout_data &&
          std::strstr(result.process.stdout_data, "unattended-cmd"), "cmd payload launch and capture");
    kano_process_free_unattended_result(&result);
#endif

    result = Run("binary");
    Check(result.status == KANO_UNATTENDED_PROCESS_COMPLETED && result.process.exit_code == 0,
          "normal binary child completed");
    Check(result.process.stdout_size == 3 && result.process.stdout_data &&
          std::memcmp(result.process.stdout_data, "a\0b", 3) == 0, "binary bytes retained");
    Check(result.cleanup_complete, "normal cleanup confirmed");
    kano_process_free_unattended_result(&result);

    const char* passthrough_args[] = {"exit-7"};
    KanoUnattendedProcessOptions passthrough{};
    passthrough.executable = KANO_UNATTENDED_CHILD_PATH;
    passthrough.argv = passthrough_args;
    passthrough.argv_count = 1;
    passthrough.mode = KANO_PROCESS_MODE_PASS_THROUGH;
    passthrough.timeout_ms = 1000;
    passthrough.cleanup_timeout_ms = 700;
    Check(kano_process_run_unattended(&passthrough, &result) && result.process.exit_code == 7 &&
          result.cleanup_complete && !result.process.stdout_data, "finite passthrough child completion");
    kano_process_free_unattended_result(&result);
    result = Run("exit-7");
    Check(result.status == KANO_UNATTENDED_PROCESS_COMPLETED && result.process.exit_code == 7,
          "child failure is distinct from runner failure");
    kano_process_free_unattended_result(&result);
    result = Run("noisy");
    Check(result.status == KANO_UNATTENDED_PROCESS_COMPLETED, "noisy child drained");
    Check(result.process.stdout_truncated && result.process.stderr_truncated, "both capture limits reported");
    kano_process_free_unattended_result(&result);

#ifdef _WIN32
    std::string sentinel_command = std::string("\"") + KANO_UNATTENDED_CHILD_PATH + "\" hang";
    STARTUPINFOA startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION sentinel{};
    Check(CreateProcessA(NULL, &sentinel_command[0], NULL, NULL, FALSE, CREATE_NO_WINDOW,
                         NULL, NULL, &startup, &sentinel) != FALSE, "sentinel launched outside Job");
    const long sentinel_pid = (long)sentinel.dwProcessId;
#else
    const pid_t sentinel_pid = fork();
    if (sentinel_pid == 0) { execl(KANO_UNATTENDED_CHILD_PATH, KANO_UNATTENDED_CHILD_PATH, "hang", (char*)NULL); _exit(127); }
    Check(sentinel_pid > 0, "sentinel launched outside group");
#endif
    for (const char* mode : {"hang", "tree"}) {
        result = Run(mode, 250);
        Check(result.process.timed_out && result.process.exit_code == 124, "hung tree timeout classified");
        Check(result.status != KANO_UNATTENDED_PROCESS_COMPLETED, "timeout never reports success");
#ifdef _WIN32
        Check(result.cleanup_complete, "hung tree cleanup confirmed");
        Check(result.status == KANO_UNATTENDED_PROCESS_TIMED_OUT, "timeout status distinct from cleanup failure");
#endif
        const size_t owned_count = CheckCapturedProcessesStopped(result);
        if (!std::strcmp(mode, "tree")) Check(owned_count >= 3, "child and grandchild fixture observed");
        Check(IsAlive((long)sentinel_pid), "unrelated sentinel survives owned cleanup");
        kano_process_free_unattended_result(&result);
    }
    for (const char* mode : {"early-exit", "early-closed"}) {
        result = Run(mode);
#ifdef _WIN32
        Check(result.status == KANO_UNATTENDED_PROCESS_COMPLETED && result.cleanup_complete,
              "early root exit still cleans descendants");
#else
        Check(result.status == KANO_UNATTENDED_PROCESS_COMPLETED ||
              result.status == KANO_UNATTENDED_PROCESS_CLEANUP_FAILED, "early cleanup classified");
#endif
        CheckCapturedProcessesStopped(result);
        Check(IsAlive((long)sentinel_pid), "sentinel survives early-exit cleanup");
        kano_process_free_unattended_result(&result);
    }
#ifdef _WIN32
    if (sentinel.hProcess) { TerminateProcess(sentinel.hProcess, 0); WaitForSingleObject(sentinel.hProcess, 1000); CloseHandle(sentinel.hProcess); }
    if (sentinel.hThread) CloseHandle(sentinel.hThread);
#else
    if (sentinel_pid > 0) { kill(sentinel_pid, SIGKILL); waitpid(sentinel_pid, NULL, 0); }
    result = Run("escaped-writer");
    Check(result.status == KANO_UNATTENDED_PROCESS_CLEANUP_FAILED && !result.cleanup_complete,
          "escaped inherited writer cannot claim containment cleanup");
    kano_process_free_unattended_result(&result);
#endif

    const std::string marker = std::string(KANO_UNATTENDED_CHILD_PATH) + ".containment-marker";
    std::remove(marker.c_str());
    const char* mark_args[] = {"mark", marker.c_str()};
    KanoUnattendedProcessOptions setup{};
    setup.executable = KANO_UNATTENDED_CHILD_PATH;
    setup.argv = mark_args;
    setup.argv_count = 2;
    setup.mode = KANO_PROCESS_MODE_CAPTURE;
    setup.timeout_ms = 1000;
    setup.cleanup_timeout_ms = 700;
    setup.capture_limits = {1024, 512};
    kano_process_test_fail_next_containment_setup();
    Check(!kano_process_run_unattended(&setup, &result), "injected setup failure rejected");
    Check(result.status == KANO_UNATTENDED_PROCESS_CONTAINMENT_FAILED && result.cleanup_complete,
          "containment setup fails closed and cleans suspended root");
    FILE* unexpected_marker = std::fopen(marker.c_str(), "rb");
    Check(unexpected_marker == NULL, "payload never executed after failed setup");
    if (unexpected_marker) { std::fclose(unexpected_marker); std::remove(marker.c_str()); }
    kano_process_free_unattended_result(&result);
    setup.executable = "kano-nonexistent-test-executable-0017";
    Check(!kano_process_run_unattended(&setup, &result) &&
          result.status == KANO_UNATTENDED_PROCESS_LAUNCH_FAILED, "spawn failure distinct from completion");
    kano_process_free_unattended_result(&result);

    KanoProcessOptions legacy{};
    legacy.executable = KANO_UNATTENDED_CHILD_PATH;
    legacy.mode = KANO_PROCESS_MODE_CAPTURE;
    legacy.timeout_ms = 0;
    KanoProcessResultV2 legacy_result{};
    KanoProcessCaptureLimitsV2 limits{1024, 512};
    Check(kano_process_run_ex_v2(&legacy, &limits, &legacy_result) && !legacy_result.timed_out &&
          legacy_result.exit_code == 0, "legacy timeout zero preserved");
    kano_process_free_result_v2(&legacy_result);
    std::printf("unattended process checks: %s\n", Failures ? "FAILED" : "passed");
    return Failures ? 1 : 0;
}
