#include "kano_process_replace.hpp"
#include <kano_local_path.hpp>
#include <algorithm>
#include <set>
#include <stdexcept>
#ifndef _WIN32
#include <unistd.h>
extern char** environ;
#endif

namespace kano::process {
namespace {
[[noreturn]] void Fail() { throw std::runtime_error("Direct process replacement is unavailable or failed."); }
bool Key(const std::string& InValue) {
    if (InValue.empty()) return false;
    const auto start = [](unsigned char value) { return (value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z') || value == '_'; };
    if (!start(static_cast<unsigned char>(InValue.front()))) return false;
    return std::all_of(InValue.begin(), InValue.end(), [&](unsigned char value) { return start(value) || (value >= '0' && value <= '9'); });
}
}
[[noreturn]] void ReplaceProcess(const std::filesystem::path& InExecutable,
    const std::vector<std::string>& InArguments,
    const std::vector<std::pair<std::string, std::string>>& InOverrides,
    const std::vector<std::string>& InRemoves) {
#ifdef _WIN32
    (void)InExecutable; (void)InArguments; (void)InOverrides; (void)InRemoves;
    Fail();
#else
    std::filesystem::path path;
    try { path = kano::platform::LocalPath(InExecutable); } catch (...) { Fail(); }
    if (!std::filesystem::is_regular_file(path) || access(path.c_str(), X_OK) != 0) Fail();
    std::set<std::string> replaced;
    for (const auto& key : InRemoves) { if (!Key(key)) Fail(); replaced.insert(key); }
    std::set<std::string> overrides;
    for (const auto& [key, value] : InOverrides) {
        if (!Key(key) || value.find('\0') != std::string::npos || !overrides.insert(key).second) Fail();
        replaced.insert(key);
    }
    for (const auto& argument : InArguments) if (argument.find('\0') != std::string::npos) Fail();
    std::vector<std::string> environment;
    for (auto entry = environ; entry && *entry; ++entry) {
        std::string value(*entry);
        if (!replaced.count(value.substr(0, value.find('=')))) environment.push_back(std::move(value));
    }
    for (const auto& [key, value] : InOverrides) environment.push_back(key + "=" + value);
    auto executable = kano::platform::PathUtf8(path);
    std::vector<char*> argv{executable.data()}, envp;
    for (const auto& argument : InArguments) argv.push_back(const_cast<char*>(argument.c_str()));
    for (auto& value : environment) envp.push_back(value.data());
    argv.push_back(nullptr); envp.push_back(nullptr);
    execve(executable.c_str(), argv.data(), envp.data());
    Fail();
#endif
}
} // namespace kano::process
