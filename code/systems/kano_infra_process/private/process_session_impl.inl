// Included in process_impl.cpp to reuse strict launch, capture and Job cleanup.
#include <map>
#include <limits>
#include <vector>

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
#endif
    ~Impl() {
#ifdef _WIN32
        if (input) CloseHandle(input);
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

void Capture(KanoUnattendedProcessResult& InCapture, SessionResult& OutResult) {
    if (InCapture.process.stdout_size)
        OutResult.stdout_data.append(InCapture.process.stdout_data, InCapture.process.stdout_size);
    if (InCapture.process.stderr_size)
        OutResult.stderr_data.append(InCapture.process.stderr_data, InCapture.process.stderr_size);
    OutResult.stdout_truncated = InCapture.process.stdout_truncated;
    OutResult.stderr_truncated = InCapture.process.stderr_truncated;
}

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
#endif
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
    (void)InOptions;
    return SessionError("Persistent contained process sessions are supported on Windows only");
#endif
}

void Session::CloseInput() {
#ifdef _WIN32
    if (mImpl && mImpl->input) { CloseHandle(mImpl->input); mImpl->input = nullptr; }
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
    (void)InTimeoutMs;
    return SessionError("Persistent contained process sessions are supported on Windows only");
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
    (void)InData; (void)InTimeoutMs;
    return SessionError("Persistent contained process sessions are supported on Windows only");
#endif
}

bool Session::IsRunning() const {
#ifdef _WIN32
    return mImpl && mImpl->process &&
        WaitForSingleObject(mImpl->process->process_info.hProcess, 0) == WAIT_TIMEOUT;
#else
    return false;
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
    (void)InTimeoutMs;
    return SessionError("Persistent contained process sessions are supported on Windows only");
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
