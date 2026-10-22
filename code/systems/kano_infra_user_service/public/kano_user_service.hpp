#pragma once

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace kano::service {

enum class Backend { LaunchAgent, SystemdUser };
enum class State { Absent, Stopped, Running };

struct Definition {
    Backend backend = Backend::LaunchAgent;
    std::string identity;
    std::filesystem::path artifact;
    std::filesystem::path executable;
    std::filesystem::path working_directory;
    std::vector<std::string> arguments; // excludes executable
    unsigned uid = 0;
};

struct Observation {
    State state = State::Absent;
    std::uint64_t pid = 0;
};

struct Result { int exit_code = -1; std::string output; };

// Defaults use a contained Session and a monotonic clock. Subclasses allow
// controlled command/state fixtures without invoking a host service manager.
class Runtime {
public:
    virtual ~Runtime() = default;
    virtual Result Run(const std::filesystem::path& InExecutable,
                       const std::vector<std::string>& InArguments, int InBudgetMs);
    virtual std::chrono::steady_clock::time_point Now();
    virtual void Sleep(int InMilliseconds);
};

// Render does not write. Every operation validates the artifact, when present,
// and loaded source/program/argv ownership. Indeterminate states throw a fixed,
// sanitized runtime_error. The caller creates/removes its private artifact.
std::string Render(const Definition& InDefinition);
Observation Inspect(const Definition& InDefinition, Runtime& InRuntime, int InBudgetMs);
void Register(const Definition& InDefinition, Runtime& InRuntime, int InBudgetMs);
void Restart(const Definition& InDefinition, Runtime& InRuntime, int InBudgetMs);
// Stop confirms unloaded/inactive state before returning. It never removes the
// artifact; a caller may remove its artifact only after this succeeds.
void Stop(const Definition& InDefinition, Runtime& InRuntime, int InBudgetMs);

} // namespace kano::service
