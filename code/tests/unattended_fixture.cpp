#include "kano_unattended.hpp"

// This probe deliberately tests C assert in every runtime/configuration. Normal
// test checks below are independent of NDEBUG and cannot disappear in Release.
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstring>
#include <csignal>

#ifdef _WIN32
extern "C" __declspec(dllimport) int RunIndependentCrtProbe(const char* mode);
#endif

int main(int argc, char** argv) {
#ifdef _WIN32
    const UINT preserved = SEM_NOALIGNMENTFAULTEXCEPT;
    SetErrorMode(GetErrorMode() | preserved);
#endif
    kano::infra::ConfigureUnattendedExecution();
    kano::infra::ConfigureUnattendedExecution();
    const char* mode = argc > 1 ? argv[1] : "normal";
    if (std::strcmp(mode, "normal") == 0) {
#ifdef _WIN32
        if (!(GetErrorMode() & preserved)) {
            std::fputs("Guard discarded the caller error mode.\n", stderr);
            return 10;
        }
#endif
        std::puts("normal completion");
        return 0;
    }
    if (std::strcmp(mode, "requested") == 0) {
        const bool expected = argc > 2 && std::strcmp(argv[2], "1") == 0;
        if (kano::infra::UnattendedExecutionRequested() != expected) {
            std::fputs("Unattended environment policy mismatch.\n", stderr);
            return 11;
        }
        return 0;
    }
    if (std::strcmp(mode, "check") == 0) {
        std::fputs("Always-active check failed.\n", stderr);
        return 12;
    }
    if (std::strcmp(mode, "assert") == 0) {
        assert(false && "Deliberate unattended assertion");
        return 0;
    }
    if (std::strcmp(mode, "abort") == 0) {
        std::fputs("Deliberate unattended abort.\n", stderr);
        std::fflush(stderr);
        std::abort();
    }
    if (std::strcmp(mode, "crash") == 0) {
#ifdef _WIN32
        RaiseException(EXCEPTION_ACCESS_VIOLATION, 0, 0, nullptr);
#else
        raise(SIGSEGV);
#endif
        return 0;
    }
#if defined(_WIN32) && defined(_MSC_VER)
    if (std::strcmp(mode, "invalid") == 0) {
        _invalid_parameter_noinfo();
        return 0;
    }
#ifdef _DEBUG
    if (std::strcmp(mode, "narrow") == 0) {
        _CrtDbgReport(_CRT_ASSERT, __FILE__, __LINE__, nullptr, "Deliberate narrow failure");
        return 0;
    }
    if (std::strcmp(mode, "wide") == 0) {
        _CrtDbgReportW(_CRT_ERROR, L"unattended_fixture.cpp", __LINE__, nullptr,
                      L"Deliberate wide failure");
        return 0;
    }
#endif
    if (std::strcmp(mode, "dll-narrow") == 0) {
        return RunIndependentCrtProbe("narrow");
    }
    if (std::strcmp(mode, "dll-wide") == 0) {
        return RunIndependentCrtProbe("wide");
    }
    if (std::strcmp(mode, "dll-invalid") == 0) {
        return RunIndependentCrtProbe("invalid");
    }
#endif
    std::fputs("Unsupported fixture mode.\n", stderr);
    return 99;
}
