#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#endif
#include <kano_process_listener.hpp>
#include <kano_process_session.hpp>
#include <charconv>
#include <chrono>
#include <sstream>

namespace kano::process {
ListenerSnapshot MatchLoopbackListeners(unsigned InPort, const std::vector<ListenerRecord>& InRecords) {
    if (!InPort || InPort > 65535 || InRecords.size() > 1) return {};
    if (InRecords.empty()) return {true, 0};
    const auto& record = InRecords.front();
    return record.pid && record.endpoint == "127.0.0.1:" + std::to_string(InPort) ? ListenerSnapshot{true, record.pid} : ListenerSnapshot{};
}
ListenerSnapshot InspectLoopbackListener(unsigned InPort, int InTimeoutMs) {
    if (!InPort || InPort > 65535 || InTimeoutMs <= 0 || InTimeoutMs > 10000) return {};
    std::vector<ListenerRecord> records;
#ifdef _WIN32
    for (const auto family : {AF_INET, AF_INET6}) {
        DWORD count = 0;
        if (GetExtendedTcpTable(nullptr, &count, FALSE, family, TCP_TABLE_OWNER_PID_LISTENER, 0) != ERROR_INSUFFICIENT_BUFFER || count > 4 * 1024 * 1024) return {};
        std::vector<unsigned char> bytes(count);
        if (GetExtendedTcpTable(bytes.data(), &count, FALSE, family, TCP_TABLE_OWNER_PID_LISTENER, 0) != NO_ERROR) return {};
        if (family == AF_INET) {
            const auto* table = reinterpret_cast<const MIB_TCPTABLE_OWNER_PID*>(bytes.data());
            for (DWORD i = 0; i < table->dwNumEntries; ++i) {
                const auto& row = table->table[i];
                if (ntohs(static_cast<u_short>(row.dwLocalPort)) == InPort)
                    records.push_back({row.dwOwningPid, row.dwLocalAddr == htonl(INADDR_LOOPBACK) ? "127.0.0.1:" + std::to_string(InPort) : "foreign"});
            }
        } else {
            const auto* table = reinterpret_cast<const MIB_TCP6TABLE_OWNER_PID*>(bytes.data());
            for (DWORD i = 0; i < table->dwNumEntries; ++i) {
                const auto& row = table->table[i];
                if (ntohs(static_cast<u_short>(row.dwLocalPort)) == InPort) records.push_back({row.dwOwningPid, "ipv6"});
            }
        }
    }
#elif defined(__APPLE__)
    Session session; SessionOptions options;
    options.executable = "/usr/sbin/lsof"; options.working_dir = "/";
    options.arguments = {"-nP", "-iTCP:" + std::to_string(InPort), "-sTCP:LISTEN", "-Fpn"};
    options.environment = {{"LC_ALL", "C"}}; options.startup_timeout_ms = InTimeoutMs;
    options.cleanup_timeout_ms = InTimeoutMs; options.stdout_max_bytes = options.stderr_max_bytes = 32768;
    const auto started = session.Start(options); if (!started.ok) return {};
    std::string output = started.stdout_data; const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(InTimeoutMs);
    bool valid = started.stderr_data.empty() && !started.stdout_truncated && !started.stderr_truncated;
    int code = started.running ? -1 : started.exit_code;
    while (started.running && valid && code == -1 && std::chrono::steady_clock::now() < end) {
        const auto state = session.Poll(10); output += state.stdout_data;
        valid = valid && state.ok && state.stderr_data.empty() && !state.stdout_truncated && !state.stderr_truncated && output.size() <= 32768;
        if (!state.running) { code = state.exit_code; break; }
    }
    const auto closed = session.Close();
    if (!valid || !closed.ok || !closed.cleanup_complete || (code != 0 && !(code == 1 && output.empty()))) return {};
    std::istringstream stream(output); std::string line; std::uint64_t pid = 0; bool pending = false, descriptor = false;
    while (std::getline(stream, line)) {
        if (line.empty()) continue;
        if (line.front() == 'p') {
            if (pending) return {};
            const auto parsed = std::from_chars(line.data() + 1, line.data() + line.size(), pid);
            if (parsed.ec != std::errc{} || parsed.ptr != line.data() + line.size() || !pid) return {};
            pending = true;
        } else if (line.front() == 'f' && pid && !descriptor) {
            // lsof emits the mandatory descriptor field even with -Fpn.
            unsigned fd = 0; const auto parsed = std::from_chars(line.data() + 1, line.data() + line.size(), fd);
            if (parsed.ec != std::errc{} || parsed.ptr != line.data() + line.size()) return {};
            descriptor = true; pending = true;
        } else if (line.front() == 'n' && pid && descriptor) { records.push_back({pid, line.substr(1)}); pending = false; descriptor = false; }
        else return {};
    }
    if (pending) return {};
#else
    return {};
#endif
    return MatchLoopbackListeners(InPort, records);
}
}
