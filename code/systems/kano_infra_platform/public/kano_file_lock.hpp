#pragma once

#include <filesystem>
#include <memory>
#include <optional>

namespace kano::platform {

// Exclusive, nonblocking file lock. An existing regular nonsymlink leaf is
// reused; missing leaves are created privately. The lock file is retained.
// LocalPath ancestry guards are used, not a race-proof filesystem sandbox.
class ExclusiveFileLock {
public:
    ~ExclusiveFileLock();
    ExclusiveFileLock(ExclusiveFileLock&&) noexcept;
    ExclusiveFileLock& operator=(ExclusiveFileLock&&) noexcept;
    ExclusiveFileLock(const ExclusiveFileLock&) = delete;
    ExclusiveFileLock& operator=(const ExclusiveFileLock&) = delete;

    // nullopt means busy only. Other failures throw sanitized runtime_error.
    // POSIX inheritance retains the descriptor across exec; Windows refuses
    // inheritThroughExec because direct process replacement is unsupported.
    static std::optional<ExclusiveFileLock> TryAcquire(
        const std::filesystem::path& InPath, bool InInheritThroughExec = false);

private:
    struct Impl;
    explicit ExclusiveFileLock(std::unique_ptr<Impl> InImpl);
    std::unique_ptr<Impl> mImpl;
};

} // namespace kano::platform
