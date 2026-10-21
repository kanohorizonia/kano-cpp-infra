#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace kano::process {
struct ListenerRecord { std::uint64_t pid; std::string endpoint; };
struct ListenerSnapshot { bool verified = false; std::uint64_t pid = 0; };
// Validates a complete observation; supplied records are not an OS authority.
ListenerSnapshot MatchLoopbackListeners(unsigned InPort, const std::vector<ListenerRecord>& InRecords);
// Windows TCP owner tables or macOS contained lsof. No process mutations.
// Empty verified snapshots prove absence; ambiguous/wildcard/IPv6 fail closed.
ListenerSnapshot InspectLoopbackListener(unsigned InPort, int InTimeoutMs = 2000);
}
