#include <kano_process_session.hpp>
#include <kano_unattended.hpp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#ifdef _WIN32
#include <windows.h>

int main(int argc, char** argv) {
    kano::infra::ConfigureUnattendedExecution();
    const std::string mode = argc > 1 ? argv[1] : "echo";
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
int main() { kano::infra::ConfigureUnattendedExecution(); return 0; }
#endif
