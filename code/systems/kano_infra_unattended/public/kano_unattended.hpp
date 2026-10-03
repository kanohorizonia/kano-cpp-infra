#pragma once

#include <cstdio>
#include <cstdlib>
#include <initializer_list>

#ifdef _WIN32
#ifndef NOMINMAX
#define KANO_UNATTENDED_UNDEFINE_NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define KANO_UNATTENDED_UNDEFINE_LEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#ifdef KANO_UNATTENDED_UNDEFINE_NOMINMAX
#undef NOMINMAX
#undef KANO_UNATTENDED_UNDEFINE_NOMINMAX
#endif
#ifdef KANO_UNATTENDED_UNDEFINE_LEAN
#undef WIN32_LEAN_AND_MEAN
#undef KANO_UNATTENDED_UNDEFINE_LEAN
#endif
#ifdef _MSC_VER
#include <crtdbg.h>
#include <csignal>
#endif
#else
#include <sys/resource.h>
#endif

namespace kano::infra {
namespace unattended_detail {

inline bool IsFalseValue(const char* value) noexcept {
    if (!value) {
        return false;
    }
    for (const char* candidate : {"0", "false", "no", "off"}) {
        const char* a = value;
        const char* b = candidate;
        while (*a && *b) {
            const char lower = (*a >= 'A' && *a <= 'Z') ? *a - 'A' + 'a' : *a;
            if (lower != *b) {
                break;
            }
            ++a;
            ++b;
        }
        if (!*a && !*b) {
            return true;
        }
    }
    return false;
}

#ifdef _WIN32
inline void WriteDiagnostic(const char* message) noexcept {
    if (!message) {
        return;
    }
    DWORD length = 0;
    while (message[length]) {
        ++length;
    }
    DWORD written = 0;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), message, length, &written, nullptr);
}

[[noreturn]] inline void Fail(const char* message, unsigned int exit_code = 3) noexcept {
    WriteDiagnostic(message);
    TerminateProcess(GetCurrentProcess(), exit_code);
    std::_Exit(3);
}

inline LONG WINAPI FailUnhandledException(EXCEPTION_POINTERS* exception) noexcept {
    const unsigned int code = exception && exception->ExceptionRecord
        ? exception->ExceptionRecord->ExceptionCode : 0xC0000005u;
    Fail("Fatal native exception in unattended execution.\n", code);
}

#ifdef _MSC_VER
inline void __cdecl FailInvalidParameter(const wchar_t*, const wchar_t*,
                                        const wchar_t*, unsigned int, uintptr_t) noexcept {
    Fail("Fatal invalid CRT parameter in unattended execution.\n");
}

inline void FailAbort(int) noexcept {
    Fail("Fatal abort in unattended execution.\n");
}

#ifdef _DEBUG
inline int __cdecl FailCrtReport(int type, char* message, int*) noexcept {
    if (type != _CRT_ERROR && type != _CRT_ASSERT) {
        return 0;
    }
    WriteDiagnostic("Fatal CRT report: ");
    WriteDiagnostic(message ? message : "unknown\n");
    Fail("\n");
}

inline int __cdecl FailCrtReportWide(int type, wchar_t* message, int*) noexcept {
    if (type != _CRT_ERROR && type != _CRT_ASSERT) {
        return 0;
    }
    WriteDiagnostic("Fatal wide CRT report: ");
    char buffer[2048] = {};
    if (message && WideCharToMultiByte(CP_UTF8, 0, message, -1, buffer,
                                     sizeof(buffer), nullptr, nullptr) > 0) {
        WriteDiagnostic(buffer);
    } else {
        WriteDiagnostic("message unavailable or too long");
    }
    Fail("\n");
}
#endif
#endif
#endif

} // namespace unattended_detail

// Call at startup, before threads. This header executes inside the caller's CRT,
// including independently linked /MT DLLs. Linking does not activate the policy.
inline void ConfigureUnattendedExecution() noexcept {
#ifdef _WIN32
    constexpr UINT flags = SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX |
                           SEM_NOOPENFILEERRORBOX;
    SetErrorMode(GetErrorMode() | flags);
    if (!SetThreadErrorMode(GetThreadErrorMode() | flags, nullptr)) {
        unattended_detail::Fail("Cannot configure unattended thread error mode.\n");
    }
    SetUnhandledExceptionFilter(unattended_detail::FailUnhandledException);
#ifdef _MSC_VER
    _set_error_mode(_OUT_TO_STDERR);
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
    _set_invalid_parameter_handler(unattended_detail::FailInvalidParameter);
    _set_thread_local_invalid_parameter_handler(unattended_detail::FailInvalidParameter);
    if (std::signal(SIGABRT, unattended_detail::FailAbort) == SIG_ERR) {
        unattended_detail::Fail("Cannot configure unattended abort handler.\n");
    }
#ifdef _DEBUG
    for (const int type : {_CRT_WARN, _CRT_ERROR, _CRT_ASSERT}) {
        _CrtSetReportMode(type, _CRTDBG_MODE_FILE);
        _CrtSetReportFile(type, _CRTDBG_FILE_STDERR);
    }
    // Local initialization is explicit and prevents repeated hook installation.
    static bool installed = false;
    if (!installed) {
        if (_CrtSetReportHook2(_CRT_RPTHOOK_INSTALL, unattended_detail::FailCrtReport) < 0 ||
            _CrtSetReportHookW2(_CRT_RPTHOOK_INSTALL, unattended_detail::FailCrtReportWide) < 0) {
            unattended_detail::Fail("Cannot install unattended CRT failure hooks.\n");
        }
        installed = true;
    }
#endif
#endif
#else
    // Keep native fatal signals and exit status. Disable core files only in this
    // process; no signal handler resumes a failed assertion or native crash.
    rlimit limit{};
    if (getrlimit(RLIMIT_CORE, &limit) != 0) {
        std::perror("Cannot query unattended core limit");
        std::_Exit(EXIT_FAILURE);
    }
    limit.rlim_cur = 0;
    if (setrlimit(RLIMIT_CORE, &limit) != 0) {
        std::perror("Cannot configure unattended core limit");
        std::_Exit(EXIT_FAILURE);
    }
#endif
}

inline bool UnattendedExecutionRequested() noexcept {
    const char* explicit_mode = std::getenv("KANO_UNATTENDED");
    if (explicit_mode && *explicit_mode) {
        return !unattended_detail::IsFalseValue(explicit_mode);
    }
    for (const char* name : {"KANO_AGENT_MODE", "CI"}) {
        const char* value = std::getenv(name);
        if (value && *value && !unattended_detail::IsFalseValue(value)) {
            return true;
        }
    }
    return false;
}

// KANO_UNATTENDED=0 explicitly retains human debugging even in an agent/CI env.
// Tests should call ConfigureUnattendedExecution() unconditionally instead.
inline bool ConfigureUnattendedExecutionIfRequested() noexcept {
    const bool requested = UnattendedExecutionRequested();
    if (requested) {
        ConfigureUnattendedExecution();
    }
    return requested;
}

} // namespace kano::infra
