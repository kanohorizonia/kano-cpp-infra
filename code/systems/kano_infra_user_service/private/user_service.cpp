#include "kano_user_service.hpp"
#include <kano_local_path.hpp>
#include <kano_process_session.hpp>
#include <algorithm>
#include <cctype>
#include <fstream>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <thread>

namespace kano::service {
namespace {
using Clock = std::chrono::steady_clock;
namespace fs = std::filesystem;
[[noreturn]] void Fail() { throw std::runtime_error("User service state or ownership could not be confirmed."); }
[[noreturn]] void Deadline() { throw std::runtime_error("User service operation deadline exceeded."); }
std::string Bytes(const fs::path& InPath) { const auto bytes = InPath.generic_u8string(); return {bytes.begin(), bytes.end()}; }
bool Text(const std::string& InText) {
    return !InText.empty() && std::none_of(InText.begin(), InText.end(), [](unsigned char value) { return value < 32 || value == 127; });
}
bool LinuxToken(const std::string& InText) {
    return Text(InText) && std::all_of(InText.begin(), InText.end(), [](unsigned char value) {
        return std::isalnum(value) || std::string("/_-.:=@+").find(static_cast<char>(value)) != std::string::npos;
    });
}
void Validate(const Definition& InDefinition) {
    if (InDefinition.identity.empty() || InDefinition.identity.size() > 240 ||
        !std::all_of(InDefinition.identity.begin(), InDefinition.identity.end(), [](unsigned char value) {
            return std::isalnum(value) || value == '.' || value == '-' || value == '_';
        }) || InDefinition.identity.front() == '.' || InDefinition.identity.front() == '-') Fail();
    for (const auto& path : {InDefinition.artifact, InDefinition.executable, InDefinition.working_directory}) {
        if (!Text(Bytes(path))) Fail();
        kano::platform::LocalPath(path);
    }
    for (const auto& argument : InDefinition.arguments) if (!Text(argument)) Fail();
    if (InDefinition.backend == Backend::SystemdUser) {
        if (InDefinition.identity.size() < 9 || InDefinition.identity.substr(InDefinition.identity.size() - 8) != ".service") Fail();
        for (const auto& path : {InDefinition.artifact, InDefinition.executable, InDefinition.working_directory}) if (!LinuxToken(Bytes(path))) Fail();
        for (const auto& argument : InDefinition.arguments) if (!LinuxToken(argument)) Fail();
    } else if (InDefinition.backend != Backend::LaunchAgent) Fail();
}
std::string Xml(const std::string& InText) {
    std::string result;
    for (const char value : InText) {
        switch (value) {
        case '&': result += "&amp;"; break;
        case '<': result += "&lt;"; break;
        case '>': result += "&gt;"; break;
        case '\"': result += "&quot;"; break;
        case '\'': result += "&apos;"; break;
        default: result += value;
        }
    }
    return result;
}
std::string RenderImpl(const Definition& InDefinition) {
    Validate(InDefinition);
    if (InDefinition.backend == Backend::LaunchAgent) {
        std::string result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>\n";
        result += "<key>Label</key><string>" + Xml(InDefinition.identity) + "</string>\n<key>ProgramArguments</key><array>\n<string>" + Xml(Bytes(InDefinition.executable)) + "</string>\n";
        for (const auto& argument : InDefinition.arguments) result += "<string>" + Xml(argument) + "</string>\n";
        result += "</array>\n<key>WorkingDirectory</key><string>" + Xml(Bytes(InDefinition.working_directory)) + "</string>\n";
        result += "<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>\n<key>ThrottleInterval</key><integer>10</integer>\n";
        result += "<key>StandardOutPath</key><string>/dev/null</string>\n<key>StandardErrorPath</key><string>/dev/null</string>\n</dict></plist>\n";
        return result;
    }
    std::string result = "[Unit]\nDescription=Owned user service\n\n[Service]\nType=simple\nWorkingDirectory=" + Bytes(InDefinition.working_directory) + "\nExecStart=" + Bytes(InDefinition.executable);
    for (const auto& argument : InDefinition.arguments) result += " " + argument;
    return result + "\nRestart=on-failure\nRestartSec=10\nUMask=0077\nNoNewPrivileges=yes\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=default.target\n";
}
bool Artifact(const Definition& InDefinition) {
    std::error_code error;
    const auto status = fs::symlink_status(InDefinition.artifact, error);
    if (error == std::errc::no_such_file_or_directory || (!error && !fs::exists(status))) return false;
    if (error || !fs::is_regular_file(status)) Fail();
    if (fs::file_size(InDefinition.artifact) > 65536) Fail();
    std::ifstream input(InDefinition.artifact, std::ios::binary);
    if (!input) Fail();
    const std::string bytes((std::istreambuf_iterator<char>(input)), {});
    if (input.bad() || bytes != RenderImpl(InDefinition)) Fail();
    return true;
}
std::string Trim(const std::string& InText) {
    const auto first = InText.find_first_not_of(" \t\r");
    if (first == std::string::npos) return {};
    return InText.substr(first, InText.find_last_not_of(" \t\r") - first + 1);
}
std::uint64_t Number(const std::string& InText) {
    if (InText.empty() || InText.size() > 20 || !std::all_of(InText.begin(), InText.end(), [](unsigned char value) { return std::isdigit(value); })) Fail();
    std::size_t count = 0;
    const auto value = std::stoull(InText, &count);
    if (count != InText.size()) Fail();
    return value;
}
class Operation {
public:
    Operation(const Definition& InDefinition, Runtime& InRuntime, int InBudgetMs)
        : mDefinition(InDefinition), mRuntime(InRuntime), mDeadline(InRuntime.Now() + std::chrono::milliseconds(InBudgetMs)) {
        if (InBudgetMs <= 0) Deadline();
        Validate(mDefinition);
    }
    int Budget(int InMaximum = 5000) {
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(mDeadline - mRuntime.Now()).count();
        if (remaining <= 0) Deadline();
        return static_cast<int>(std::min<std::int64_t>(remaining, InMaximum));
    }
    Result Command(const std::vector<std::string>& InArguments, int InMaximumMs = 5000) {
        auto result = mRuntime.Run(mDefinition.backend == Backend::LaunchAgent ? fs::path("/bin/launchctl") : fs::path("/bin/systemctl"), InArguments, Budget(InMaximumMs));
        Budget();
        if (result.output.size() > 65536 || result.output.find('\0') != std::string::npos) Fail();
        return result;
    }
    std::string Domain() const { return "gui/" + std::to_string(mDefinition.uid); }
    std::string Target() const { return Domain() + "/" + mDefinition.identity; }
    void Must(const std::vector<std::string>& InArguments, int InMaximumMs = 5000) { if (Command(InArguments, InMaximumMs).exit_code != 0) Fail(); }
    Observation Inspect() {
        const bool bArtifact = Artifact(mDefinition);
        return mDefinition.backend == Backend::LaunchAgent ? LaunchState(bArtifact) : LinuxState(bArtifact);
    }
    Observation LaunchState(bool InArtifact) {
        const auto result = Command({"print", Target()});
        if (result.exit_code == 113) return {};
        if (result.exit_code != 0 || !InArtifact) Fail();
        std::istringstream input(result.output);
        std::string line, program, path, state;
        std::vector<std::string> arguments;
        unsigned programs = 0, paths = 0, arrays = 0, states = 0, pids = 0, depth = 0, roots = 0;
        std::uint64_t pid = 0;
        bool bInArguments = false;
        while (std::getline(input, line)) {
            line = Trim(line);
            if (bInArguments) {
                if (line == "}") bInArguments = false;
                else if (line.empty() || line.find('{') != std::string::npos) Fail();
                else arguments.push_back(line);
                continue;
            }
            if (line == "}") { if (depth == 0) Fail(); --depth; continue; }
            if (depth == 0) {
                if (line.empty()) continue;
                if (roots != 0 || line != Target() + " = {") Fail();
                ++roots; ++depth; continue;
            }
            if (depth != 1) {
                if (!line.empty() && line.back() == '{') ++depth;
                continue;
            }
            if (line == "arguments = {") { bInArguments = true; ++arrays; }
            else if (line.rfind("program = ", 0) == 0) { ++programs; program = line.substr(10); }
            else if (line.rfind("path = ", 0) == 0) { ++paths; path = line.substr(7); }
            else if (line.rfind("state = ", 0) == 0) { ++states; state = line.substr(8); }
            else if (line.rfind("pid = ", 0) == 0) { ++pids; pid = Number(line.substr(6)); }
            else if (!line.empty() && line.back() == '{') ++depth;
        }
        auto expected = mDefinition.arguments;
        expected.insert(expected.begin(), Bytes(mDefinition.executable));
        if (programs != 1 || paths != 1 || arrays != 1 || states != 1 || pids > 1 || bInArguments || depth != 0 || roots != 1 ||
            program != Bytes(mDefinition.executable) || path != Bytes(mDefinition.artifact) || arguments != expected) Fail();
        if (state == "running") { if (pids != 1 || pid == 0) Fail(); return {State::Running, pid}; }
        if (state != "waiting" && state != "exited" && state != "not running" && state != "spawn scheduled") Fail();
        if (pid != 0) Fail();
        return {State::Stopped, 0};
    }
    Observation LinuxState(bool InArtifact) {
        const auto result = Command({"--user", "show", mDefinition.identity, "--no-pager", "--property=LoadState,ActiveState,SubState,MainPID,FragmentPath,ExecStart"});
        std::map<std::string, std::string> values;
        std::istringstream input(result.output);
        std::string line;
        const std::set<std::string> expected{"LoadState", "ActiveState", "SubState", "MainPID", "FragmentPath", "ExecStart"};
        while (std::getline(input, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            const auto equal = line.find('=');
            if (equal == std::string::npos || !expected.count(line.substr(0, equal)) || !values.emplace(line.substr(0, equal), line.substr(equal + 1)).second) Fail();
        }
        if (values.size() != expected.size()) Fail();
        const auto pid = Number(values["MainPID"]);
        if (values["LoadState"] == "not-found") {
            if ((result.exit_code != 0 && result.exit_code != 4) || !values["FragmentPath"].empty() || !values["ExecStart"].empty() ||
                values["ActiveState"] != "inactive" || values["SubState"] != "dead" || pid != 0) Fail();
            return {};
        }
        if (result.exit_code != 0 || values["LoadState"] != "loaded" || !InArtifact || values["FragmentPath"] != Bytes(mDefinition.artifact)) Fail();
        // Restrict accepted definitions to unquoted tokens. Then the native
        // systemd show serialization is unambiguous; no shell parser/eval.
        const auto& command = values["ExecStart"];
        const std::string prefix = "{ path=" + Bytes(mDefinition.executable) + " ; argv[]=";
        const auto end = command.find(" ; ignore_errors=no ;", prefix.size());
        if (command.rfind(prefix, 0) != 0 || end == std::string::npos || command.find("}", end) != command.size() - 1 || command.find("{", 1) != std::string::npos) Fail();
        std::string expectedArgv = Bytes(mDefinition.executable);
        for (const auto& argument : mDefinition.arguments) expectedArgv += " " + argument;
        if (command.substr(prefix.size(), end - prefix.size()) != expectedArgv) Fail();
        if (values["ActiveState"] == "active" && values["SubState"] == "running" && pid > 0) return {State::Running, pid};
        if ((values["ActiveState"] == "inactive" && values["SubState"] == "dead") ||
            (values["ActiveState"] == "failed" && values["SubState"] == "failed")) {
            if (pid != 0) Fail();
            return {State::Stopped, 0};
        }
        // Transitional states remain indeterminate; do not authorize mutation.
        Fail();
    }
    void WaitStopped() {
        while (true) {
            const auto state = Inspect();
            if (mDefinition.backend == Backend::LaunchAgent ? state.state == State::Absent : state.state != State::Running) return;
            mRuntime.Sleep(std::min(Budget(), 100));
        }
    }
private:
    const Definition& mDefinition;
    Runtime& mRuntime;
    Clock::time_point mDeadline;
};
template<class Callback> auto Safe(Callback InCallback) -> decltype(InCallback()) {
    try { return InCallback(); }
    catch (const std::runtime_error& error) {
        if (std::string(error.what()) == "User service operation deadline exceeded.") Deadline();
        Fail();
    } catch (...) { Fail(); }
}
} // namespace

Result Runtime::Run(const fs::path& InExecutable, const std::vector<std::string>& InArguments, int InBudgetMs) {
    return Safe([&] {
        if (InBudgetMs <= 0) Deadline();
        const auto deadline = Now() + std::chrono::milliseconds(InBudgetMs);
        kano::process::Session session;
        kano::process::SessionOptions options;
        options.executable = Bytes(InExecutable); options.arguments = InArguments;
        options.startup_timeout_ms = InBudgetMs; options.cleanup_timeout_ms = 1000;
        options.stdout_max_bytes = 65536; options.stderr_max_bytes = 65536;
        auto result = session.Start(options);
        std::string output;
        bool bValid = result.ok;
        bool bDeadline = false;
        const auto capture = [&](const kano::process::SessionResult& InResult) {
            output += InResult.stdout_data; output += InResult.stderr_data;
            return !InResult.stdout_truncated && !InResult.stderr_truncated && output.size() <= 65536;
        };
        // Start reports state without draining output. Even an already exited
        // child needs one Poll; final Stop capture can contain the last bytes.
        if (bValid) result = session.Poll(0);
        while (bValid) {
            bValid = result.ok && capture(result);
            if (!bValid) break;
            if (!result.running) break;
            const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Now()).count();
            if (left <= 0) { bValid = false; bDeadline = true; break; }
            result = session.Poll(static_cast<int>(std::min<std::int64_t>(left, 50)));
        }
        const int exitCode = result.exit_code;
        const auto stopped = session.Stop(1000);
        const auto closed = session.Close();
        const bool bCaptured = capture(stopped) && capture(closed);
        if (!stopped.ok || !closed.ok || !stopped.cleanup_complete || !closed.cleanup_complete || !bCaptured) Fail();
        if (bDeadline) Deadline();
        if (!bValid) Fail();
        return Result{exitCode, std::move(output)};
    });
}
Clock::time_point Runtime::Now() { return Clock::now(); }
void Runtime::Sleep(int InMilliseconds) { if (InMilliseconds < 0) Fail(); std::this_thread::sleep_for(std::chrono::milliseconds(InMilliseconds)); }
std::string Render(const Definition& InDefinition) { return Safe([&] { return RenderImpl(InDefinition); }); }
Observation Inspect(const Definition& InDefinition, Runtime& InRuntime, int InBudgetMs) {
    return Safe([&] { return Operation(InDefinition, InRuntime, InBudgetMs).Inspect(); });
}
void Register(const Definition& InDefinition, Runtime& InRuntime, int InBudgetMs) {
    Safe([&] {
        Operation operation(InDefinition, InRuntime, InBudgetMs);
        if (!Artifact(InDefinition)) Fail();
        const auto state = operation.Inspect();
        if (InDefinition.backend == Backend::LaunchAgent) {
            if (state.state != State::Absent) return;
            operation.Must({"bootstrap", operation.Domain(), Bytes(InDefinition.artifact)});
        } else {
            if (state.state == State::Running) return;
            operation.Must({"--user", "daemon-reload"});
            operation.Must({"--user", "enable", "--now", InDefinition.identity});
        }
        if (operation.Inspect().state == State::Absent) Fail();
    });
}
void Restart(const Definition& InDefinition, Runtime& InRuntime, int InBudgetMs) {
    Safe([&] {
        Operation operation(InDefinition, InRuntime, InBudgetMs);
        if (operation.Inspect().state == State::Absent) Fail();
        // kickstart can wait through the rendered ten-second throttle. Keep
        // the operation deadline, while allowing its full remaining budget.
        if (InDefinition.backend == Backend::LaunchAgent) operation.Must({"kickstart", "-k", operation.Target()}, std::numeric_limits<int>::max());
        else operation.Must({"--user", "restart", InDefinition.identity});
        if (operation.Inspect().state == State::Absent) Fail();
    });
}
void Stop(const Definition& InDefinition, Runtime& InRuntime, int InBudgetMs) {
    Safe([&] {
        Operation operation(InDefinition, InRuntime, InBudgetMs);
        const auto state = operation.Inspect();
        if (state.state == State::Absent) return;
        if (InDefinition.backend == Backend::LaunchAgent) operation.Must({"bootout", operation.Target()});
        else operation.Must({"--user", "disable", "--now", InDefinition.identity});
        operation.WaitStopped();
    });
}
} // namespace kano::service
