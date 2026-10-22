#include <catch2/catch_session.hpp>
#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_exception.hpp>
#include <kano_file_lock.hpp>
#include <kano_process_replace.hpp>
#include <kano_process_session.hpp>
#include <kano_user_service.hpp>
#include <kano_unattended.hpp>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {
namespace fs = std::filesystem;
using kano::service::Backend;
using kano::service::Definition;
using kano::service::Result;
using kano::service::State;
using Clock = std::chrono::steady_clock;
const std::string kOwnershipError = "User service state or ownership could not be confirmed.";
const std::string kDeadlineError = "User service operation deadline exceeded.";

struct TemporaryDirectory {
    fs::path root;
    TemporaryDirectory() {
        static std::atomic<unsigned> sequence{0};
        const char* external = std::getenv("KANO_TEST_TEMP_ROOT");
        const auto parent = fs::canonical(external && *external ? fs::path(external) : fs::temp_directory_path());
        root = parent / ("kano-user-service-" +
            std::to_string(Clock::now().time_since_epoch().count()) + "-" +
            std::to_string(sequence.fetch_add(1)));
        if (!fs::create_directory(root)) throw std::runtime_error("Test directory creation failed.");
        fs::permissions(root, fs::perms::owner_all, fs::perm_options::replace);
    }
    ~TemporaryDirectory() { std::error_code error; fs::remove_all(root, error); }
};

std::string Bytes(const fs::path& InPath) {
    const auto bytes = InPath.generic_u8string();
    return {bytes.begin(), bytes.end()};
}
void Write(const fs::path& InPath, const std::string& InBytes) {
    std::ofstream output(InPath, std::ios::binary | std::ios::trunc);
    output.write(InBytes.data(), static_cast<std::streamsize>(InBytes.size()));
    if (!output) throw std::runtime_error("Test artifact write failed.");
    output.close();
    fs::permissions(InPath, fs::perms::owner_read | fs::perms::owner_write, fs::perm_options::replace);
}
std::string Read(const fs::path& InPath) {
    std::ifstream input(InPath, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), {}};
}
Definition MakeDefinition(const TemporaryDirectory& InDirectory, Backend InBackend) {
    Definition definition;
    definition.backend = InBackend;
    definition.identity = InBackend == Backend::LaunchAgent ? "com.kano.test.user-service" : "kano-test-user.service";
    definition.artifact = InDirectory.root / (InBackend == Backend::LaunchAgent ? "owned.plist" : "owned.service");
    definition.executable = InDirectory.root / "controlled-child";
    definition.working_directory = InDirectory.root;
    definition.arguments = {"run", "--port", "18421"};
    definition.uid = 501;
    return definition;
}
void Artifact(const Definition& InDefinition) { Write(InDefinition.artifact, kano::service::Render(InDefinition)); }
std::string Target(const Definition& InDefinition) {
    return "gui/" + std::to_string(InDefinition.uid) + "/" + InDefinition.identity;
}
std::vector<std::string> InspectArguments(const Definition& InDefinition) {
    if (InDefinition.backend == Backend::LaunchAgent) return {"print", Target(InDefinition)};
    return {"--user", "show", InDefinition.identity, "--no-pager",
            "--property=LoadState,ActiveState,SubState,MainPID,FragmentPath,ExecStart"};
}
std::string LaunchPrint(const Definition& InDefinition, const std::string& InState = "running", unsigned InPid = 312) {
    std::string result = Target(InDefinition) + " = {\n\tpath = " + Bytes(InDefinition.artifact) +
        "\n\tprogram = " + Bytes(InDefinition.executable) + "\n\targuments = {\n\t\t" + Bytes(InDefinition.executable) + "\n";
    for (const auto& argument : InDefinition.arguments) result += "\t\t" + argument + "\n";
    result += "\t}\n\tstate = " + InState + "\n";
    if (InPid) result += "\tpid = " + std::to_string(InPid) + "\n";
    return result + "\tresource coalition = {\n\t\tid = 14\n\t\tstate = active\n\t\tmembers = {\n\t\t\t312\n\t\t}\n\t}\n\tjetsam coalition = {\n\t\tid = 15\n\t\tstate = active\n\t}\n}\n";
}
std::string LinuxShow(const Definition& InDefinition, State InState = State::Running) {
    if (InState == State::Absent)
        return "LoadState=not-found\nActiveState=inactive\nSubState=dead\nMainPID=0\nFragmentPath=\nExecStart=\n";
    std::string command = "{ path=" + Bytes(InDefinition.executable) + " ; argv[]=" + Bytes(InDefinition.executable);
    for (const auto& argument : InDefinition.arguments) command += " " + argument;
    command += " ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }";
    return "LoadState=loaded\nActiveState=" + std::string(InState == State::Running ? "active\nSubState=running\nMainPID=312" : "inactive\nSubState=dead\nMainPID=0") +
        "\nFragmentPath=" + Bytes(InDefinition.artifact) + "\nExecStart=" + command + "\n";
}
Result Observation(const Definition& InDefinition, State InState) {
    if (InDefinition.backend == Backend::LaunchAgent)
        return InState == State::Absent ? Result{113, "Could not find service.\n"} :
            Result{0, LaunchPrint(InDefinition, InState == State::Running ? "running" : "waiting", InState == State::Running ? 312 : 0)};
    return {InState == State::Absent ? 4 : 0, LinuxShow(InDefinition, InState)};
}
void Replace(std::string& InOutText, const std::string& InBefore, const std::string& InAfter) {
    const auto position = InOutText.find(InBefore);
    REQUIRE(position != std::string::npos);
    InOutText.replace(position, InBefore.size(), InAfter);
}

struct Step {
    std::vector<std::string> arguments;
    Result result;
    int elapsed = 0;
};
class ControlledRuntime final : public kano::service::Runtime {
public:
    explicit ControlledRuntime(Backend InBackend) : backend(InBackend) {}
    Backend backend;
    std::vector<Step> steps;
    std::size_t consumed = 0;
    Clock::time_point now{};
    std::vector<int> sleeps;
    std::vector<int> budgets;
    Result Run(const fs::path& InExecutable, const std::vector<std::string>& InArguments, int InBudgetMs) override {
        CHECK(Bytes(InExecutable) == (backend == Backend::LaunchAgent ? "/bin/launchctl" : "/bin/systemctl"));
        REQUIRE(consumed < steps.size());
        CHECK(InBudgetMs > 0);
        budgets.push_back(InBudgetMs);
        const auto& step = steps[consumed++];
        CHECK(InArguments == step.arguments);
        now += std::chrono::milliseconds(step.elapsed);
        return step.result;
    }
    Clock::time_point Now() override { return now; }
    void Sleep(int InMilliseconds) override {
        CHECK(InMilliseconds > 0);
        CHECK(InMilliseconds <= 100);
        sleeps.push_back(InMilliseconds);
        now += std::chrono::milliseconds(InMilliseconds);
    }
    void Inspect(const Definition& InDefinition, State InState, int InElapsed = 0) {
        steps.push_back({InspectArguments(InDefinition), Observation(InDefinition, InState), InElapsed});
    }
    void Complete() const { CHECK(consumed == steps.size()); }
};

struct EnvironmentValue {
    std::string name;
    std::string previous;
    bool bPresent = false;
    EnvironmentValue(const char* InName, const char* InValue) : name(InName) {
        const char* old = std::getenv(InName);
        bPresent = old != nullptr;
        if (old) previous = old;
#ifdef _WIN32
        if (_putenv_s(InName, InValue)) throw std::runtime_error("Test environment setup failed.");
#else
        if (setenv(InName, InValue, 1)) throw std::runtime_error("Test environment setup failed.");
#endif
    }
    ~EnvironmentValue() {
#ifdef _WIN32
        _putenv_s(name.c_str(), bPresent ? previous.c_str() : "");
#else
        if (bPresent) setenv(name.c_str(), previous.c_str(), 1); else unsetenv(name.c_str());
#endif
    }
};
struct ChildOutput { std::string output; int exitCode = -1; };
ChildOutput Finish(kano::process::Session& InSession, int InBudgetMs = 3000) {
    ChildOutput output;
    const auto deadline = Clock::now() + std::chrono::milliseconds(InBudgetMs);
    bool bExited = false;
    while (Clock::now() < deadline) {
        const auto result = InSession.Poll(20);
        REQUIRE(result.ok);
        REQUIRE_FALSE(result.stdout_truncated);
        REQUIRE_FALSE(result.stderr_truncated);
        output.output += result.stdout_data;
        REQUIRE(result.stderr_data.empty());
        if (!result.running) { output.exitCode = result.exit_code; bExited = true; break; }
    }
    const auto stopped = InSession.Stop(2000);
    const auto closed = InSession.Close();
    REQUIRE(stopped.cleanup_complete);
    REQUIRE(closed.cleanup_complete);
    REQUIRE(bExited);
    return output;
}
kano::process::SessionOptions ChildOptions(const std::vector<std::string>& InArguments) {
    kano::process::SessionOptions options;
    options.executable = KANO_USER_SERVICE_CHILD_PATH;
    options.arguments = InArguments;
    options.startup_timeout_ms = 2000;
    options.cleanup_timeout_ms = 2000;
    return options;
}
}

TEST_CASE("User service render is pure and escapes LaunchAgent data", "[user_service]") {
    TemporaryDirectory directory;
    auto definition = MakeDefinition(directory, Backend::LaunchAgent);
    definition.executable = directory.root / "child & safe";
    definition.arguments = {"literal $(touch marker)", "a'b", "<safe> \"quoted\""};
    const auto bytes = kano::service::Render(definition);
    CHECK_FALSE(fs::exists(definition.artifact));
    CHECK(bytes.find("child &amp; safe") != std::string::npos);
    CHECK(bytes.find("&lt;safe&gt; &quot;quoted&quot;") != std::string::npos);
    CHECK(bytes.find("literal $(touch marker)") != std::string::npos);
    CHECK(bytes.find("a&apos;b") != std::string::npos);
    CHECK(bytes.find("<key>StandardOutPath</key><string>/dev/null</string>") != std::string::npos);
    CHECK(bytes.find("<key>StandardErrorPath</key><string>/dev/null</string>") != std::string::npos);
    CHECK(bytes.find("<key>SuccessfulExit</key><false/>") != std::string::npos);
    CHECK(bytes.find("<key>ThrottleInterval</key><integer>10</integer>") != std::string::npos);
    definition.identity = "../foreign";
    CHECK_THROWS_WITH(kano::service::Render(definition), kOwnershipError);
    definition = MakeDefinition(directory, Backend::SystemdUser);
    const auto unit = kano::service::Render(definition);
    CHECK(unit.find("Restart=on-failure\nRestartSec=10\nUMask=0077\nNoNewPrivileges=yes\nStandardOutput=null\nStandardError=null") != std::string::npos);
    CHECK_FALSE(fs::exists(definition.artifact));
    for (const auto& argument : {std::string("with space"), std::string("%h"), std::string("$(command)"), std::string("line\nfeed")}) {
        definition.arguments = {argument};
        CHECK_THROWS_WITH(kano::service::Render(definition), kOwnershipError);
    }
}

TEST_CASE("User service ownership requires exact artifacts and loaded identity", "[user_service]") {
    for (const auto backend : {Backend::LaunchAgent, Backend::SystemdUser}) {
        TemporaryDirectory directory;
        auto definition = MakeDefinition(directory, backend);
        Artifact(definition);
        ControlledRuntime runtime(backend);
        runtime.Inspect(definition, State::Running);
        const auto running = kano::service::Inspect(definition, runtime, 500);
        CHECK(running.state == State::Running);
        CHECK(running.pid == 312);
        runtime.Inspect(definition, State::Stopped);
        const auto stopped = kano::service::Inspect(definition, runtime, 500);
        CHECK(stopped.state == State::Stopped);
        CHECK(stopped.pid == 0);
        runtime.Inspect(definition, State::Absent);
        CHECK(kano::service::Inspect(definition, runtime, 500).state == State::Absent);
        runtime.Complete();

        for (const auto& replacement : {std::make_pair(Bytes(definition.artifact), Bytes(definition.artifact) + ".foreign"),
                                      std::make_pair(Bytes(definition.executable), Bytes(definition.executable) + ".foreign"),
                                      std::make_pair(std::string("18421"), std::string("18422"))}) {
            auto foreign = Observation(definition, State::Running);
            Replace(foreign.output, replacement.first, replacement.second);
            ControlledRuntime denied(backend);
            denied.steps.push_back({InspectArguments(definition), foreign});
            CHECK_THROWS_WITH(kano::service::Restart(definition, denied, 500), kOwnershipError);
            denied.Complete();
        }
        Write(definition.artifact, "foreign artifact bytes\n");
        ControlledRuntime tampered(backend);
        CHECK_THROWS_WITH(kano::service::Inspect(definition, tampered, 500), kOwnershipError);
        tampered.Complete();
        fs::remove(definition.artifact);
        ControlledRuntime missing(backend);
        missing.Inspect(definition, State::Running);
        CHECK_THROWS_WITH(kano::service::Inspect(definition, missing, 500), kOwnershipError);
        missing.Complete();
    }
}

TEST_CASE("User service register restart and stop use ordered bounded commands", "[user_service]") {
    for (const auto backend : {Backend::LaunchAgent, Backend::SystemdUser}) {
        TemporaryDirectory directory;
        const auto definition = MakeDefinition(directory, backend);
        Artifact(definition);
        const auto original = Read(definition.artifact);
        ControlledRuntime runtime(backend);
        runtime.Inspect(definition, State::Absent);
        if (backend == Backend::LaunchAgent)
            runtime.steps.push_back({{"bootstrap", "gui/501", Bytes(definition.artifact)}, {0, ""}});
        else {
            runtime.steps.push_back({{"--user", "daemon-reload"}, {0, ""}});
            runtime.steps.push_back({{"--user", "enable", "--now", definition.identity}, {0, ""}});
        }
        runtime.Inspect(definition, State::Running);
        kano::service::Register(definition, runtime, 1000);
        runtime.Inspect(definition, State::Running);
        kano::service::Register(definition, runtime, 1000);
        runtime.Inspect(definition, State::Running);
        runtime.steps.push_back({backend == Backend::LaunchAgent ?
            std::vector<std::string>{"kickstart", "-k", Target(definition)} :
            std::vector<std::string>{"--user", "restart", definition.identity}, {0, ""}});
        runtime.Inspect(definition, State::Running);
        kano::service::Restart(definition, runtime, 1000);
        runtime.Inspect(definition, State::Running);
        runtime.steps.push_back({backend == Backend::LaunchAgent ?
            std::vector<std::string>{"bootout", Target(definition)} :
            std::vector<std::string>{"--user", "disable", "--now", definition.identity}, {0, ""}});
        runtime.Inspect(definition, State::Running);
        runtime.Inspect(definition, backend == Backend::LaunchAgent ? State::Absent : State::Stopped);
        kano::service::Stop(definition, runtime, 1000);
        CHECK(runtime.sleeps == std::vector<int>{100});
        runtime.Inspect(definition, State::Absent);
        kano::service::Stop(definition, runtime, 1000);
        runtime.Complete();
        CHECK(Read(definition.artifact) == original);
    }
}

TEST_CASE("User service denied unknown and stale states never authorize changes", "[user_service]") {
    for (const auto backend : {Backend::LaunchAgent, Backend::SystemdUser}) {
        TemporaryDirectory directory;
        const auto definition = MakeDefinition(directory, backend);
        Artifact(definition);
        std::vector<Result> invalid{{5, "Permission denied.\n"}, {0, ""}, {0, std::string(65537, 'x')}, {0, std::string("a\0b", 3)}};
        auto duplicate = Observation(definition, State::Running);
        duplicate.output += backend == Backend::LaunchAgent ? "state = running\n" : "LoadState=loaded\n";
        invalid.push_back(duplicate);
        auto badPid = Observation(definition, State::Running);
        Replace(badPid.output, backend == Backend::LaunchAgent ? "pid = 312" : "MainPID=312",
                backend == Backend::LaunchAgent ? "pid = 0" : "MainPID=0");
        invalid.push_back(badPid);
        auto transition = Observation(definition, State::Running);
        Replace(transition.output, backend == Backend::LaunchAgent ? "state = running" : "ActiveState=active", backend == Backend::LaunchAgent ? "state = unrecognized" : "ActiveState=activating");
        invalid.push_back(transition);
        if (backend == Backend::SystemdUser) {
            auto badAbsent = Observation(definition, State::Absent);
            Replace(badAbsent.output, "MainPID=0", "MainPID=312");
            invalid.push_back(badAbsent);
        }
        for (const auto& result : invalid) {
            ControlledRuntime runtime(backend);
            runtime.steps.push_back({InspectArguments(definition), result});
            CHECK_THROWS_WITH(kano::service::Register(definition, runtime, 500), kOwnershipError);
            runtime.Complete();
        }
        ControlledRuntime commandDenied(backend);
        commandDenied.Inspect(definition, State::Running);
        commandDenied.steps.push_back({backend == Backend::LaunchAgent ?
            std::vector<std::string>{"bootout", Target(definition)} :
            std::vector<std::string>{"--user", "disable", "--now", definition.identity}, {5, "denied"}});
        CHECK_THROWS_WITH(kano::service::Stop(definition, commandDenied, 500), kOwnershipError);
        commandDenied.Complete();
        CHECK(fs::exists(definition.artifact));
    }
}

TEST_CASE("User service deadlines bound inspect and stop confirmation", "[user_service]") {
    for (const auto backend : {Backend::LaunchAgent, Backend::SystemdUser}) {
        TemporaryDirectory directory;
        const auto definition = MakeDefinition(directory, backend);
        Artifact(definition);
        ControlledRuntime expired(backend);
        CHECK_THROWS_WITH(kano::service::Inspect(definition, expired, 0), kDeadlineError);
        expired.Complete();
        expired.Inspect(definition, State::Running, 501);
        CHECK_THROWS_WITH(kano::service::Inspect(definition, expired, 500), kDeadlineError);
        expired.Complete();
        ControlledRuntime timeout(backend);
        timeout.Inspect(definition, State::Running);
        timeout.steps.push_back({backend == Backend::LaunchAgent ?
            std::vector<std::string>{"bootout", Target(definition)} :
            std::vector<std::string>{"--user", "disable", "--now", definition.identity}, {0, ""}});
        timeout.Inspect(definition, State::Running);
        timeout.Inspect(definition, State::Running);
        CHECK_THROWS_WITH(kano::service::Stop(definition, timeout, 200), kDeadlineError);
        timeout.Complete();
        CHECK((timeout.sleeps == std::vector<int>{100, 100}));
        CHECK(fs::exists(definition.artifact));
    }
}

TEST_CASE("LaunchAgent exec proxy is bounded and never reported as running proof", "[user_service]") {
    TemporaryDirectory directory;
    const auto definition = MakeDefinition(directory, Backend::LaunchAgent); Artifact(definition);
    ControlledRuntime runtime(Backend::LaunchAgent);
    runtime.Inspect(definition, State::Absent);
    runtime.steps.push_back({{"bootstrap", "gui/501", Bytes(definition.artifact)}, {0, ""}});
    runtime.steps.push_back({InspectArguments(definition), {0, LaunchPrint(definition, "xpcproxy", 312)}});
    runtime.Inspect(definition, State::Running);
    CHECK_NOTHROW(kano::service::Register(definition, runtime, 500)); runtime.Complete();
    CHECK(runtime.sleeps == std::vector<int>{100});
    ControlledRuntime deadline(Backend::LaunchAgent);
    deadline.steps.push_back({InspectArguments(definition), {0, LaunchPrint(definition, "xpcproxy", 312)}});
    deadline.steps.push_back({InspectArguments(definition), {0, LaunchPrint(definition, "xpcproxy", 312)}});
    CHECK_THROWS_WITH(kano::service::Inspect(definition, deadline, 200), kDeadlineError); deadline.Complete();
    CHECK((deadline.sleeps == std::vector<int>{100, 100}));
    for (const auto mode : {"no-pid", "foreign-program", "unknown-state"}) {
        ControlledRuntime invalid(Backend::LaunchAgent);
        auto print = LaunchPrint(definition, mode == std::string("unknown-state") ? "unrecognized" : "xpcproxy", mode == std::string("no-pid") ? 0 : 312);
        if (mode == std::string("foreign-program")) Replace(print, "program = " + Bytes(definition.executable), "program = /foreign/child");
        invalid.steps.push_back({InspectArguments(definition), {0, print}});
        CHECK_THROWS_WITH(kano::service::Stop(definition, invalid, 500), kOwnershipError); invalid.Complete();
        CHECK(invalid.sleeps.empty());
    }
    CHECK(fs::exists(definition.artifact));
}

TEST_CASE("LaunchAgent restart permits throttle time within one decreasing operation budget", "[user_service]") {
    TemporaryDirectory directory;
    const auto definition = MakeDefinition(directory, Backend::LaunchAgent);
    Artifact(definition);
    ControlledRuntime runtime(Backend::LaunchAgent);
    runtime.Inspect(definition, State::Running, 12);
    runtime.steps.push_back({{"kickstart", "-k", Target(definition)}, {0, ""}, 10025});
    runtime.Inspect(definition, State::Running, 8);
    CHECK_NOTHROW(kano::service::Restart(definition, runtime, 15000));
    runtime.Complete();
    CHECK(runtime.budgets == std::vector<int>{5000, 14988, 4963});

    ControlledRuntime expired(Backend::LaunchAgent);
    expired.Inspect(definition, State::Running, 20);
    expired.steps.push_back({{"kickstart", "-k", Target(definition)}, {0, ""}, 14980});
    CHECK_THROWS_WITH(kano::service::Restart(definition, expired, 15000), kDeadlineError);
    expired.Complete();
    CHECK(expired.budgets == std::vector<int>{5000, 14980});
    CHECK(fs::exists(definition.artifact));
}

TEST_CASE("Exclusive file locks exclude independent children and release on destruction", "[process][lock]") {
    TemporaryDirectory directory;
    const auto path = directory.root / "owned.lock";
    auto lock = kano::platform::ExclusiveFileLock::TryAcquire(path);
    REQUIRE(lock.has_value());
    CHECK(fs::is_regular_file(path));
    CHECK_FALSE(kano::platform::ExclusiveFileLock::TryAcquire(path).has_value());
    kano::process::Session busy;
    REQUIRE(busy.Start(ChildOptions({"probe-lock", Bytes(path)})).ok);
    const auto busyOutput = Finish(busy);
    CHECK(busyOutput.exitCode == 0);
    CHECK(busyOutput.output.find("busy") != std::string::npos);
    lock.reset();
    kano::process::Session released;
    REQUIRE(released.Start(ChildOptions({"probe-lock", Bytes(path)})).ok);
    const auto releasedOutput = Finish(released);
    CHECK(releasedOutput.exitCode == 0);
    CHECK(releasedOutput.output.find("acquired") != std::string::npos);
    CHECK(fs::is_regular_file(path));
    CHECK_THROWS(kano::platform::ExclusiveFileLock::TryAcquire(directory.root));
    auto moved = kano::platform::ExclusiveFileLock::TryAcquire(path);
    REQUIRE(moved.has_value());
    auto owner = std::move(moved);
    CHECK_FALSE(kano::platform::ExclusiveFileLock::TryAcquire(path).has_value());
    owner.reset();
    CHECK(kano::platform::ExclusiveFileLock::TryAcquire(path).has_value());
#ifndef _WIN32
    const auto permissions = fs::status(path).permissions();
    CHECK((permissions & (fs::perms::group_all | fs::perms::others_all)) == fs::perms::none);
    const auto leaf = directory.root / "linked.lock";
    fs::create_symlink(path, leaf);
    CHECK_THROWS(kano::platform::ExclusiveFileLock::TryAcquire(leaf));
    const auto realParent = directory.root / "real-parent";
    fs::create_directory(realParent);
    const auto linkedParent = directory.root / "linked-parent";
    fs::create_directory_symlink(realParent, linkedParent);
    CHECK_THROWS(kano::platform::ExclusiveFileLock::TryAcquire(linkedParent / "new.lock"));
    fs::permissions(path, fs::perms::owner_read | fs::perms::owner_write | fs::perms::group_read, fs::perm_options::replace);
    CHECK_THROWS(kano::platform::ExclusiveFileLock::TryAcquire(path));
#endif
}

TEST_CASE("Default service runtime drains fast helpers and bounds owned hanging helpers", "[user_service][process]") {
    kano::service::Runtime runtime;
    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        const auto result = runtime.Run(KANO_USER_SERVICE_CHILD_PATH, {"fast-output"}, 2000);
        CHECK(result.exit_code == 7);
        CHECK(result.output.find("fast-stdout-metadata") != std::string::npos);
        CHECK(result.output.find("fast-stderr-diagnostic") != std::string::npos);
    }
    const auto start = Clock::now();
    CHECK_THROWS_WITH(runtime.Run(KANO_USER_SERVICE_CHILD_PATH, {"hanging-output"}, 100), kDeadlineError);
    CHECK(Clock::now() - start < std::chrono::seconds(4));
}

#ifndef _WIN32
TEST_CASE("An inherited lock survives direct exec with the same owned PID", "[process][lock]") {
    TemporaryDirectory directory;
    const auto path = directory.root / "inherited.lock";
    kano::process::Session session;
    REQUIRE(session.Start(ChildOptions({"inherit-lock", Bytes(path)})).ok);
    const auto pid = session.GetIdentity().pid;
    std::string output;
    const auto deadline = Clock::now() + std::chrono::seconds(3);
    while (Clock::now() < deadline && output.find("pid=") == std::string::npos) {
        const auto result = session.Poll(20);
        REQUIRE(result.ok);
        output += result.stdout_data;
        REQUIRE(result.running);
    }
    REQUIRE(output.find("inherited=held\n") != std::string::npos);
    CHECK(output.find("pid=" + std::to_string(pid) + "\n") != std::string::npos);
    CHECK_FALSE(kano::platform::ExclusiveFileLock::TryAcquire(path).has_value());
    session.CloseInput();
    const auto result = Finish(session);
    CHECK(result.exitCode == 0);
    CHECK(kano::platform::ExclusiveFileLock::TryAcquire(path).has_value());
}

TEST_CASE("Direct exec preserves empty environment values removes selected keys and does not mutate the parent", "[process][environment]") {
    EnvironmentValue inherited("KANO_REPLACE_INHERITED", "parent-inherited");
    EnvironmentValue overrideValue("KANO_REPLACE_OVERRIDE", "parent-override");
    EnvironmentValue empty("KANO_REPLACE_EMPTY", "parent-not-empty");
    EnvironmentValue removed("KANO_REPLACE_REMOVED", "parent-removed");
    kano::process::Session session;
    REQUIRE(session.Start(ChildOptions({"replace-environment"})).ok);
    const auto pid = session.GetIdentity().pid;
    const auto result = Finish(session);
    CHECK(result.exitCode == 0);
    CHECK(result.output.find("pid=" + std::to_string(pid) + "\n") != std::string::npos);
    CHECK(result.output.find("KANO_REPLACE_INHERITED=value:parent-inherited\n") != std::string::npos);
    CHECK(result.output.find("KANO_REPLACE_OVERRIDE=value:child-value\n") != std::string::npos);
    CHECK(result.output.find("KANO_REPLACE_EMPTY=value:\n") != std::string::npos);
    CHECK(result.output.find("KANO_REPLACE_REMOVED=absent\n") != std::string::npos);
    CHECK(std::string(std::getenv("KANO_REPLACE_INHERITED")) == "parent-inherited");
    CHECK(std::string(std::getenv("KANO_REPLACE_OVERRIDE")) == "parent-override");
    CHECK(std::string(std::getenv("KANO_REPLACE_EMPTY")) == "parent-not-empty");
    CHECK(std::string(std::getenv("KANO_REPLACE_REMOVED")) == "parent-removed");
    CHECK_THROWS_WITH(kano::process::ReplaceProcess("/nonexistent/kano-controlled-child", {}, {}, {}),
                      "Direct process replacement is unavailable or failed.");
    for (const auto& name : {std::string("bad=name"), std::string("1BAD"), std::string("bad-name"), std::string("bad\0name", 8)}) {
        CHECK_THROWS_WITH(kano::process::ReplaceProcess(KANO_USER_SERVICE_CHILD_PATH, {}, {{name, "value"}}, {}),
                          "Direct process replacement is unavailable or failed.");
        CHECK_THROWS_WITH(kano::process::ReplaceProcess(KANO_USER_SERVICE_CHILD_PATH, {}, {}, {name}),
                          "Direct process replacement is unavailable or failed.");
    }
    CHECK_THROWS_WITH(kano::process::ReplaceProcess(KANO_USER_SERVICE_CHILD_PATH, {}, {{"KANO_DUPLICATE", "one"}, {"KANO_DUPLICATE", "two"}}, {}),
                      "Direct process replacement is unavailable or failed.");
    CHECK_THROWS_WITH(kano::process::ReplaceProcess(KANO_USER_SERVICE_CHILD_PATH, {std::string("bad\0argument", 12)}, {}, {}),
                      "Direct process replacement is unavailable or failed.");
    CHECK_THROWS_WITH(kano::process::ReplaceProcess(KANO_USER_SERVICE_CHILD_PATH, {}, {{"KANO_VALUE", std::string("bad\0value", 9)}}, {}),
                      "Direct process replacement is unavailable or failed.");
    CHECK(std::string(std::getenv("KANO_REPLACE_OVERRIDE")) == "parent-override");
}
#else
TEST_CASE("Windows refuses direct exec and inherited file locks", "[process][lock]") {
    TemporaryDirectory directory;
    CHECK_THROWS(kano::platform::ExclusiveFileLock::TryAcquire(directory.root / "exec.lock", true));
    CHECK_THROWS_WITH(kano::process::ReplaceProcess(KANO_USER_SERVICE_CHILD_PATH, {}, {}, {}),
                      "Direct process replacement is unavailable or failed.");
}
#endif

TEST_CASE("LaunchAgent opt-in restart background and log settings preserve exact ownership", "[user_service]") {
    TemporaryDirectory directory;
    auto definition = MakeDefinition(directory, Backend::LaunchAgent);
    const auto original = kano::service::Render(definition);
    CHECK(original.find("<key>SuccessfulExit</key><false/>") != std::string::npos);
    definition.restart = kano::service::RestartPolicy::Always;
    definition.background = true;
    definition.stdout_path = directory.root / "out&metadata.log";
    definition.stderr_path = directory.root / "err&metadata.log";
    const auto rendered = kano::service::Render(definition);
    CHECK(rendered.find("<key>KeepAlive</key><true/>") != std::string::npos);
    CHECK(rendered.find("<key>ProcessType</key><string>Background</string>") != std::string::npos);
    CHECK(rendered.find("out&amp;metadata.log") != std::string::npos);
    CHECK(rendered.find("err&amp;metadata.log") != std::string::npos);
    Artifact(definition);
    ControlledRuntime runtime(Backend::LaunchAgent);
    runtime.Inspect(definition, State::Running);
    CHECK(kano::service::Inspect(definition, runtime, 1000).pid == 312);
    runtime.Complete();
    auto changed = definition;
    changed.restart = kano::service::RestartPolicy::OnFailure;
    CHECK_THROWS_WITH(kano::service::Stop(changed, runtime, 1000), kOwnershipError);
    changed = definition; changed.background = false;
    CHECK_THROWS_WITH(kano::service::Stop(changed, runtime, 1000), kOwnershipError);
    changed = definition; changed.stdout_path = directory.root / "different-out.log";
    CHECK_THROWS_WITH(kano::service::Stop(changed, runtime, 1000), kOwnershipError);
    changed = definition; changed.stderr_path = directory.root / "different-err.log";
    CHECK_THROWS_WITH(kano::service::Stop(changed, runtime, 1000), kOwnershipError);
    changed = definition;
    changed.stdout_path = "relative.log";
    CHECK_THROWS(kano::service::Render(changed));
    changed = MakeDefinition(directory, Backend::SystemdUser);
    changed.restart = kano::service::RestartPolicy::Always;
    CHECK(kano::service::Render(changed).find("Restart=always") != std::string::npos);
    changed.background = true;
    CHECK_THROWS(kano::service::Render(changed));
}

int main(int argc, char** argv) {
    kano::infra::ConfigureUnattendedExecution();
    return Catch::Session().run(argc, argv);
}
