#include "kano_unattended.hpp"
#include <cstring>

extern "C" __declspec(dllexport) int RunIndependentCrtProbe(const char* mode) {
    // /MT DLL state is independent of the executable's /MD CRT. Activation must
    // occur here, after DLL startup and before this DLL's actual native work.
    kano::infra::ConfigureUnattendedExecution();
    std::fputs("Independent CRT DLL configured.\n", stderr);
    std::fflush(stderr);
    if (std::strcmp(mode, "invalid") == 0) {
        _invalid_parameter_noinfo();
        return 0;
    }
#ifdef _DEBUG
    if (std::strcmp(mode, "narrow") == 0) {
        _CrtDbgReport(_CRT_ASSERT, __FILE__, __LINE__, nullptr, "Independent DLL narrow failure");
        return 0;
    }
    if (std::strcmp(mode, "wide") == 0) {
        _CrtDbgReportW(_CRT_ERROR, L"unattended_crt_dll.cpp", __LINE__, nullptr,
                      L"Independent DLL wide failure");
        return 0;
    }
#endif
    return 99;
}
