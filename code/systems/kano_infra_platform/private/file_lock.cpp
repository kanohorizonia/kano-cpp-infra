#include "kano_file_lock.hpp"
#include "kano_local_path.hpp"
#include <stdexcept>
#include <utility>
#ifdef _WIN32
#include <windows.h>
#include <sddl.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace kano::platform {
namespace {
[[noreturn]] void Fail() { throw std::runtime_error("Exclusive file lock could not be acquired safely."); }
}
struct ExclusiveFileLock::Impl {
#ifdef _WIN32
    HANDLE handle = INVALID_HANDLE_VALUE;
    ~Impl() { if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }
#else
    int descriptor = -1;
    ~Impl() { if (descriptor >= 0) close(descriptor); }
#endif
};
ExclusiveFileLock::ExclusiveFileLock(std::unique_ptr<Impl> InImpl) : mImpl(std::move(InImpl)) {}
ExclusiveFileLock::~ExclusiveFileLock() = default;
ExclusiveFileLock::ExclusiveFileLock(ExclusiveFileLock&&) noexcept = default;
ExclusiveFileLock& ExclusiveFileLock::operator=(ExclusiveFileLock&&) noexcept = default;
std::optional<ExclusiveFileLock> ExclusiveFileLock::TryAcquire(const std::filesystem::path& InPath, bool InInheritThroughExec) {
    namespace fs = std::filesystem;
    fs::path path;
    try { path = LocalPath(InPath); } catch (...) { Fail(); }
    std::error_code error;
    const auto status = fs::symlink_status(path, error);
    if (error && error != std::errc::no_such_file_or_directory) Fail();
    if (fs::exists(status) && !fs::is_regular_file(status)) Fail();
    auto impl = std::make_unique<Impl>();
#ifdef _WIN32
    if (InInheritThroughExec) Fail();
    // A restrictive share mode is the lock; a separately opened regular leaf
    // cannot race a successful owner without producing a sharing violation.
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;FA;;;SY)(A;;FA;;;OW)", SDDL_REVISION_1, &descriptor, nullptr)) Fail();
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
    impl->handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, &attributes,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    LocalFree(descriptor);
    if (impl->handle == INVALID_HANDLE_VALUE) {
        if (GetLastError() == ERROR_SHARING_VIOLATION || GetLastError() == ERROR_LOCK_VIOLATION) return std::nullopt;
        Fail();
    }
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(impl->handle, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))) Fail();
#else
    int flags = O_RDWR | O_CREAT | O_NOFOLLOW;
    if (!InInheritThroughExec) flags |= O_CLOEXEC;
    impl->descriptor = open(path.c_str(), flags, 0600);
    if (impl->descriptor < 0) Fail();
    struct stat info{};
    if (fstat(impl->descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
        (info.st_mode & 0077) != 0) Fail();
    if (flock(impl->descriptor, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK || errno == EAGAIN) return std::nullopt;
        Fail();
    }
    // Validate the path still names the locked inode. This closes ordinary
    // replacement races, without claiming race-proof ancestor containment.
    struct stat current{};
    if (lstat(path.c_str(), &current) != 0 || !S_ISREG(current.st_mode) ||
        current.st_dev != info.st_dev || current.st_ino != info.st_ino) Fail();
#endif
    return ExclusiveFileLock(std::move(impl));
}
} // namespace kano::platform
