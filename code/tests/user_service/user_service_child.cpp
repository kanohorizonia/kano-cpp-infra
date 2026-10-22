#include <kano_file_lock.hpp>
#include <kano_process_replace.hpp>
#include <kano_unattended.hpp>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <string>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

namespace {
void ReportEnvironment() {
    for (const char* name : {"KANO_REPLACE_INHERITED", "KANO_REPLACE_OVERRIDE",
                            "KANO_REPLACE_EMPTY", "KANO_REPLACE_REMOVED"}) {
        const char* value = std::getenv(name);
        std::printf("%s=%s%s\n", name, value ? "value:" : "absent", value ? value : "");
    }
}
unsigned long long ProcessId() {
#ifdef _WIN32
    return GetCurrentProcessId();
#else
    return static_cast<unsigned long long>(getpid());
#endif
}
}

int main(int argc, char** argv) {
    kano::infra::ConfigureUnattendedExecution();
    if (argc < 2) return 2;
    const std::string mode(argv[1]);
    try {
        if (mode == "probe-lock") {
            if (argc != 3) return 2;
            const auto lock = kano::platform::ExclusiveFileLock::TryAcquire(argv[2]);
            std::puts(lock ? "acquired" : "busy");
            return 0;
        }
#ifndef _WIN32
        if (mode == "inherit-lock") {
            if (argc != 3) return 2;
            auto lock = kano::platform::ExclusiveFileLock::TryAcquire(argv[2], true);
            if (!lock) return 3;
            kano::process::ReplaceProcess(std::filesystem::absolute(argv[0]),
                {"hold-inherited-lock", argv[2]}, {}, {});
        }
        if (mode == "hold-inherited-lock") {
            if (argc != 3) return 2;
            const auto lock = kano::platform::ExclusiveFileLock::TryAcquire(argv[2]);
            std::printf("inherited=%s\npid=%llu\n", lock ? "missing" : "held", ProcessId());
            std::fflush(stdout);
            char input[16];
            while (std::fgets(input, sizeof(input), stdin)) {}
            return lock ? 4 : 0;
        }
        if (mode == "replace-environment") {
            kano::process::ReplaceProcess(std::filesystem::absolute(argv[0]), {"environment"},
                {{"KANO_REPLACE_OVERRIDE", "child-value"}, {"KANO_REPLACE_EMPTY", ""}},
                {"KANO_REPLACE_REMOVED"});
        }
#endif
        if (mode == "environment") {
            std::printf("pid=%llu\n", ProcessId());
            ReportEnvironment();
            return 0;
        }
        if (mode == "fast-output") {
            std::fputs("fast-stdout-metadata\n", stdout);
            std::fputs("fast-stderr-diagnostic\n", stderr);
            return 7;
        }
        if (mode == "hanging-output") {
            std::puts("owned-hanging-helper");
            std::fflush(stdout);
            char input[16];
            while (std::fgets(input, sizeof(input), stdin)) {}
            return 0;
        }
    } catch (const std::exception&) {
        std::fputs("Controlled child failed.\n", stderr);
        return 5;
    }
    return 2;
}
