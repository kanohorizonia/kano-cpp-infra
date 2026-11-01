#include <kano_process.h>
#include <kano_unattended.hpp>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <set>
#include <string>
#ifdef _WIN32
#include <windows.h>
#include <winioctl.h>
#include <cstddef>
#include <cwchar>
#include <vector>
#else
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#ifndef KANO_UNATTENDED_CHILD_PATH
#error KANO_UNATTENDED_CHILD_PATH must name the compiled child fixture
#endif

static int Failures = 0;
static void Check(bool condition, const char* message) {
    if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); ++Failures; }
}

static KanoUnattendedProcessResult Run(const char* mode, int timeout_ms = 2000) {
    const char* args[] = {mode};
    KanoUnattendedProcessOptions options{};
    options.executable = KANO_UNATTENDED_CHILD_PATH;
    options.argv = args;
    options.argv_count = 1;
    options.mode = KANO_PROCESS_MODE_CAPTURE;
    options.timeout_ms = timeout_ms;
    options.cleanup_timeout_ms = 700;
    options.capture_limits = {1024, 512};
    KanoUnattendedProcessResult result{};
    const auto started = std::chrono::steady_clock::now();
    const bool ok = kano_process_run_unattended(&options, &result);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    std::printf("case=%s status=%d exit=%d timeout=%d cleanup=%d error=%lu elapsed=%lld bytes=%zu/%zu\n",
                mode, (int)result.status, result.process.exit_code, result.process.timed_out,
                result.cleanup_complete, result.system_error, result.elapsed_ms,
                result.process.stdout_size, result.process.stderr_size);
    Check(ok == (result.status == KANO_UNATTENDED_PROCESS_COMPLETED), "return matches status");
    Check(elapsed < timeout_ms + options.cleanup_timeout_ms + 1000, "bounded execution elapsed");
    Check(result.elapsed_ms >= 0 && result.elapsed_ms <= elapsed + 50, "monotonic diagnostics");
    Check(result.process.stdout_size <= 1024 && result.process.stderr_size <= 512, "bounded capture");
#ifdef _WIN32
    Check(result.containment == KANO_PROCESS_CONTAINMENT_WINDOWS_JOB, "Windows Job established");
#else
    Check(result.containment == KANO_PROCESS_CONTAINMENT_POSIX_GROUP, "POSIX group established");
#endif
    return result;
}

static bool IsAlive(long pid) {
#ifdef _WIN32
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);
    if (!process) return false;
    const bool alive = WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
    CloseHandle(process);
    return alive;
#else
    return kill((pid_t)pid, 0) == 0 || errno == EPERM;
#endif
}

static size_t CheckCapturedProcessesStopped(const KanoUnattendedProcessResult& result) {
    const std::string output = result.process.stdout_data
        ? std::string(result.process.stdout_data, result.process.stdout_size) : "";
    size_t cursor = 0;
    int count = 0;
    std::set<long> unique_pids;
    while ((cursor = output.find("PID:", cursor)) != std::string::npos) {
        const long pid = std::strtol(output.c_str() + cursor + 4, NULL, 10);
        if (pid > 0) {
#ifdef _WIN32
            if (IsAlive(pid)) std::fprintf(stderr, "alive owned PID:%ld captured=%s\n", pid, output.c_str());
            Check(!IsAlive(pid), "owned process stopped");
#else
            /* A zombie may remain until the platform's orphan reaper runs. */
            Check(!IsAlive(pid) || !result.cleanup_complete, "group cleanup diagnostics match liveness");
#endif
            ++count;
            unique_pids.insert(pid);
        }
        cursor += 4;
    }
    Check(count > 0, "fixture published owned process IDs");
    return unique_pids.size();
}

#ifdef _WIN32
static std::wstring ExtendedPath(const std::wstring& path) {
    return L"\\\\?\\" + path;
}

static std::string AsciiPath(const std::wstring& path) {
    std::string result;
    for (size_t i = 0; i < path.size(); ++i) {
        if (path[i] > 127) return std::string();
        result.push_back((char)path[i]);
    }
    return result;
}

static std::wstring ExistingShortPath(const std::wstring& path) {
    const std::wstring extended = ExtendedPath(path);
    const DWORD size = GetShortPathNameW(extended.c_str(), NULL, 0);
    if (!size) return std::wstring();
    std::vector<wchar_t> buffer(size);
    const DWORD written = GetShortPathNameW(extended.c_str(), &buffer[0], size);
    if (!written || written >= size) return std::wstring();
    std::wstring result(&buffer[0], written);
    if (result.compare(0, 4, L"\\\\?\\") == 0) result.erase(0, 4);
    return result;
}

static std::wstring AbsoluteFixturePath(std::wstring path) {
    for (size_t i = 0; i < path.size(); ++i)
        if (path[i] == L'/') path[i] = L'\\';
    const DWORD size = GetFullPathNameW(path.c_str(), 0, NULL, NULL);
    if (!size) return std::wstring();
    std::vector<wchar_t> buffer(size);
    const DWORD written = GetFullPathNameW(path.c_str(), size, &buffer[0], NULL);
    if (!written || written >= size) return std::wstring();
    return std::wstring(&buffer[0], written);
}

static std::string DirectoryIdentity(const std::wstring& path) {
    HANDLE directory = CreateFileW(ExtendedPath(path).c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (directory == INVALID_HANDLE_VALUE) return std::string();
    FILE_ID_INFO identity{};
    const bool identified = GetFileInformationByHandleEx(
        directory, FileIdInfo, &identity, sizeof(identity)) != FALSE;
    CloseHandle(directory);
    if (!identified) return std::string();
    char volume[18];
    std::snprintf(volume, sizeof(volume), "%016llx:",
                  (unsigned long long)identity.VolumeSerialNumber);
    std::string result(volume);
    for (size_t i = 0; i < sizeof(identity.FileId.Identifier); ++i) {
        char byte[3];
        std::snprintf(byte, sizeof(byte), "%02x", (unsigned int)identity.FileId.Identifier[i]);
        result += byte;
    }
    return result + "\n";
}

class CwdFixture {
public:
    std::wstring root;
    std::vector<std::wstring> directories;
    std::vector<std::wstring> files;
    const char* failure_stage;
    DWORD failure_error;

    CwdFixture() : failure_stage("GetTempPathW"), failure_error(ERROR_SUCCESS) {
        wchar_t temporary[32768];
        const DWORD length = GetTempPathW((DWORD)(sizeof(temporary) / sizeof(temporary[0])), temporary);
        if (!length || length >= sizeof(temporary) / sizeof(temporary[0])) {
            failure_error = !length ? GetLastError() : ERROR_INSUFFICIENT_BUFFER;
            return;
        }
        failure_stage = "GetFullPathNameW(temp)";
        const std::wstring absolute = AbsoluteFixturePath(temporary);
        if (absolute.empty()) { failure_error = GetLastError(); return; }
        failure_stage = "GetShortPathNameW(temp)";
        const std::wstring short_base = ExistingShortPath(absolute);
        if (short_base.empty()) { failure_error = GetLastError(); return; }
        std::wstring base = absolute;
        failure_stage = "temp ASCII local-drive admission";
        if (base.size() < 3 || base[1] != L':' || AsciiPath(base).empty() || AsciiPath(short_base).empty()) {
            failure_error = ERROR_INVALID_NAME;
            return;
        }
        if (base.back() != L'\\') base += L'\\';
        wchar_t name[64];
        std::swprintf(name, sizeof(name) / sizeof(name[0]), L"k147-%lu-%llu",
                      GetCurrentProcessId(), (unsigned long long)GetTickCount64());
        const std::wstring created = base + name;
        failure_stage = "CreateDirectoryW(root)";
        if (!CreateDirectoryW(ExtendedPath(created).c_str(), NULL)) {
            failure_error = GetLastError();
            return;
        }
        directories.push_back(created);
        failure_stage = "GetShortPathNameW(root)";
        const std::wstring short_root = ExistingShortPath(created);
        if (short_root.empty()) { failure_error = GetLastError(); return; }
        root = created;
        failure_stage = "root ASCII/length admission";
        if (root.size() >= 120 || AsciiPath(root).empty() || AsciiPath(short_root).empty()) {
            failure_error = root.size() >= 120 ? ERROR_FILENAME_EXCED_RANGE : ERROR_NO_UNICODE_TRANSLATION;
            root.clear();
        }
    }

    ~CwdFixture() {
        for (size_t i = files.size(); i > 0; --i) {
            const bool removed = DeleteFileW(ExtendedPath(files[i - 1]).c_str()) != FALSE;
            Check(removed || GetLastError() == ERROR_FILE_NOT_FOUND, "owned CWD marker cleanup");
        }
        for (size_t i = directories.size(); i > 0; --i)
            Check(RemoveDirectoryW(ExtendedPath(directories[i - 1]).c_str()) != FALSE,
                  "owned CWD directory cleanup");
    }

    bool AddDirectory(const std::wstring& path) {
        if (!CreateDirectoryW(ExtendedPath(path).c_str(), NULL)) return false;
        directories.push_back(path);
        return true;
    }

    bool RenameDirectory(const std::wstring& from, const std::wstring& to) {
        if (!MoveFileExW(ExtendedPath(from).c_str(), ExtendedPath(to).c_str(), 0)) return false;
        for (size_t i = 0; i < directories.size(); ++i)
            if (directories[i] == from) directories[i] = to;
        return true;
    }
};

class RestoreCurrentDirectory {
public:
    std::vector<wchar_t> original;
    bool changed;
    RestoreCurrentDirectory() : changed(false) {
        const DWORD size = GetCurrentDirectoryW(0, NULL);
        if (!size) return;
        original.resize(size);
        if (!GetCurrentDirectoryW(size, &original[0])) original.clear();
    }
    ~RestoreCurrentDirectory() {
        if (changed) Check(SetCurrentDirectoryW(&original[0]) != FALSE, "test CWD restored");
    }
    bool Set(const std::wstring& path) {
        if (original.empty()) return false;
        changed = SetCurrentDirectoryW(path.c_str()) != FALSE;
        return changed;
    }
};

static bool CapturedIdentity(const KanoProcessResultV2& result, const std::string& expected) {
    return !expected.empty() && result.stdout_data && result.stdout_size == expected.size() &&
           std::memcmp(result.stdout_data, expected.data(), expected.size()) == 0;
}

static KanoUnattendedProcessOptions CwdOptions(const char* cwd, const char* const* args, size_t count) {
    KanoUnattendedProcessOptions options{};
    options.executable = KANO_UNATTENDED_CHILD_PATH;
    options.working_dir = cwd;
    options.argv = args;
    options.argv_count = count;
    options.mode = KANO_PROCESS_MODE_CAPTURE;
    options.timeout_ms = 1000;
    options.cleanup_timeout_ms = 700;
    options.capture_limits = {1024, 512};
    return options;
}

static void CheckCwdIdentity(const std::string& cwd, const std::string& identity, bool unchanged = false) {
    const char* args[] = {"cwd-id", cwd.c_str()};
    const KanoUnattendedProcessOptions options = CwdOptions(cwd.c_str(), args, unchanged ? 2 : 1);
    KanoUnattendedProcessResult result{};
    Check(kano_process_run_unattended(&options, &result) &&
          result.status == KANO_UNATTENDED_PROCESS_COMPLETED && result.process.exit_code == 0 &&
          result.cleanup_complete && CapturedIdentity(result.process, identity),
          "CWD child runs in the requested physical directory");
    kano_process_free_unattended_result(&result);
}

static void CheckCwdRefused(const std::string& cwd, const std::wstring& marker) {
    const std::string marker_arg = AsciiPath(marker);
    const char* args[] = {"mark", marker_arg.c_str()};
    const KanoUnattendedProcessOptions options = CwdOptions(cwd.c_str(), args, 2);
    KanoUnattendedProcessResult result{};
    Check(!kano_process_run_unattended(&options, &result) &&
          result.status == KANO_UNATTENDED_PROCESS_LAUNCH_FAILED && result.system_error != 0 &&
          result.cleanup_complete, "unsupported CWD fails before launch with native diagnostics");
    Check(GetFileAttributesW(ExtendedPath(marker).c_str()) == INVALID_FILE_ATTRIBUTES &&
          GetLastError() == ERROR_FILE_NOT_FOUND, "refused CWD never executes marker child");
    kano_process_free_unattended_result(&result);
}

static bool MakeOwnedJunction(const std::wstring& junction, const std::wstring& target) {
    /* Mount points need no symlink privilege; both endpoints belong to this fixture. */
    struct MountPointBuffer {
        DWORD tag;
        WORD data_length;
        WORD reserved;
        WORD substitute_offset;
        WORD substitute_length;
        WORD print_offset;
        WORD print_length;
        wchar_t path[1024];
    } buffer{};
    const std::wstring substitute = L"\\??\\" + target;
    if (substitute.size() + target.size() + 2 > sizeof(buffer.path) / sizeof(buffer.path[0])) return false;
    buffer.tag = IO_REPARSE_TAG_MOUNT_POINT;
    buffer.substitute_length = (WORD)(substitute.size() * sizeof(wchar_t));
    buffer.print_offset = (WORD)((substitute.size() + 1) * sizeof(wchar_t));
    buffer.print_length = (WORD)(target.size() * sizeof(wchar_t));
    std::memcpy(buffer.path, substitute.c_str(), (substitute.size() + 1) * sizeof(wchar_t));
    std::memcpy((char*)buffer.path + buffer.print_offset, target.c_str(),
                (target.size() + 1) * sizeof(wchar_t));
    buffer.data_length = (WORD)(8 + buffer.print_offset + buffer.print_length + sizeof(wchar_t));
    HANDLE directory = CreateFileW(ExtendedPath(junction).c_str(), GENERIC_WRITE, 0, NULL,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (directory == INVALID_HANDLE_VALUE) return false;
    DWORD returned = 0;
    const bool created = DeviceIoControl(directory, FSCTL_SET_REPARSE_POINT, &buffer,
        (DWORD)(offsetof(MountPointBuffer, path) + buffer.print_offset + buffer.print_length + sizeof(wchar_t)),
        NULL, 0, &returned, NULL) != FALSE;
    CloseHandle(directory);
    return created;
}

static void CheckLongWorkingDirectories() {
    CwdFixture fixture;
    if (fixture.root.empty())
        std::fprintf(stderr, "CWD fixture setup: stage=%s error=%lu\n",
                     fixture.failure_stage, fixture.failure_error);
    Check(!fixture.root.empty(), "fresh ASCII CWD fixture has an existing short root");
    if (fixture.root.empty()) return;

    CheckCwdIdentity(AsciiPath(fixture.root), DirectoryIdentity(fixture.root), true);
    const std::wstring parent = fixture.root + L"\\long-parent-component";
    if (!fixture.AddDirectory(parent)) {
        Check(false, "long CWD parent created");
        return;
    }
    const std::wstring boundary = parent + L"\\" + std::wstring(257 - parent.size(), L'b');
    if (!fixture.AddDirectory(boundary)) {
        Check(false, "258-byte CWD fixture created");
        return;
    }
    const std::string boundary_identity = DirectoryIdentity(boundary);
    CheckCwdIdentity(AsciiPath(boundary), boundary_identity, true);
    CheckCwdIdentity(AsciiPath(boundary + L"\\"), boundary_identity);

    const std::wstring target = parent + L"\\" + std::wstring(269 - parent.size(), L'l');
    if (!fixture.AddDirectory(target)) {
        Check(false, "long CWD fixture created");
        return;
    }
    const std::wstring short_target = ExistingShortPath(target);
    const std::string identity = DirectoryIdentity(target);
    Check(target.size() > 258 && !short_target.empty() && short_target.size() <= 258 &&
          !AsciiPath(short_target).empty() && !identity.empty(), "long CWD has an existing bounded representation");
    if (short_target.empty() || short_target.size() > 258 || identity.empty()) return;
    CheckCwdIdentity(AsciiPath(target), identity);
    CheckCwdIdentity(AsciiPath(target + L"\\"), identity);

    {
        RestoreCurrentDirectory restore;
        const bool changed = restore.Set(parent);
        Check(changed, "relative CWD fixture base selected");
        const std::string relative = AsciiPath(target.substr(parent.size() + 1));
        Check(relative.size() <= 258, "relative supplied CWD remains below the raw limit");
        if (changed) CheckCwdIdentity(relative, identity);
    }

    /* The existing Windows legacy API includes argv[0]; unattended argv omits it. */
    const char* args[] = {KANO_UNATTENDED_CHILD_PATH, "cwd-id"};
    const std::string target_arg = AsciiPath(target);
    KanoProcessOptions legacy{};
    legacy.executable = KANO_UNATTENDED_CHILD_PATH;
    legacy.working_dir = target_arg.c_str();
    legacy.argv = args;
    legacy.argv_count = 2;
    legacy.mode = KANO_PROCESS_MODE_CAPTURE;
    KanoProcess process = kano_process_spawn_ex(&legacy);
    Check(process != NULL, "legacy spawn uses the same long CWD admission");
    if (process) {
        KanoProcessCaptureLimitsV2 limits{1024, 512};
        KanoProcessResultV2 result{};
        const bool waited = kano_process_wait_v2(process, 1000, &limits, &result);
        if (!waited || result.exit_code != 0 || !CapturedIdentity(result, identity)) {
            std::printf("case=legacy-cwd waited=%d exit=%d timeout=%d bytes=%zu/%zu expected=%zu\n",
                waited ? 1 : 0, result.exit_code, result.timed_out ? 1 : 0,
                result.stdout_size, result.stderr_size, identity.size());
            std::printf("legacy-cwd stdout-hex=");
            for (size_t i = 0; i < result.stdout_size; ++i)
                std::printf("%02x", (unsigned int)(unsigned char)result.stdout_data[i]);
            std::printf(" expected-hex=");
            for (size_t i = 0; i < identity.size(); ++i)
                std::printf("%02x", (unsigned int)(unsigned char)identity[i]);
            std::putchar('\n');
        }
        Check(waited && result.exit_code == 0 &&
              CapturedIdentity(result, identity), "legacy long CWD child identity captured");
        const std::wstring renamed = target + L"-renamed";
        const bool moved_while_pinned = fixture.RenameDirectory(target, renamed);
        Check(!moved_while_pinned, "CWD identity remains pinned through process_free");
        kano_process_free_result_v2(&result);
        kano_process_free(process);
        if (moved_while_pinned) {
            const bool restored = fixture.RenameDirectory(renamed, target);
            Check(restored, "unexpected early rename restored");
            if (!restored) return;
        } else {
            const bool moved_after_free = fixture.RenameDirectory(target, renamed);
            Check(moved_after_free, "process_free releases CWD rename protection");
            if (moved_after_free) {
                const bool restored = fixture.RenameDirectory(renamed, target);
                Check(restored, "released CWD directory restored");
                if (!restored) return;
            }
        }
    }

    std::wstring uncompressible = fixture.root;
    std::wstring short_uncompressible;
    for (unsigned int i = 0; i < 40; ++i) {
        wchar_t component[16];
        std::swprintf(component, sizeof(component) / sizeof(component[0]), L"\\d%07u", i);
        uncompressible += component;
        if (!fixture.AddDirectory(uncompressible)) break;
        short_uncompressible = ExistingShortPath(uncompressible);
        if (short_uncompressible.size() > 258) break;
    }
    Check(short_uncompressible.size() > 258, "already-8.3 components have no bounded short representation");
    const std::wstring no_short_marker = fixture.root + L"\\no-short-marker";
    fixture.files.push_back(no_short_marker);
    if (short_uncompressible.size() > 258) CheckCwdRefused(AsciiPath(uncompressible), no_short_marker);

    const std::wstring outside = fixture.root + L"\\outside-canary";
    const std::wstring junction = target + L"\\junction";
    const bool outside_created = fixture.AddDirectory(outside);
    const bool junction_created = fixture.AddDirectory(junction);
    const bool linked = outside_created && junction_created && MakeOwnedJunction(junction, outside);
    Check(linked, "owned long CWD junction fixture created");
    const std::wstring reparse_marker = outside + L"\\reparse-marker";
    fixture.files.push_back(reparse_marker);
    if (linked) CheckCwdRefused(AsciiPath(junction), reparse_marker);
}
#endif

int main() {
    kano::infra::ConfigureUnattendedExecution();
    KanoUnattendedProcessResult result{};
    KanoUnattendedProcessOptions invalid{};
    Check(!kano_process_run_unattended(&invalid, &result), "empty options rejected");
    Check(result.status == KANO_UNATTENDED_PROCESS_INVALID_OPTIONS && result.cleanup_complete,
          "invalid options create no process");
    invalid.executable = KANO_UNATTENDED_CHILD_PATH;
    invalid.timeout_ms = 200;
    invalid.cleanup_timeout_ms = 200;
    invalid.mode = KANO_PROCESS_MODE_CAPTURE;
    Check(!kano_process_run_unattended(&invalid, &result), "unbounded capture rejected");
    invalid.capture_limits = {1024, 512};
    invalid.timeout_ms = 0;
    Check(!kano_process_run_unattended(&invalid, &result), "zero timeout rejected");
    invalid.timeout_ms = 200;
    invalid.cleanup_timeout_ms = 0;
    Check(!kano_process_run_unattended(&invalid, &result), "zero cleanup budget rejected");
    const char* invalid_arg = "unused";
    invalid.cleanup_timeout_ms = 200;
    invalid.argv = &invalid_arg;
    invalid.argv_count = (size_t)-1;
    Check(!kano_process_run_unattended(&invalid, &result), "overflowing argument count rejected");
    kano_process_free_unattended_result(&result);

#ifdef _WIN32
    const char* cmd_args[] = {"/d", "/c", "echo unattended-cmd"};
    KanoUnattendedProcessOptions cmd{};
    cmd.executable = "cmd.exe";
    cmd.argv = cmd_args;
    cmd.argv_count = 3;
    cmd.mode = KANO_PROCESS_MODE_CAPTURE;
    cmd.timeout_ms = 1000;
    cmd.cleanup_timeout_ms = 700;
    cmd.capture_limits = {1024, 512};
    Check(kano_process_run_unattended(&cmd, &result) && result.process.exit_code == 0 &&
          result.cleanup_complete && result.process.stdout_data &&
          std::strstr(result.process.stdout_data, "unattended-cmd"), "cmd payload launch and capture");
    kano_process_free_unattended_result(&result);
    CheckLongWorkingDirectories();
#endif

    result = Run("binary");
    Check(result.status == KANO_UNATTENDED_PROCESS_COMPLETED && result.process.exit_code == 0,
          "normal binary child completed");
    Check(result.process.stdout_size == 3 && result.process.stdout_data &&
          std::memcmp(result.process.stdout_data, "a\0b", 3) == 0, "binary bytes retained");
    Check(result.cleanup_complete, "normal cleanup confirmed");
    kano_process_free_unattended_result(&result);

    const char* passthrough_args[] = {"exit-7"};
    KanoUnattendedProcessOptions passthrough{};
    passthrough.executable = KANO_UNATTENDED_CHILD_PATH;
    passthrough.argv = passthrough_args;
    passthrough.argv_count = 1;
    passthrough.mode = KANO_PROCESS_MODE_PASS_THROUGH;
    passthrough.timeout_ms = 1000;
    passthrough.cleanup_timeout_ms = 700;
    Check(kano_process_run_unattended(&passthrough, &result) && result.process.exit_code == 7 &&
          result.cleanup_complete && !result.process.stdout_data, "finite passthrough child completion");
    kano_process_free_unattended_result(&result);
    result = Run("exit-7");
    Check(result.status == KANO_UNATTENDED_PROCESS_COMPLETED && result.process.exit_code == 7,
          "child failure is distinct from runner failure");
    kano_process_free_unattended_result(&result);
    result = Run("noisy");
    Check(result.status == KANO_UNATTENDED_PROCESS_COMPLETED, "noisy child drained");
    Check(result.process.stdout_truncated && result.process.stderr_truncated, "both capture limits reported");
    kano_process_free_unattended_result(&result);

#ifdef _WIN32
    std::string sentinel_command = std::string("\"") + KANO_UNATTENDED_CHILD_PATH + "\" hang";
    STARTUPINFOA startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION sentinel{};
    Check(CreateProcessA(NULL, &sentinel_command[0], NULL, NULL, FALSE, CREATE_NO_WINDOW,
                         NULL, NULL, &startup, &sentinel) != FALSE, "sentinel launched outside Job");
    const long sentinel_pid = (long)sentinel.dwProcessId;
#else
    const pid_t sentinel_pid = fork();
    if (sentinel_pid == 0) { execl(KANO_UNATTENDED_CHILD_PATH, KANO_UNATTENDED_CHILD_PATH, "hang", (char*)NULL); _exit(127); }
    Check(sentinel_pid > 0, "sentinel launched outside group");
#endif
    for (const char* mode : {"hang", "tree"}) {
        result = Run(mode, 250);
        Check(result.process.timed_out && result.process.exit_code == 124, "hung tree timeout classified");
        Check(result.status != KANO_UNATTENDED_PROCESS_COMPLETED, "timeout never reports success");
#ifdef _WIN32
        Check(result.cleanup_complete, "hung tree cleanup confirmed");
        Check(result.status == KANO_UNATTENDED_PROCESS_TIMED_OUT, "timeout status distinct from cleanup failure");
#endif
        const size_t owned_count = CheckCapturedProcessesStopped(result);
        if (!std::strcmp(mode, "tree")) Check(owned_count >= 3, "child and grandchild fixture observed");
        Check(IsAlive((long)sentinel_pid), "unrelated sentinel survives owned cleanup");
        kano_process_free_unattended_result(&result);
    }
    for (const char* mode : {"early-exit", "early-closed"}) {
        result = Run(mode);
#ifdef _WIN32
        Check(result.status == KANO_UNATTENDED_PROCESS_COMPLETED && result.cleanup_complete,
              "early root exit still cleans descendants");
#else
        Check(result.status == KANO_UNATTENDED_PROCESS_COMPLETED ||
              result.status == KANO_UNATTENDED_PROCESS_CLEANUP_FAILED, "early cleanup classified");
#endif
        CheckCapturedProcessesStopped(result);
        Check(IsAlive((long)sentinel_pid), "sentinel survives early-exit cleanup");
        kano_process_free_unattended_result(&result);
    }
#ifdef _WIN32
    if (sentinel.hProcess) { TerminateProcess(sentinel.hProcess, 0); WaitForSingleObject(sentinel.hProcess, 1000); CloseHandle(sentinel.hProcess); }
    if (sentinel.hThread) CloseHandle(sentinel.hThread);
#else
    if (sentinel_pid > 0) { kill(sentinel_pid, SIGKILL); waitpid(sentinel_pid, NULL, 0); }
    result = Run("escaped-writer");
    Check(result.status == KANO_UNATTENDED_PROCESS_CLEANUP_FAILED && !result.cleanup_complete,
          "escaped inherited writer cannot claim containment cleanup");
    kano_process_free_unattended_result(&result);
#endif

    const std::string marker = std::string(KANO_UNATTENDED_CHILD_PATH) + ".containment-marker";
    std::remove(marker.c_str());
    const char* mark_args[] = {"mark", marker.c_str()};
    KanoUnattendedProcessOptions setup{};
    setup.executable = KANO_UNATTENDED_CHILD_PATH;
    setup.argv = mark_args;
    setup.argv_count = 2;
    setup.mode = KANO_PROCESS_MODE_CAPTURE;
    setup.timeout_ms = 1000;
    setup.cleanup_timeout_ms = 700;
    setup.capture_limits = {1024, 512};
    kano_process_test_fail_next_containment_setup();
    Check(!kano_process_run_unattended(&setup, &result), "injected setup failure rejected");
    Check(result.status == KANO_UNATTENDED_PROCESS_CONTAINMENT_FAILED && result.cleanup_complete,
          "containment setup fails closed and cleans suspended root");
    FILE* unexpected_marker = std::fopen(marker.c_str(), "rb");
    Check(unexpected_marker == NULL, "payload never executed after failed setup");
    if (unexpected_marker) { std::fclose(unexpected_marker); std::remove(marker.c_str()); }
    kano_process_free_unattended_result(&result);
    setup.executable = "kano-nonexistent-test-executable-0017";
    Check(!kano_process_run_unattended(&setup, &result) &&
          result.status == KANO_UNATTENDED_PROCESS_LAUNCH_FAILED, "spawn failure distinct from completion");
    kano_process_free_unattended_result(&result);

    KanoProcessOptions legacy{};
    legacy.executable = KANO_UNATTENDED_CHILD_PATH;
    legacy.mode = KANO_PROCESS_MODE_CAPTURE;
    legacy.timeout_ms = 0;
    KanoProcessResultV2 legacy_result{};
    KanoProcessCaptureLimitsV2 limits{1024, 512};
    Check(kano_process_run_ex_v2(&legacy, &limits, &legacy_result) && !legacy_result.timed_out &&
          legacy_result.exit_code == 0, "legacy timeout zero preserved");
    kano_process_free_result_v2(&legacy_result);
    std::printf("unattended process checks: %s\n", Failures ? "FAILED" : "passed");
    return Failures ? 1 : 0;
}
