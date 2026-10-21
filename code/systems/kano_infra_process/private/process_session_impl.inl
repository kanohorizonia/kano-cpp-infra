// Included in process_impl.cpp to reuse strict launch, capture and Job cleanup.
#include <map>
#include <limits>
#include <vector>
#ifndef _WIN32
#include <pthread.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#else
extern char** environ;
#endif
#endif

namespace kano::process {

struct Session::Impl {
    KanoProcess process = nullptr;
    SessionOptions options;
    Identity identity;
    bool cleanup_unverified = false;
#ifdef _WIN32
    HANDLE input = nullptr;
    struct PendingInput {
        OVERLAPPED operation{};
        std::string data; // one bounded chunk, independent of caller lifetime
        ~PendingInput() { if (operation.hEvent) CloseHandle(operation.hEvent); }
    };
    std::unique_ptr<PendingInput> pending;
    bool input_active = false;
    void ReapInput() {
        if (!input_active && pending && WaitForSingleObject(pending->operation.hEvent, 0) == WAIT_OBJECT_0)
            pending.reset();
    }
#else
    int input = -1;
    bool root_reaped = false;
    bool termination_requested = false;
    bool ownership_lost = false;
    bool containment_empty = false;
    int exit_code = -1;
    void State(SessionResult& OutResult) {
        OutResult.running = false;
        OutResult.exit_code = exit_code;
        if (ownership_lost) {
            OutResult.ok = false; OutResult.system_error = ECHILD;
            OutResult.message = "Owned child wait identity is unavailable";
            return;
        }
        if (root_reaped) return;
        siginfo_t info{};
        if (waitid(P_PID, (id_t)process->pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0) {
            if (info.si_pid == process->pid) {
                exit_code = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
                OutResult.exit_code = exit_code;
            } else OutResult.running = true;
        } else if (errno == EINTR) OutResult.running = true;
        else {
            ownership_lost = cleanup_unverified = true;
            OutResult.ok = false; OutResult.system_error = errno;
            OutResult.message = "Cannot observe owned child without reaping";
        }
    }
#endif
    ~Impl() {
#ifdef _WIN32
        if (input) CloseHandle(input);
#else
        if (input >= 0) close(input);
        if (process && !root_reaped && !ownership_lost && termination_requested) {
            int status = 0;
            (void)waitpid(process->pid, &status, WNOHANG);
        }
#endif
        if (process) kano_process_free(process); // closes kill-on-close Job
#ifdef _WIN32
        ReapInput();
        // An OS cancellation that never completes must not create a dangling
        // OVERLAPPED/buffer. Explicit Close reports this as incomplete cleanup.
        // Exceptional retention is at most one 64KiB chunk/event per Session.
        if (pending) pending.release();
#endif
    }
};

namespace {
SessionResult SessionError(const char* InMessage, unsigned long InError = 0) {
    SessionResult result;
    result.message = InMessage;
    result.system_error = InError;
    return result;
}

#ifdef _WIN32
bool Wide(const std::string& InText, std::wstring& OutText) {
    if (InText.find('\0') != std::string::npos || InText.size() > INT_MAX) return false;
    if (InText.empty()) { OutText.clear(); return true; }
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        InText.data(), (int)InText.size(), nullptr, 0);
    if (!size) return false;
    OutText.resize((size_t)size);
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, InText.data(),
        (int)InText.size(), &OutText[0], size) == size;
}

std::string Utf8(const std::wstring& InText) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, InText.data(),
        (int)InText.size(), nullptr, 0, nullptr, nullptr);
    std::string text((size_t)size, '\0');
    if (size) WideCharToMultiByte(CP_UTF8, 0, InText.data(), (int)InText.size(),
        &text[0], size, nullptr, nullptr);
    return text;
}

struct EnvironmentLess {
    bool operator()(const std::wstring& InA, const std::wstring& InB) const {
        return _wcsicmp(InA.c_str(), InB.c_str()) < 0;
    }
};

bool Environment(const SessionOptions& InOptions, std::vector<wchar_t>& OutBlock) {
    std::map<std::wstring, std::wstring, EnvironmentLess> entries;
    LPWCH block = GetEnvironmentStringsW();
    if (!block) return false;
    for (const wchar_t* entry = block; *entry; entry += wcslen(entry) + 1) {
        std::wstring value(entry);
        const size_t split = value.find(L'=', 1); // retain Windows drive entries
        if (split != std::wstring::npos) entries[value.substr(0, split)] = value.substr(split + 1);
    }
    FreeEnvironmentStringsW(block);
    for (const auto& entry : InOptions.environment) {
        std::wstring name, value;
        if (entry.first.empty() || entry.first.find('=') != std::string::npos ||
            !Wide(entry.first, name) || !Wide(entry.second, value)) {
            SetLastError(ERROR_INVALID_PARAMETER);
            return false;
        }
        if (value.empty()) entries.erase(name);
        else entries[name] = value;
    }
    for (const auto& entry : entries) {
        OutBlock.insert(OutBlock.end(), entry.first.begin(), entry.first.end());
        OutBlock.push_back(L'=');
        OutBlock.insert(OutBlock.end(), entry.second.begin(), entry.second.end());
        OutBlock.push_back(L'\0');
    }
    OutBlock.push_back(L'\0');
    if (entries.empty()) OutBlock.push_back(L'\0');
    return true;
}

bool HandleIdentity(HANDLE InProcess, DWORD InPid, Identity& OutIdentity) {
    FILETIME created{}, exited{}, kernel{}, user{};
    DWORD exitCode = 0;
    wchar_t path[32768];
    DWORD size = (DWORD)(sizeof(path) / sizeof(path[0]));
    if (WaitForSingleObject(InProcess, 0) != WAIT_TIMEOUT ||
        !GetExitCodeProcess(InProcess, &exitCode) || exitCode != STILL_ACTIVE ||
        !GetProcessTimes(InProcess, &created, &exited, &kernel, &user) ||
        !QueryFullProcessImageNameW(InProcess, 0, path, &size)) return false;
    OutIdentity.pid = InPid;
    OutIdentity.creation_time = ((std::uint64_t)created.dwHighDateTime << 32) | created.dwLowDateTime;
    OutIdentity.executable = Utf8(std::wstring(path, size));
    return !OutIdentity.executable.empty();
}

bool InputPipe(HANDLE& OutParent, HANDLE& OutChild) {
    static LONG sequence = 0;
    wchar_t name[128];
    swprintf_s(name, L"\\\\.\\pipe\\kano-process-input-%lu-%lu", GetCurrentProcessId(),
        (unsigned long)InterlockedIncrement(&sequence));
    OutParent = CreateNamedPipeW(name, PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED |
        FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE |
        PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, nullptr);
    if (OutParent == INVALID_HANDLE_VALUE) { OutParent = nullptr; return false; }
    SECURITY_ATTRIBUTES attributes{sizeof(attributes), nullptr, TRUE};
    OutChild = CreateFileW(name, GENERIC_READ, 0, &attributes, OPEN_EXISTING, 0, nullptr);
    if (OutChild == INVALID_HANDLE_VALUE) {
        const DWORD error = GetLastError();
        OutChild = nullptr;
        CloseHandle(OutParent); OutParent = nullptr; SetLastError(error); return false;
    }
    OVERLAPPED connection{};
    connection.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    const BOOL connected = connection.hEvent && ConnectNamedPipe(OutParent, &connection);
    const DWORD error = connected ? ERROR_SUCCESS : GetLastError();
    if (connection.hEvent) CloseHandle(connection.hEvent);
    if (!connected && error != ERROR_PIPE_CONNECTED) {
        CloseHandle(OutChild); OutChild = nullptr;
        CloseHandle(OutParent); OutParent = nullptr; SetLastError(error); return false;
    }
    return true;
}

bool Validate(const SessionOptions& InOptions) {
    if (InOptions.executable.empty() || InOptions.startup_timeout_ms <= 0 ||
        InOptions.cleanup_timeout_ms <= 0 || !InOptions.stdout_max_bytes ||
        !InOptions.stderr_max_bytes || InOptions.stdout_max_bytes == (size_t)-1 ||
        InOptions.stderr_max_bytes == (size_t)-1) return false;
    std::wstring checked;
    if (!Wide(InOptions.executable, checked) || !Wide(InOptions.working_dir, checked)) return false;
    for (const auto& arg : InOptions.arguments) if (!Wide(arg, checked)) return false;
    return true;
}

struct LaunchText {
    std::vector<const char*> arguments;
    KanoProcessOptions options{};
    std::wstring executable, command, directory;
    std::vector<wchar_t> environment;
    bool Initialize(const SessionOptions& InOptions) {
        for (const auto& arg : InOptions.arguments) arguments.push_back(arg.c_str());
        options.executable = InOptions.executable.c_str();
        options.working_dir = InOptions.working_dir.empty() ? nullptr : InOptions.working_dir.c_str();
        options.argv = arguments.data(); options.argv_count = arguments.size();
        options.mode = KANO_PROCESS_MODE_CAPTURE;
        KanoProcess temporary = kano_process_alloc(&options);
        if (!temporary) return false;
        temporary->strict_unattended = true;
        char* line = kano_process_build_command_line(temporary);
        const bool valid = line && Wide(line, command) && Wide(InOptions.executable, executable) &&
            Wide(InOptions.working_dir, directory);
        free(line); kano_process_free(temporary);
        return valid && Environment(InOptions, environment);
    }
};

void State(KanoProcess InProcess, SessionResult& OutResult) {
    const DWORD waited = WaitForSingleObject(InProcess->process_info.hProcess, 0);
    OutResult.running = waited == WAIT_TIMEOUT;
    if (waited == WAIT_OBJECT_0) {
        DWORD code = 0;
        if (GetExitCodeProcess(InProcess->process_info.hProcess, &code)) OutResult.exit_code = (int)code;
        else { OutResult.ok = false; OutResult.system_error = GetLastError(); }
    } else if (waited == WAIT_FAILED) {
        OutResult.ok = false; OutResult.system_error = GetLastError();
    }
}
#else
bool PosixText(const std::string& InText) {
    for (size_t index = 0; index < InText.size();) {
        const unsigned char first = (unsigned char)InText[index++];
        if (!first) return false;
        if (first < 0x80) continue;
        unsigned int value = 0, minimum = 0;
        size_t continuation = 0;
        if (first >= 0xc2 && first <= 0xdf) { value = first & 0x1f; minimum = 0x80; continuation = 1; }
        else if (first >= 0xe0 && first <= 0xef) { value = first & 0x0f; minimum = 0x800; continuation = 2; }
        else if (first >= 0xf0 && first <= 0xf4) { value = first & 0x07; minimum = 0x10000; continuation = 3; }
        else return false;
        if (continuation > InText.size() - index) return false;
        for (size_t part = 0; part < continuation; ++part) {
            const unsigned char next = (unsigned char)InText[index++];
            if ((next & 0xc0) != 0x80) return false;
            value = (value << 6) | (next & 0x3f);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
    }
    return true;
}

bool Validate(const SessionOptions& InOptions) {
    if (InOptions.executable.empty() || InOptions.executable.front() != '/' ||
        InOptions.startup_timeout_ms <= 0 || InOptions.cleanup_timeout_ms <= 0 ||
        !InOptions.stdout_max_bytes || !InOptions.stderr_max_bytes ||
        InOptions.stdout_max_bytes == (size_t)-1 || InOptions.stderr_max_bytes == (size_t)-1 ||
        !PosixText(InOptions.executable) || !PosixText(InOptions.working_dir)) return false;
    for (const auto& argument : InOptions.arguments) if (!PosixText(argument)) return false;
    for (const auto& entry : InOptions.environment)
        if (entry.first.empty() || entry.first.find('=') != std::string::npos ||
            !PosixText(entry.first) || !PosixText(entry.second)) return false;
    return true;
}

struct LaunchText {
    std::vector<const char*> arguments;
    KanoProcessOptions options{};
    std::vector<std::string> environment;
    std::vector<char*> environment_pointers;
    bool Initialize(const SessionOptions& InOptions) {
        for (const auto& argument : InOptions.arguments) arguments.push_back(argument.c_str());
        options.executable = InOptions.executable.c_str();
        options.working_dir = InOptions.working_dir.empty() ? nullptr : InOptions.working_dir.c_str();
        options.argv = arguments.data(); options.argv_count = arguments.size();
        options.mode = KANO_PROCESS_MODE_CAPTURE;
        std::map<std::string, std::string> entries;
#if defined(__APPLE__)
        char** inherited = *_NSGetEnviron();
#else
        char** inherited = ::environ;
#endif
        for (char** entry = inherited; entry && *entry; ++entry) {
            const std::string text(*entry);
            const size_t split = text.find('=');
            if (split != std::string::npos && split) entries[text.substr(0, split)] = text.substr(split + 1);
        }
        for (const auto& entry : InOptions.environment) {
            if (entry.second.empty()) entries.erase(entry.first);
            else entries[entry.first] = entry.second;
        }
        for (const auto& entry : entries) environment.push_back(entry.first + "=" + entry.second);
        for (auto& entry : environment) environment_pointers.push_back(&entry[0]);
        environment_pointers.push_back(nullptr);
        return true;
    }
};

bool InputPipe(int& OutParent, int& OutChild, long long InDeadline) {
    std::unique_lock<std::mutex> lock(kano_process_spawn_mutex, std::defer_lock);
    if (!kano_process_lock_spawn(lock, InDeadline)) return false;
    int endpoints[2] = {-1, -1};
    if (!kano_process_cloexec_pipe(endpoints)) return false;
    if (!kano_process_make_nonblocking(endpoints[1])) {
        const int error = errno;
        close(endpoints[0]); close(endpoints[1]); errno = error;
        return false;
    }
    OutParent = endpoints[1]; OutChild = endpoints[0];
    return true;
}

ssize_t WritePipe(int InFd, const char* InData, size_t InSize) {
    sigset_t pipeSignal, previous, pending;
    sigemptyset(&pipeSignal); sigaddset(&pipeSignal, SIGPIPE);
    const int blocked = pthread_sigmask(SIG_BLOCK, &pipeSignal, &previous);
    if (blocked) { errno = blocked; return -1; }
    if (sigpending(&pending) != 0) {
        const int error = errno;
        (void)pthread_sigmask(SIG_SETMASK, &previous, nullptr);
        errno = error; return -1;
    }
    const bool alreadyPending = sigismember(&pending, SIGPIPE) == 1;
    const ssize_t count = write(InFd, InData, InSize);
    int error = errno;
    // Consume only a newly generated blocked SIGPIPE, preserving any signal
    // pending before this write and the caller's original thread mask.
    if (count < 0 && error == EPIPE && !alreadyPending && sigpending(&pending) == 0 &&
        sigismember(&pending, SIGPIPE) == 1) {
        int observed = 0;
        const int waited = sigwait(&pipeSignal, &observed);
        if (waited) error = waited;
    }
    const int restored = pthread_sigmask(SIG_SETMASK, &previous, nullptr);
    if (restored) { errno = restored; return -1; }
    errno = error;
    return count;
}
#endif

void Capture(KanoUnattendedProcessResult& InCapture, SessionResult& OutResult) {
    if (InCapture.process.stdout_size)
        OutResult.stdout_data.append(InCapture.process.stdout_data, InCapture.process.stdout_size);
    if (InCapture.process.stderr_size)
        OutResult.stderr_data.append(InCapture.process.stderr_data, InCapture.process.stderr_size);
    OutResult.stdout_truncated = InCapture.process.stdout_truncated;
    OutResult.stderr_truncated = InCapture.process.stderr_truncated;
}
} // namespace

Session::Session() : mImpl(new Impl) {}
Session::~Session() { if (mImpl) Close(); }
Session::Session(Session&&) noexcept = default;
Session& Session::operator=(Session&& InOther) noexcept {
    if (this != &InOther) { if (mImpl) Close(); mImpl = std::move(InOther.mImpl); }
    return *this;
}

SessionResult Session::Start(const SessionOptions& InOptions) {
#ifdef _WIN32
    if (!mImpl) mImpl.reset(new Impl);
    if (mImpl->cleanup_unverified)
        return SessionError("Previous launch cleanup is unverified; session cannot be reused");
    if (mImpl->process) return SessionError("Session already owns a process; close it before restart");
    if (!Validate(InOptions)) return SessionError("Invalid session options");
    mImpl->identity = {};
    const long long deadline = kano_process_now_ms() + InOptions.startup_timeout_ms;
    LaunchText launch;
    if (!launch.Initialize(InOptions)) return SessionError("Cannot prepare process launch", GetLastError());
    HANDLE childInput = nullptr;
    if (!InputPipe(mImpl->input, childInput)) return SessionError("Cannot create process input", GetLastError());
    KanoProcessSessionLaunch extra{childInput, launch.environment.data(), launch.executable.c_str(),
        &launch.command[0], launch.directory.empty() ? nullptr : launch.directory.c_str()};
    KanoUnattendedProcessResult spawned{};
    spawned.status = KANO_UNATTENDED_PROCESS_COMPLETED;
    spawned.cleanup_complete = true;
    mImpl->process = kano_process_spawn_internal(&launch.options, &spawned, deadline,
        InOptions.cleanup_timeout_ms, &extra);
    CloseHandle(childInput);
#ifdef KANO_PROCESS_TESTING
    if (!mImpl->process && kano_process_fail_launch_cleanup_confirmation) {
        kano_process_fail_launch_cleanup_confirmation = false;
        // The fixture child must already be confirmed stopped. Only the first
        // reported observation is hidden; this hook never creates an orphan.
        if (spawned.cleanup_complete) spawned.cleanup_complete = false;
    }
#endif
    mImpl->options = InOptions;
    SessionResult result;
    result.ok = mImpl->process != nullptr;
    result.system_error = spawned.system_error;
    result.cleanup_complete = spawned.cleanup_complete;
    if (!result.ok) {
        mImpl->cleanup_unverified = !result.cleanup_complete;
        CloseInput();
        result.message = "Contained process launch failed (status=" + std::to_string(spawned.status) + ")";
        return result;
    }
    if (!HandleIdentity(mImpl->process->process_info.hProcess, mImpl->process->process_info.dwProcessId,
        mImpl->identity)) {
        // A very short-lived child may already have exited. Its creation identity
        // is still available from the retained root handle, without PID lookup.
        FILETIME created{}, exited{}, kernel{}, user{};
        if (GetProcessTimes(mImpl->process->process_info.hProcess, &created, &exited, &kernel, &user)) {
            mImpl->identity.pid = mImpl->process->process_info.dwProcessId;
            mImpl->identity.creation_time = ((std::uint64_t)created.dwHighDateTime << 32) | created.dwLowDateTime;
            mImpl->identity.executable = InOptions.executable;
        } else {
            const DWORD error = GetLastError();
            auto closed = Close(); closed.ok = false; closed.system_error = error;
            closed.message = "Cannot establish owned process identity"; return closed;
        }
    }
    State(mImpl->process, result);
    return result;
#else
    if (!mImpl) mImpl.reset(new Impl);
    if (mImpl->cleanup_unverified)
        return SessionError("Previous launch cleanup is unverified; session cannot be reused");
    if (mImpl->process) return SessionError("Session already owns a process; close it before restart");
    if (!Validate(InOptions)) {
        auto result = SessionError("Invalid session options", EINVAL);
        result.cleanup_complete = true;
        return result;
    }
    struct sigaction childAction{};
    const int childActionResult = sigaction(SIGCHLD, nullptr, &childAction);
    if (childActionResult != 0 || childAction.sa_handler == SIG_IGN ||
        (childAction.sa_flags & SA_NOCLDWAIT)) {
        auto result = SessionError("Session requires retained child wait ownership", childActionResult ? errno : ECHILD);
        result.cleanup_complete = true;
        return result;
    }
    mImpl->identity = {};
    mImpl->root_reaped = mImpl->termination_requested = mImpl->ownership_lost = mImpl->containment_empty = false;
    mImpl->exit_code = -1;
    const long long deadline = kano_process_now_ms() + InOptions.startup_timeout_ms;
    LaunchText launch;
    if (!launch.Initialize(InOptions)) {
        auto result = SessionError("Cannot prepare process launch", errno);
        result.cleanup_complete = true; return result;
    }
    int childInput = -1;
    if (!InputPipe(mImpl->input, childInput, deadline)) {
        auto result = SessionError("Cannot create process input", errno);
        result.cleanup_complete = true; return result;
    }
    KanoProcessSessionLaunch extra{childInput, launch.environment_pointers.data()};
    KanoUnattendedProcessResult spawned{};
    spawned.status = KANO_UNATTENDED_PROCESS_COMPLETED;
    spawned.cleanup_complete = true;
    mImpl->process = kano_process_spawn_internal(&launch.options, &spawned, deadline,
        InOptions.cleanup_timeout_ms, &extra);
    close(childInput);
#ifdef KANO_PROCESS_TESTING
    if (!mImpl->process && kano_process_fail_launch_cleanup_confirmation) {
        kano_process_fail_launch_cleanup_confirmation = false;
        if (spawned.cleanup_complete) spawned.cleanup_complete = false;
    }
#endif
    mImpl->options = InOptions;
    SessionResult result;
    result.ok = mImpl->process != nullptr;
    result.system_error = spawned.system_error;
    result.cleanup_complete = spawned.cleanup_complete;
    if (!result.ok) {
        mImpl->cleanup_unverified = !result.cleanup_complete;
        CloseInput();
        result.message = "Contained process launch failed (status=" + std::to_string(spawned.status) + ")";
        return result;
    }
    // This records the owned child only. General POSIX PID identity queries
    // remain unsupported; waitid(WNOWAIT) retains the actual ownership token.
    mImpl->identity.pid = (std::uint64_t)mImpl->process->pid;
    mImpl->identity.executable = InOptions.executable;
    mImpl->State(result);
    return result;
#endif
}

void Session::CloseInput() {
#ifdef _WIN32
    if (mImpl && mImpl->input) { CloseHandle(mImpl->input); mImpl->input = nullptr; }
#else
    if (mImpl && mImpl->input >= 0) { close(mImpl->input); mImpl->input = -1; }
#endif
}

SessionResult Session::Poll(int InTimeoutMs) {
#ifdef _WIN32
    if (!mImpl || !mImpl->process || InTimeoutMs < 0) return SessionError("Invalid session poll");
    mImpl->ReapInput();
    const long long deadline = kano_process_now_ms() + InTimeoutMs;
    KanoUnattendedProcessResult capture{};
    capture.status = KANO_UNATTENDED_PROCESS_COMPLETED;
    KanoProcessCaptureLimitsV2 limits{mImpl->options.stdout_max_bytes, mImpl->options.stderr_max_bytes};
    SessionResult result; result.ok = true;
    do {
        bool progress = false;
        if (!kano_process_strict_read(mImpl->process, false, &limits, &capture, &progress) ||
            !kano_process_strict_read(mImpl->process, true, &limits, &capture, &progress)) {
            result.ok = false; result.message = "Process capture failed"; result.system_error = capture.system_error;
        }
        State(mImpl->process, result);
        if (!result.ok || progress || !result.running || kano_process_now_ms() >= deadline) break;
        const long long remaining = deadline - kano_process_now_ms();
        if (remaining > 0) Sleep((DWORD)(remaining < 5 ? remaining : 5));
    } while (true);
    Capture(capture, result);
    kano_process_free_unattended_result(&capture);
    return result;
#else
    if (!mImpl || !mImpl->process || InTimeoutMs < 0) return SessionError("Invalid session poll", EINVAL);
    const long long deadline = kano_process_now_ms() + InTimeoutMs;
    KanoUnattendedProcessResult capture{};
    capture.status = KANO_UNATTENDED_PROCESS_COMPLETED;
    KanoProcessCaptureLimitsV2 limits{mImpl->options.stdout_max_bytes, mImpl->options.stderr_max_bytes};
    SessionResult result; result.ok = true;
    do {
        bool progress = false;
        if (!kano_process_strict_read(mImpl->process, false, &limits, &capture, &progress) ||
            !kano_process_strict_read(mImpl->process, true, &limits, &capture, &progress)) {
            result.ok = false; result.message = "Process capture failed"; result.system_error = capture.system_error;
        }
        mImpl->State(result);
        if (!result.ok || progress || !result.running || kano_process_now_ms() >= deadline) break;
        const long long remaining = deadline - kano_process_now_ms();
        if (remaining > 0) (void)poll(nullptr, 0, (int)(remaining < 5 ? remaining : 5));
    } while (true);
    Capture(capture, result);
    kano_process_free_unattended_result(&capture);
    return result;
#endif
}

SessionResult Session::Write(const std::string& InData, int InTimeoutMs) {
#ifdef _WIN32
    if (!mImpl || !mImpl->process || !mImpl->input || InTimeoutMs <= 0)
        return SessionError("Invalid session input write");
    const long long deadline = kano_process_now_ms() + InTimeoutMs;
    SessionResult result; result.ok = true;
    mImpl->ReapInput();
    if (mImpl->pending) return SessionError("Previous input cancellation is incomplete");
    mImpl->pending.reset(new Impl::PendingInput);
    auto* pending = mImpl->pending.get();
    pending->operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!pending->operation.hEvent) {
        const DWORD error = GetLastError(); mImpl->pending.reset();
        return SessionError("Cannot create input event", error);
    }
    mImpl->input_active = true;
    size_t written = 0;
    bool cancellationIncomplete = false;
    while (written < InData.size()) {
        ResetEvent(pending->operation.hEvent);
        DWORD count = 0;
        const size_t remainingBytes = InData.size() - written;
        const DWORD requested = (DWORD)(remainingBytes < 65536 ? remainingBytes : 65536);
        pending->data.assign(InData, written, requested);
        const BOOL immediate = WriteFile(mImpl->input, pending->data.data(), requested,
            &count, &pending->operation);
        DWORD error = immediate ? ERROR_SUCCESS : GetLastError();
        if (!immediate && error == ERROR_IO_PENDING) {
            do {
                // Drain while stdin is blocked, avoiding bidirectional pipe deadlock.
                auto drained = Poll(0);
                const size_t stdoutRemaining = mImpl->options.stdout_max_bytes - result.stdout_data.size();
                const size_t stderrRemaining = mImpl->options.stderr_max_bytes - result.stderr_data.size();
                result.stdout_data.append(drained.stdout_data, 0, stdoutRemaining);
                result.stderr_data.append(drained.stderr_data, 0, stderrRemaining);
                result.stdout_truncated |= drained.stdout_truncated || drained.stdout_data.size() > stdoutRemaining;
                result.stderr_truncated |= drained.stderr_truncated || drained.stderr_data.size() > stderrRemaining;
                if (!drained.ok) { error = drained.system_error ? drained.system_error : ERROR_READ_FAULT; break; }
                const long long remaining = deadline - kano_process_now_ms();
                if (remaining <= 0) { error = ERROR_TIMEOUT; break; }
                const DWORD waited = WaitForSingleObject(pending->operation.hEvent, (DWORD)(remaining < 5 ? remaining : 5));
                if (waited == WAIT_OBJECT_0) {
                    error = GetOverlappedResult(mImpl->input, &pending->operation, &count, FALSE)
                        ? ERROR_SUCCESS : GetLastError();
                    break;
                }
                if (waited == WAIT_FAILED) { error = GetLastError(); break; }
            } while (true);
            if (error != ERROR_SUCCESS) {
                CancelIoEx(mImpl->input, &pending->operation);
                // Cancellation itself is bounded. If it cannot be confirmed,
                // retain its event/buffer until the process exits (below).
                const DWORD cancelled = WaitForSingleObject(pending->operation.hEvent,
                    (DWORD)mImpl->options.cleanup_timeout_ms);
                if (cancelled != WAIT_OBJECT_0) {
                    CloseInput();
                    // Closing the only issuing handle completes cancellation.
                    // Do not free storage before the completion is observed.
                    if (WaitForSingleObject(pending->operation.hEvent, 0) != WAIT_OBJECT_0) {
                        cancellationIncomplete = true;
                        result.message = "Input cancellation incomplete; session input closed";
                    }
                }
            }
        }
        if (error != ERROR_SUCCESS || !count) {
            result.ok = false; result.system_error = error;
            if (result.message.empty()) result.message = error == ERROR_TIMEOUT ? "Process input deadline exceeded" : "Process input failed";
            break;
        }
        written += count;
        if (written < InData.size() && kano_process_now_ms() >= deadline) {
            result.ok = false; result.system_error = ERROR_TIMEOUT; result.message = "Process input deadline exceeded"; break;
        }
    }
    mImpl->input_active = false;
    if (!cancellationIncomplete) mImpl->pending.reset();
    State(mImpl->process, result);
    return result;
#else
    if (!mImpl || !mImpl->process || mImpl->input < 0 || InTimeoutMs <= 0)
        return SessionError("Invalid session input write", EINVAL);
    const long long deadline = kano_process_now_ms() + InTimeoutMs;
    SessionResult result; result.ok = true;
    size_t written = 0;
    while (written < InData.size()) {
        auto drained = Poll(0);
        const size_t stdoutRemaining = mImpl->options.stdout_max_bytes - result.stdout_data.size();
        const size_t stderrRemaining = mImpl->options.stderr_max_bytes - result.stderr_data.size();
        result.stdout_data.append(drained.stdout_data, 0, stdoutRemaining);
        result.stderr_data.append(drained.stderr_data, 0, stderrRemaining);
        result.stdout_truncated |= drained.stdout_truncated || drained.stdout_data.size() > stdoutRemaining;
        result.stderr_truncated |= drained.stderr_truncated || drained.stderr_data.size() > stderrRemaining;
        if (!drained.ok) {
            result.ok = false; result.system_error = drained.system_error;
            result.message = drained.message; break;
        }
        if (kano_process_now_ms() >= deadline) {
            result.ok = false; result.system_error = ETIMEDOUT;
            result.message = "Process input deadline exceeded"; break;
        }
        const size_t remainingBytes = InData.size() - written;
        const size_t requested = remainingBytes < 65536 ? remainingBytes : 65536;
        const ssize_t count = WritePipe(mImpl->input, InData.data() + written, requested);
        if (count > 0) { written += (size_t)count; continue; }
        const int error = count < 0 ? errno : EIO;
        if (error == EINTR) continue;
        if (error != EAGAIN && error != EWOULDBLOCK) {
            result.ok = false; result.system_error = error; result.message = "Process input failed";
            if (error == EPIPE) CloseInput();
            break;
        }
        const long long remaining = deadline - kano_process_now_ms();
        if (remaining > 0) {
            struct pollfd input = {mImpl->input, POLLOUT | POLLERR | POLLHUP, 0};
            if (poll(&input, 1, (int)(remaining < 5 ? remaining : 5)) < 0 && errno != EINTR) {
                result.ok = false; result.system_error = errno; result.message = "Cannot wait for process input"; break;
            }
        }
    }
    mImpl->State(result);
    return result;
#endif
}

bool Session::IsRunning() const {
#ifdef _WIN32
    return mImpl && mImpl->process &&
        WaitForSingleObject(mImpl->process->process_info.hProcess, 0) == WAIT_TIMEOUT;
#else
    if (!mImpl || !mImpl->process) return false;
    SessionResult result; result.ok = true;
    mImpl->State(result);
    return result.ok && result.running;
#endif
}

Identity Session::GetIdentity() const { return mImpl ? mImpl->identity : Identity{}; }

SessionResult Session::Stop(int InTimeoutMs) {
#ifdef _WIN32
    if (InTimeoutMs <= 0) return SessionError("Cleanup budget must be positive");
    SessionResult result; result.ok = true;
    if (!mImpl || !mImpl->process) {
        result.cleanup_complete = !mImpl || !mImpl->cleanup_unverified;
        result.ok = result.cleanup_complete;
        if (!result.ok) result.message = "Previous launch cleanup remains unverified";
        return result;
    }
    CloseInput();
    const long long deadline = kano_process_now_ms() + InTimeoutMs;
    KanoUnattendedProcessResult capture{};
    capture.status = KANO_UNATTENDED_PROCESS_COMPLETED;
    HANDLE members[kano_process_max_cleanup_handles]{};
    size_t memberCount = 0;
    const bool observable = kano_process_strict_collect_members(mImpl->process, members,
        &memberCount, deadline, &capture);
    if (!TerminateJobObject(mImpl->process->job, 1)) {
        result.ok = false; result.system_error = GetLastError(); result.message = "Owned Job termination failed";
    }
    KanoProcessCaptureLimitsV2 limits{mImpl->options.stdout_max_bytes, mImpl->options.stderr_max_bytes};
    do {
        mImpl->ReapInput();
        bool progress = false;
        const bool captured = kano_process_strict_read(mImpl->process, false, &limits, &capture, &progress) &&
            kano_process_strict_read(mImpl->process, true, &limits, &capture, &progress);
        bool membersStopped = observable;
        for (size_t i = 0; i < memberCount; ++i)
            if (WaitForSingleObject(members[i], 0) != WAIT_OBJECT_0) membersStopped = false;
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting{};
        const bool accounted = QueryInformationJobObject(mImpl->process->job,
            JobObjectBasicAccountingInformation, &accounting, sizeof(accounting), nullptr) != FALSE;
        State(mImpl->process, result);
        if (captured && accounted && membersStopped && !mImpl->pending &&
            WaitForSingleObject(mImpl->process->process_info.hProcess, 0) == WAIT_OBJECT_0 && accounting.ActiveProcesses == 0 &&
            kano_process_strict_pipes_closed(mImpl->process)) {
            result.cleanup_complete = true; break;
        }
        const long long remaining = deadline - kano_process_now_ms();
        if (remaining <= 0) break;
        if (!progress) Sleep((DWORD)(remaining < 5 ? remaining : 5));
    } while (true);
    for (size_t i = 0; i < memberCount; ++i) CloseHandle(members[i]);
    Capture(capture, result);
    if (capture.status != KANO_UNATTENDED_PROCESS_COMPLETED) {
        result.ok = false; result.system_error = capture.system_error;
    }
    kano_process_free_unattended_result(&capture);
    if (!result.cleanup_complete) { result.ok = false; result.message = "Owned process cleanup could not be confirmed within budget"; }
    if (result.cleanup_complete) {
        kano_process_free(mImpl->process); mImpl->process = nullptr;
    }
    return result;
#else
    if (InTimeoutMs <= 0) return SessionError("Cleanup budget must be positive", EINVAL);
    SessionResult result; result.ok = true;
    if (!mImpl || !mImpl->process) {
        result.cleanup_complete = !mImpl || !mImpl->cleanup_unverified;
        result.ok = result.cleanup_complete;
        if (!result.ok) result.message = "Previous launch cleanup remains unverified";
        return result;
    }
    CloseInput();
    const long long deadline = kano_process_now_ms() + InTimeoutMs;
    mImpl->State(result);
    if (!mImpl->termination_requested && !mImpl->ownership_lost && !mImpl->root_reaped) {
        // The root remains unreaped here, reserving the PID/group identity.
        mImpl->termination_requested = true;
        if (!kano_process_signal_unreaped_tree(mImpl->process, SIGKILL)) {
            result.ok = false; result.system_error = errno; result.message = "Owned process termination failed";
        }
    }
    KanoUnattendedProcessResult capture{};
    capture.status = KANO_UNATTENDED_PROCESS_COMPLETED;
    KanoProcessCaptureLimitsV2 limits{mImpl->options.stdout_max_bytes, mImpl->options.stderr_max_bytes};
    do {
        bool progress = false;
        const bool stdoutCaptured = kano_process_strict_read(mImpl->process, false, &limits, &capture, &progress);
        const bool stderrCaptured = kano_process_strict_read(mImpl->process, true, &limits, &capture, &progress);
        mImpl->State(result);
        if (!result.running && !mImpl->root_reaped && !mImpl->ownership_lost && mImpl->termination_requested) {
            int status = 0;
            const pid_t waited = waitpid(mImpl->process->pid, &status, WNOHANG);
            if (waited == mImpl->process->pid) {
                mImpl->root_reaped = true;
                mImpl->exit_code = kano_process_status_to_exit_code(status);
                result.exit_code = mImpl->exit_code;
            } else if (waited < 0 && errno != EINTR) {
                mImpl->ownership_lost = mImpl->cleanup_unverified = true;
                result.ok = false; result.system_error = errno; result.message = "Owned child reaping failed";
            }
        }
        if (mImpl->root_reaped && !mImpl->containment_empty) {
            if (kill(-mImpl->process->process_group, 0) != 0) {
                if (errno == ESRCH) mImpl->containment_empty = true;
                else { result.system_error = errno; }
            }
        }
        if (stdoutCaptured && stderrCaptured && !mImpl->ownership_lost && mImpl->root_reaped &&
            mImpl->containment_empty && kano_process_strict_pipes_closed(mImpl->process)) {
            result.cleanup_complete = true; break;
        }
        if (mImpl->ownership_lost) break;
        const long long remaining = deadline - kano_process_now_ms();
        if (remaining <= 0) break;
        if (!progress) (void)poll(nullptr, 0, (int)(remaining < 5 ? remaining : 5));
    } while (true);
    Capture(capture, result);
    if (capture.status != KANO_UNATTENDED_PROCESS_COMPLETED) {
        result.ok = false; result.system_error = capture.system_error;
    }
    kano_process_free_unattended_result(&capture);
    if (!result.cleanup_complete) {
        result.ok = false;
        if (result.message.empty()) result.message = "Owned process cleanup could not be confirmed within budget";
    } else {
        kano_process_free(mImpl->process); mImpl->process = nullptr;
    }
    return result;
#endif
}

SessionResult Session::Close() { return Stop(mImpl ? mImpl->options.cleanup_timeout_ms : 5000); }

bool QueryIdentity(std::uint64_t InPid, Identity& OutIdentity, std::string& OutError) {
    OutIdentity = {}; OutError.clear();
#ifdef _WIN32
    if (!InPid || InPid > MAXDWORD) { OutError = "Invalid process identity PID"; return false; }
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, (DWORD)InPid);
    if (!process) { OutError = "Process identity unavailable (error=" + std::to_string(GetLastError()) + ")"; return false; }
    const bool valid = HandleIdentity(process, (DWORD)InPid, OutIdentity);
    const DWORD error = GetLastError();
    CloseHandle(process);
    if (!valid) { OutIdentity = {}; OutError = "Process is not live or identity unavailable (error=" + std::to_string(error) + ")"; }
    return valid;
#else
    (void)InPid; OutError = "Exact process identity is supported on Windows only"; return false;
#endif
}

Identity CurrentIdentity() {
    Identity identity;
#ifdef _WIN32
    HandleIdentity(GetCurrentProcess(), GetCurrentProcessId(), identity);
#endif
    return identity;
}

bool IsAlive(const Identity& InIdentity) {
    Identity current; std::string error;
    if (!InIdentity.pid || !InIdentity.creation_time || InIdentity.executable.empty() ||
        !QueryIdentity(InIdentity.pid, current, error)) return false;
#ifdef _WIN32
    std::wstring expected, actual;
    return current.creation_time == InIdentity.creation_time && Wide(current.executable, actual) &&
        Wide(InIdentity.executable, expected) && _wcsicmp(expected.c_str(), actual.c_str()) == 0;
#else
    return false;
#endif
}

bool QueryParent(const Identity& InIdentity, std::uint64_t& OutParent) {
    OutParent = 0;
#ifdef _WIN32
    if (!IsAlive(InIdentity)) return false;
    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) do {
        if (entry.th32ProcessID == InIdentity.pid) { OutParent = entry.th32ParentProcessID; break; }
    } while (Process32NextW(snapshot, &entry));
    CloseHandle(snapshot);
    if (OutParent && IsAlive(InIdentity)) return true;
#endif
    OutParent = 0; return false;
}

DetachedResult LaunchDetached(const SessionOptions& InOptions) {
    DetachedResult result;
#ifdef _WIN32
    if (!Validate(InOptions)) { result.message = "Invalid detached launch options"; return result; }
    const long long deadline = kano_process_now_ms() + InOptions.startup_timeout_ms;
    LaunchText launch;
    if (!launch.Initialize(InOptions)) {
        result.system_error = GetLastError(); result.message = "Cannot prepare detached launch"; return result;
    }
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    const DWORD flags = CREATE_SUSPENDED | DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP |
        CREATE_UNICODE_ENVIRONMENT;
    if (!CreateProcessW(launch.executable.c_str(), &launch.command[0], nullptr, nullptr, FALSE,
        flags, launch.environment.data(), launch.directory.empty() ? nullptr : launch.directory.c_str(),
        &startup, &process)) {
        result.system_error = GetLastError(); result.message = "Detached launch failed"; return result;
    }
    result.ok = HandleIdentity(process.hProcess, process.dwProcessId, result.identity);
    if (result.ok && kano_process_now_ms() >= deadline) { result.ok = false; SetLastError(ERROR_TIMEOUT); }
    if (!result.ok || ResumeThread(process.hThread) == (DWORD)-1) {
        result.ok = false; result.system_error = GetLastError();
        result.message = "Detached launch could not establish independent ownership";
        TerminateProcess(process.hProcess, 1);
        if (WaitForSingleObject(process.hProcess, (DWORD)InOptions.cleanup_timeout_ms) != WAIT_OBJECT_0)
            result.message += "; suspended child cleanup unconfirmed";
        result.identity = {};
    }
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
#else
    (void)InOptions;
    result.message = "Detached process launch is supported on Windows only";
#endif
    return result;
}

} // namespace kano::process
