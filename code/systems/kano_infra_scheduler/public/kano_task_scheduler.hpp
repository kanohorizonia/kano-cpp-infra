#pragma once
#include <json/json.h>
#include <filesystem>
#include <string>

namespace kano::scheduler {
// The helper isolates potentially blocking COM calls in a contained Session.
// A timed-out mutation has an unknown outcome: read back before any retry.
Json::Value Invoke(const std::filesystem::path& helper, const Json::Value& request,
                   int timeoutMs = 10000);
}
