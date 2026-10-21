#include <kano_task_scheduler.hpp>
#include <kano_process_session.hpp>
#include <chrono>
#include <algorithm>
#include <memory>
#include <stdexcept>

namespace kano::scheduler {
Json::Value Invoke(const std::filesystem::path& helper, const Json::Value& request, int timeoutMs) {
    if (timeoutMs <= 0 || timeoutMs > 600000) throw std::invalid_argument("Invalid scheduler operation budget.");
    Json::StreamWriterBuilder writer; writer["indentation"] = "";
    const auto input = Json::writeString(writer, request) + "\n";
    if (input.size() > 1024 * 1024) throw std::invalid_argument("Scheduler request exceeds limit.");
    process::SessionOptions options; const auto helperBytes = helper.u8string(); options.executable = {helperBytes.begin(), helperBytes.end()};
    options.startup_timeout_ms = timeoutMs; options.cleanup_timeout_ms = 5000;
    options.stdout_max_bytes = 1024 * 1024; options.stderr_max_bytes = 65536;
    process::Session child;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    auto remaining = [&] { return static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count()); };
    auto result = child.Start(options);
    if (!result.ok) throw std::runtime_error("Scheduler helper could not start: " + result.message);
    std::string output = result.stdout_data;
    result = child.Write(input, std::max(1, remaining())); output += result.stdout_data; child.CloseInput();
    bool failed = !result.ok || result.stdout_truncated || result.stderr_truncated || output.size() > 1024 * 1024;
    while (!failed && result.running && remaining() > 0) {
        result = child.Poll(std::min(50, remaining())); output += result.stdout_data;
        failed = !result.ok || result.stdout_truncated || result.stderr_truncated || output.size() > 1024 * 1024;
    }
    const auto exitCode = result.exit_code;
    const bool timedOut = result.running;
    const auto cleanup = child.Stop(5000);
    if (failed || timedOut || !cleanup.cleanup_complete || exitCode != 0)
        throw std::runtime_error("Scheduler helper failed or timed out; mutation outcome may be unknown. Read back before retry.");
    Json::CharReaderBuilder reader; reader["rejectDupKeys"] = true; reader["failIfExtra"] = true;
    Json::Value value; std::string errors;
    const auto parser = std::unique_ptr<Json::CharReader>(reader.newCharReader());
    if (!parser->parse(output.data(), output.data() + output.size(), &value, &errors) || !value.isObject())
        throw std::runtime_error("Invalid scheduler helper response.");
    if (!value["ok"].asBool()) throw std::runtime_error("Scheduler refused operation: " + value["error"].asString());
    return value;
}
}
