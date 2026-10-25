#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace kano::process {

// Creation time is an opaque OS token; compare it only on the same OS/host.
struct Identity {
    std::uint64_t pid = 0;
    std::uint64_t creation_time = 0;
    std::string executable;
};

struct SessionOptions {
    std::string executable;
    std::string working_dir;
    std::vector<std::string> arguments; // excludes executable
    // With inheritance, overrides replace keys and empty values remove them.
    // Without inheritance, these are exact values; empty values stay present.
    // Keys are case-insensitive on Windows and case-sensitive on POSIX.
    std::vector<std::pair<std::string, std::string>> environment;
    int startup_timeout_ms = 10000;
    int cleanup_timeout_ms = 5000;
    std::size_t stdout_max_bytes = 65536; // per operation, both must be positive
    std::size_t stderr_max_bytes = 65536;
    bool inherit_environment = true;
    // Windows contained Sessions only: disable extension points at creation.
    // Unsupported for detached launches and non-Windows Sessions.
    bool disable_extension_points = false;
};

struct SessionResult {
    bool ok = false;
    bool running = false;
    bool cleanup_complete = false;
    int exit_code = -1;
    unsigned long system_error = 0;
    std::string message;
    std::string stdout_data;
    std::string stderr_data;
    bool stdout_truncated = false;
    bool stderr_truncated = false;
};

// Single-owner, single-thread API. No lifetime timeout. Explicit operation
// budgets are monotonic; kernel calls/scheduling can exceed a requested budget.
// Windows: child is suspended until a kill-on-close Job owns it. Child stdin,
// stdout and stderr are the only inherited handles. Owner death kills the Job.
// POSIX: executable is an absolute UTF-8 path; argv/cwd/environment pass as
// exact UTF-8 bytes through execve. A process group owns non-escaping children.
// Poll observes exit without reaping; Stop signals before reaping the root.
// The caller must retain normal SIGCHLD wait ownership for the Session.
class Session {
public:
    Session();
    ~Session();
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;
    Session(Session&&) noexcept;
    Session& operator=(Session&&) noexcept;

    // Unconfirmed failed-launch cleanup is sticky: Stop/Close cannot later
    // claim completion without proof, and this Session cannot be reused.
    SessionResult Start(const SessionOptions& InOptions);
    // A partial/failed write is not retried internally; caller must stop or
    // recover its protocol. Cancellation has a separate cleanup budget; an
    // unconfirmed cancellation closes input and prevents successful cleanup.
    SessionResult Write(const std::string& InData, int InTimeoutMs);
    void CloseInput();
    // Returns bounded incremental raw bytes, draining both streams fairly.
    // A zero timeout performs one nonblocking drain; positive waits return
    // when output, EOF, process exit, or the operation deadline is observed.
    SessionResult Poll(int InTimeoutMs = 0);
    bool IsRunning() const;
    // POSIX reports the owned PID/executable with creation_time=0; general
    // QueryIdentity/IsAlive remain Windows-only and cannot validate that token.
    Identity GetIdentity() const;
    // Immediately terminates only the owned Job/group and confirms its members,
    // root and capture writers have stopped within the cleanup budget.
    SessionResult Stop(int InTimeoutMs);
    SessionResult Close();

private:
    struct Impl;
    std::unique_ptr<Impl> mImpl;
};

struct DetachedResult {
    bool ok = false;
    Identity identity;
    unsigned long system_error = 0;
    std::string message;
};

// No inherited handles or new per-launch owner Job. Survives immediate caller
// exit, while retaining any OS-imposed ancestor Job boundary. The detached
// executable must establish ownership of its own worker processes.
DetachedResult LaunchDetached(const SessionOptions& InOptions);
bool QueryIdentity(std::uint64_t InPid, Identity& OutIdentity, std::string& OutError);
Identity CurrentIdentity();
bool IsAlive(const Identity& InIdentity);
// Read-only parent PID with exact child identity checked before/after snapshot.
bool QueryParent(const Identity& InIdentity, std::uint64_t& OutParent);

} // namespace kano::process
