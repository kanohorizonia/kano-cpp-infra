#include <kano_process_session.hpp>
#include <kano_process.h>
#include <kano_unattended.hpp>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#ifdef _WIN32
#include <windows.h>
#else
#include <atomic>
#include <cerrno>
#include <cstring>
#include <functional>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
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
#else
using Clock = std::chrono::steady_clock;

static std::string Until(Session& InSession, const char* InText, int InBudget = 3000,
                         bool* OutStderrTruncated = nullptr, std::size_t* OutStderrBytes = nullptr) {
    std::string output;
    const auto deadline = Clock::now() + std::chrono::milliseconds(InBudget);
    while (Clock::now() < deadline) {
        const auto result = InSession.Poll(20);
        Check(result.ok, "POSIX poll succeeds");
        Check(result.stdout_data.size() <= 1024 && result.stderr_data.size() <= 512,
            "POSIX per-poll capture is bounded");
        output += result.stdout_data;
        if (OutStderrTruncated) *OutStderrTruncated |= result.stderr_truncated;
        if (OutStderrBytes) *OutStderrBytes += result.stderr_data.size();
        if (output.find(InText) != std::string::npos || !result.running) break;
    }
    return output;
}

static std::string Hex(const std::string& InText) {
    static const char digits[] = "0123456789abcdef";
    std::string result;
    for (const unsigned char value : InText) {
        result.push_back(digits[value >> 4]);
        result.push_back(digits[value & 15]);
    }
    return result;
}

static bool HasLine(const std::string& InOutput, const std::string& InLine) {
    return ("\n" + InOutput).find("\n" + InLine + "\n") != std::string::npos;
}

struct TestDirectory {
    std::string root;
    std::vector<std::string> children;
    TestDirectory() {
        char pattern[] = "/tmp/kano-session-XXXXXX";
        const char* created = mkdtemp(pattern);
        Check(created != nullptr, "create isolated POSIX test directory");
        if (!created) return;
        char resolved[PATH_MAX];
        root = realpath(created, resolved) ? resolved : created;
    }
    std::string Child(const std::string& InName) {
        if (root.empty()) return {};
        const std::string path = root + "/" + InName;
        Check(mkdir(path.c_str(), 0700) == 0, "create isolated UTF-8 working directory");
        children.push_back(path);
        return path;
    }
    ~TestDirectory() {
        for (const auto& path : children) rmdir(path.c_str());
        if (!root.empty()) rmdir(root.c_str());
    }
};

struct TestEnvironment {
    std::string name;
    std::string previous;
    bool was_present = false;
    TestEnvironment(const char* InName, const char* InValue) : name(InName) {
        const char* value = std::getenv(InName);
        was_present = value != nullptr;
        if (value) previous = value;
        Check(setenv(InName, InValue, 1) == 0, "prepare controlled parent environment");
    }
    ~TestEnvironment() {
        if (was_present) setenv(name.c_str(), previous.c_str(), 1);
        else unsetenv(name.c_str());
    }
};

static void CheckEnvironment(const std::string& InOutput, const char* InName,
                             const char* InExpected) {
    const auto expected = InExpected ? Hex(InExpected) : "absent";
    Check(HasLine(InOutput, std::string("env:") + InName + "=" + expected),
        "child environment bytes match the launch contract");
}

static void CheckContext(const std::string& InOutput, const SessionOptions& InOptions) {
    Check(HasLine(InOutput, "cwd=" + Hex(InOptions.working_dir)), "child cwd is exact UTF-8");
    Check(HasLine(InOutput, "argc=" + std::to_string(InOptions.arguments.size() - 1)),
        "child argument count is exact");
    for (std::size_t index = 1; index < InOptions.arguments.size(); ++index)
        Check(HasLine(InOutput, "arg" + std::to_string(index - 1) + "=" + Hex(InOptions.arguments[index])),
            "child argv preserves exact bytes without shell interpretation");
}

static bool IsLiveProcess(long InPid) {
    if (InPid <= 0) return false;
#ifdef __linux__
    // An orphan zombie can await the host's reaper after group SIGKILL. It is
    // stopped, but its retained PID must not be called confirmed group cleanup.
    const std::string path = "/proc/" + std::to_string(InPid) + "/stat";
    if (FILE* file = std::fopen(path.c_str(), "r")) {
        char state[4096];
        const char* line = std::fgets(state, sizeof(state), file);
        std::fclose(file);
        const char* closing = line ? std::strrchr(state, ')') : nullptr;
        if (closing && closing[1] == ' ' && (closing[2] == 'Z' || closing[2] == 'X')) return false;
    }
#endif
    return kill((pid_t)InPid, 0) == 0 || errno == EPERM;
}

static void WaitNotLive(long InPid, int InBudget = 2000) {
    const auto deadline = Clock::now() + std::chrono::milliseconds(InBudget);
    while (IsLiveProcess(InPid) && Clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    Check(!IsLiveProcess(InPid), "controlled fixture process stopped");
}

static void CheckInvalid(const SessionOptions& InOptions, const char* InMessage) {
    Session session;
    const auto result = session.Start(InOptions);
    Check(!result.ok && result.cleanup_complete && result.system_error == EINVAL && !result.running,
        InMessage);
    Check(session.Close().cleanup_complete, "invalid launch leaves no cleanup obligation");
}

static void RunPosixTests() {
    std::puts("POSIX Session: closed standard descriptor launch regression");
    for (int mask = 1; mask <= 7; ++mask) {
        // Only this freshly exec'd owner closes standard descriptors; the main
        // test process keeps its stdio and never forks a C++ runtime itself.
        const std::string maskText = std::to_string(mask);
        const char* arguments[] = {"closed-stdio-owner", maskText.c_str()};
        KanoUnattendedProcessOptions options{};
        options.executable = KANO_SESSION_CHILD_PATH;
        options.argv = arguments; options.argv_count = 2;
        options.mode = KANO_PROCESS_MODE_CAPTURE; options.timeout_ms = 10000;
        options.cleanup_timeout_ms = 700; options.capture_limits = {1024, 512};
        KanoUnattendedProcessResult result{};
        const bool ran = kano_process_run_unattended(&options, &result);
        std::printf("closed-stdio mask=%d status=%d exit=%d cleanup=%d error=%lu\n",
            mask, (int)result.status, result.process.exit_code, result.cleanup_complete, result.system_error);
        Check(ran && result.status == KANO_UNATTENDED_PROCESS_COMPLETED &&
            result.process.exit_code == 0 && result.cleanup_complete,
            "closed-stdio owner validates Session, strict/legacy capture and pass-through launches");
        kano_process_free_unattended_result(&result);
    }
    std::puts("POSIX Session: persistent I/O and EOF");
    {
        Session session;
        Check(session.Start(Options("echo")).ok, "POSIX persistent launch");
        const auto identity = session.GetIdentity();
        Check(identity.pid && !identity.creation_time && identity.executable == KANO_SESSION_CHILD_PATH,
            "POSIX Session exposes only its retained PID and executable");
        Check(Until(session, "ready").find("ready") != std::string::npos, "POSIX readiness output");
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
        Check(session.IsRunning(), "POSIX idle session has no lifetime timer");
        Check(session.Write("hello\n", 500).ok, "POSIX stdin write");
        Check(Until(session, "hello").find("hello") != std::string::npos, "POSIX incremental response");
        Check(session.Write("cancel\n", 500).ok, "POSIX local protocol cancellation write");
        Check(Until(session, "cancelled").find("cancelled") != std::string::npos,
            "POSIX local protocol cancellation response");
        Check(session.IsRunning(), "local protocol cancellation retains the Session");
        Check(session.Write("shutdown\n", 500).ok, "POSIX shutdown command write");
        Check(Until(session, "stopped").find("stopped") != std::string::npos, "POSIX shutdown response");
        const auto closed = session.Close();
        Check(closed.ok && closed.cleanup_complete && !closed.running, "POSIX normal shutdown cleanup");
        Check(session.Close().cleanup_complete, "POSIX repeated close is idempotent");
        WaitNotLive((long)identity.pid);
    }
    {
        Session session;
        Check(session.Start(Options("echo")).ok, "POSIX EOF launch");
        Until(session, "ready"); session.CloseInput(); session.CloseInput();
        Check(Until(session, "eof").find("eof") != std::string::npos, "POSIX stdin EOF is delivered");
        Check(session.Close().cleanup_complete, "POSIX EOF cleanup");
    }
    std::puts("POSIX Session: bounded stderr and write failures");
    {
        Session session;
        Check(session.Start(Options("noise")).ok, "POSIX noisy child launch");
        bool truncated = false;
        std::size_t stderrBytes = 0;
        Check(Until(session, "ready", 3000, &truncated, &stderrBytes).find("ready") != std::string::npos,
            "POSIX noisy stderr drains without deadlock");
        Check(stderrBytes && truncated, "POSIX stderr capture reports bounded truncation");
        Check(session.Write("shutdown\n", 500).ok, "POSIX noisy child shutdown");
        Check(session.Close().cleanup_complete, "POSIX noisy child cleanup");
    }
    {
        Session session;
        Check(session.Start(Options("no-read")).ok, "POSIX blocked-input child launch");
        Until(session, "ready");
        const auto started = Clock::now();
        const auto written = session.Write(std::string(1024 * 1024, 'x'), 50);
        Check(!written.ok && written.system_error == ETIMEDOUT, "POSIX blocked stdin reaches its deadline");
        Check(Clock::now() - started < std::chrono::milliseconds(1500), "POSIX blocked write remains bounded");
        Check(session.Stop(700).cleanup_complete, "POSIX blocked-input cleanup");
    }
    {
        Session session;
        Check(session.Start(Options("closed-input")).ok, "POSIX closed-input child launch");
        Until(session, "ready");
        struct sigaction before{}, after{};
        sigset_t beforeBlocked{}, afterBlocked{};
        Check(sigaction(SIGPIPE, nullptr, &before) == 0, "observe original global SIGPIPE disposition");
        Check(pthread_sigmask(SIG_SETMASK, nullptr, &beforeBlocked) == 0, "observe caller signal mask");
        const auto written = session.Write("broken-pipe\n", 500);
        Check(!written.ok && written.system_error == EPIPE, "POSIX broken stdin reports EPIPE without killing caller");
        Check(sigaction(SIGPIPE, nullptr, &after) == 0 && before.sa_handler == after.sa_handler &&
            before.sa_flags == after.sa_flags, "POSIX write preserves global SIGPIPE disposition");
        Check(pthread_sigmask(SIG_SETMASK, nullptr, &afterBlocked) == 0, "observe caller signal mask after write");
        for (int signal = 1; signal < NSIG; ++signal) {
            Check(sigismember(&before.sa_mask, signal) == sigismember(&after.sa_mask, signal),
                "POSIX write preserves the global SIGPIPE handler mask");
            Check(sigismember(&beforeBlocked, signal) == sigismember(&afterBlocked, signal),
                "POSIX write preserves the caller signal mask");
        }
        Check(session.Stop(700).cleanup_complete, "POSIX broken-input cleanup");
    }
    {
        Session session;
        Check(session.Start(Options("closed-input")).ok, "POSIX pending-SIGPIPE fixture launch");
        Until(session, "ready");
        sigset_t pipeSignal{}, previous{}, pending{};
        sigemptyset(&pipeSignal); sigaddset(&pipeSignal, SIGPIPE);
        const int blocked = pthread_sigmask(SIG_BLOCK, &pipeSignal, &previous);
        Check(blocked == 0, "block SIGPIPE in this test thread");
        if (!blocked) {
            Check(sigpending(&pending) == 0, "observe preexisting pending SIGPIPE");
            const bool alreadyPending = sigismember(&pending, SIGPIPE) == 1;
            if (!alreadyPending) Check(raise(SIGPIPE) == 0, "prepare a caller-owned pending SIGPIPE");
            const auto written = session.Write("broken-pipe\n", 500);
            Check(!written.ok && written.system_error == EPIPE, "blocked SIGPIPE still reports EPIPE");
            const bool stillPending = sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE) == 1;
            Check(stillPending,
                "process write preserves a caller-owned pending SIGPIPE");
            if (!alreadyPending && stillPending) {
                int observed = 0;
                Check(sigwait(&pipeSignal, &observed) == 0 && observed == SIGPIPE,
                    "consume only the test-owned pending signal");
            }
            Check(pthread_sigmask(SIG_SETMASK, &previous, nullptr) == 0, "restore test thread signal mask");
        }
        Check(session.Stop(700).cleanup_complete, "POSIX pending-SIGPIPE fixture cleanup");
    }
    std::puts("POSIX Session: launch diagnostics and fail-closed validation");
    {
        struct sigaction ignored{}, previous{};
        ignored.sa_handler = SIG_IGN;
        sigemptyset(&ignored.sa_mask);
        const int changed = sigaction(SIGCHLD, &ignored, &previous);
        Check(changed == 0, "prepare controlled auto-reap signal disposition");
        if (!changed) {
            Session session;
            const auto result = session.Start(Options("echo"));
            Check(!result.ok && result.cleanup_complete && result.system_error == ECHILD,
                "POSIX launch refuses unavailable child wait ownership before creating a child");
            Check(sigaction(SIGCHLD, &previous, nullptr) == 0, "restore controlled child signal disposition");
        }
    }
    {
        Session session; auto options = Options("echo"); options.executable += ".missing";
        const auto result = session.Start(options);
        Check(!result.ok && result.cleanup_complete && result.system_error == ENOENT,
            "POSIX missing exec is diagnosed with confirmed cleanup");
        options = Options("echo"); options.working_dir = options.executable + "/not-a-directory";
        const auto cwdResult = session.Start(options);
        Check(!cwdResult.ok && cwdResult.cleanup_complete &&
            (cwdResult.system_error == ENOENT || cwdResult.system_error == ENOTDIR),
            "POSIX invalid cwd is diagnosed with confirmed cleanup");
    }
    {
        auto options = Options("echo"); options.environment = {{"", "value"}};
        CheckInvalid(options, "POSIX empty environment name rejected");
        options.environment = {{"invalid=name", "value"}};
        CheckInvalid(options, "POSIX equals in environment name rejected");
        options.environment = {{std::string("bad\0name", 8), "value"}};
        CheckInvalid(options, "POSIX embedded NUL in environment name rejected");
        options.environment = {{"KANO_SESSION_TEST_OVERRIDE", std::string("bad\0value", 9)}};
        CheckInvalid(options, "POSIX embedded NUL in environment value rejected");
        options = Options("echo"); options.arguments.push_back(std::string("bad\0arg", 7));
        CheckInvalid(options, "POSIX embedded NUL in argv rejected");
        options = Options("echo"); options.executable += std::string("\0suffix", 7);
        CheckInvalid(options, "POSIX embedded NUL in executable rejected");
        options = Options("echo"); options.working_dir = std::string("bad\0cwd", 7);
        CheckInvalid(options, "POSIX embedded NUL in cwd rejected");
        options = Options("echo"); options.executable = "relative-child";
        CheckInvalid(options, "POSIX relative executable rejected before launch");
        options = Options("echo"); options.arguments.push_back(std::string("\xc3\x28", 2));
        CheckInvalid(options, "POSIX invalid UTF-8 argv rejected");
        options = Options("echo"); options.environment = {{"KANO_SESSION_TEST_OVERRIDE", std::string("\xff", 1)}};
        CheckInvalid(options, "POSIX invalid UTF-8 environment value rejected");
    }
    {
        Session session;
        Check(session.Start(Options("exit-7")).ok, "POSIX startup-failure child launch");
        std::string diagnostic;
        int exitCode = -1;
        const auto deadline = Clock::now() + std::chrono::seconds(2);
        while (Clock::now() < deadline) {
            const auto result = session.Poll(20); diagnostic += result.stderr_data;
            Check(result.ok, "POSIX exited child poll succeeds");
            if (!result.running) { exitCode = result.exit_code; break; }
        }
        Check(exitCode == 7 && diagnostic.find("controlled startup cause") != std::string::npos,
            "POSIX exit cause and stderr retained");
        Check(session.Close().cleanup_complete, "POSIX failed child cleanup");
    }
    {
        Session session;
        Check(session.Start(Options("exit-7")).ok, "POSIX retained-child ownership fixture launch");
        const auto identity = session.GetIdentity();
        const auto deadline = Clock::now() + std::chrono::seconds(2);
        while (session.IsRunning() && Clock::now() < deadline) session.Poll(20);
        Check(!session.IsRunning(), "POSIX poll observes exit before reaping");
        int status = 0;
        const auto reaped = identity.pid ? waitpid((pid_t)identity.pid, &status, WNOHANG) : -1;
        Check(reaped == (pid_t)identity.pid && WIFEXITED(status) && WEXITSTATUS(status) == 7,
            "test can reap the exited child retained by Session");
        const auto polled = session.Poll(0);
        Check(!polled.ok && polled.system_error == ECHILD && !polled.cleanup_complete,
            "POSIX lost root ownership is diagnosed without claiming cleanup");
        const auto stopped = session.Stop(150);
        Check(!stopped.ok && !stopped.cleanup_complete,
            "POSIX lost ownership fails closed before signaling a reusable PID");
    }
    {
        TestDirectory directory;
        if (!directory.root.empty()) {
            const std::string marker = directory.root + "/marker";
            Session session; auto options = Options("mark"); options.arguments.push_back(marker);
            kano_process_test_fail_next_containment_setup();
            const auto result = session.Start(options);
            Check(!result.ok && result.cleanup_complete, "POSIX containment failure is fail-closed");
            Check(access(marker.c_str(), F_OK) != 0 && errno == ENOENT,
                "POSIX payload never executes before containment");
            Check(session.Close().cleanup_complete == result.cleanup_complete,
                "POSIX failed-start cleanup proof is preserved");
            unlink(marker.c_str());
        }
    }
    {
        Session session;
        kano_process_test_fail_next_containment_setup();
        kano_process_test_fail_next_launch_cleanup_confirmation();
        const auto started = session.Start(Options("echo"));
        Check(!started.ok && !started.cleanup_complete, "POSIX injected launch cleanup is unconfirmed");
        const auto stopped = session.Stop(700);
        const auto closed = session.Close();
        Check(!stopped.ok && !stopped.cleanup_complete && !closed.ok && !closed.cleanup_complete,
            "POSIX empty stop and close preserve unconfirmed launch cleanup");
        const auto restarted = session.Start(Options("echo"));
        Check(!restarted.ok && !restarted.cleanup_complete && !session.IsRunning(),
            "POSIX unverified failed Session refuses restart");
    }
    std::puts("POSIX Session: exact context and concurrent launch isolation");
    {
        TestDirectory directory;
        TestEnvironment inherited("KANO_SESSION_TEST_INHERITED", "inherited-parent");
        TestEnvironment overridden("KANO_SESSION_TEST_OVERRIDE", "parent");
        TestEnvironment removed("KANO_SESSION_TEST_REMOVED", "parent-to-remove");
        TestEnvironment upper("KANO_SESSION_TEST_CASE", "upper-parent");
        TestEnvironment lower("kano_session_test_case", "lower-parent");
        char parentCwd[PATH_MAX]{};
        Check(getcwd(parentCwd, sizeof(parentCwd)) != nullptr, "observe parent cwd");
        auto firstOptions = Options("context");
        firstOptions.working_dir = directory.Child("cwd-\xCE\xA9-\xE4\xB8\x80");
        firstOptions.arguments = {"context", "", "two words", "quote\"'", "back\\slash\\",
            "$HOME;$(exit 9)&*?", "\xCE\xA9-\xE4\xB8\x80-\xF0\x9F\x90\xB1"};
        firstOptions.environment = {{"KANO_SESSION_TEST_OVERRIDE", "child-\xCE\xA9-\xE4\xB8\x80"},
            {"KANO_SESSION_TEST_REMOVED", ""}, {"kano_session_test_case", "lower-child"}};
        auto secondOptions = Options("context");
        secondOptions.working_dir = directory.Child("other-\xE4\xBA\x8C");
        secondOptions.arguments = {"context", "second launch", "", "\xE4\xBA\x8C-\\\""};
        secondOptions.environment = {{"KANO_SESSION_TEST_OVERRIDE", "second-child"},
            {"KANO_SESSION_TEST_INHERITED", "second-inherited"}, {"KANO_SESSION_TEST_CASE", "upper-second"}};
        Session first, second;
        SessionResult firstStart, secondStart;
        std::atomic<int> ready{0};
        std::atomic<bool> launch{false};
        auto start = [&](Session& InSession, const SessionOptions& InOptions, SessionResult& OutResult) {
            ready.fetch_add(1);
            while (!launch.load()) std::this_thread::yield();
            OutResult = InSession.Start(InOptions);
        };
        std::thread firstThread(start, std::ref(first), std::cref(firstOptions), std::ref(firstStart));
        std::thread secondThread(start, std::ref(second), std::cref(secondOptions), std::ref(secondStart));
        while (ready.load() < 2) std::this_thread::yield();
        launch.store(true);
        firstThread.join(); secondThread.join();
        Check(firstStart.ok && secondStart.ok, "distinct Sessions start concurrently");
        const auto firstOutput = Until(first, "ready");
        const auto secondOutput = Until(second, "ready");
        CheckContext(firstOutput, firstOptions); CheckContext(secondOutput, secondOptions);
        CheckEnvironment(firstOutput, "KANO_SESSION_TEST_INHERITED", "inherited-parent");
        CheckEnvironment(firstOutput, "KANO_SESSION_TEST_OVERRIDE", "child-\xCE\xA9-\xE4\xB8\x80");
        CheckEnvironment(firstOutput, "KANO_SESSION_TEST_REMOVED", nullptr);
        CheckEnvironment(firstOutput, "KANO_SESSION_TEST_CASE", "upper-parent");
        CheckEnvironment(firstOutput, "kano_session_test_case", "lower-child");
        CheckEnvironment(secondOutput, "KANO_SESSION_TEST_INHERITED", "second-inherited");
        CheckEnvironment(secondOutput, "KANO_SESSION_TEST_OVERRIDE", "second-child");
        CheckEnvironment(secondOutput, "KANO_SESSION_TEST_REMOVED", "parent-to-remove");
        CheckEnvironment(secondOutput, "KANO_SESSION_TEST_CASE", "upper-second");
        CheckEnvironment(secondOutput, "kano_session_test_case", "lower-parent");
        first.CloseInput();
        Check(Until(first, "eof").find("eof") != std::string::npos,
            "first Session receives EOF while the second remains live");
        Check(second.IsRunning(), "concurrent Session did not inherit another stdin writer");
        Check(second.Write("still-live\n", 500).ok &&
            Until(second, "still-live").find("still-live") != std::string::npos,
            "second Session remains interactive after first EOF");
        const auto firstClosed = first.Close();
        const auto secondClosed = second.Close();
        Check(firstClosed.cleanup_complete && secondClosed.cleanup_complete,
            "isolated concurrent Sessions clean up");
        char currentCwd[PATH_MAX]{};
        Check(getcwd(currentCwd, sizeof(currentCwd)) && std::string(currentCwd) == parentCwd,
            "child launch preserves parent cwd");
        const std::pair<const char*, const char*> expected[] = {
            {"KANO_SESSION_TEST_INHERITED", "inherited-parent"}, {"KANO_SESSION_TEST_OVERRIDE", "parent"},
            {"KANO_SESSION_TEST_REMOVED", "parent-to-remove"}, {"KANO_SESSION_TEST_CASE", "upper-parent"},
            {"kano_session_test_case", "lower-parent"}};
        for (const auto& entry : expected) {
            const char* value = std::getenv(entry.first);
            Check(value && std::string(value) == entry.second, "concurrent launches preserve parent environment");
        }
    }
    std::puts("POSIX Session: owned descendants and escaped capture writer");
    {
        Session session;
        Check(session.Start(Options("tree")).ok, "POSIX descendant tree launch");
        const auto output = Until(session, "tree=");
        long root = 0, leaf = 0;
        Check(std::sscanf(output.c_str(), "tree=%ld,%ld", &root, &leaf) == 2 && root > 0 && leaf > 0,
            "POSIX descendant PID report");
        const auto stopped = session.Stop(700);
        WaitNotLive(root); WaitNotLive(leaf);
#ifdef __linux__
        Check(stopped.cleanup_complete || (!stopped.ok && !stopped.message.empty()),
            "Linux unconfirmed zombie-group cleanup is explicit");
        if (!stopped.cleanup_complete)
            std::puts("Linux tree cleanup remains unconfirmed after all fixture processes stopped");
#else
        Check(stopped.ok && stopped.cleanup_complete, "POSIX descendant cleanup confirmed");
#endif
        Check(!stopped.running, "POSIX stopped tree root is no longer running");
        const auto closed = session.Close();
        Check(!stopped.cleanup_complete || closed.cleanup_complete,
            "POSIX repeated cleanup retains confirmed descendant proof");
    }
    {
        Session session;
        auto options = Options("escaped-writer"); options.cleanup_timeout_ms = 150;
        Check(session.Start(options).ok, "POSIX escaped-writer launch");
        const auto output = Until(session, "escaped=");
        long escaped = 0;
        Check(std::sscanf(output.c_str(), "escaped=%ld", &escaped) == 1 && escaped > 0,
            "POSIX escaped fixture PID report");
        const auto started = Clock::now();
        const auto stopped = session.Stop(150);
        Check(!stopped.ok && !stopped.cleanup_complete && !stopped.running,
            "POSIX escaped inherited writer cannot claim cleanup");
        Check(Clock::now() - started < std::chrono::milliseconds(1000),
            "POSIX incomplete cleanup remains bounded");
        WaitNotLive(escaped, 3500);
        Check(session.Close().cleanup_complete, "POSIX cleanup completes after escaped writer closes itself");
        Check(session.Close().cleanup_complete, "POSIX completed escaped-writer cleanup is idempotent");
    }
}
#endif

static bool PolicyEnvironmentValue(const char* InName, std::string& OutValue) {
#ifdef _WIN32
    char value[256]{};
    SetLastError(ERROR_SUCCESS);
    const DWORD length = GetEnvironmentVariableA(InName, value, sizeof(value));
    const DWORD error = GetLastError();
    Check(length < sizeof(value), "controlled environment value fits fixture buffer");
    OutValue = value;
    return length || error != ERROR_ENVVAR_NOT_FOUND;
#else
    const char* value = std::getenv(InName);
    OutValue = value ? value : "";
    return value != nullptr;
#endif
}

static void SetPolicyEnvironment(const char* InName, const char* InValue) {
#ifdef _WIN32
    Check(SetEnvironmentVariableA(InName, InValue) != FALSE, "set controlled parent environment");
#else
    Check((InValue ? setenv(InName, InValue, 1) : unsetenv(InName)) == 0,
        "set controlled parent environment");
#endif
}

struct PolicyEnvironment {
    const char* name;
    std::string previous;
    bool was_present;
    PolicyEnvironment(const char* InName, const char* InValue) : name(InName),
        was_present(PolicyEnvironmentValue(InName, previous)) {
        SetPolicyEnvironment(name, InValue);
    }
    ~PolicyEnvironment() { SetPolicyEnvironment(name, was_present ? previous.c_str() : nullptr); }
};

static void CheckPolicyEnvironment(const std::string& InOutput, const char* InName,
                                   const char* InExpected) {
    const std::string line = std::string("\n") + InName + "=" +
        (InExpected ? std::string("value:") + InExpected : "absent");
    const std::string output = "\n" + InOutput;
    Check(output.find(line + "\n") != std::string::npos ||
        output.find(line + "\r\n") != std::string::npos,
        "child distinguishes exact values, empty values and absent environment keys");
}

static void RunEnvironmentPolicyTests() {
    std::puts("Session: inherited and exact environment policies");
    PolicyEnvironment inherited("KANO_SESSION_TEST_INHERITED", "parent-inherited");
    PolicyEnvironment overridden("KANO_SESSION_TEST_OVERRIDE", "parent-override");
    PolicyEnvironment removed("KANO_SESSION_TEST_REMOVED", "parent-remove");
    PolicyEnvironment empty("KANO_SESSION_TEST_EMPTY", "parent-empty");
    PolicyEnvironment forwarded("FORWARDED_ALLOW_IPS", "parent-forwarded");
    auto options = Options("environment-policy");
    Check(options.inherit_environment, "environment inheritance remains enabled by default");
    options.environment = {{"KANO_SESSION_TEST_OVERRIDE", "child-override"},
        {"KANO_SESSION_TEST_REMOVED", ""}, {"KANO_SESSION_TEST_EMPTY", ""},
        {"FORWARDED_ALLOW_IPS", ""}};
    Session session;
    Check(session.Start(options).ok, "inherited environment policy launch");
    const auto inheritedOutput = Until(session, "FORWARDED_ALLOW_IPS=");
    CheckPolicyEnvironment(inheritedOutput, "KANO_SESSION_TEST_INHERITED", "parent-inherited");
    CheckPolicyEnvironment(inheritedOutput, "KANO_SESSION_TEST_OVERRIDE", "child-override");
    CheckPolicyEnvironment(inheritedOutput, "KANO_SESSION_TEST_REMOVED", nullptr);
    CheckPolicyEnvironment(inheritedOutput, "KANO_SESSION_TEST_EMPTY", nullptr);
    CheckPolicyEnvironment(inheritedOutput, "FORWARDED_ALLOW_IPS", nullptr);
    Check(session.Close().cleanup_complete, "inherited environment policy cleanup");

    options.inherit_environment = false;
    Check(session.Start(options).ok, "exact environment policy launch");
    const auto exactOutput = Until(session, "FORWARDED_ALLOW_IPS=");
    CheckPolicyEnvironment(exactOutput, "KANO_SESSION_TEST_INHERITED", nullptr);
    CheckPolicyEnvironment(exactOutput, "KANO_SESSION_TEST_OVERRIDE", "child-override");
    CheckPolicyEnvironment(exactOutput, "KANO_SESSION_TEST_REMOVED", "");
    CheckPolicyEnvironment(exactOutput, "KANO_SESSION_TEST_EMPTY", "");
    CheckPolicyEnvironment(exactOutput, "FORWARDED_ALLOW_IPS", "");
    Check(session.Close().cleanup_complete, "exact environment policy cleanup");

    options.environment.clear();
    Check(session.Start(options).ok, "empty exact environment launch");
    const auto emptyOutput = Until(session, "FORWARDED_ALLOW_IPS=");
    for (const char* name : {"KANO_SESSION_TEST_INHERITED", "KANO_SESSION_TEST_OVERRIDE",
             "KANO_SESSION_TEST_REMOVED", "KANO_SESSION_TEST_EMPTY", "FORWARDED_ALLOW_IPS"})
        CheckPolicyEnvironment(emptyOutput, name, nullptr);
    Check(session.Close().cleanup_complete, "empty exact environment cleanup");
#ifdef _WIN32
    char directory[MAX_PATH]{}, path[MAX_PATH]{};
    const bool created = GetTempPathA(MAX_PATH, directory) &&
        GetTempFileNameA(directory, "kse", 0, path);
    Check(created, "create owned detached environment result file");
    if (created) {
        options.arguments = {"environment-file", path};
        options.environment = {{"KANO_SESSION_TEST_OVERRIDE", "detached-value"},
            {"KANO_SESSION_TEST_EMPTY", ""}, {"FORWARDED_ALLOW_IPS", ""}};
        const auto launched = LaunchDetached(options);
        Check(launched.ok, "detached exact environment launch");
        if (launched.ok) WaitGone(launched.identity);
        FILE* file = nullptr;
        Check(fopen_s(&file, path, "rb") == 0 && file, "read owned detached environment result");
        std::string output;
        if (file) {
            char buffer[1024];
            const auto count = std::fread(buffer, 1, sizeof(buffer), file);
            output.assign(buffer, count); std::fclose(file);
        }
        CheckPolicyEnvironment(output, "KANO_SESSION_TEST_INHERITED", nullptr);
        CheckPolicyEnvironment(output, "KANO_SESSION_TEST_OVERRIDE", "detached-value");
        CheckPolicyEnvironment(output, "KANO_SESSION_TEST_EMPTY", "");
        CheckPolicyEnvironment(output, "FORWARDED_ALLOW_IPS", "");
        Check(DeleteFileA(path) != FALSE, "remove only owned detached environment result file");
    }
#endif
    const std::pair<const char*, const char*> expected[] = {
        {"KANO_SESSION_TEST_INHERITED", "parent-inherited"}, {"KANO_SESSION_TEST_OVERRIDE", "parent-override"},
        {"KANO_SESSION_TEST_REMOVED", "parent-remove"}, {"KANO_SESSION_TEST_EMPTY", "parent-empty"},
        {"FORWARDED_ALLOW_IPS", "parent-forwarded"}};
    for (const auto& entry : expected) {
        std::string value;
        Check(PolicyEnvironmentValue(entry.first, value) && value == entry.second,
            "child environment policy preserves the parent environment");
    }
}

int main() {
    kano::infra::ConfigureUnattendedExecution();
    RunEnvironmentPolicyTests();
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
    RunPosixTests();
#endif
    std::printf("process_session failures=%d\n", Failures);
    return Failures ? 1 : 0;
}
