#include <kano_process_session.hpp>
#include <kano_unattended.hpp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#ifdef _WIN32
#include <windows.h>
#endif

static int ReportEnvironment(FILE* InOutput) {
    const char* names[] = {"KANO_SESSION_TEST_INHERITED", "KANO_SESSION_TEST_OVERRIDE",
        "KANO_SESSION_TEST_REMOVED", "KANO_SESSION_TEST_EMPTY", "FORWARDED_ALLOW_IPS"};
    for (const char* name : names) {
#ifdef _WIN32
        // Query the OS block directly: an empty variable is distinct from an
        // absent one, independently of CRT environment initialization.
        char value[256]{};
        SetLastError(ERROR_SUCCESS);
        const DWORD length = GetEnvironmentVariableA(name, value, sizeof(value));
        if (length >= sizeof(value)) return 8;
        const bool present = length || GetLastError() != ERROR_ENVVAR_NOT_FOUND;
        std::fprintf(InOutput, "%s=%s%s\n", name, present ? "value:" : "absent", present ? value : "");
#else
        const char* value = std::getenv(name);
        std::fprintf(InOutput, "%s=%s%s\n", name, value ? "value:" : "absent", value ? value : "");
#endif
    }
    return std::fflush(InOutput) == 0 ? 0 : 9;
}

#ifdef _WIN32
int main(int argc, char** argv) {
    kano::infra::ConfigureUnattendedExecution();
    const std::string mode = argc > 1 ? argv[1] : "echo";
    if (mode == "environment-policy") return ReportEnvironment(stdout);
    if (mode == "environment-file") {
        if (argc != 3) return 2;
        FILE* file = nullptr;
        if (fopen_s(&file, argv[2], "wb") || !file) return 3;
        const int result = ReportEnvironment(file);
        return std::fclose(file) == 0 ? result : 4;
    }
    if (mode == "leaf") { Sleep(60000); return 0; }
    if (mode == "detached-leaf") { Sleep(5000); return 0; }
    if (mode == "exit-7") { std::fputs("controlled startup cause\n", stderr); return 7; }
    if (mode == "mark") {
        FILE* file = nullptr; fopen_s(&file, argv[2], "wb");
        if (file) { std::fputs("executed", file); std::fclose(file); }
        return 0;
    }
    if (mode == "no-read") { std::puts("ready"); std::fflush(stdout); Sleep(60000); return 0; }
    if (mode == "environment") {
        const char* value = std::getenv("KANO_SESSION_TEST_OVERRIDE");
        std::printf("override=%s\n", value ? value : "absent");
        return 0;
    }
    if (mode == "tree") {
        std::string command = std::string("\"") + argv[0] + "\" leaf";
        STARTUPINFOA startup{}; startup.cb = sizeof(startup);
        PROCESS_INFORMATION child{};
        if (!CreateProcessA(nullptr, &command[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
            nullptr, nullptr, &startup, &child)) return 3;
        std::printf("tree=%lu,%lu\n", GetCurrentProcessId(), child.dwProcessId); std::fflush(stdout);
        CloseHandle(child.hThread); CloseHandle(child.hProcess);
        Sleep(60000); return 0;
    }
    if (mode == "owner") {
        kano::process::Session child;
        kano::process::SessionOptions options;
        options.executable = argv[0]; options.arguments = {"tree"};
        if (!child.Start(options).ok) return 4;
        const auto deadline = GetTickCount64() + 5000;
        while (GetTickCount64() < deadline) {
            auto output = child.Poll(50);
            if (!output.stdout_data.empty()) {
                std::fwrite(output.stdout_data.data(), 1, output.stdout_data.size(), stdout);
                std::fflush(stdout); Sleep(60000); return 0;
            }
        }
        return 5;
    }
    if (mode == "detached-check") {
        kano::process::SessionOptions options;
        options.executable = argv[0]; options.arguments = {"detached-leaf"};
        auto launched = kano::process::LaunchDetached(options);
        std::printf("detached=%llu\n", (unsigned long long)launched.identity.pid); std::fflush(stdout);
        return launched.ok ? 0 : 6;
    }
    if (mode == "noise") {
        const std::string noise(4096, 'e');
        for (int i = 0; i < 512; ++i) std::fwrite(noise.data(), 1, noise.size(), stderr);
        std::fflush(stderr);
    }
    std::puts("ready"); std::fflush(stdout);
    char line[4096];
    while (std::fgets(line, sizeof(line), stdin)) {
        if (!std::strcmp(line, "shutdown\n")) { std::puts("stopped"); std::fflush(stdout); return 0; }
        if (!std::strcmp(line, "cancel\n")) std::puts("cancelled");
        else std::fputs(line, stdout);
        std::fflush(stdout);
    }
    std::puts("eof"); std::fflush(stdout);
    return 0;
}
#else
#include <kano_process.h>
#include <cerrno>
#include <chrono>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <sys/types.h>
#include <unistd.h>

static bool ClosedStandardDescriptors(int InMask) {
    for (int descriptor = 0; descriptor < 3; ++descriptor) {
        if (!(InMask & (1 << descriptor))) continue;
        errno = 0;
        if (fcntl(descriptor, F_GETFD) != -1 || errno != EBADF) return false;
    }
    return true;
}

static int StandardDescriptorProbe(bool InReadInput) {
    for (int descriptor = InReadInput ? 0 : 1; descriptor < 3; ++descriptor) {
        const int flags = fcntl(descriptor, F_GETFD);
        if (flags < 0 || (flags & FD_CLOEXEC)) return 10 + descriptor;
    }
    std::puts("stdio-out-ready"); std::fflush(stdout);
    std::fputs("stdio-err-ready\n", stderr); std::fflush(stderr);
    if (!InReadInput) return 0;
    char input[64];
    if (!std::fgets(input, sizeof(input), stdin) || std::strcmp(input, "stdio-known-input\n")) return 13;
    std::puts("stdio-input-ok"); std::fflush(stdout);
    std::fputs("stdio-response-ok\n", stderr); std::fflush(stderr);
    return 0;
}

static bool SessionProbeOutput(kano::process::Session& InSession, std::string& OutStdout,
                               std::string& OutStderr, bool InRequireExit) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    const char* expectedOut = InRequireExit ? "stdio-input-ok\n" : "stdio-out-ready\n";
    const char* expectedErr = InRequireExit ? "stdio-response-ok\n" : "stdio-err-ready\n";
    while (std::chrono::steady_clock::now() < deadline) {
        const auto result = InSession.Poll(20);
        if (!result.ok || result.stdout_truncated || result.stderr_truncated ||
            result.stdout_data.size() > 1024 || result.stderr_data.size() > 512) return false;
        OutStdout += result.stdout_data; OutStderr += result.stderr_data;
        const bool observed = OutStdout.find(expectedOut) != std::string::npos &&
            OutStderr.find(expectedErr) != std::string::npos;
        if (observed && (!InRequireExit || (!result.running && result.exit_code == 0))) return true;
        if (!result.running) return false;
    }
    return false;
}

static bool CapturedProbeOutput(const KanoProcessResultV2& InResult) {
    return InResult.exit_code == 0 && !InResult.timed_out &&
        !InResult.stdout_truncated && !InResult.stderr_truncated &&
        InResult.stdout_data && InResult.stderr_data &&
        std::string(InResult.stdout_data, InResult.stdout_size) == "stdio-out-ready\n" &&
        std::string(InResult.stderr_data, InResult.stderr_size) == "stdio-err-ready\n";
}

static int ClosedStdioOwner(const char* InExecutable, const char* InMaskText) {
    char* end = nullptr;
    const long mask = std::strtol(InMaskText, &end, 10);
    if (!end || *end || mask < 1 || mask > 7) return 20;
    std::fflush(nullptr);
    for (int descriptor = 0; descriptor < 3; ++descriptor)
        if (mask & (1 << descriptor)) close(descriptor);
    if (!ClosedStandardDescriptors((int)mask)) return 21;

    kano::process::Session session;
    kano::process::SessionOptions options;
    options.executable = InExecutable; options.arguments = {"stdio-probe"};
    options.startup_timeout_ms = 2000; options.cleanup_timeout_ms = 700;
    options.stdout_max_bytes = 1024; options.stderr_max_bytes = 512;
    if (!session.Start(options).ok) return 30;
    if (!ClosedStandardDescriptors((int)mask)) return 31;
    std::string output, diagnostic;
    if (!SessionProbeOutput(session, output, diagnostic, false)) return 32;
    if (!session.Write("stdio-known-input\n", 500).ok) return 33;
    if (!ClosedStandardDescriptors((int)mask)) return 34;
    if (!SessionProbeOutput(session, output, diagnostic, true)) return 35;
    const auto closed = session.Close();
    if (!closed.ok || !closed.cleanup_complete || closed.running) return 36;
    if (!ClosedStandardDescriptors((int)mask)) return 37;

    const char* captureArguments[] = {"stdio-output"};
    KanoUnattendedProcessOptions strict{};
    strict.executable = InExecutable; strict.argv = captureArguments; strict.argv_count = 1;
    strict.mode = KANO_PROCESS_MODE_CAPTURE; strict.timeout_ms = 2000;
    strict.cleanup_timeout_ms = 700; strict.capture_limits = {1024, 512};
    KanoUnattendedProcessResult strictResult{};
    const bool strictOk = kano_process_run_unattended(&strict, &strictResult);
    const bool strictOutput = CapturedProbeOutput(strictResult.process);
    const bool strictCleanup = strictResult.cleanup_complete;
    kano_process_free_unattended_result(&strictResult);
    if (!strictOk) return 40;
    if (!strictOutput) return 41;
    if (!strictCleanup) return 42;
    if (!ClosedStandardDescriptors((int)mask)) return 43;

    KanoProcessOptions legacy{};
    legacy.executable = InExecutable; legacy.argv = captureArguments; legacy.argv_count = 1;
    legacy.mode = KANO_PROCESS_MODE_CAPTURE; legacy.timeout_ms = 2000;
    const KanoProcessCaptureLimitsV2 limits{1024, 512};
    KanoProcessResultV2 legacyResult{};
    const bool legacyOk = kano_process_run_ex_v2(&legacy, &limits, &legacyResult);
    const bool legacyOutput = CapturedProbeOutput(legacyResult);
    kano_process_free_result_v2(&legacyResult);
    if (!legacyOk) return 50;
    if (!legacyOutput) return 51;
    if (!ClosedStandardDescriptors((int)mask)) return 52;

    const char* passThroughArguments[] = {"stdio-inherited", InMaskText};
    strict.argv = passThroughArguments; strict.argv_count = 2;
    strict.mode = KANO_PROCESS_MODE_PASS_THROUGH;
    const bool passThroughOk = kano_process_run_unattended(&strict, &strictResult);
    const bool passThroughExit = strictResult.process.exit_code == 0;
    const bool passThroughCleanup = strictResult.cleanup_complete;
    const bool passThroughNoCapture = !strictResult.process.stdout_data && !strictResult.process.stderr_data;
    kano_process_free_unattended_result(&strictResult);
    if (!passThroughOk) return 60;
    if (!passThroughExit) return 61;
    if (!passThroughCleanup || !passThroughNoCapture) return 62;
    if (!ClosedStandardDescriptors((int)mask)) return 63;
    return 0;
}

static std::string Hex(const std::string& InText) {
    static const char digits[] = "0123456789abcdef";
    std::string result;
    for (const unsigned char value : InText) {
        result.push_back(digits[value >> 4]);
        result.push_back(digits[value & 15]);
    }
    return result;
}

static void ReportContext(int InArgc, char** InArgv) {
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) std::exit(8);
    std::printf("cwd=%s\n", Hex(cwd).c_str());
    std::printf("argc=%d\n", InArgc - 2);
    for (int index = 2; index < InArgc; ++index)
        std::printf("arg%d=%s\n", index - 2, Hex(InArgv[index]).c_str());
    const char* names[] = {"KANO_SESSION_TEST_INHERITED", "KANO_SESSION_TEST_OVERRIDE",
        "KANO_SESSION_TEST_REMOVED", "KANO_SESSION_TEST_CASE", "kano_session_test_case"};
    for (const char* name : names) {
        const char* value = std::getenv(name);
        std::printf("env:%s=%s\n", name, value ? Hex(value).c_str() : "absent");
    }
    std::fflush(stdout);
}

int main(int argc, char** argv) {
    kano::infra::ConfigureUnattendedExecution();
    alarm(12); // A failed test cannot leave an unbounded fixture alive.
    const std::string mode = argc > 1 ? argv[1] : "echo";
    if (mode == "environment-policy") return ReportEnvironment(stdout);
    if (mode == "stdio-probe") return StandardDescriptorProbe(true);
    if (mode == "stdio-output") return StandardDescriptorProbe(false);
    if (mode == "closed-stdio-owner") return argc == 3 ? ClosedStdioOwner(argv[0], argv[2]) : 19;
    if (mode == "stdio-inherited") {
        if (argc != 3) return 14;
        char* end = nullptr;
        const long mask = std::strtol(argv[2], &end, 10);
        if (!end || *end || mask < 1 || mask > 7) return 15;
        return ClosedStandardDescriptors((int)mask) ? 0 : 16;
    }
    if (mode == "exit-7") { std::fputs("controlled startup cause\n", stderr); return 7; }
    if (mode == "mark") {
        if (argc < 3) return 2;
        FILE* file = std::fopen(argv[2], "wb");
        if (!file) return 3;
        std::fputs("executed", file); std::fclose(file);
        return 0;
    }
    if (mode == "no-read" || mode == "closed-input") {
        if (mode == "closed-input") close(STDIN_FILENO);
        std::puts("ready"); std::fflush(stdout);
        for (;;) pause();
    }
    if (mode == "tree") {
        const pid_t leaf = fork();
        if (leaf < 0) return 4;
        if (!leaf) { alarm(12); for (;;) pause(); }
        std::printf("tree=%ld,%ld\n", (long)getpid(), (long)leaf); std::fflush(stdout);
        for (;;) pause();
    }
    if (mode == "escaped-writer") {
        int ready[2];
        if (pipe(ready)) return 4;
        const pid_t leaf = fork();
        if (leaf < 0) { close(ready[0]); close(ready[1]); return 4; }
        if (!leaf) {
            close(ready[0]); close(STDIN_FILENO);
            alarm(3);
            if (setsid() < 0) _exit(5);
            const char readyByte = 'r';
            if (write(ready[1], &readyByte, 1) != 1) _exit(6);
            close(ready[1]);
            usleep(2000000); // Retain inherited capture writers outside the owned group.
            _exit(0);
        }
        close(ready[1]);
        char readyByte = 0;
        const auto received = read(ready[0], &readyByte, 1);
        close(ready[0]);
        if (received != 1 || readyByte != 'r') return 7;
        std::printf("escaped=%ld\n", (long)leaf); std::fflush(stdout);
    }
    if (mode == "context") ReportContext(argc, argv);
    if (mode == "noise") {
        const std::string noise(4096, 'e');
        for (int index = 0; index < 512; ++index)
            std::fwrite(noise.data(), 1, noise.size(), stderr);
        std::fflush(stderr);
    }
    std::puts("ready"); std::fflush(stdout);
    char line[4096];
    while (std::fgets(line, sizeof(line), stdin)) {
        if (!std::strcmp(line, "shutdown\n")) { std::puts("stopped"); std::fflush(stdout); return 0; }
        if (!std::strcmp(line, "cancel\n")) std::puts("cancelled");
        else std::fputs(line, stdout);
        std::fflush(stdout);
    }
    std::puts("eof"); std::fflush(stdout);
    return 0;
}
#endif
