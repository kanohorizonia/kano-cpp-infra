#include "kano_process.h"
#include "kano_unattended.hpp"

#include <cstdio>
#include <cstring>
#include <string>

int main(int argc, char** argv) {
    kano::infra::ConfigureUnattendedExecution();
    if (argc != 4) {
        std::fputs("Usage: unattended_harness <fixture> <mode> <diagnostic>\n", stderr);
        return 2;
    }
    const char* arguments[] = {argv[2]};
    KanoUnattendedProcessOptions options{};
    options.executable = argv[1];
    options.argv = arguments;
    options.argv_count = 1;
    options.mode = KANO_PROCESS_MODE_CAPTURE;
    options.timeout_ms = 3000;
    options.cleanup_timeout_ms = 1000;
    options.capture_limits = {65536, 65536};
    KanoUnattendedProcessResult result{};
    const bool completed = kano_process_run_unattended(&options, &result);
    const bool normal = std::strcmp(argv[2], "normal") == 0;
    const std::string diagnostic = normal
        ? std::string(result.process.stdout_data ? result.process.stdout_data : "", result.process.stdout_size)
        : std::string(result.process.stderr_data ? result.process.stderr_data : "", result.process.stderr_size);
    const bool passed = completed && result.status == KANO_UNATTENDED_PROCESS_COMPLETED &&
        result.cleanup_complete && !result.process.timed_out &&
        result.containment != KANO_PROCESS_CONTAINMENT_NONE &&
        (normal ? result.process.exit_code == 0 : result.process.exit_code != 0) &&
        diagnostic.find(argv[3]) != std::string::npos;
    std::fprintf(stderr, "mode=%s completed=%d status=%d exit=%d cleanup=%d elapsed_ms=%lld\n",
                 argv[2], completed, static_cast<int>(result.status), result.process.exit_code,
                 result.cleanup_complete, result.elapsed_ms);
    if (!passed) {
        std::fwrite(diagnostic.data(), 1, diagnostic.size(), stderr);
    }
    kano_process_free_unattended_result(&result);
    return passed ? 0 : 1;
}
