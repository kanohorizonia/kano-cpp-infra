#include <cstdio>
#include <cstring>
#include <string>
#ifdef _WIN32
#include <windows.h>
#else
#include <signal.h>
#include <sys/types.h>
#include <unistd.h>
#endif

static void SleepMs(unsigned int ms) {
#ifdef _WIN32
    Sleep(ms);
#else
    usleep(ms * 1000);
#endif
}

static long Spawn(const char* executable, const char* mode, bool inherit_capture = true) {
#ifdef _WIN32
    std::string command = std::string("\"") + executable + "\" " + mode;
    STARTUPINFOA startup{};
    startup.cb = sizeof(startup);
    if (inherit_capture) {
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
        startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
        startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    }
    PROCESS_INFORMATION process{};
    if (!CreateProcessA(NULL, &command[0], NULL, NULL, inherit_capture ? TRUE : FALSE,
                        CREATE_NO_WINDOW, NULL, NULL, &startup, &process)) return -1;
    const long pid = (long)process.dwProcessId;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return pid;
#else
    const pid_t pid = fork();
    if (pid == 0) {
        if (!inherit_capture) { close(STDOUT_FILENO); close(STDERR_FILENO); }
        execl(executable, executable, mode, (char*)NULL);
        _exit(127);
    }
    return (long)pid;
#endif
}

int main(int argc, char** argv) {
    const char* mode = argc > 1 ? argv[1] : "binary";
#ifdef _WIN32
    const long pid = (long)GetCurrentProcessId();
#else
    const long pid = (long)getpid();
#endif
    if (!std::strcmp(mode, "binary")) {
        const char bytes[] = {'a', '\0', 'b'};
        std::fwrite(bytes, 1, sizeof(bytes), stdout);
        std::fwrite("err", 1, 3, stderr);
        return 0;
    }
    if (!std::strcmp(mode, "exit-7")) return 7;
    if (!std::strcmp(mode, "mark")) {
        if (argc < 3) return 2;
        FILE* marker = std::fopen(argv[2], "wb");
        if (!marker) return 3;
        std::fputs("payload executed\n", marker);
        std::fclose(marker);
        return 0;
    }
    if (!std::strcmp(mode, "noisy")) {
        char bytes[8192];
        std::memset(bytes, 'x', sizeof(bytes));
        for (int i = 0; i < 128; ++i) {
            std::fwrite(bytes, 1, sizeof(bytes), stdout);
            std::fwrite(bytes, 1, sizeof(bytes), stderr);
        }
        return 0;
    }
    if (!std::strcmp(mode, "tree") || !std::strcmp(mode, "tree-leaf") ||
        !std::strcmp(mode, "early-exit") || !std::strcmp(mode, "early-closed")) {
        const long child = Spawn(argv[0], !std::strcmp(mode, "tree") ? "tree-leaf" : "hang",
                                 std::strcmp(mode, "early-closed") != 0);
        if (child <= 0) return 4;
        std::printf("PID:%ld\n", child);
        std::fflush(stdout);
        if (!std::strcmp(mode, "early-exit") || !std::strcmp(mode, "early-closed")) return 0;
    }
#ifndef _WIN32
    if (!std::strcmp(mode, "escaped-writer")) {
        const pid_t child = fork();
        if (child < 0) return 4;
        if (child == 0) {
            if (setsid() < 0) _exit(5);
            std::printf("ESCAPED_PID:%ld\n", (long)getpid());
            std::fflush(stdout);
            SleepMs(2000); /* bounded fixture, outside process-group ownership */
            _exit(0);
        }
        SleepMs(100); /* ensure the child escapes before the leader exits */
        return 0;
    }
#endif
    std::printf("PID:%ld\n", pid);
    std::fflush(stdout);
    SleepMs(20000); /* fixture self-limit protects failed test invocations */
    return 0;
}
