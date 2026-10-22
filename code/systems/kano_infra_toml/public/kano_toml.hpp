#pragma once
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace kano::config {
// Full pinned TOML syntax/duplicate validation. Errors never expose input text.
bool IsValidToml(std::string_view InBytes);
// Update named string/string-array fields in one table, preserving all other
// semantic values. Formatting/comments may change; callers retain raw backups.
// Existing target fields must have the corresponding type. No filesystem IO.
// Refusals throw a fixed sanitized runtime_error, not parser diagnostics.
std::string RewriteTomlTable(
    const std::string& InBytes, const std::vector<std::string>& InTablePath,
    const std::map<std::string,std::string>& InStrings,
    const std::map<std::string,std::vector<std::string>>& InStringArrays);
}
