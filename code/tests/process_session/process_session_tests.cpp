#include <kano_process_session.hpp>
#include <kano_process.h>
#include <kano_unattended.hpp>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#ifdef _WIN32
#include <windows.h>
#endif

using namespace kano::process;
static int Failures = 0;
static void Check(bool InCondition, const char* InMessage) {
    if (!InCondition) { std::fprintf(stderr, "FAIL: %s\n", InMessage); ++Failures; }
}
static SessionOptions Options(const char* InMode) {
    SessionOptions options;
    options.executable = KANO_SESSION_CHILD_PATH;
    options.arguments = {InMode}; options.cleanup_timeout_ms = 700;
    options.stdout_max_bytes = 1024; options.stderr_max_bytes = 512;
    return options;
}
#ifdef _WIN32
static std::string Until(Session& InSession, const char* InText, int InBudget = 3000) {
    std::string output;
    const auto deadline = GetTickCount64() + InBudget;
    while (GetTickCount64() < deadline) {
        auto result = InSession.Poll(20);
        Check(result.ok, "poll succeeds");
        Check(result.stdout_data.size() <= 1024 && result.stderr_data.size() <= 512, "per-poll bounded capture");
        output += result.stdout_data;
        if (output.find(InText) != std::string::npos || !result.running) break;
    }
    return output;
}
static void WaitGone(const Identity& InIdentity) {
    const auto deadline = GetTickCount64() + 2000;
    while (IsAlive(InIdentity) && GetTickCount64() < deadline) Sleep(5);
    Check(!IsAlive(InIdentity), "owned process is gone");
}
#endif

int main() {
    kano::infra::ConfigureUnattendedExecution();
#ifdef _WIN32
    const auto self = CurrentIdentity();
    Check(self.pid && self.creation_time && !self.executable.empty() && IsAlive(self), "current exact identity");
    auto stale = self; ++stale.creation_time;
    Check(!IsAlive(stale), "creation mismatch rejects reused/stale PID");
    stale = self; stale.executable += ".foreign";
    Check(!IsAlive(stale), "image mismatch rejects foreign identity");
    {
        Session session;
        Check(session.Start(Options("echo")).ok, "persistent launch");
        const auto identity = session.GetIdentity();
        Check(IsAlive(identity), "session identity is live");
        Check(Until(session, "ready").find("ready") != std::string::npos, "readiness output");
        Sleep(120); Check(session.IsRunning(), "idle session has no lifetime timer");
        Check(session.Write("hello\n", 500).ok, "stdin write");
        Check(Until(session, "hello").find("hello") != std::string::npos, "incremental response");
        Check(session.Write("cancel\n", 500).ok, "cancel command write");
        Check(Until(session, "cancelled").find("cancelled") != std::string::npos, "cancel response");
        Check(session.Write("shutdown\n", 500).ok, "shutdown command write");
        Check(Until(session, "stopped").find("stopped") != std::string::npos, "shutdown response");
        auto closed = session.Close();
        Check(closed.ok && closed.cleanup_complete && !closed.running, "normal shutdown cleanup");
        Check(session.Close().cleanup_complete, "repeat close is idempotent");
        WaitGone(identity);
    }
    {
        Session session; Check(session.Start(Options("echo")).ok, "EOF launch");
        Until(session, "ready"); session.CloseInput();
        Check(Until(session, "eof").find("eof") != std::string::npos, "stdin EOF is delivered");
        Check(session.Close().cleanup_complete, "EOF cleanup");
    }
    {
        Session session; Check(session.Start(Options("noise")).ok, "noisy child launch");
        Check(Until(session, "ready").find("ready") != std::string::npos, "noisy stderr drains without deadlock");
        Check(session.Write("shutdown\n", 500).ok, "noisy child shutdown");
        Check(session.Close().cleanup_complete, "noisy child cleanup");
    }
    {
        Session session; Check(session.Start(Options("no-read")).ok, "blocked-input child launch");
        Until(session, "ready");
        const auto started = GetTickCount64();
        auto written = session.Write(std::string(1024 * 1024, 'x'), 50);
        Check(!written.ok && written.system_error == ERROR_TIMEOUT, "blocked stdin reaches operation deadline");
        Check(GetTickCount64() - started < 1500, "blocked write and cancellation are bounded");
        Check(session.Stop(700).cleanup_complete, "blocked-input owned cleanup");
    }
    {
        Session session; auto options = Options("echo"); options.executable += ".missing";
        auto result = session.Start(options);
        Check(!result.ok && result.cleanup_complete && result.system_error, "launch failure is diagnosed without child");
    }
    {
        Session session; Check(session.Start(Options("exit-7")).ok, "startup-failure launch");
        std::string diagnostic;
        int exitCode = -1;
        const auto deadline = GetTickCount64() + 2000;
        while (GetTickCount64() < deadline) {
            auto result = session.Poll(20); diagnostic += result.stderr_data;
            if (!result.running) { exitCode = result.exit_code; break; }
        }
        Check(exitCode == 7 && diagnostic.find("controlled startup cause") != std::string::npos, "exit cause and stderr retained");
        Check(session.Close().cleanup_complete, "failed child cleanup");
    }
    {
        char temp[MAX_PATH]; GetTempPathA(MAX_PATH, temp);
        const std::string marker = std::string(temp) + "kano-session-marker-" + std::to_string(self.pid);
        DeleteFileA(marker.c_str());
        Session session; auto options = Options("mark"); options.arguments.push_back(marker);
        kano_process_test_fail_next_containment_setup();
        auto result = session.Start(options);
        Check(!result.ok && result.cleanup_complete, "containment failure is fail-closed");
        Check(GetFileAttributesA(marker.c_str()) == INVALID_FILE_ATTRIBUTES, "payload never ran before containment");
        const auto closed = session.Close();
        Check(closed.cleanup_complete == result.cleanup_complete, "failed-start cleanup proof is preserved by close");
    }
    {
        Session session;
        kano_process_test_fail_next_containment_setup();
        kano_process_test_fail_next_launch_cleanup_confirmation();
        const auto started = session.Start(Options("echo"));
        Check(!started.ok && !started.cleanup_complete, "injected initial cleanup observation is unconfirmed");
        const auto stopped = session.Stop(700);
        const auto closed = session.Close();
        Check(!stopped.ok && !stopped.cleanup_complete && !closed.ok && !closed.cleanup_complete,
            "empty stop and close preserve unconfirmed launch cleanup");
        const auto restarted = session.Start(Options("echo"));
        Check(!restarted.ok && !restarted.cleanup_complete && !session.IsRunning(),
            "unverified failed session refuses restart");
    }
    {
        SetEnvironmentVariableA("KANO_SESSION_TEST_OVERRIDE", "parent");
        Session session; auto options = Options("environment");
        options.environment = {{"kano_session_test_override", "child"}};
        Check(session.Start(options).ok, "environment override launch");
        Check(Until(session, "override=child").find("override=child") != std::string::npos, "case insensitive override");
        Check(session.Close().cleanup_complete, "override cleanup");
        options.environment = {{"KANO_SESSION_TEST_OVERRIDE", ""}};
        Check(session.Start(options).ok, "environment removal launch");
        Check(Until(session, "override=absent").find("override=absent") != std::string::npos, "empty override removes inherited key");
        Check(session.Close().cleanup_complete, "removal cleanup");
        char value[16]; GetEnvironmentVariableA("KANO_SESSION_TEST_OVERRIDE", value, sizeof(value));
        Check(std::string(value) == "parent", "child environment does not mutate parent");
        SetEnvironmentVariableA("KANO_SESSION_TEST_OVERRIDE", nullptr);
    }
    {
        Session session; Check(session.Start(Options("tree")).ok, "descendant tree launch");
        auto output = Until(session, "tree=");
        unsigned long root = 0, leaf = 0;
        Check(std::sscanf(output.c_str(), "tree=%lu,%lu", &root, &leaf) == 2, "descendant PID report");
        Identity identity; std::string error;
        Check(QueryIdentity(leaf, identity, error), "observe exact descendant identity");
        auto closed = session.Stop(700);
        Check(closed.ok && closed.cleanup_complete, "tree cleanup confirmed");
        WaitGone(identity);
    }
    {
        Session session; Check(session.Start(Options("owner")).ok, "nested owner launch");
        auto output = Until(session, "tree=");
        unsigned long root = 0, leaf = 0;
        Check(std::sscanf(output.c_str(), "tree=%lu,%lu", &root, &leaf) == 2, "nested owner descendant report");
        Identity rootIdentity, leafIdentity; std::string error;
        Check(QueryIdentity(root, rootIdentity, error) && QueryIdentity(leaf, leafIdentity, error), "nested identities observed");
        // Kill only the retained exact owner handle, exercising Job handle close
        // rather than invoking the owner's normal destructor/shutdown path.
        const auto owner = session.GetIdentity();
        HANDLE process = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, (DWORD)owner.pid);
        Check(process && IsAlive(owner) && TerminateProcess(process, 9), "controlled abrupt parent death");
        if (process) { WaitForSingleObject(process, 700); CloseHandle(process); }
        WaitGone(rootIdentity); WaitGone(leafIdentity);
        Check(session.Close().cleanup_complete, "abrupt parent cleanup confirmed");
    }
    {
        Session session; Check(session.Start(Options("detached-check")).ok, "contained detached-parent launch");
        auto output = Until(session, "detached=");
        unsigned long long pid = 0;
        Check(std::sscanf(output.c_str(), "detached=%llu", &pid) == 1 && pid, "detached identity report");
        Identity identity; std::string error;
        Check(QueryIdentity(pid, identity, error), "detached child identity is live");
        const auto deadline = GetTickCount64() + 500;
        while (session.IsRunning() && GetTickCount64() < deadline) session.Poll(10);
        Check(!session.IsRunning() && IsAlive(identity), "detached child survives immediate parent exit");
        Check(session.Close().cleanup_complete, "detached child remains inside outer Job boundary");
        WaitGone(identity);
    }
#else
    Session session;
    auto result = session.Start(Options("echo"));
    Check(!result.ok && !result.message.empty(), "unsupported OS fails explicitly");
#endif
    std::printf("process_session failures=%d\n", Failures);
    return Failures ? 1 : 0;
}
