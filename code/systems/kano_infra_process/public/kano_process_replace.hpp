#pragma once

#include <filesystem>
#include <string>
#include <utility>
#include <vector>

namespace kano::process {

// POSIX only: replace this process directly with no output capture, retaining
// PID and inherited terminal/service streams. Build an inherited environment
// copy; overrides preserve explicitly empty values, and removals erase keys.
// This never mutates the parent/global environment. Failure throws a fixed,
// sanitized runtime_error; Windows explicitly refuses this operation.
[[noreturn]] void ReplaceProcess(
    const std::filesystem::path& InExecutable,
    const std::vector<std::string>& InArguments,
    const std::vector<std::pair<std::string, std::string>>& InOverrides,
    const std::vector<std::string>& InRemoves = {});

} // namespace kano::process
